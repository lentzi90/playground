# Playground

Random stuff that I may want to store for later

## CAPO

Setup bootstrap cluster:

```bash
kind create cluster
# Install ORC
kubectl apply -f "https://github.com/k-orc/openstack-resource-controller/releases/latest/download/install.yaml"
# If you want to use ClusterClasses
export CLUSTER_TOPOLOGY=true
# If you want to use ignition
export EXP_KUBEADM_BOOTSTRAP_FORMAT_IGNITION=true
clusterctl init --infrastructure=openstack
kubectl apply -k setup-scripts
```

### ClusterResourceSets for CNI and cloud provider

Save the Calico manifest, OpenStack cloud provider and cloud-config secret to be used in the ClusterResourceSet:

```bash
kustomize build ClusterResourceSets/calico > ClusterResourceSets/calico.yaml
kustomize build ClusterResourceSets/cloud-provider-openstack > ClusterResourceSets/cloud-provider-openstack.yaml
kubectl -n kube-system create secret generic cloud-config \
  --from-file=clouds.yaml=CAPO/credentials/clouds.yaml \
  --from-file=cloud.conf=CAPO/credentials/cloud.conf \
  --dry-run=client -o yaml > ClusterResourceSets/cloud-config-secret.yaml
```

Apply the ClusterResourceSets:

```bash
kubectl apply --server-side -k ClusterResourceSets
```

Any cluster with the label `cni=calico` will automatically get Calico deployed and any cluster with the label `cloud=openstack` will automatically get the OpenStack cloud provider deployed now.

### CAPO cluster credentials

Create `CAPO/credentials/clouds.yaml` file and `CAPO/credentials/cloud.conf` file to be used by the external cloud provider and CAPO:

```ini
# cloud.conf
[Global]
use-clouds=true
cloud=TODO
clouds-file=/etc/config/clouds.yaml
```

Create secrets from the files:

```bash
kubectl apply -k CAPO/credentials
```

### CAPO cluster-class

Apply the ClusterClass:

```bash
# Apply the cluster-class
kubectl apply -k ClusterClasses/capo-class
```

Then create a cluster:

```bash
kubectl apply -f CAPO/cluster.yaml
```

### CAPO cluster

```bash
kubectl apply -k CAPO/test-cluster
```

### CAPO upstream ClusterClass

Create a cluster using the upstream ClusterClass and image template.

```bash
# Set variables
source CAPO/.env
# Apply the clusterclass
clusterctl generate yaml --from https://github.com/kubernetes-sigs/cluster-api-provider-openstack/releases/latest/download/clusterclass-dev-test.yaml | kubectl apply -f -
# If the openstack cloud does not support qcow2, download the image and convert.
wget https://stable.release.flatcar-linux.net/amd64-usr/current/flatcar_production_openstack_image.img
qemu-img convert -f qcow2 -O raw flatcar_production_openstack_image.img flatcar_production.raw
openstack image create --file flatcar_production.raw flatcar_production
# Now we can apply the image template. It will pick up the existing image, or download as needed.
kubectl apply -f https://github.com/kubernetes-sigs/cluster-api-provider-openstack/releases/latest/download/image-template-node.yaml

# Create a cluster
clusterctl generate cluster lennart-test --kubernetes-version=v1.33.4 --flavor=dev-test | kubectl apply -f -
```

### CNI and external cloud provider

Apply manually if you did not use the ClusterResourceSets.

```bash
# Get the workload cluster kubeconfig
clusterctl get kubeconfig lennart-test > kubeconfig.yaml
kubectl --kubeconfig=kubeconfig.yaml apply -k ClusterResourceSets/calico
kubectl --kubeconfig=kubeconfig.yaml apply -k ClusterResourceSets/cloud-provider-openstack
```

## CAPI In-memory provider

```bash
kind create cluster
export CLUSTER_TOPOLOGY=true
clusterctl init --infrastructure=in-memory
kubectl apply -f https://github.com/kubernetes-sigs/cluster-api/releases/download/v1.5.1/clusterclass-in-memory-quick-start.yaml
clusterctl generate cluster in-memory-test --flavor=in-memory-development --kubernetes-version=v1.31.1 > in-memory-cluster.yaml

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
  "iso_checksum": "e240e4b801f7bb68c20d1356b60968ad0c33a41d00d828e74ceb3364a0317be9",
  "iso_checksum_type": "sha256",
  "iso_url": "https://releases.ubuntu.com/noble/ubuntu-24.04.1-live-server-amd64.iso",
  "kubernetes_deb_version": "1.31.1-1.1",
  "kubernetes_rpm_version": "1.31.1",
  "kubernetes_semver": "v1.31.1",
  "kubernetes_series": "v1.31"
}
```

Build the image:

```bash
PACKER_VAR_FILES=qemu_vars.json make build-qemu-ubuntu-2404
```

Convert the image to raw format (otherwise each BMH needs enough memory to load the whole image in order to convert it).

```bash
qemu-img convert -f qcow2 -O raw output/ubuntu-2404-kube-v1.31.1/ubuntu-2404-kube-v1.31.1 \
  output/ubuntu-2404-kube-v1.31.1/ubuntu-2404-kube-v1.31.1.raw
# Calculate the checksum
sha256 output/ubuntu-2404-kube-v1.31.1/ubuntu-2404-kube-v1.31.1.raw
```

## Metal3

```bash
# Generate credentials for Ironic
IRONIC_USERNAME="$(uuidgen)"
IRONIC_PASSWORD="$(uuidgen)"
echo "${IRONIC_USERNAME}" > Metal3/bmo/ironic-username
echo "${IRONIC_PASSWORD}" > Metal3/bmo/ironic-password
echo "IRONIC_HTPASSWD=$(htpasswd -n -b -B "${IRONIC_USERNAME}" "${IRONIC_PASSWORD}")" > Metal3/ironic/ironic-htpasswd

# Download disk image
wget -O Metal3/images/ubuntu-2404.img https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img
# Convert to raw
qemu-img convert -f qcow2 -O raw Metal3/images/ubuntu-2404.img Metal3/images/ubuntu-2404.raw

./Metal3/dev-setup.sh
# Wait for BMO to come up
# Create BMHs backed by VMs
NUM_BMH=5 ./Metal3/create-bmhs.sh
# (Optional) Apply ClusterResourceSets
kubectl apply --server-side -k ClusterResourceSets
# Apply setup-scripts for installing k8s on plain images
kubectl apply -k setup-scripts
# Apply cluster
kubectl apply -k Metal3/cluster

# Get the kubeconfig for the workload cluster
clusterctl get kubeconfig test-1 > kubeconfig.yaml
```

Add CNI to make nodes healthy (only needed if you didn't apply the CRS):

```bash
kubectl --kubeconfig=kubeconfig.yaml apply -k ClusterResourceSets/calico
```

### Metal3 cluster-class

```bash
# (Optional) Apply ClusterResourceSets
kubectl apply --server-side -k ClusterResourceSets
# Apply ClusterClass
kubectl apply -k ClusterClasses/metal3-class
# Create Cluster
kubectl apply -f Metal3/cluster.yaml
```

### Move from bootstrap to management cluster

Turn the workload cluster into a management cluster.

```bash
clusterctl init --control-plane kubeadm --infrastructure metal3 --ipam metal3
# Install Ironic and BMO
kubectl apply -k Metal3/bmo-management
kubectl apply -k Metal3/ironic-management
```

Back in the bootstrap cluster, do the move:

```bash
# Label CRDs to include in move
kubectl label crd baremetalhosts.metal3.io clusterctl.cluster.x-k8s.io=""
kubectl label crd baremetalhosts.metal3.io cluster.x-k8s.io/move=""
kubectl label crd hardwaredata.metal3.io clusterctl.cluster.x-k8s.io=""
kubectl label crd hardwaredata.metal3.io clusterctl.cluster.x-k8s.io/move=""

# Move the cluster. This will also move the BMHs and hardwaredata that are part of the cluster.
clusterctl move --to-kubeconfig=kubeconfig.yaml

# Manually move BMHs that are not part of the cluster
mkdir -p Metal3/tmp/bmhs
for bmh in $(kubectl get bmh -o jsonpath="{.items[*].metadata.name}"); do
  echo "Saving BMH ${bmh}..."
  # Save the BMH status
  # Remove status.hardware since this is part of the hardwaredata
  kubectl get bmh "${bmh}" -o jsonpath="{.status}" |
   jq 'del(.hardware)' > "Metal3/tmp/bmhs/${bmh}-status.json"
  # Save the BMH with the status annotation
  kubectl annotate bmh "${bmh}" \
    baremetalhost.metal3.io/status="$(cat Metal3/tmp/bmhs/${bmh}-status.json)" \
    --dry-run=client -o yaml > "Metal3/tmp/bmhs/${bmh}-bmh.yaml"
  # Save the hardwaredata
  kubectl get hardwaredata "${bmh}" -o yaml > "Metal3/tmp/bmhs/${bmh}-hardwaredata.yaml"
  # Save the BMC credentials
  secret="$(kubectl get bmh "${bmh}" -o jsonpath="{.spec.bmc.credentialsName}")"
  kubectl get secret "${secret}" -o yaml > "Metal3/tmp/bmhs/${bmh}-bmc-secret.yaml"

  # Detach BMHs
  kubectl annotate bmh "${bmh}" baremetalhost.metal3.io/detached="manual-move"
  # Cleanup
  rm "Metal3/tmp/bmhs/${bmh}-status.json"
done

# Apply the BMHs and hardwaredata in the management cluster
kubectl apply -f Metal3/tmp/bmhs

# Cleanup
kubectl delete bmh --all
rm -r Metal3/tmp/bmhs
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

- Create workload cluster using Metal3 as normal
- Approve CSRs!
- Turn it into a management cluster by initializing it with Kamaji and Metal3
- Pivot from the bootstrap cluster
- Create a workload cluster with hosted control plane in the management cluster

```bash
# Do a normal bootstrap cluster setup with Metal3 first.
# Continue here after moving from the bootstrap to the management cluster.
# Tested with v0.15.2
clusterctl init --control-plane kamaji
# Install metallb (needed for Kamaji k8s API endpoints)
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.2/config/manifests/metallb-native.yaml
# Create an IPAddressPool and L2Advertisement
kubectl apply -k Metal3/metallb
# Install local-path-provisioner (needed for Kamaji etcd)
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.31/deploy/local-path-storage.yaml
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# Install kamaji
# NOTE: To get a specific version, checkout the repo at the desired tag and use the helm chart from there.
# Replace the image.tag with the desired version.
helm repo add clastix https://clastix.github.io/charts
helm repo update
helm install kamaji clastix/kamaji \
  --version 0.0.0+latest \
  --namespace kamaji-system \
  --create-namespace \
  --set image.tag=latest

kubectl apply -k setup-scripts

# Create the workload cluster with Kamaji as control-plane provider
kubectl apply -k Metal3/kamaji
# The above has a hard-coded API endpoint and cluster name.
# Another cluster can be created by changing these.
kustomize build Metal3/kamaji | sed -e "s/kamaji-1/kamaji-2/g" -e "s/192.168.222.150/192.168.222.160/g" | kubectl apply -f -

# Get the workload cluster kubeconfig
clusterctl get kubeconfig kamaji-1 > hosted.yaml
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
kubectl apply --server-side=true -k kube-prometheus/setup
kubectl apply -k kube-prometheus
```

Access grafana:

```bash
kubectl -n monitoring port-forward svc/grafana 3000
```

Log in to <localhost:3000> using `admin`/`admin`.
