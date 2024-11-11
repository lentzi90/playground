#!/usr/bin/env bash

set -eux

NUM_BMH=${NUM_BMH:-"5"}
MEMORY="${MEMORY:-4096}"
CPUS="${CPUS:-2}"

REPO_ROOT=$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")
cd "${REPO_ROOT}" || exit 1

echo "Waiting for ironic deployment to be available..."
kubectl wait --for=condition=Available --timeout=300s deployment/ironic -n baremetal-operator-system

for ((i=0; i<NUM_BMH; i++))
do
  # Create libvirt domain
  VM_NAME="bmo-e2e-${i}"
  export BOOT_MAC_ADDRESS="00:60:2f:31:81:0${i}"
  # Skip this iteration if the VM already exists
  if virsh list --all | grep -q "${VM_NAME}"; then
    continue
  fi

  virt-install \
    --connect qemu:///system \
    --name "${VM_NAME}" \
    --description "Virtualized BareMetalHost" \
    --osinfo=ubuntu-lts-latest \
    --ram="${MEMORY}" \
    --vcpus="${CPUS}" \
    --disk size=25 \
    --graphics=none \
    --console pty \
    --serial pty \
    --pxe \
    --network network=baremetal-e2e,mac="${BOOT_MAC_ADDRESS}" \
    --noautoconsole

  sed -e "s/MAC_ADDRESS/${BOOT_MAC_ADDRESS}/g" -e "s/NAME/${VM_NAME}/g" \
    "${REPO_ROOT}/Metal3/bmh-template.yaml" | kubectl apply -f -
done

kubectl get bmh
