#!/usr/bin/env bash

set -eux

REPO_ROOT=$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")
cd "${REPO_ROOT}" || exit 1

virsh -c qemu:///system net-define "${REPO_ROOT}/Metal3/net.xml"
virsh -c qemu:///system net-start baremetal-e2e

# First time setup
# docker network rm kind
# docker network create -d=bridge \
#     -o com.docker.network.bridge.enable_ip_masquerade=true \
#     -o com.docker.network.driver.mtu=1500 \
#     -o com.docker.network.bridge.name="kind" \
#     --ipv6 --subnet "fc00:f853:ccd:e793::/64" \
#     kind

sudo ip link add metalend type veth peer name kindend
sudo ip link set metalend master metal3
sudo ip link set kindend master kind
sudo ip link set metalend up
sudo ip link set kindend up

sudo iptables -I FORWARD -i kind -o metal3 -j ACCEPT
sudo iptables -I FORWARD -i metal3 -o kind -j ACCEPT

# Create a kind cluster using the configuration from kind.yaml
kind create cluster --config "${REPO_ROOT}/Metal3/kind.yaml"

# TODO: This is needed because dnsmasq checks if the DHCP address range
# is available. Keepalived only assigns a /32 single address and then
# dnsmasq errors with:
# dnsmasq-dhcp: no address range available for DHCP request via eth0
docker exec kind-control-plane ip addr add 192.168.222.2/24 dev eth0

# Start sushy-tools container to provide Redfish BMC emulation
docker run --name sushy-tools --rm --network host -d \
  -v /var/run/libvirt:/var/run/libvirt \
  -v "${REPO_ROOT}/Metal3/sushy-tools.conf:/etc/sushy/sushy-emulator.conf" \
  -e SUSHY_EMULATOR_CONFIG=/etc/sushy/sushy-emulator.conf \
  quay.io/metal3-io/sushy-tools:latest sushy-emulator

# Image server variables
IMAGE_DIR="${REPO_ROOT}/Metal3/images"

## Run the image server
mkdir -p "${IMAGE_DIR}"
docker run --name image-server-e2e -d \
  -p 80:8080 \
  -v "${IMAGE_DIR}:/usr/share/nginx/html" nginxinc/nginx-unprivileged

kubectl create namespace baremetal-operator-system

# If you want to use ClusterClasses
export CLUSTER_TOPOLOGY=true

clusterctl init --infrastructure=metal3 --ipam=metal3
kubectl apply -k "${REPO_ROOT}/Metal3/irso"
kubectl -n ironic-standalone-operator-system wait --timeout=5m --for=condition=Available deploy/ironic-standalone-operator-controller-manager

# Apply Ironic with retry logic (up to 5 attempts with 10 second delays).
# The IrSO webhook is not guaranteed to be ready when the IrSO deployment is,
# so some retries may be needed.
MAX_RETRIES=5
RETRY_DELAY=10
RETRY_COUNT=0
echo "Applying Ironic configuration..."
while [ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]; do
  if kubectl apply -k "${REPO_ROOT}/Metal3/ironic"; then
    echo "Successfully applied Ironic configuration"
    break
  else
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "Failed to apply Ironic configuration. Retrying in ${RETRY_DELAY} seconds... (Attempt ${RETRY_COUNT}/${MAX_RETRIES})"
    sleep ${RETRY_DELAY}
  fi
done
if [ ${RETRY_COUNT} -eq ${MAX_RETRIES} ]; then
  echo "ERROR: Failed to apply Ironic configuration after ${MAX_RETRIES} attempts. Exiting."
  exit 1
fi

kubectl apply -k "${REPO_ROOT}/Metal3/ironic"
kubectl apply -k "${REPO_ROOT}/Metal3/bmo"
