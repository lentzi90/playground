# Kubevirt

Install krew plugin:

```bash
kubectl krew install virt
```

Set up a kind cluster with kubevirt:

```bash
kind create cluster
# Tested with v1.5.0
export VERSION=$(curl -s https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt)
echo ${VERSION}
kubectl create -f "https://github.com/kubevirt/kubevirt/releases/download/${VERSION}/kubevirt-operator.yaml"
kubectl create -f "https://github.com/kubevirt/kubevirt/releases/download/${VERSION}/kubevirt-cr.yaml"
```

Setup Containerized Data Importer (CDI):

```bash
# Tested with v1.62.0
export VERSION=$(basename $(curl -s -w %{redirect_url} https://github.com/kubevirt/containerized-data-importer/releases/latest))
echo ${VERSION}
kubectl create -f https://github.com/kubevirt/containerized-data-importer/releases/download/${VERSION}/cdi-operator.yaml
kubectl create -f https://github.com/kubevirt/containerized-data-importer/releases/download/${VERSION}/cdi-cr.yaml
# Create storageclass with "immediate" volume binding mode
# Otherwise CDI will not be able to download the image because it waits for the volume
kubectl apply -f storageclass.yaml
```

Test Fedora 42 VM using CDI with generic cloud image:

```bash
kubectl apply -f fedora42_datavolume.yaml
# The local-path provisioner cannot create the volume until it knows which node to use
kubectl annotate pvc fedora42 volume.kubernetes.io/selected-node=kind-control-plane
# Wait for the datavolume to be filled
kubectl wait --for=condition=Ready dv fedora42

kubectl apply -f fedora42_virtualmachine.yaml
# Connect to the console
kubectl virt console fedora42
```

Test Fedora CoreOS using OCI artifact:

```bash
# Generate ignition config from butane (coreos-user.yaml)
podman run --interactive --rm quay.io/coreos/butane:release \
       --pretty --strict < coreos-user.yaml > ignition.json
kubectl create secret generic ignition-payload --from-file=userdata=ignition.json
kubectl apply -f coreos_virtualmachine.yaml
# Connect to the console
kubectl virt console coreos
```
