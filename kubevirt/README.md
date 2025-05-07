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
```

NOTE! The CRI may need extra configuration to make block device imports work.
See https://github.com/kubevirt/containerized-data-importer/blob/main/doc/block_cri_ownership_config.md

## Test Fedora 42 VM using CDI with generic cloud image

```bash
kubectl apply -f fedora42_datavolume.yaml
# The local-path provisioner cannot create the volume until it knows which node to use
# This is only an issue when using the local-path provisioner that comes with kind
kubectl annotate pvc fedora42 volume.kubernetes.io/selected-node=kind-control-plane
# Wait for the datavolume to be filled
kubectl wait --for=condition=Ready dv fedora42

kubectl apply -f fedora42_virtualmachine.yaml
# Connect to the console
kubectl virt console fedora42
```

## Test Fedora CoreOS using OCI artifact

```bash
# Generate ignition config from butane (coreos-user.yaml)
podman run --interactive --rm quay.io/coreos/butane:release \
       --pretty --strict < coreos-user.yaml > ignition.json
kubectl create secret generic ignition-payload --from-file=userdata=ignition.json
kubectl apply -f coreos_virtualmachine.yaml
# Connect to the console
kubectl virt console coreos
```

## Home Assistant VM using CDI with compressed qcow2 image

This is using EFI boot also and shows how to upload a local image through the CDI proxy.
See https://www.home-assistant.io/installation/linux

This has been tested in a CAPO cluster (not kind like the previous tests).

Use CLI to upload the image:
```bash
wget https://github.com/home-assistant/operating-system/releases/download/15.2/haos_ova-15.2.qcow2.xz
tar -xvf haos_ova-15.2.qcow2.xz

# Connect to the CDI upload proxy in a separate terminal
kubectl port-forward -n cdi service/cdi-uploadproxy 8443:443
# Upload the image to the CDI upload proxy (insecure is needed because we are using self-signed certs)
kubectl virt image-upload dv haos --size=100Gi \
  --access-mode=ReadWriteOnce --force-bind \
  --uploadproxy-url=https://localhost:8443 --insecure \
  --image-path=$(pwd)/haos_ova-15.2.qcow2.xz
```

Alternatively, apply the datavolume to download the image from the internet:

```bash
kubectl apply -f haos_datavolume.yaml
# The local-path provisioner cannot create the volume until it knows which node to use
# This is only an issue when using the local-path provisioner that comes with kind
kubectl annotate pvc haos volume.kubernetes.io/selected-node=kind-control-plane
```

Create the VM:

```bash
kubectl apply -f haos_virtualmachine.yaml
# Check that it boots
kubectl virt console haos

# Port forward to access the Home Assistant web interface
# This does not work with kind
kubectl virt port-forward vm/haos 8123

# For kind, do this instead
ip_address="$(kubectl get node kind-control-plane -o jsonpath="{.status.addresses[0].address}")"
kubectl virt export vm/haos --port 8123 --name haos --external-ip "${ip_address}"
echo "Access Home Assistant at http://${ip_address}:8123"
```

Now go to http://localhost:8123 to see that Home Assistant is running.
