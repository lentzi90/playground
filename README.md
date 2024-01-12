# Playground

Random stuff that I may want to store for later

## CAPO cluster-class

Create a `clouds.yaml` file in `CAPO/cluster-class`.

```bash
kind create cluster
export CLUSTER_TOPOLOGY=true
clusterctl init --infrastructure=openstack
# Create cluster-class/clouds.yaml file to be used by CAPO
# Apply the cluster-class
kubectl apply -k CAPO/cluster-class
# Create a cluster
kubectl apply -f CAPO/cluster.yaml
```

### CNI and external cloud provider

Create cluster-resources/cloud.conf file to be used by the external cloud provider.

```ini
[Global]
auth-url=TODO
application-credential-id=TODO
application-credential-secret=TODO
region=TODO
domain-name=TODO
```

```bash
# Get the workload cluster kubeconfig
clusterctl get kubeconfig lennart-test > kubeconfig.yaml
kubectl --kubeconfig=kubeconfig.yaml apply -k CAPO/cluster-resources
```

## CAPO cluster

Create a `clouds.yaml` file in `CAPO/test-cluster`.
Then apply the cluster:

```bash
kind create cluster
clusterctl init --infrastructure=openstack
kubectl apply -k CAPO/test-cluster
```

The same CNI and external cloud provider as above can be used here also.

## CAPI In-memory provider

```bash
kind create cluster
export CLUSTER_TOPOLOGY=true
clusterctl init --infrastructure=in-memory
kubectl apply -f https://github.com/kubernetes-sigs/cluster-api/releases/download/v1.5.1/clusterclass-in-memory-quick-start.yaml
clusterctl generate cluster in-memory-test --flavor=in-memory-development --kubernetes-version=v1.28.1 > in-memory-cluster.yaml

# Create a single cluster
kubectl apply -f in-memory-cluster.yaml

# Create many clusters
START=0
NUM=100
for ((i=START; i<NUM; i++))
do
  name="test-$(printf "%03d\n" "$i")"
  sed "s/in-memory-test/${name}/g" in-memory-cluster.yaml | kubectl apply -f -
done
```

## Image-builder

Build node images using qemu.
Create a file with variables:

```json
{
  "iso_checksum": "a4acfda10b18da50e2ec50ccaf860d7f20b389df8765611142305c0e911d16fd",
  "iso_checksum_type": "sha256",
  "iso_url": "https://releases.ubuntu.com/jammy/ubuntu-22.04.3-live-server-amd64.iso",
  "kubernetes_deb_version": "1.28.4-1.1",
  "kubernetes_rpm_version": "1.28.4",
  "kubernetes_semver": "v1.28.4",
  "kubernetes_series": "v1.28"
}
```

Build the image:

```bash
PACKER_VAR_FILES=qemu_vars.json make build-qemu-ubuntu-2204
```

Convert the image to raw format (otherwise each BMH needs enough memory to load the whole image in order to convert it).

```bash
qemu-img convert -f qcow2 -O raw output/ubuntu-2204-kube-v1.28.4/ubuntu-2204-kube-v1.28.4 \
  output/ubuntu-2204-kube-v1.28.4/ubuntu-2204-kube-v1.28.4.raw
# Calculate the checksum
sha256 output/ubuntu-2204-kube-v1.28.4/ubuntu-2204-kube-v1.28.4.raw
```

## Metal3

```bash
./Metal3/dev-setup.sh
# Wait for BMO to come up
# Create BMHs backed by VMs
NUM_BMH=5 ./Metal3/create-bmhs.sh
# Apply cluster
kubectl apply -k Metal3/cluster
```

Add CNI to make nodes healthy:

```bash
clusterctl get kubeconfig test-1 > kubeconfig.yaml
kubectl --kubeconfig=kubeconfig.yaml apply -k Metal3/cni
```

### K3s as bootstrap and control-plane provider

Add the following to `${HOME}/.cluster-api/clusterctl.yaml`:

```yaml
providers:
- name: "k3s"
  url: https://github.com/cluster-api-provider-k3s/cluster-api-k3s/releases/latest/bootstrap-components.yaml
  type: "BootstrapProvider"
- name: "k3s"
  url: https://github.com/cluster-api-provider-k3s/cluster-api-k3s/releases/latest/control-plane-components.yaml
  type: "ControlPlaneProvider"
```

Then initialize the k3s providers and create a cluster

```bash
clusterctl init --bootstrap k3s --control-plane k3s
# Wait for them to be ready, then continue
kubectl apply -k Metal3/k3s
```

### Kamaji as control-plane provider

```bash
clusterctl init --control-plane kamaji
# Install metallb
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.12/config/manifests/metallb-native.yaml
# Create an IPAddressPool and L2Advertisement
kubectl apply -k Metal3/metallb
# Wait for them to be ready, then continue
kubectl apply -k Metal3/kamaji
```

## CAPI visualizer

Visualize the clusters and related objects.

```bash
kustomize build --enable-helm capi-visualizer | kubectl apply -f -
kubectl -n observability port-forward svc/capi-visualizer 8081
```
Then go to <http://localhost:8081/>.

## Kube-prometheus

Deploy the kube-prometheus example manifests.

```bash
kubectl apply -k kube-prometheus/setup
kubectl apply -k kube-prometheus
```
