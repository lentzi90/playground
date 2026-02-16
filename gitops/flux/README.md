# Flux

Create a cluster and install the flux-operator.
The `flux.yaml` then takes care of installing flux itself and syncing the state from the repository.
It will install cert-manager, CAPI-operator, ORC and CAPI, Metal3 and CAPO.

```bash
kind create cluster
kubectl apply -f https://github.com/controlplaneio-fluxcd/flux-operator/releases/latest/download/install.yaml
kubectl apply -f flux/flux.yaml
```

## Notifications

The `notifications.yaml` sets up webhook-based notifications for Flux events.
It includes:

- **Provider**: A generic webhook provider that sends to `http://host.docker.internal:8080/webhook`
- **flux-changes Alert**: Notifies on actual changes (new revisions, resources created/configured/deleted)
- **flux-errors Alert**: Notifies on all errors

### Testing Notifications

The webhook receiver runs as a pod inside the cluster for maximum portability.

1. Deploy the webhook receiver:

   ```bash
   kubectl apply -f webhook-receiver/deployment.yaml
   ```

2. Wait for it to be ready:

   ```bash
   kubectl wait -n webhook-receiver deployment/webhook-receiver --for=condition=Available --timeout=60s
   ```

3. Watch the logs to see incoming notifications:

   ```bash
   kubectl logs -n webhook-receiver -l app=webhook-receiver -f
   ```

4. To trigger a notification, you can:
   - Push a change to the repository
   - Force a reconciliation: `flux reconcile kustomization flux-system --with-source`
   - Introduce an error (e.g., reference a non-existent path)

### Filtering Logic

The alerts use `inclusionList` and `exclusionList` to filter out noise:

- **Included**: Events containing "stored artifact", "fetched revision", "created", "configured", "deleted", "Applied revision"
- **Excluded**: Events containing "no changes since", "next run in"

This ensures you only get notified when there's an actual change, not on every periodic reconciliation.
