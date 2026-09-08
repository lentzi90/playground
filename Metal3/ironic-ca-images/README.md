# Ironic CA-Trust Images

Bakes Ironic's cert-manager-issued CA certificate directly into the
`cdi-importer` and KubeVirtBMC `virtbmc` agent images, so both trust
Ironic's HTTPS endpoint without any DataVolume `certConfigMap` field, agent
env var, or mutating admission webhook. See the "Key design decisions"
section in `../README.md` for the full writeup and rationale.

## Build

```bash
# Extract Ironic's CA cert directly from the cert-manager Secret
# (dev-setup.sh does this automatically in step 7b)
kubectl get secret ironic-cacert -n baremetal-operator-system \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > Metal3/ironic-ca-images/ironic-ca.crt

cd Metal3/ironic-ca-images

docker build -f Dockerfile.cdi-importer \
  --build-arg CDI_IMPORTER_IMAGE=quay.io/kubevirt/cdi-importer:v1.65.0 \
  -t cdi-importer:ironic-ca .

docker build -f Dockerfile.virtbmc-agent \
  --build-arg VIRTBMC_AGENT_IMAGE=kubevirtbmc/virtbmc:v0.10.0 \
  -t kubevirtbmc/virtbmc:v0.10.0-ca .

kind load docker-image cdi-importer:ironic-ca --name <cluster>
kind load docker-image kubevirtbmc/virtbmc:v0.10.0-ca --name <cluster>
```

## Deploy

`dev-setup.sh` does this automatically (step 7b). To do it by hand:

```bash
kubectl -n cdi set env deployment/cdi-operator \
  IMPORTER_IMAGE=cdi-importer:ironic-ca

kubectl -n kubevirtbmc-system patch deployment kubevirtbmc-controller-manager \
  --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/args/5","value":"--agent-image-tag=v0.10.0-ca"}]'
```

(Adjust the JSON Patch index if the controller's args list differs; find the
`--agent-image-tag=...` entry's index first with
`kubectl get deployment kubevirtbmc-controller-manager -n kubevirtbmc-system -o jsonpath='{.spec.template.spec.containers[0].args}'`.)

This is the CA-trust approach used by default in `dev-setup.sh`; no admission webhook is deployed.

## Why this works

Both `cdi-importer` and `virtbmc` are Go binaries. On Linux, Go's pure-Go
`x509.SystemCertPool()` always reads from a fixed list of well-known OS
trust-store file paths (never via cgo or an OS API call). Overwriting the
right file with a CA bundle that includes Ironic's CA is enough:

- `cdi-importer` is CentOS Stream 9 based and ships `update-ca-trust`, so we
  drop the cert into `/etc/pki/ca-trust/source/anchors/` and run
  `update-ca-trust extract`.
- `virtbmc`'s final image is `gcr.io/distroless/static:nonroot`, which has no
  shell/`update-ca-certificates`. Instead, a throwaway Alpine stage merges
  the bundle, and the result is copied directly over
  `/etc/ssl/certs/ca-certificates.crt` in the final stage.

## Caveat

The CA is baked in at image-build time. If Ironic's CA is ever rotated (not
its leaf cert — cert-manager typically rotates leaf certs automatically
while the CA itself is long-lived), these images need rebuilding. The
`ironic-ca-webhook` alternative reads the ConfigMap live and doesn't have
this limitation, at the cost of running an extra admission webhook.
