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

## Pulling from the private registry

zot denies anonymous access, so an image from it needs a credential. The chart
renders one **automatically when `image` starts with `registry.host`**: a public
image gets nothing, `registry.matejkovac.sk/apps/nsr` gets a
`kubernetes.io/dockerconfigjson` Secret named `<name>-registry` plus the
matching `imagePullSecrets` entry.

There is no dockerconfigjson in git, and there should never be one — that file
is base64, not encryption, so committing it publishes the robot's password. Git
holds only the *name* of the Infisical key; the value is fetched by
external-secrets and assembled in the cluster.

```
Infisical  /platform/ZOT_K8S_PASSWORD
      │  external-secrets, hourly
      ▼
Secret  <app>-registry   (kubernetes.io/dockerconfigjson, one per namespace)
      │
      ▼
kubelet pulls  registry.matejkovac.sk/apps/<app>
```

- The credential is the read-only **`k8s` robot** from zot's `accessControl`: it
  can pull `apps/**` and `charts/**` and push nothing, so a compromised node
  cannot overwrite an image.
- One Secret per namespace — `imagePullSecrets` cannot cross namespaces. It is
  the same robot each time, not one per app.
- Set `registry.pullSecret: true` for an app whose workload lives in its own
  chart: `image` is empty here, so there is nothing to detect. That chart then
  references `<name>-registry` itself.
- Rotating the password is a change in Infisical only. New pulls pick it up on
  the next refresh; running pods are unaffected, their pull already happened.

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
- **`Delete=false` on every PVC**, so the claim is not swept up when the
  Application itself is deleted. Normal pruning still works, so the app never
  gets stuck OutOfSync.

**What actually protects the data is the StorageClass, not the annotation.**
`local-path-retain` sets `reclaimPolicy: Retain`, so deleting a PVC leaves the
PV and the files on disk. That holds however the claim is removed — pruned by
ArgoCD, deleted by hand, or lost with the namespace.

The limit worth knowing: a retained volume does **not** reattach automatically.
Delete a PVC and recreate it and you get a fresh, empty volume; the old data
sits in a `Released` PV, readable straight off the filesystem and reattachable
only by clearing its `claimRef` by hand:

```bash
kubectl get pv                     # find the Released one
kubectl patch pv <pv> -p '{"spec":{"claimRef":null}}'
```

So the guarantee is "your data is never destroyed", not "your data always comes
back by itself".

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