#!/usr/bin/env bash

set -eux

NUM_BMH=${NUM_BMH:-"5"}
BMO_E2E_EMULATOR=${BMO_E2E_EMULATOR:-"vbmc"}
# This is the IP of the host from minikubes point of view
IP_ADDRESS="192.168.222.1"

REPO_ROOT=$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")
cd "${REPO_ROOT}" || exit 1

if [[ "${BMO_E2E_EMULATOR}" == "vbmc" ]]; then
  # Start VBMC
  docker run --name vbmc --network host -d \
    -v /var/run/libvirt/libvirt-sock:/var/run/libvirt/libvirt-sock \
    -v /var/run/libvirt/libvirt-sock-ro:/var/run/libvirt/libvirt-sock-ro \
    quay.io/metal3-io/vbmc
else
  echo "Invalid e2e emulator specified: ${BMO_E2E_EMULATOR}"
  exit 1
fi

for ((i=0; i<NUM_BMH; i++))
do
  # Create libvirt domain
  VM_NAME="bmo-e2e-${i}"
  export BOOT_MAC_ADDRESS="00:60:2f:31:81:0${i}"

  virt-install \
    --connect qemu:///system \
    --name "${VM_NAME}" \
    --description "Virtualized BareMetalHost" \
    --osinfo=ubuntu-lts-latest \
    --ram=4096 \
    --vcpus=2 \
    --disk size=25 \
    --graphics=none \
    --console pty \
    --serial pty \
    --pxe \
    --network network=baremetal-e2e,mac="${BOOT_MAC_ADDRESS}" \
    --noautoconsole

  # Add BMH VM to VBMC
  VBMC_PORT="1623${i}"
  docker exec vbmc vbmc add "${VM_NAME}" --port "${VBMC_PORT}"
  docker exec vbmc vbmc start "${VM_NAME}"

  sed -e "s/VBMC_IP/${IP_ADDRESS}/g" -e "s/MAC_ADDRESS/${BOOT_MAC_ADDRESS}/g" -e "s/NAME/${VM_NAME}/g" \
    -e "s/VBMC_PORT/${VBMC_PORT}/g" "${REPO_ROOT}/Metal3/bmh-template.yaml" | kubectl apply -f -
done

docker exec vbmc vbmc list
kubectl get bmh
