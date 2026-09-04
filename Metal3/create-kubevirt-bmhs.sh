#!/usr/bin/env bash

set -eux

NUM_BMH=${NUM_BMH:-"2"}
CP_MEMORY="${CP_MEMORY:-4096}"
WORKER_MEMORY="${WORKER_MEMORY:-4096}"
CPUS="${CPUS:-2}"
CP_DISK_SIZE="${CP_DISK_SIZE:-30}"
WORKER_DISK_SIZE="${WORKER_DISK_SIZE:-25}"

REPO_ROOT=$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")
cd "${REPO_ROOT}" || exit 1

echo "Waiting for ironic deployment to be available..."
kubectl wait --for=condition=Available --timeout=300s deployment/ironic-service -n baremetal-operator-system

mkdir -p "${REPO_ROOT}/Metal3/tmp"

# Ensure bmc-creds secret exists
kubectl get secret bmc-creds 2>/dev/null || kubectl create secret generic bmc-creds \
  --from-literal=username=admin --from-literal=password=password

for ((i=0; i<NUM_BMH; i++))
do
  VM_NAME="kubevirt-node-${i}"
  MAC_ADDRESS=$(printf "52:54:00:00:00:%02x" "$i")
  # Distinct, easy-to-grep MAC prefix for the baremetal-net (Multus bridge)
  # interface, so guest OS boot scripts can find it by MAC regardless of
  # what predictable-network-interface-name the kernel assigns it (PCI slot
  # ordering on q35 is not simply sequential across interfaces). See
  # cluster-kubevirt/kcp.yaml preKubeadmCommands for the detection script.
  BM_MAC_ADDRESS=$(printf "52:54:00:10:00:%02x" "$i")

  # Skip if VM already exists
  if kubectl get vm "${VM_NAME}" 2>/dev/null; then
    echo "VM ${VM_NAME} already exists, skipping..."
    continue
  fi

  # Determine resources based on role
  if [ "${i}" -eq 0 ]; then
    MEMORY="${CP_MEMORY}"
    DISK_SIZE="${CP_DISK_SIZE}"
  else
    MEMORY="${WORKER_MEMORY}"
    DISK_SIZE="${WORKER_DISK_SIZE}"
  fi

  echo "Creating VM ${VM_NAME} (cpus=${CPUS}, memory=${MEMORY}M, disk=${DISK_SIZE}Gi)..."

  # Create PVC
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${VM_NAME}-rootdisk
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: ${DISK_SIZE}Gi
EOF

  # Create VirtualMachine
  cat <<EOF | kubectl apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${VM_NAME}
  namespace: default
spec:
  runStrategy: Halted
  template:
    metadata:
      labels:
        kubevirt.io/domain: ${VM_NAME}
    spec:
      domain:
        cpu:
          cores: ${CPUS}
        devices:
          disks:
          - name: rootdisk
            disk:
              bus: virtio
          - name: cdrom
            cdrom:
              bus: sata
          interfaces:
          - name: default
            macAddress: "${MAC_ADDRESS}"
            bridge: {}
          - name: baremetal
            macAddress: "${BM_MAC_ADDRESS}"
            bridge: {}
        firmware:
          bootloader:
            efi:
              secureBoot: false
        machine:
          type: q35
        resources:
          requests:
            memory: ${MEMORY}M
      volumes:
      - name: rootdisk
        persistentVolumeClaim:
          claimName: ${VM_NAME}-rootdisk
      networks:
      - name: default
        pod: {}
      - name: baremetal
        multus:
          networkName: baremetal-net
EOF

  # Create VirtualMachineBMC
  cat <<EOF | kubectl apply -f -
apiVersion: bmc.kubevirt.io/v1beta1
kind: VirtualMachineBMC
metadata:
  name: ${VM_NAME}-bmc
  namespace: default
spec:
  virtualMachineRef:
    name: ${VM_NAME}
  authSecretRef:
    name: bmc-creds
EOF

  echo "Waiting for VirtualMachineBMC ${VM_NAME}-bmc to be ready..."
  # As of KubeVirtBMC v0.10.0 (upstream PR #276), the VirtualMachineBMC
  # condition type was renamed from "Ready" to "ServiceReady".
  kubectl wait --for=condition=ServiceReady --timeout=120s virtualmachinebmc "${VM_NAME}-bmc"

  # Create BareMetalHost
  cat <<EOF | kubectl apply -f -
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: ${VM_NAME}
spec:
  online: true
  bmc:
    address: redfish-virtualmedia+http://${VM_NAME}-virtbmc.default.svc:80/redfish/v1/Systems/1
    credentialsName: bmc-creds
  bootMACAddress: ${MAC_ADDRESS}
  bootMode: UEFI
  rootDeviceHints:
    deviceName: /dev/vda
EOF

  echo "Created BMH ${VM_NAME}"
done

echo ""
echo "All VMs and BMHs created:"
kubectl get vm
echo ""
kubectl get virtualmachinebmc
echo ""
kubectl get bmh
