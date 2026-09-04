#!/usr/bin/env bash
# dev-setup-kubevirtbmc.sh
#
# Completes the Metal3 stack setup on top of an existing Kind cluster
# that already has KubeVirt, CDI, and cert-manager deployed.
#
# Prerequisites:
#   - Kind cluster named kubevirtbmc-test with /dev/kvm passthrough
#   - KubeVirt with DeclarativeHotplugVolumes feature gate enabled
#   - CDI with StorageProfile configured for local-path
#   - cert-manager
#   - The patched kubevirtbmc source at ../../kubevirtbmc on branch
#     lentzi90/metal3-fixes-v0.10.0 (this script builds and loads the images)
#
# This script:
#   0. Cleans up leftover test resources from previous runs
#   1. Builds the patched kubevirtbmc controller and agent images and
#      loads them into the Kind cluster
#   2. Deploys (or redeploys) KubeVirtBMC with the patched images
#   3. Prepares the OS image and deploys the in-cluster image server
#   3b. Installs Multus + a Linux-bridge "baremetal-net" NetworkAttachmentDefinition
#      giving VMs a second NIC on a real L2 network, used for kube-vip
#   4. Installs CAPI + Metal3 infrastructure provider + Metal3 IPAM
#   5. Installs IrSO (Ironic Standalone Operator)
#   6. Installs Ironic (with TLS, via cert-manager), then bakes its CA cert
#      directly into the cdi-importer and virtbmc agent images (see
#      Metal3/ironic-ca-images/) so both trust Ironic's HTTPS endpoint with
#      no certConfigMap, env var, or admission webhook required
#   7. Installs BMO (Bare Metal Operator)
#   8. Applies setup-scripts (install-k8s secret)

set -eux

REPO_ROOT=$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")
cd "${REPO_ROOT}" || exit 1

IMAGE_DIR="${REPO_ROOT}/Metal3/images"
CLUSTER_NAME="${CLUSTER_NAME:-kubevirtbmc-test}"
KIND_NODE="${CLUSTER_NAME}-control-plane"

KUBEVIRTBMC_REPO="${KUBEVIRTBMC_REPO:-${REPO_ROOT}/kubevirtbmc}"
CONTROLLER_IMAGE="${CONTROLLER_IMAGE:-kubevirtbmc/virtbmc-controller:metal3-patch}"
AGENT_IMAGE="${AGENT_IMAGE:-kubevirtbmc/virtbmc:metal3-patch}"

echo "=== Step 0: Clean up test resources from previous runs ==="
kubectl delete bmh --all --ignore-not-found 2>/dev/null || true
kubectl delete virtualmachinebmc --all --ignore-not-found 2>/dev/null || true
kubectl delete vm --all --ignore-not-found 2>/dev/null || true
kubectl delete pvc --all --ignore-not-found 2>/dev/null || true

echo "=== Step 1: Build patched kubevirtbmc images ==="
if [ ! -d "${KUBEVIRTBMC_REPO}" ]; then
  echo "ERROR: kubevirtbmc source not found at ${KUBEVIRTBMC_REPO}"
  echo "Clone it and check out branch lentzi90/metal3-fixes-v0.10.0."
  exit 1
fi
pushd "${KUBEVIRTBMC_REPO}"
echo "Building controller image: ${CONTROLLER_IMAGE}"
docker build -t "${CONTROLLER_IMAGE}" .
echo "Building agent image: ${AGENT_IMAGE}"
docker build -f Dockerfile.virtbmc -t "${AGENT_IMAGE}" .
popd

echo "=== Step 2: Load patched images into Kind ==="
kind load docker-image "${CONTROLLER_IMAGE}" --name "${CLUSTER_NAME}"
kind load docker-image "${AGENT_IMAGE}" --name "${CLUSTER_NAME}"

echo "=== Step 3: Deploy (or redeploy) KubeVirtBMC with patched images ==="
# Render the kustomize manifests, substitute the placeholder controller image
# (config/manager/manager.yaml uses "image: controller:latest" as a placeholder
# that make deploy normally overrides via kustomize edit), and apply.
pushd "${KUBEVIRTBMC_REPO}"
kubectl kustomize config/default | \
  sed "s|image: starbops/virtbmc-controller:[^ ]*|image: ${CONTROLLER_IMAGE}|g" | \
  kubectl apply -f -
popd
# Belt-and-suspenders: explicitly set the controller image in case the sed
# substitution missed any variant of the upstream placeholder tag.
kubectl set image deployment/kubevirtbmc-controller-manager \
  manager="${CONTROLLER_IMAGE}" \
  -n kubevirtbmc-system
# Append the agent image name and tag to the controller's args so that
# VirtualMachineBMC pods are spawned with our locally-built agent image.
# We use the JSON Patch "add" op with path "/-" to append (not replace).
# Guard with || true so a re-run (where the args already exist) doesn't fail.
EXISTING_ARGS=$(kubectl get deployment kubevirtbmc-controller-manager \
  -n kubevirtbmc-system \
  -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null || echo "")
if ! echo "${EXISTING_ARGS}" | grep -q "agent-image-name"; then
  kubectl patch deployment kubevirtbmc-controller-manager \
    -n kubevirtbmc-system \
    --type=json \
    -p "[
      {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"--agent-image-name=kubevirtbmc/virtbmc\"},
      {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"--agent-image-tag=metal3-patch\"}
    ]"
fi
# Wait for the controller rollout to complete (allow extra time for cert-manager
# to issue the webhook-server-cert secret on first deploy).
kubectl -n kubevirtbmc-system rollout status deployment/kubevirtbmc-controller-manager --timeout=180s

echo "=== Step 4: Configure CDI for local-path storage ==="
# As of KubeVirtBMC v0.9.0, DataVolumes are created with the
# cdi.kubevirt.io/storage.bind.immediate.requested annotation (upstream
# commit c0aa9de), so the default Kind StorageClass ("standard", which uses
# WaitForFirstConsumer) now binds PVCs immediately without needing a
# dedicated Immediate-binding StorageClass or a pvc-annotator workaround.
#
# Ensure CDI knows the access mode and volume mode for the storage class.
# Without this, DataVolume imports may stay in WaitForFirstConsumer indefinitely
# or fail with filesystem overhead errors.
kubectl patch storageprofile standard \
  --type=merge \
  -p '{"spec":{"claimPropertySets":[{"accessModes":["ReadWriteOnce"],"volumeMode":"Filesystem"}]}}'

# Increase CDI filesystem overhead so the IPA deploy ISO (~530 MB) fits in a
# PVC sized exactly to the file. CDI reserves a fraction of the PVC for
# filesystem metadata; 15% covers ext4 overhead on the local-path volumes.
kubectl patch cdi cdi --type=merge \
  -p '{"spec":{"config":{"filesystemOverhead":{"global":"0.15"}}}}'

echo "=== Step 5: Prepare OS image ==="
mkdir -p "${IMAGE_DIR}"
if [ ! -f "${IMAGE_DIR}/ubuntu-2404.img" ]; then
  echo "Downloading Ubuntu 24.04 cloud image..."
  wget -O "${IMAGE_DIR}/ubuntu-2404.img" \
    https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img
fi

echo "Calculating checksum..."
pushd "${IMAGE_DIR}"
sha256sum ubuntu-2404.img > ubuntu-2404.img.sha256sum
popd

echo "Copying image into Kind node..."
docker exec "${KIND_NODE}" mkdir -p /tmp/metal3-images
docker exec -i "${KIND_NODE}" bash -c "cat > /tmp/metal3-images/ubuntu-2404.img" \
  < "${IMAGE_DIR}/ubuntu-2404.img"
docker exec -i "${KIND_NODE}" bash -c "cat > /tmp/metal3-images/ubuntu-2404.img.sha256sum" \
  < "${IMAGE_DIR}/ubuntu-2404.img.sha256sum"

echo "=== Step 6: Deploy image server ==="
kubectl apply -f "${REPO_ROOT}/Metal3/image-server-kubevirt.yaml"
kubectl wait --for=condition=Available --timeout=120s deployment/image-server

echo "=== Step 6b: Install Multus + baremetal-net bridge network ==="
# Gives VMs a second NIC on a real Linux bridge (genuine L2/broadcast
# domain), used for kube-vip's ARP-mode VIP. See
# kubevirt-baremetal-network.yaml for the full rationale and address plan.

# Kind node images only ship kindnet's own ptp/host-local/loopback/portmap
# CNI binaries -- the plain "bridge" plugin used by the NetworkAttachmentDefinition
# below must be installed manually.
CNI_PLUGINS_VERSION="${CNI_PLUGINS_VERSION:-v1.5.1}"
CNI_PLUGINS_DIR="$(mktemp -d)"
curl -sL "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-amd64-${CNI_PLUGINS_VERSION}.tgz" \
  -o "${CNI_PLUGINS_DIR}/cni-plugins.tgz"
tar -xzf "${CNI_PLUGINS_DIR}/cni-plugins.tgz" -C "${CNI_PLUGINS_DIR}" ./bridge
docker cp "${CNI_PLUGINS_DIR}/bridge" "${KIND_NODE}":/opt/cni/bin/bridge
rm -rf "${CNI_PLUGINS_DIR}"

# Install Multus (thick daemonset, vendored from the upstream quickstart at
# https://github.com/k8snetworkplumbingwg/multus-cni).
kubectl apply -f "${REPO_ROOT}/Metal3/multus-daemonset-thick.yaml"
kubectl -n kube-system rollout status daemonset/kube-multus-ds --timeout=120s

# Create the baremetal-net NetworkAttachmentDefinition.
kubectl apply -f "${REPO_ROOT}/Metal3/kubevirt-baremetal-network.yaml"

echo "=== Step 7: Install CAPI + Metal3 ==="
kubectl create namespace baremetal-operator-system 2>/dev/null || true

export CLUSTER_TOPOLOGY=true
clusterctl init --infrastructure=metal3 --ipam=metal3

echo "=== Step 8: Install IrSO ==="
kubectl apply -k "${REPO_ROOT}/Metal3/irso"
kubectl -n ironic-standalone-operator-system wait --timeout=5m \
  --for=condition=Available deploy/ironic-standalone-operator-controller-manager

echo "=== Step 9: Install Ironic (with TLS) ==="
# Apply with retry logic (webhook may not be ready immediately)
MAX_RETRIES=5
RETRY_DELAY=10
RETRY_COUNT=0
echo "Applying Ironic configuration..."
while [ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]; do
  if kubectl apply -k "${REPO_ROOT}/Metal3/ironic-kubevirt"; then
    echo "Successfully applied Ironic configuration"
    break
  else
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "Retry ${RETRY_COUNT}/${MAX_RETRIES} in ${RETRY_DELAY}s..."
    sleep ${RETRY_DELAY}
  fi
done
if [ ${RETRY_COUNT} -eq ${MAX_RETRIES} ]; then
  echo "ERROR: Failed to apply Ironic configuration after ${MAX_RETRIES} attempts."
  exit 1
fi

echo "=== Step 9b: Bake Ironic's CA cert into cdi-importer and virtbmc images ==="
# Both the CDI importer (which downloads the IPA deploy ISO / OS image over
# HTTPS) and the virtbmc agent (which calls GetRemoteFileSize over HTTPS)
# need to trust Ironic's cert-manager-issued certificate. Rather than a
# DataVolume certConfigMap, an agent env var, or a mutating admission
# webhook, the CA is baked directly into both images' trust stores (see
# Metal3/ironic-ca-images/README.md) — no runtime trust-propagation
# machinery needed at all.
kubectl wait --for=condition=Ready --timeout=120s \
  certificate/ironic-cacert -n baremetal-operator-system
CA_IMAGES_DIR="${REPO_ROOT}/Metal3/ironic-ca-images"
kubectl get secret ironic-cacert -n baremetal-operator-system \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > "${CA_IMAGES_DIR}/ironic-ca.crt"

IMPORTER_CA_IMAGE="${IMPORTER_CA_IMAGE:-cdi-importer:ironic-ca}"
AGENT_CA_IMAGE="${AGENT_CA_IMAGE:-kubevirtbmc/virtbmc:metal3-patch-ca}"

docker build -f "${CA_IMAGES_DIR}/Dockerfile.cdi-importer" \
  --build-arg CDI_IMPORTER_IMAGE=quay.io/kubevirt/cdi-importer:v1.65.0 \
  -t "${IMPORTER_CA_IMAGE}" "${CA_IMAGES_DIR}"
docker build -f "${CA_IMAGES_DIR}/Dockerfile.virtbmc-agent" \
  --build-arg VIRTBMC_AGENT_IMAGE="${AGENT_IMAGE}" \
  -t "${AGENT_CA_IMAGE}" "${CA_IMAGES_DIR}"
rm -f "${CA_IMAGES_DIR}/ironic-ca.crt"

kind load docker-image "${IMPORTER_CA_IMAGE}" --name "${CLUSTER_NAME}"
kind load docker-image "${AGENT_CA_IMAGE}" --name "${CLUSTER_NAME}"

# Point CDI's importer pods at the CA-trusting variant.
kubectl -n cdi set env deployment/cdi-operator \
  IMPORTER_IMAGE="${IMPORTER_CA_IMAGE}"

# Point KubeVirtBMC's agent pods at the CA-trusting variant by rewriting the
# --agent-image-tag arg in place (index-independent, so it's safe even if
# the controller's arg list changes upstream).
AGENT_CA_TAG="${AGENT_CA_IMAGE#*:}"
kubectl get deployment kubevirtbmc-controller-manager -n kubevirtbmc-system -o json | \
  python3 -c "
import json, sys
dep = json.load(sys.stdin)
args = dep['spec']['template']['spec']['containers'][0]['args']
dep['spec']['template']['spec']['containers'][0]['args'] = [
    '--agent-image-tag=${AGENT_CA_TAG}' if a.startswith('--agent-image-tag=') else a
    for a in args
]
print(json.dumps(dep))
" | kubectl apply -f -
kubectl -n kubevirtbmc-system rollout status deployment/kubevirtbmc-controller-manager --timeout=180s

echo "=== Step 10: Install BMO ==="
kubectl apply -k "${REPO_ROOT}/Metal3/bmo"

echo "=== Step 11: Apply setup-scripts ==="
kubectl apply -k "${REPO_ROOT}/setup-scripts"

echo "=== Step 12: Ensure bmc-creds secret ==="
kubectl get secret bmc-creds 2>/dev/null || \
  kubectl create secret generic bmc-creds \
    --from-literal=username=admin --from-literal=password=password

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo ""
echo "  Phase 1 — BMH Inspection:"
echo "    1. Wait for Ironic to be ready:"
echo "         kubectl wait --for=condition=Available --timeout=300s \\"
echo "           deployment/ironic-service -n baremetal-operator-system"
echo "    2. Create a single VM+BMH (inspection enabled by default):"
echo "         NUM_BMH=1 ./Metal3/create-kubevirt-bmhs.sh"
echo "    3. Watch the BMH lifecycle (expect: registering → inspecting → available):"
echo "         kubectl get bmh -w"
echo "    4. Monitor IPA ramdisk download:"
echo "         kubectl get dv -w"
echo "    5. Monitor Ironic / KubeVirtBMC logs:"
echo "         kubectl logs -n baremetal-operator-system deploy/ironic-service -f --tail=50"
echo "         kubectl logs -l app=virtbmc -f --tail=50"
echo ""
echo "  Phase 2 — BMH Provisioning (after Phase 1):"
echo "    1. Patch the BMH directly to trigger provisioning:"
echo "         kubectl patch bmh kubevirt-node-0 --type=merge \\"
echo "           -p '{\"spec\":{\"image\":{\"url\":\"http://10.96.200.200:8080/ubuntu-2404.img\",\"checksum\":\"http://10.96.200.200:8080/ubuntu-2404.img.sha256sum\",\"checksumType\":\"sha256\"},\"userData\":{\"name\":\"user-data\",\"namespace\":\"default\"}}}'"
echo ""
echo "  Phase 3 — Workload Cluster (after Phase 1+2 validated):"
echo "    1. Apply the network-fixups DaemonSet (proxy_arp for the pod network,"
echo "       rp_filter loosening for the baremetal-net/kube-vip path):"
echo "         kubectl apply -f Metal3/kubevirtbmc-test/network-fixups-daemonset.yaml"
echo "    2. Create 2 VMs+BMHs and apply the cluster:"
echo "         NUM_BMH=2 ./Metal3/create-kubevirt-bmhs.sh"
echo "         kubectl apply -k Metal3/cluster-kubevirt"
