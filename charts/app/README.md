# charts/app

The repeating resources every migrated app needs, driven by one value.

`name` decides everything:

| | derived as |
|---|---|
| namespace | `<name>` |
| Infisical folder | `/<name>` |
| synced Secret | `<name>-secrets` |
| TLS Secret | `<name>-tls` |
| Service / Ingress / Deployment | `<name>` |

So a whole app can be:

```yaml
# applications/whoami/values.yaml
name: whoami
image: traefik/whoami
host: whoami.matejkovac.sk
containerPort: 80
```

That renders a Namespace, an ExternalSecret syncing Infisical `/whoami`, a
Deployment with those secrets as env vars, a Service, and an Ingress with a
cert-manager certificate.

## What renders when

Two values act as switches, so the chart also suits apps that are not a simple
web deployment:

- **`image` empty** → no Deployment or Service. Namespace, secrets and ingress
  only, for an app whose workload comes from its own chart.
- **`host` empty** → no Ingress or certificate. For workers, cron jobs and
  anything with no public route.
- **`secrets.enabled: false`** → no ExternalSecret, for an app with no secrets.

## Secrets

Everything in the app's Infisical folder is synced into one Secret and mounted
with `envFrom`, so **adding a secret in Infisical requires no change in git** —
it appears as an env var on the next refresh (default hourly).

Consequences worth knowing:

- Infisical key names become env var names verbatim. Name them as such
  (`DATABASE_URL`, not `database url`).
- Everything in the folder reaches the container. Don't park unrelated secrets
  in an app's folder.
- The Secret is `creationPolicy: Owner`, so deleting the app deletes its
  credentials from the cluster rather than orphaning them.

Override the folder with `secrets.path` only when an app genuinely cannot own
one named after itself — the convention is the feature.

## Storage

Each `persistence` entry becomes a PVC named `<name>-<key>`, mounted at its
`mountPath`:

```yaml
persistence:
  data:
    size: 1Gi
    mountPath: /app/data
  uploads:
    size: 10Gi
    mountPath: /app/uploads
```

Three things the chart does on your behalf, all of them about not losing data:

- **`Recreate` deployment strategy** as soon as any volume exists. A rolling
  update starts the new pod before stopping the old one, and a ReadWriteOnce
  volume cannot attach to both — the new pod blocks on attach, and if it ever
  did succeed, two processes sharing one SQLite file corrupt it.
- **`replicas > 1` is refused** with a ReadWriteOnce volume, at template time
  rather than as a pod stuck in `ContainerCreating`.
- **`Prune=false` on every PVC.** ArgoCD will not delete a claim when it
  disappears from git, so a rename, a removed entry or a mistaken `git rm`
  cannot destroy the data. The cost is that genuinely removing a volume needs a
  deliberate `kubectl delete pvc`.

Two caveats specific to this cluster, both from k3s' default `local-path`
class:

- **The data lives on one node's disk.** There is no replication and no
  snapshot. Anything here needs its own backup — the cluster is not one.
- **No `allowVolumeExpansion`.** Growing a volume later means creating a new
  claim and copying, so size with headroom now.

## Local rendering

```bash
helm template whoami charts/app -f applications/whoami/values.yaml
```

Worth doing before every push. A values key this chart does not define is
silently ignored, exactly as with the upstream charts in `infrastructure/`.