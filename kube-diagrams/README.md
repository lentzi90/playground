# Kube-diagrams

See https://github.com/philippemerle/KubeDiagrams

```bash
alias kube-diagrams='docker run -v "$(pwd)":/work philippemerle/kubediagrams kube-diagrams'
kube-diagrams -c kubediagram.yaml -o test.png test.yaml
kubectl get cluster,kubeadmcontrolplane,m3c,machine,m3mt,m3dt,m3m,bmh -o yaml | kube-diagrams -c kubediagram.yaml -o test.png -
```
