# KubeVirtBMC End-to-End Integration Test Results

## Objective

Verify that KubeVirtBMC works as a BMC emulator for Metal3 with a real Kubernetes
cluster (not just cirros VMs). The goal is to provision a two-node CAPI cluster
(1 control-plane + 1 worker) using Metal3 + KubeVirt VMs managed by KubeVirtBMC
as the Redfish BMC interface.

## Test Environment

| Component | Version |
|-----------|---------|
| Host | 4 vCPUs, 15 GB RAM, 145 GB disk |
| Kind | v0.31.0 |
| Kubernetes (management) | v1.35.0 |
| KubeVirt | v1.8.1 |
| CDI | v1.65.0 |
| cert-manager | v1.17.2 |
| KubeVirtBMC | v0.10.0 + 5 patches (branch `lentzi90/metal3-fixes-v0.10.0` in `../kubevirtbmc/`; Ironic's CA baked directly into the `cdi-importer`/`virtbmc` images, no admission webhook or runtime ConfigMap |
| CAPI | v1.14.1 |
| CAPM3 | v1.13.3 |
| BMO | latest |
| IrSO | latest |
| Ironic | latest (TLS via cert-manager) |

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Kind Cluster (management)                               │
│                                                           │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐               │
│  │  CAPI    │  │   BMO    │  │  Ironic  │               │
│  │ + CAPM3  │  │          │  │  (TLS)   │               │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘               │
│       │             │             │                      │
│       │       ┌─────┴─────────────┴────┐                │
│       │       │     KubeVirtBMC         │                │
│       │       │  (Redfish API per VM)   │                │
│       │       └─────┬─────────────┬─────┘                │
│       │             │             │                      │
│  ┌────┴─────────────┴──┐  ┌───────┴──────────────┐       │
│  │  KubeVirt VM (CP)    │  │  KubeVirt VM (Worker) │      │
│  │  kubevirt-node-0     │  │  kubevirt-node-1      │      │
│  │  eth0: pod net       │  │  eth0: pod net        │      │
│  │  eth1: baremetal-net │  │  eth1: baremetal-net  │      │
│  │  (both bridge binding)│ │  (both bridge binding)│      │
│  │  PVC rootdisk         │  │  PVC rootdisk         │      │
│  └────┬──────────────────┘  └───┬───────────────────┘     │
│       │ eth1                    │ eth1                    │
│       └───────────┬─────────────┘                         │
│           br-baremetal (real Linux bridge,                │
│            192.168.100.0/24, Multus NAD)                  │
│           kube-vip VIP 192.168.100.100 floats here         │
│                                                            │
│  ┌──────────────────┐                                     │
│  │   Image Server    │  (reached over the pod network,    │
│  │ nginx (hostPath)  │   eth0, like Ironic/KubeVirtBMC)    │
│  │ 10.96.200.200     │                                     │
│  └──────────────────┘                                      │
└─────────────────────────────────────────────────────────┘
```

Two separate networks are attached to every VM:

- **`eth0` / pod network** — KubeVirt's default `pod: {}` network with
  `bridge: {}` binding. Backed by Kind's default CNI (kindnet), which is a
  point-to-point veth+route mesh, **not** a real L2 broadcast domain (no
  bridge device at all — verified with `ip link show type bridge` /
  `bridge link show` on the Kind node). Used for everything that only needs
  routed IP reachability to the management cluster: Ironic, the image
  server, the KubeVirtBMC agent, and CAPI's own connectivity to the
  workload cluster's API server.
- **`eth1` / `baremetal-net`** — a second NIC via Multus, backed by the
  plain CNI `bridge` plugin (`kubevirt-baremetal-network.yaml`), which
  creates a genuine Linux bridge (`br-baremetal`) on the Kind node. All VMs
  attached to it share a real L2/broadcast domain, exactly like a rack of
  servers on a switch. This is what makes `kube-vip` (ARP mode) viable: the
  VIP's gratuitous ARP announcements actually propagate and can be
  redirected on failover. See Key Design Decision 3 below, and "kube-vip vs.
  proxy_arp" for why the default pod network could never support this.

### Key Design Decisions

1. **TLS for Ironic, with CA trust baked into images**: Ironic's httpd (image
   service) is exposed over HTTPS using a cert-manager-issued certificate.
   Both the CDI importer (which downloads DataVolume contents) and the
   KubeVirtBMC `virtbmc` agent (which calls `GetRemoteFileSize` over HTTPS)
   need to trust Ironic's CA. Rather than a DataVolume `certConfigMap` field,
   an agent env var, or a mutating admission webhook, Ironic's CA is baked
   directly into custom variants of the `cdi-importer` and `virtbmc` images
   at build time (`Metal3/ironic-ca-images/`), built on stock upstream images
   with no source changes. `dev-setup-kubevirtbmc.sh` (step 9b) does this
   automatically: it extracts the CA from the `ironic-cacert` Secret
   (cert-manager, in `baremetal-operator-system`), builds the CA-trusting
   image variants, loads them into Kind, and points CDI's `cdi-operator`
   (`IMPORTER_IMAGE` env var) and KubeVirtBMC's controller
   (`--agent-image-tag` flag) at them. This works because Go's pure-Go
   `x509.SystemCertPool()` on Linux always reads well-known OS trust-store
   paths (e.g. `/etc/ssl/certs/ca-certificates.crt`) with no `cgo` or env var
   needed. See `Metal3/ironic-ca-images/README.md` for details, and the
   caveat that these images need rebuilding if Ironic's CA is ever rotated.

2. **Bridge networking on the pod network**: VMs use KubeVirt `bridge`
   binding with the default `pod` network for `eth0`. `create-kubevirt-bmhs.sh`
   uses `bridge: {}`, which also gives the VM access to ClusterIP services
   through the pod network's routing. This network alone is *not* sufficient
   for kube-vip -- see Key Design Decision 3.

3. **kube-vip on a second, real-L2 network (`baremetal-net`), not a Service**:
   Kind's default pod network has no real L2 broadcast domain (only
   point-to-point veth+routes), so a gratuitous ARP announcing a floating VIP
   never propagates and the Kind node's routing table never learns a route to
   it. Attaching a **second NIC via Multus, backed by the CNI `bridge` plugin**
   (`kubevirt-baremetal-network.yaml`) creates a real Linux bridge
   (`br-baremetal`) -- a genuine L2 segment where kube-vip's ARP mode works
   exactly as it does on this repo's libvirt- and OpenStack-backed clusters.

   `kcp.yaml` deploys kube-vip as a static pod, with `vip_interface`
   resolved at boot via a MAC-address lookup (`52:54:00:10:00:xx`, see
   `create-kubevirt-bmhs.sh`).

4. **In-cluster image server**: Ubuntu 24.04 cloud image served by an nginx pod
   with hostPath mount, using a fixed ClusterIP (`10.96.200.200:8080`).

5. **StorageClass for CDI DataVolumes**: KubeVirtBMC sets the
   `cdi.kubevirt.io/storage.bind.immediate.requested` annotation on every
   DataVolume it creates, so CDI binds the PVC immediately even on a
   `WaitForFirstConsumer` StorageClass. The default Kind `standard`
   StorageClass works out of the box, with its `StorageProfile.claimPropertySets`
   patched (see `dev-setup-kubevirtbmc.sh`).

6. **`proxy_arp` and `rp_filter` on veth interfaces**: With KubeVirt bridge
    networking in Kind, the VM gets a pod-subnet IP via DHCP but sees the
    entire `/24` as directly connected. Return traffic to other pods fails
    because the host veth doesn't proxy-ARP by default. Setting
    `net.ipv4.conf.default.proxy_arp=1` and enabling proxy_arp on all
    existing veths is required for pod-to-VM connectivity.
    Separately, kube-vip's VIP on `baremetal-net` (Decision 3) introduces
    *asymmetric routing*: management-cluster pods reach the VIP via
    `br-baremetal`, but the VM's response (destined back to the pod
    network) routes out its **other** NIC (`eth0`, the pod network's
    default route) -- Kind's default `rp_filter=1` (strict) would drop that
    as spoofed. Both fixups are applied by the same DaemonSet
    (`Metal3/kubevirtbmc-test/network-fixups-daemonset.yaml`).


## Patches Applied to KubeVirtBMC

All patches are committed on branch `lentzi90/metal3-fixes-v0.10.0`.

| Commit | Fix | Status |
|--------|-----|--------|
| `3bd70b5` | InsertMedia cleans up existing DataVolume before retry | ✅ Ready for upstream |
| `bb044e3` | InsertMedia removes existing cdrom volume to avoid duplicate-name admission error | ✅ Ready for upstream |
| `dec997d` | EjectMedia clears in-memory state on "no media inserted" error | ✅ Ready for upstream |
| `fef46c7` | Retry InsertMedia VM update on conflict to handle concurrent KubeVirt modifications during reprovision | ✅ Ready for upstream |
| `e9f75df` | PowerOn waits for DataVolume imports to complete before returning | ✅ Ready for upstream — real functional gap: upstream's Try-Then-Verify PowerOn calls `Start()` and returns based on VM/VMI state alone, with no DV-import wait |
| `77bade6` | Test updates matching the behavior changes above | — test-only |

## Current Status

| Step | Result |
|------|--------|
| Kind cluster + KubeVirt + CDI + cert-manager | ✅ |
| KubeVirtBMC deployment (5-patch images, v0.10.0 base) | ✅ |
| CAPI + Metal3 + IPAM installation | ✅ |
| IrSO + Ironic (TLS) + BMO installation | ✅ |
| In-cluster image server (nginx + hostPath) | ✅ |
| DataVolume binds on default `standard` StorageClass | ✅ |
| CDI DataVolume trusts Ironic's CA (baked into `cdi-importer` image) | ✅ |
| VirtualMachine creation with PVC rootdisk | ✅ |
| VirtualMachineBMC creation and Redfish service | ✅ |
| BMH registration → inspecting → available | ✅ |
| CAPI cluster creation and BMH claim | ✅ |
| Ironic deploy ISO CDI DataVolume import over HTTPS (inspection + provisioning) | ✅ |
| IPA ramdisk boot, hardware inspection, disk image write, reboot into Ubuntu 24.04 | ✅ |
| Workload cluster kube-apiserver reachable in-cluster (via kube-vip VIP `192.168.100.100:6443` on `baremetal-net`) | ✅ |
| Final cluster state | `Cluster` phase `Provisioned`, `KubeadmControlPlane` `Available`, both `Machine`s `Running`, both workload nodes `Ready` (`kubevirt-node-0`, `kubevirt-node-1`) |

## Full Setup Procedure (From Scratch)

The script `dev-setup-kubevirtbmc.sh` assumes the Kind cluster, KubeVirt, CDI,
and cert-manager are already installed. The complete sequence from a blank VM is:

### Phase 0 — Prerequisites (one-time, outside the script)

```bash
# 1. Create Kind cluster with KVM passthrough
kind create cluster --name kind \
  --config Metal3/kind-kubevirtbmc.yaml

# 2. Install KubeVirt
kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/v1.8.1/kubevirt-operator.yaml
kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/v1.8.1/kubevirt-cr.yaml

# 3. Install CDI
CDI_VERSION=v1.65.0
kubectl apply -f "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-operator.yaml"
kubectl apply -f "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-cr.yaml"

# 4. Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.17.2/cert-manager.yaml

# 5. Wait for everything to be ready
kubectl -n cert-manager wait deployment --all --for condition=Available --timeout=180s
kubectl -n kubevirt wait kv kubevirt --for condition=Available --timeout=600s
kubectl -n cdi wait cdi cdi --for condition=Available --timeout=300s

# 6. Enable DeclarativeHotplugVolumes feature gate (required for virtual media)
kubectl patch kubevirt kubevirt -n kubevirt --type merge \
  -p '{"spec":{"configuration":{"developerConfiguration":{"featureGates":["DeclarativeHotplugVolumes"]}}}}'
```

### Phase 1 — Build and load KubeVirtBMC images

```bash
# The patched images only need rebuilding when the source changes.
# If images already exist in the local Docker daemon, skip the build steps.
docker build -t kubevirtbmc/virtbmc-controller:metal3-patch ../kubevirtbmc/
docker build -f ../kubevirtbmc/Dockerfile.virtbmc \
  -t kubevirtbmc/virtbmc:metal3-patch ../kubevirtbmc/

kind load docker-image kubevirtbmc/virtbmc-controller:metal3-patch --name kind
kind load docker-image kubevirtbmc/virtbmc:metal3-patch --name kind
```

### Phase 2 — Copy the OS image into the Kind node

**Important**: `/tmp` inside the Kind node is a `tmpfs` mount.
`docker cp` writes through the overlay filesystem and therefore *cannot reach*
tmpfs-mounted paths. Use `docker exec -i` with a shell pipe instead:

```bash
NODE=kind-control-plane
docker exec "$NODE" bash -c "mkdir -p /tmp/metal3-images"
docker exec -i "$NODE" bash -c \
  "cat > /tmp/metal3-images/ubuntu-2404.img" \
  < Metal3/images/ubuntu-2404.img
docker exec -i "$NODE" bash -c \
  "cat > /tmp/metal3-images/ubuntu-2404.img.sha256sum" \
  < Metal3/images/ubuntu-2404.img.sha256sum
```

If the image has not been downloaded yet:
```bash
mkdir -p Metal3/images
wget -O Metal3/images/ubuntu-2404.img \
  https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img
pushd Metal3/images && sha256sum ubuntu-2404.img > ubuntu-2404.img.sha256sum && popd
```

### Phase 3 — Run the stack setup script

```bash
# The script will:
#   - Deploy KubeVirtBMC with patched images
#   - Patch CDI StorageProfile for the default StorageClass
#   - Deploy in-cluster image server
#   - Install Multus + the baremetal-net bridge network (for kube-vip)
#   - Install CAPI + Metal3 + IPAM
#   - Install IrSO + Ironic (TLS via cert-manager) + BMO
#   - Bake Ironic's CA into cdi-importer/virtbmc images and switch CDI/
#     KubeVirtBMC to use them
bash Metal3/dev-setup-kubevirtbmc.sh
```

### Phase 4 — Create VMs, BMHs, and the workload cluster

```bash
# Wait for Ironic to be ready
kubectl wait --for=condition=Available --timeout=300s \
  deployment/ironic-service -n baremetal-operator-system

# Apply the network-fixups DaemonSet: proxy_arp (pod-network VM<->pod
# connectivity, Issue 2) and rp_filter loosening (asymmetric routing for
# the kube-vip VIP on baremetal-net, see Key Design Decision 6)
kubectl apply -f Metal3/kubevirtbmc-test/network-fixups-daemonset.yaml

# Fix CAPI RBAC: add create+delete on ConfigMaps so the CRS controller can
# set ownerReferences on the Calico ConfigMap
kubectl get clusterrole capi-manager-role -o json | \
  python3 -c "
import json, sys
role = json.load(sys.stdin)
for rule in role['rules']:
    if 'configmaps' in rule.get('resources', []):
        verbs = set(rule.get('verbs', []))
        verbs.update(['create', 'delete'])
        rule['verbs'] = sorted(verbs)
print(json.dumps(role, indent=2))
" | kubectl apply -f -

# Create 2 VMs + BMHs (1 CP + 1 worker)
NUM_BMH=2 ./Metal3/create-kubevirt-bmhs.sh

# Apply the CAPI cluster manifests
kubectl apply -k Metal3/cluster-kubevirt
```

### Phase 5 — Monitor key milestones

| Milestone | Command to watch |
|-----------|----------------|
| BMH available | `kubectl get bmh -w` |
| CP provisioned | `kubectl get bmh,machine -w` |
| kubeadm init | SSH to VM: `cloud-init status` or `journalctl -u cloud-final -f` |
| CP Node Ready | `kubectl exec kctl -- kubectl --kubeconfig=/tmp/wl.yaml get nodes -w` |
| Calico pods up | `kubectl exec kctl -- kubectl --kubeconfig=/tmp/wl.yaml get pods -n kube-system -w` |
| Worker provisioned | `kubectl get bmh,machine -w` |
| Worker Node Ready | `kubectl exec kctl -- kubectl --kubeconfig=/tmp/wl.yaml get nodes -w` |

The kubeconfig for the workload cluster is accessed from a helper pod:

```bash
kubectl get secret kubevirt-test-1-kubeconfig \
  -o jsonpath='{.data.value}' | base64 -d > /tmp/wl.yaml
kubectl run kctl -n default \
  --image=bitnami/kubectl --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"kctl","image":"bitnami/kubectl","command":["sleep","3600"]}]}}'
kubectl wait pod/kctl -n default --for=condition=Ready --timeout=60s
kubectl cp /tmp/wl.yaml kctl:/tmp/wl.yaml -n default
kubectl exec kctl -n default -- kubectl --kubeconfig=/tmp/wl.yaml get nodes
```
