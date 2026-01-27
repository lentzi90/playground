# FLux

Create a cluster and install the flux-operator.
The `flux.yaml` then takes care of installing flux itself and syncing the state from the repository.
It will install cert-manager, CAPI-operator, ORC and CAPI, Metal3 and CAPO.

```bash
kind create cluster
kubectl apply -f https://github.com/controlplaneio-fluxcd/flux-operator/releases/latest/download/install.yaml
kubectl apply -f flux/flux.yaml
```
