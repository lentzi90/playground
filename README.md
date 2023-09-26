# Playground

Random stuff that I may want to store for later

## CAPO cluster-class

```bash
kind create cluster
clusterctl init --infrastructure=openstack
# Create cluster-class/clouds.yaml file to be used by CAPO
# Apply the cluster-class
kubectl apply -k cluster-class
```

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
