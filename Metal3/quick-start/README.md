# Metal3 quick-start

Based on <https://book.metal3.io/quick-start>

Set up environment:

```bash
kind create cluster --config kind.yaml
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.3/cert-manager.yaml

docker run --name dnsmasq --rm -d --net=host --privileged --user 997:994 \
  --env-file dnsmasq.env --entrypoint /bin/rundnsmasq \
  quay.io/metal3-io/ironic
docker run --name image-server --rm -d -p 80:8080 \
  -v "$(pwd)/disk-images:/usr/share/nginx/html" nginxinc/nginx-unprivileged
docker run --name sushy-tools --rm --network host -d \
  -v /var/run/libvirt:/var/run/libvirt \
  -v "$(pwd)/sushy-tools.conf:/etc/sushy/sushy-emulator.conf" \
  -e SUSHY_EMULATOR_CONFIG=/etc/sushy/sushy-emulator.conf \
  quay.io/metal3-io/sushy-tools:latest sushy-emulator

# Check node IP
kubectl get node -o wide
# Edit IP as needed in ironic/kustomization.yaml
kubectl apply -k ironic
kubectl apply -k bmo

virsh -c qemu:///system net-define net.xml
virsh -c qemu:///system net-start baremetal

virt-install \
  --connect qemu:///system \
  --name bmh-vm-01 \
  --description "Virtualized BareMetalHost" \
  --osinfo=ubuntu-lts-latest \
  --ram=4096 \
  --vcpus=2 \
  --disk size=25 \
  --graphics=none \
  --console pty \
  --serial pty \
  --pxe \
  --network network=baremetal,mac="00:60:2f:31:81:01" \
  --noautoconsole

virt-install \
  --connect qemu:///system \
  --name bmh-vm-02 \
  --description "Virtualized BareMetalHost" \
  --osinfo=ubuntu-lts-latest \
  --ram=4096 \
  --vcpus=2 \
  --disk size=25 \
  --graphics=none \
  --console pty \
  --serial pty \
  --pxe \
  --network network=baremetal,mac="00:60:2f:31:81:02" \
  --noautoconsole

virt-install \
  --connect qemu:///system \
  --name bmh-vm-03 \
  --description "Virtualized BareMetalHost" \
  --osinfo=ubuntu-lts-latest \
  --ram=4096 \
  --vcpus=2 \
  --disk size=25 \
  --graphics=none \
  --console pty \
  --serial pty \
  --pxe \
  --network network=baremetal,mac="00:60:2f:31:81:03" \
  --noautoconsole

virt-install \
  --connect qemu:///system \
  --name bmh-vm-04 \
  --description "Virtualized BareMetalHost" \
  --osinfo=ubuntu-lts-latest \
  --ram=4096 \
  --vcpus=2 \
  --disk size=25 \
  --graphics=none \
  --console pty \
  --serial pty \
  --pxe \
  --network network=baremetal,mac="00:60:2f:31:81:04" \
  --noautoconsole


kubectl apply -f bmhs.yaml
```

Provision bml-04:

```bash
kubectl apply -f scenarios/01-provision-bmh.yaml
```

Create cluster:

```bash
clusterctl init --infrastructure metal3

export IMAGE_CHECKSUM="5784d826093ec7145164f3ee45ceeaed1046e6d46fc7adfcb5035d63fc69c9c8"
export IMAGE_CHECKSUM_TYPE="sha256"
export IMAGE_FORMAT="raw"
export IMAGE_URL="http://192.168.222.1/CENTOS_9_NODE_IMAGE_K8S_v1.29.0.img"
export KUBERNETES_VERSION="v1.29.0"
# These can be used to add user-data
export CTLPLANE_KUBEADM_EXTRA_CONFIG="
    users:
    - name: user
      sudo: 'ALL=(ALL) NOPASSWD:ALL'
      sshAuthorizedKeys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF3XsjgwkAkxd5aioPiBws7O5nx5ofcR4TvAIOvSQ9Ce lennart.jern@est.tech"
export WORKERS_KUBEADM_EXTRA_CONFIG="
      users:
      - name: user
        sudo: 'ALL=(ALL) NOPASSWD:ALL'
        sshAuthorizedKeys:
        - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF3XsjgwkAkxd5aioPiBws7O5nx5ofcR4TvAIOvSQ9Ce lennart.jern@est.tech"
# NOTE! You must ensure that this is forwarded or assigned somehow to the
# server(s) that is selected for the control-plane.
export CLUSTER_APIENDPOINT_HOST="192.168.222.100"
export CLUSTER_APIENDPOINT_PORT="6443"

clusterctl generate cluster my-cluster > my-cluster.yaml
# Inspect the manifest and adjust as needed, then apply
kubectl apply -f my-cluster.yaml
```

Scale cluster:

```bash
kubectl scale md my-cluster --replicas 2
```
