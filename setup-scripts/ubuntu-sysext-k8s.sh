#!/usr/bin/env bash

# https://github.com/kubernetes-sigs/cri-tools/releases
CRICTL_VERSION="v1.33.0"
# https://github.com/kubernetes/kubernetes/releases
KUBERNETES_VERSION="v1.33.0"
# https://github.com/cri-o/cri-o/releases
CRIO_VERSION="v1.32.4"

apt-get install -y conntrack socat
# Install crictl
curl -sSL -o /tmp/crictl.tar.gz https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz
tar --extract --file /tmp/crictl.tar.gz
mv crictl /usr/local/bin/
# Folders where we store the raw files
mkdir -p /opt/extensions/crio
mkdir -p /opt/extensions/kubernetes
# Folder where systemd-sysext will look for the images
mkdir -p /var/lib/extensions
curl -o /opt/extensions/crio/crio-${CRIO_VERSION}.raw -L https://github.com/flatcar/sysext-bakery/releases/download/latest/crio-${CRIO_VERSION}-x86-64.raw
curl -o /opt/extensions/kubernetes/kubernetes-${KUBERNETES_VERSION}.raw -L https://github.com/flatcar/sysext-bakery/releases/download/latest/kubernetes-${KUBERNETES_VERSION}-x86-64.raw
ln -s /opt/extensions/crio/crio-${CRIO_VERSION}.raw /var/lib/extensions/crio.raw
ln -s /opt/extensions/kubernetes/kubernetes-${KUBERNETES_VERSION}.raw /var/lib/extensions/kubernetes.raw
systemctl enable --now systemd-sysext
systemctl restart systemd-sysext
# Make sure crio is running before continuingt o kubeadm init
systemctl enable --now crio
# Apply sysctl settings (ip forwarding)
sysctl --system
