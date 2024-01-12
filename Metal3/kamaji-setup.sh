#!/usr/bin/env bash

set -eux

REPO_ROOT=$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")
cd "${REPO_ROOT}" || exit 1

k8s_version="v1.28.1"
image_name="ubuntu-2204-kube-${k8s_version}.raw"

if [ ! -f ${REPO_ROOT}/Metal3/images/${image_name} ]; then
  rm -rf Metal3/images
  mkdir -p Metal3/images
  wget "https://artifactory.nordix.org/artifactory/metal3/images/k8s_${k8s_version}/UBUNTU_22.04_NODE_IMAGE_K8S_${k8s_version}.qcow2"
  qemu-img convert -f qcow2 -O raw "UBUNTU_22.04_NODE_IMAGE_K8S_${k8s_version}.qcow2" Metal3/images/${image_name}
  sha256sum Metal3/images/${image_name}  | awk '{print $1}' > Metal3/images/${image_name}_sha256sum
fi

./Metal3/dev-setup.sh

clusterctl init --control-plane kamaji

kubectl wait --for=condition=Available --timeout=300s -n baremetal-operator-system deployment baremetal-operator-controller-manager
kubectl wait --for=condition=Available --timeout=300s -n baremetal-operator-system deployment ironic

NUM_BMH=1 ./Metal3/create-bmhs.sh

kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.12/config/manifests/metallb-native.yaml

kubectl wait --for=condition=Available --timeout=300s -n metallb-system deployment controller

kubectl apply -k Metal3/metallb

# Install kamaji
helm repo add clastix https://clastix.github.io/charts
helm repo update
helm install kamaji clastix/kamaji -n kamaji-system --create-namespace

kubectl apply -k Metal3/kamaji
