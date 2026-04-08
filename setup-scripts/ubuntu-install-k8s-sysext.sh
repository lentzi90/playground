#!/usr/bin/env bash
# Install Kubernetes and containerd on Ubuntu using systemd-sysext overlays
# from Flatcar's sysext-bakery (extensions.flatcar.org).
#
# This approach avoids installing packages via apt and instead uses squashfs
# sysext images that overlay binaries into /usr.
#
# Required environment variables:
#   KUBERNETES_VERSION - e.g. "v1.35.2"
#
# Optional environment variables:
#   CONTAINERD_VERSION - e.g. "2.0.5" (no "v" prefix, default: "2.0.5")
#   ARCH               - e.g. "x86-64" (default: "x86-64")

set -euo pipefail

###############################################################################
# Configuration
###############################################################################

KUBERNETES_VERSION="${KUBERNETES_VERSION:?KUBERNETES_VERSION must be set (e.g. v1.35.2)}"
CONTAINERD_VERSION="${CONTAINERD_VERSION:-2.0.5}"
ARCH="${ARCH:-x86-64}"

# Derived variables
# Note: Kubernetes releases use the "v" prefix (e.g. kubernetes-v1.32.13-x86-64.raw)
# while containerd releases do not (e.g. containerd-2.0.5-x86-64.raw).
KUBE_VERSION="${KUBERNETES_VERSION#v}"          # strip leading "v" → "1.32.13"
KUBE_MAJOR_MINOR="${KUBE_VERSION%.*}"           # e.g. "1.32"

SYSEXT_BASE_URL="https://extensions.flatcar.org/extensions"

echo "======================================================================"
echo "Installing Kubernetes ${KUBERNETES_VERSION} and containerd ${CONTAINERD_VERSION}"
echo "Architecture: ${ARCH}"
echo "======================================================================"

###############################################################################
# Helper: repackage_sysext
#
# Flatcar sysext images ship with ID=flatcar in their extension-release files.
# Ubuntu's systemd-sysext requires the ID to match the host OS. We repackage
# the image with ID=_any so it works on any distribution.
#
# Usage: repackage_sysext <name> <version> <arch> <source_raw_path>
###############################################################################
repackage_sysext() {
    local name="$1"
    local version="$2"
    local arch="$3"
    local src_raw="$4"

    local dest_dir="/opt/extensions/${name}"
    local dest_raw="${dest_dir}/${name}-${version}-${arch}.raw"
    local tmp_dir
    tmp_dir=$(mktemp -d "/tmp/sysext-${name}-XXXXXX")

    echo "  Repackaging ${name} sysext with ID=_any ..."

    # Extract the squashfs image
    unsquashfs -d "${tmp_dir}/squashfs-root" "${src_raw}"

    # Replace all extension-release files with ID=_any
    find "${tmp_dir}/squashfs-root" -path "*/extension-release.d/*" -type f | while read -r relfile; do
        echo "ID=_any" > "${relfile}"
    done

    # Recreate the squashfs image
    mkdir -p "${dest_dir}"
    mksquashfs "${tmp_dir}/squashfs-root" "${dest_raw}" -noappend -quiet

    # Create the symlink in /etc/extensions/
    mkdir -p /etc/extensions
    ln -sf "${dest_raw}" "/etc/extensions/${name}.raw"

    # Cleanup
    rm -rf "${tmp_dir}" "${src_raw}"

    echo "  Installed ${dest_raw}"
    echo "  Symlinked /etc/extensions/${name}.raw -> ${dest_raw}"
}

###############################################################################
# Phase 1 — Kernel modules and sysctl prerequisites
###############################################################################
echo ""
echo "--- Phase 1: Kernel modules and sysctl prerequisites ---"

modprobe overlay
modprobe br_netfilter

cat <<EOF > /etc/modules-load.d/kubernetes.conf
overlay
br_netfilter
EOF

cat <<EOF > /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

###############################################################################
# Phase 2 — Install squashfs-tools (needed for repackaging sysexts)
###############################################################################
echo ""
echo "--- Phase 2: Installing squashfs-tools ---"

apt-get update -qq
apt-get install -y -qq squashfs-tools

###############################################################################
# Phase 3 — Download and install containerd sysext
###############################################################################
echo ""
echo "--- Phase 3: Containerd sysext (${CONTAINERD_VERSION}) ---"

CONTAINERD_RAW_URL="${SYSEXT_BASE_URL}/containerd/containerd-${CONTAINERD_VERSION}-${ARCH}.raw"
CONTAINERD_TMP_RAW="/tmp/containerd-${CONTAINERD_VERSION}-${ARCH}.raw"

echo "  Downloading ${CONTAINERD_RAW_URL} ..."
curl -fsSL -o "${CONTAINERD_TMP_RAW}" "${CONTAINERD_RAW_URL}"

repackage_sysext "containerd" "${CONTAINERD_VERSION}" "${ARCH}" "${CONTAINERD_TMP_RAW}"

# Download sysupdate configuration (best-effort)
mkdir -p /etc/sysupdate.containerd.d
curl -fsSL -o /etc/sysupdate.containerd.d/containerd.conf \
    "${SYSEXT_BASE_URL}/containerd/containerd.conf" 2>/dev/null || true

###############################################################################
# Phase 4 — Download and install kubernetes sysext
###############################################################################
echo ""
echo "--- Phase 4: Kubernetes sysext (${KUBERNETES_VERSION}) ---"

KUBE_RAW_URL="${SYSEXT_BASE_URL}/kubernetes/kubernetes-${KUBERNETES_VERSION}-${ARCH}.raw"
KUBE_TMP_RAW="/tmp/kubernetes-${KUBERNETES_VERSION}-${ARCH}.raw"

echo "  Downloading ${KUBE_RAW_URL} ..."
curl -fsSL -o "${KUBE_TMP_RAW}" "${KUBE_RAW_URL}"

repackage_sysext "kubernetes" "${KUBERNETES_VERSION}" "${ARCH}" "${KUBE_TMP_RAW}"

# Download sysupdate configurations (best-effort)
mkdir -p /etc/sysupdate.kubernetes.d
curl -fsSL -o "/etc/sysupdate.kubernetes.d/kubernetes-v${KUBE_MAJOR_MINOR}.conf" \
    "${SYSEXT_BASE_URL}/kubernetes/kubernetes-v${KUBE_MAJOR_MINOR}.conf" 2>/dev/null || true

mkdir -p /etc/sysupdate.d
curl -fsSL -o /etc/sysupdate.d/noop.conf \
    "${SYSEXT_BASE_URL}/noop.conf" 2>/dev/null || true

###############################################################################
# Phase 5 — Activate and configure
###############################################################################
echo ""
echo "--- Phase 5: Activate sysexts and configure services ---"

# Activate all sysext images
systemd-sysext refresh

# Configure containerd with SystemdCgroup
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Start and enable containerd
systemctl restart containerd
systemctl enable containerd

# Reload systemd and enable kubelet
systemctl daemon-reload
systemctl enable kubelet

echo ""
echo "======================================================================"
echo "Done! Kubernetes ${KUBERNETES_VERSION} and containerd ${CONTAINERD_VERSION}"
echo "are installed via systemd-sysext overlays."
echo "======================================================================"
