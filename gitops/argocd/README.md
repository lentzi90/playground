# Gitops with argocd

```bash
kind create cluster
export ARGOCD_VERSION=v3.2.6
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/core-install.yaml

kubectl apply -k argocd

# Until the below issue is resolved, it is necessary to do some kind of argocd
# command to initialize properly.
# https://github.com/argoproj/argo-cd/issues/12903
kubectl config set-context --current --namespace=argocd # change current kube context to argocd namespace
argocd --core login
argocd --core app list

argocd admin dashboard -n argocd
```
