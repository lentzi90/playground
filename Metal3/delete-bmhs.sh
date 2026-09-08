#!/usr/bin/env bash

set -eux

NUM_BMH=${NUM_BMH:-"2"}

REPO_ROOT=$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")
cd "${REPO_ROOT}" || exit 1

for ((i=0; i<NUM_BMH; i++))
do
  VM_NAME="kubevirt-node-${i}"
  echo "Deleting ${VM_NAME}..."
  kubectl delete bmh "${VM_NAME}" --ignore-not-found
  kubectl delete virtualmachinebmc "${VM_NAME}-bmc" --ignore-not-found
  kubectl delete vm "${VM_NAME}" --ignore-not-found
  kubectl delete pvc "${VM_NAME}-rootdisk" --ignore-not-found
done

rm -rf "${REPO_ROOT}/Metal3/tmp"

echo "Cleanup complete"
kubectl get vm 2>/dev/null || true
kubectl get bmh 2>/dev/null || true
