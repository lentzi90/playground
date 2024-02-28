## Why use Kamaji with Metal3
- Save resources
- Reduce operational burden
- Speed up control plane management
- Greater flexibility
---
## 1 Multi-workers cluster vs. Multi 1-worker clusters
---
## 1-node clusters vs. Kamaji-hosted clusters
- Save resources
Note: Kamaji, by default, has 1 etcd cluster with 3 members that is shared among all the tenant CPs. It means you don't need to have 1 etcd for every cluster (this number can be configured). 
- Worker nodes don't have to run as CPs
- Easy to manage: All CPs in one place
- **Pull mode** vs. **Push mode**
Note: If you use a Multi-cluster management, like Karmada, you can assume connections to CPs and manage the clusters kubeconfig directly (pull mode), instead of having to install an agent on each of the member clusters
---
## Setup
---
## Demo
