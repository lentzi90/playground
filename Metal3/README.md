# Metal3 + KubeVirt + KubeVirtBMC Dev Lab

## Overview

This is a self-contained development lab for exercising the [Metal3](https://metal3.io/)
bare-metal provisioning stack (Ironic + Ironic Standalone Operator + Bare
Metal Operator + Cluster API Provider Metal3) **without any physical
hardware**. [KubeVirt](https://kubevirt.io/) VMs stand in for bare-metal
servers, and [KubeVirtBMC](https://github.com/kubevirtbmc/kubevirtbmc)
exposes a Redfish (virtual media) BMC in front of each VM, so Ironic can
inspect, PXE-less-deploy, and power-cycle them exactly as if they were real
machines with a BMC. Everything runs inside a single Kind cluster: the
management components, the simulated bare-metal VMs, and (once provisioned)
the workload cluster's control-plane and worker nodes.

The goal is a fast, disposable, laptop-friendly environment for testing
Metal3/CAPM3 changes, Ironic behavior, and KubeVirtBMC itself — not a
production-representative deployment.

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
  bridge device at all). Used for everything that only needs routed IP
  reachability to the management cluster: Ironic, the image server, the
  KubeVirtBMC agent, and CAPI's own connectivity to the workload cluster's
  API server.
- **`eth1` / `baremetal-net`** — a second NIC via Multus, backed by the
  plain CNI `bridge` plugin (see [`kubevirt-baremetal-network.yaml`](kubevirt-baremetal-network.yaml)),
  which creates a genuine Linux bridge (`br-baremetal`) on the Kind node.
  All VMs attached to it share a real L2/broadcast domain, exactly like a
  rack of servers on a switch. This is what makes `kube-vip` (ARP mode)
  viable: the VIP's gratuitous ARP announcements actually propagate and can
  be redirected on failover.

## Key design decisions

1. **TLS for Ironic, with CA trust baked into images.** Ironic's httpd
   (image service) is exposed over HTTPS using a cert-manager-issued
   certificate (see [`ironic/certificate.yaml`](ironic/certificate.yaml)).
   Both the CDI importer (which downloads DataVolume contents) and the
   KubeVirtBMC `virtbmc` agent (which calls `GetRemoteFileSize` over HTTPS)
   need to trust Ironic's CA. Rather than a DataVolume `certConfigMap`
   field, an agent env var, or a mutating admission webhook, Ironic's CA is
   baked directly into custom variants of the `cdi-importer` and `virtbmc`
   images at build time (see [`ironic-ca-images/`](ironic-ca-images/)),
   built on stock **upstream** images with **no source changes at all** —
   just a CA cert copied into the trust store. [`dev-setup.sh`](dev-setup.sh)
   does this automatically: it extracts the CA from the `ironic-cacert`
   Secret (cert-manager, in `baremetal-operator-system`), builds the
   CA-trusting image variants, loads them into Kind, and points CDI's
   `cdi-operator` (`IMPORTER_IMAGE` env var) and KubeVirtBMC's controller
   (`--agent-image-tag` flag) at them. This works because Go's pure-Go
   `x509.SystemCertPool()` on Linux always reads well-known OS trust-store
   paths (e.g. `/etc/ssl/certs/ca-certificates.crt`) with no `cgo` or env
   var needed. See [`ironic-ca-images/README.md`](ironic-ca-images/README.md)
   for details, and the caveat that these images need rebuilding if
   Ironic's CA is ever rotated.
2. **Bridge networking on the pod network.** VMs use KubeVirt `bridge`
   binding with the default `pod` network for `eth0`.
   [`create-bmhs.sh`](create-bmhs.sh) uses `bridge: {}`, which also gives
   the VM access to ClusterIP services through the pod network's routing.
   This network alone is *not* sufficient for kube-vip.
3. **kube-vip on a second, real-L2 network (`baremetal-net`), not a
   Service.** Kind's default pod network has no real L2 broadcast domain
   (only point-to-point veth+routes), so a gratuitous ARP announcing a
   floating VIP never propagates. Attaching a **second NIC via Multus,
   backed by the CNI `bridge` plugin**
   ([`kubevirt-baremetal-network.yaml`](kubevirt-baremetal-network.yaml))
   creates a real Linux bridge (`br-baremetal`) — a genuine L2 segment
   where kube-vip's ARP mode works. [`cluster/kcp.yaml`](cluster/kcp.yaml)
   deploys kube-vip as a static pod, with `vip_interface` resolved at boot
   via a MAC-address lookup (`52:54:00:10:00:xx`, see
   [`create-bmhs.sh`](create-bmhs.sh)).
4. **In-cluster image server.** An Ubuntu 24.04 cloud image is served by an
   nginx pod with a hostPath mount, using a fixed ClusterIP
   (`10.96.200.200:8080`); see [`image-server.yaml`](image-server.yaml).
5. **StorageClass for CDI DataVolumes.** KubeVirtBMC sets the
   `cdi.kubevirt.io/storage.bind.immediate.requested` annotation on every
   DataVolume it creates, so CDI binds the PVC immediately even on a
   `WaitForFirstConsumer` StorageClass. The default Kind `standard`
   StorageClass works out of the box, with its `StorageProfile.claimPropertySets`
   patched (see [`dev-setup.sh`](dev-setup.sh)).
6. **`proxy_arp` and `rp_filter` fixups on veth interfaces.** With KubeVirt
   bridge networking in Kind, the VM gets a pod-subnet IP via DHCP but sees
   the entire `/24` as directly connected. Return traffic to other pods
   fails because the host veth doesn't proxy-ARP by default. Setting
   `net.ipv4.conf.default.proxy_arp=1` and enabling proxy_arp on all
   existing veths is required for pod-to-VM connectivity. Separately,
   kube-vip's VIP on `baremetal-net` introduces *asymmetric routing*:
   management-cluster pods reach the VIP via `br-baremetal`, but the VM's
   response routes out its **other** NIC (`eth0`, the pod network's default
   route) — Kind's default `rp_filter=1` (strict) would drop that as
   spoofed. Both fixups are applied by the same DaemonSet
   ([`kubevirtbmc-test/network-fixups-daemonset.yaml`](kubevirtbmc-test/network-fixups-daemonset.yaml)).

## Setup

### Prerequisites

Before running anything in this directory, you need a Kind cluster with:

- Named `kubevirtbmc-test` (or set `CLUSTER_NAME` to match) with
  `/dev/kvm` passthrough — see [`kind.yaml`](kind.yaml).
- [KubeVirt](https://kubevirt.io/) installed, with the
  `DeclarativeHotplugVolumes` feature gate enabled.
- [CDI](https://github.com/kubevirtsig/containerized-data-importer)
  (Containerized Data Importer) installed, with a StorageProfile for
  local-path storage.
- [cert-manager](https://cert-manager.io/) installed (used to issue
  Ironic's TLS certificate).

Everything else — KubeVirtBMC, Multus, CAPI/CAPM3, IrSO, Ironic, BMO — is
installed by the scripts below.

### 1. Run `dev-setup.sh`

```bash
./Metal3/dev-setup.sh
```

This single script (see its header comment for the full numbered list)
will:

1. Clean up any leftover VMs/BMHs/PVCs from a previous run.
2. Install upstream KubeVirtBMC directly from its GitHub release manifest
   (`kubevirtbmc-install.yaml`).
3. Patch the `standard` StorageProfile and raise CDI's filesystem overhead
   so DataVolume imports bind and fit correctly.
4. Download the Ubuntu 24.04 cloud image, copy it into the Kind node, and
   deploy the in-cluster image server (fixed ClusterIP `10.96.200.200:8080`).
5. Install the `bridge` CNI plugin binary on the Kind node, install Multus,
   and create the `baremetal-net` NetworkAttachmentDefinition.
6. Run `clusterctl init --infrastructure=metal3 --ipam=metal3` (with
   `CLUSTER_TOPOLOGY=true`).
7. Install IrSO (Ironic Standalone Operator) and then Ironic itself (with
   TLS), retrying the apply a few times in case the IrSO webhook isn't
   ready yet.
8. Bake Ironic's CA into CA-trusting `cdi-importer` and `virtbmc` image
   variants, load them into Kind, and point CDI/KubeVirtBMC at them (see
   [Key design decision 1](#key-design-decisions) above).
9. Install BMO (Bare Metal Operator).
10. Apply `setup-scripts` (provides the `install-k8s` secret consumed by
    `cluster/kcp.yaml`/`cluster/kct.yaml`).
11. Ensure the `bmc-creds` and `user-data` Secrets exist.

The script prints a "Next steps" summary at the end, which the remaining
steps below follow.

### 2. Phase 1 — create a BMH and validate inspection

Wait for Ironic, then create a single VM + BMH and watch it move through
inspection:

```bash
kubectl wait --for=condition=Available --timeout=300s \
  deployment/ironic-service -n baremetal-operator-system

NUM_BMH=1 ./Metal3/create-bmhs.sh

kubectl get bmh -w        # expect: registering → inspecting → available
kubectl get dv -w         # IPA ramdisk download
kubectl logs -n baremetal-operator-system deploy/ironic-service -f --tail=50
kubectl logs -l app=virtbmc -f --tail=50
```

`create-bmhs.sh` creates, per BMH: a root-disk PVC, a KubeVirt
`VirtualMachine` (two NICs — `default`/pod network and
`baremetal`/`baremetal-net` via Multus, both `bridge` binding), a
`VirtualMachineBMC`, and a `BareMetalHost` pointing at that VM's Redfish
endpoint. It waits on `condition=ServiceReady` (the KubeVirtBMC ≥ v0.10.0
condition type; see [`troubleshooting.md`](troubleshooting.md)).

### 3. Phase 2 — trigger provisioning

Once the BMH from Phase 1 is `available`, patch it directly to provision
an image (the `user-data` Secret was already created by `dev-setup.sh`):

```bash
kubectl patch bmh kubevirt-node-0 --type=merge \
  -p '{"spec":{"image":{"url":"http://10.96.200.200:8080/ubuntu-2404.img","checksum":"http://10.96.200.200:8080/ubuntu-2404.img.sha256sum","checksumType":"sha256"},"userData":{"name":"user-data","namespace":"default"}}}'

kubectl get bmh -w        # expect: available → provisioning → provisioned
```

### 4. Phase 3 — deploy the workload cluster

Clean up the single-BMH test resources with
[`delete-bmhs.sh`](delete-bmhs.sh) if you want a clean slate, then:

```bash
# Required for pod<->VM connectivity and for the kube-vip VIP's asymmetric
# return path (see Key design decision 6 above).
kubectl apply -f Metal3/kubevirtbmc-test/network-fixups-daemonset.yaml

# Render this lab's Calico manifest (derived from the shared
# ../ClusterResourceSets/calico base, see cluster-resource-sets/calico/kustomization.yaml)
# into the file consumed by cluster-resource-sets/kustomization.yaml's configMapGenerator.
# Re-run this whenever ClusterResourceSets/calico or cluster-resource-sets/calico changes.
kustomize build Metal3/cluster-resource-sets/calico > Metal3/cluster-resource-sets/calico.yaml

# Apply the ClusterResourceSet(s), kept separate from the Cluster API
# resources below (see Metal3/cluster-resource-sets/kustomization.yaml),
# mirroring how ../ClusterResourceSets is applied independently of the CAPO
# cluster manifests. --server-side is required: the calico-cni ConfigMap
# wraps the full ~300 KB Calico manifest, and client-side apply's
# kubectl.kubernetes.io/last-applied-configuration annotation would push the
# object's total annotations size over the Kubernetes API's 256 KiB limit.
kubectl apply --server-side -k Metal3/cluster-resource-sets

# Create 2 VMs+BMHs (index 0 = control plane, index 1+ = workers) and
# apply the Cluster API resources.
NUM_BMH=2 ./Metal3/create-bmhs.sh
kubectl apply -k Metal3/cluster
```

`Metal3/cluster` (see [`cluster/kustomization.yaml`](cluster/kustomization.yaml))
creates the `Cluster`, `Metal3Cluster` (with the kube-vip VIP
`192.168.100.100:6443` as `controlPlaneEndpoint`), `KubeadmControlPlane`
(embeds the kube-vip static pod manifest and the `preKubeadmCommands` that
detect the `baremetal-net` NIC by MAC and bring it up before `kubeadm
init`), `KubeadmConfigTemplate`/`MachineDeployment` for the worker(s), and
`Metal3DataTemplate`s. The `Cluster` is labeled `cni: calico`, which is what
the `ClusterResourceSet` applied from `Metal3/cluster-resource-sets` (see
[Key design decision 7](#key-design-decisions) below) selects on to deliver
Calico.

### 5. Reach the workload cluster

Once the control-plane `BareMetalHost` has provisioned and kube-vip has
claimed the VIP, fetch the workload cluster's kubeconfig from the Cluster
API `Secret`:

```bash
kubectl get secret kubevirt-test-1-kubeconfig \
  -o jsonpath='{.data.value}' | base64 -d > /tmp/wl.yaml
```

The VIP (`192.168.100.100`) lives on `baremetal-net`, which is only
reachable from inside the management cluster (via the Kind node's root
network namespace) — not from your workstation. To talk to the workload
API server, run a helper pod inside the management cluster:

```bash
kubectl run kctl --image=bitnami/kubectl --restart=Never --command -- sleep 3600
kubectl wait --for=condition=Ready pod/kctl --timeout=60s
kubectl cp /tmp/wl.yaml kctl:/tmp/wl.yaml
kubectl exec kctl -- kubectl --kubeconfig=/tmp/wl.yaml get nodes
kubectl delete pod kctl
```
