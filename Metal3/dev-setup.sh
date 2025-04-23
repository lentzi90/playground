#!/usr/bin/env bash

set -eux

REPO_ROOT=$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")
cd "${REPO_ROOT}" || exit 1

virsh -c qemu:///system net-define "${REPO_ROOT}/Metal3/net.xml"
virsh -c qemu:///system net-start baremetal-e2e
virsh -c qemu:///system pool-define-as --name=baremetal-e2e --type=dir --target=/tmp/baremetal-e2e
virsh -c qemu:///system pool-build baremetal-e2e
virsh -c qemu:///system pool-start baremetal-e2e

# Create a kind cluster using the configuration from kind.yaml
kind create cluster --config "${REPO_ROOT}/Metal3/kind.yaml"

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
# If you want to use ClusterResourceSets
export EXP_CLUSTER_RESOURCE_SET=true

clusterctl init --infrastructure=metal3
kubectl apply -k "${REPO_ROOT}/Metal3/ironic"
kubectl apply -k "${REPO_ROOT}/Metal3/bmo"
