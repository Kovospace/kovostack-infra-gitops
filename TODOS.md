# TODOS

## Nice to have in the future

### Publish charts/app to the OCI registry

**This is now the only way to get chart version pinning.** Tagging the chart in
this repo was tried and does not work: ArgoCD refuses a multi-source Application
that references two revisions of the same repository, and the `$values` source
must stay on `main` so CI deploys take effect.

```
cannot reference a different revision of the same repository
($values references "…" while the application references "chart-app-1.0.0")
```

An OCI registry is a different repository as far as ArgoCD is concerned, so the
conflict disappears:

```yaml
sources:
  - repoURL: registry.matejkovac.sk/charts   # no protocol prefix
    chart: app
    targetRevision: 1.1.0                     # pinned
    helm:
      valueFiles:
        - $values/applications/nsr/values.yaml
        - $values/versions/nsr.yaml
  - repoURL: git@github.com:Kovospace/kovostack-infra-gitops.git
    targetRevision: main                      # values stay live
    ref: values
```

**Why it matters:** today every app tracks `charts/app` at `main`, so a chart
change reaches all of them on the next reconcile. The PVC sync-wave deadlock and
the `Prune=false` sync block each broke every workload simultaneously for
exactly this reason. Pinned versions turn that into a per-app upgrade you can
stage.

What it needs:

- zot already reserves `charts/**` in its `accessControl`.
- A **push robot** — the existing `k8s` identity is read-only and must stay so.
- CI: `helm package` + `helm push oci://registry.matejkovac.sk/charts` on tags
  matching `chart-<name>-<semver>`, the convention already in use.
- The registry registered in ArgoCD as a Helm repo (`type: helm`,
  `enableOCI: true`) with credentials — another bootstrap secret, same shape as
  the Infisical and deploy-key ones.

The chart does not have to move repositories for this; only the published
artifact needs to live in the registry. Splitting `charts/` into its own repo is
a separate decision and is not required.

### Backup CronJob for persistent volumes

Nothing currently backs up PVC contents. `local-path-retain` protects against a
deleted claim, but not against a lost VM or a corrupted file — and neither does
git. **Restoring the cluster from this repo produces a healthy app with an empty
database and no uploads.** Infisical covers the secrets; nothing covers the data.

Add an opt-in CronJob to `charts/app`, driven by the existing `persistence`
entries:

```yaml
backup:
  enabled: true
  schedule: "0 3 * * *"
  sqlite: /app/data/payload.db   # optional: consistent DB snapshot
  destination: s3:...            # restic repo
```

**The part that must not be got wrong:** a live SQLite file cannot be backed up
with `cp`/`tar`. A copy taken mid-transaction restores as a corrupt database,
and the failure is silent until the restore. Use SQLite's own snapshot:

```bash
sqlite3 /app/data/payload.db ".backup '/tmp/snapshot.db'"
```

then push the snapshot and the uploads directory with `restic` (deduplicating,
with history, and it can verify a restore).

Requirements worth settling before building it:

- Off-VM destination — a backup on the same disk protects against nothing that
  actually happens.
- Restore **tested**, not assumed. An untested backup is a guess.
- Retention, so it neither grows forever nor keeps only yesterday's corruption.
- Alert on failure; a silently broken backup is worse than none, because it
  stops anyone worrying about it.

**Consider instead:** the platform already runs Postgres, and Payload has a
Postgres adapter. Moving the database there reduces this to backing up uploads
only, and inherits whatever backup story Postgres gets anyway.

### Infisical Kubernetes auth instead of a static machine identity

Today the `ClusterSecretStore` authenticates with Universal Auth — a long-lived
`clientId`/`clientSecret` pair held in the `infisical-credentials` Secret and
applied by hand (`bootstrap/infisical-credentials.example.yaml`). It is the one
credential in the cluster that cannot come from external-secrets, because it is
what external-secrets authenticates with.

The ESO Infisical provider also supports `kubernetesAuthCredentials`, where the
cluster proves its identity with its own ServiceAccount token instead:

```yaml
auth:
  kubernetesAuthCredentials:
    identityId:                 # not a secret — an Infisical identity UUID
      name: infisical-identity
      key: identityId
      namespace: external-secrets
    serviceAccountTokenPath: {} # defaults to the projected token path
```

**Why it would be nice**

- No long-lived shared secret to store, rotate, or leak.
- Credentials become short-lived and automatically rotated by Kubernetes.
- The bootstrap stops depending on a manual step that git does not record — a
  cluster rebuild would need only the identity UUID, which is not sensitive.

**Why it was not done now**

It inverts the dependency. Infisical must validate the ServiceAccount token by
calling the cluster's TokenReview API, but Infisical runs in Docker on the host,
outside the cluster. Making that work means:

- routing Infisical → k3s API server (`:6443`) from inside its container, the
  same host-gateway problem that `CLUSTER_INGRESS_IP` solves in the other
  direction;
- giving Infisical credentials and CA trust for the k3s API;
- accepting that Infisical then needs the cluster to be reachable in order to
  serve secrets, coupling two systems that are currently independent.

That is a substantial integration to remove a single credential, and it makes
the platform's secret store depend on the cluster it is meant to bootstrap.

**Revisit when** Infisical moves into the cluster, or a second cluster/consumer
makes one static credential per consumer genuinely burdensome.

**Cheaper alternative if the goal is only "reproducible from git":** SOPS + age
or Sealed Secrets, committing the credential as ciphertext. Cost is a
decryption key that must be backed up outside the cluster.

**Related, and independent of all of the above:** Kubernetes Secrets are
base64-encoded, not encrypted, in etcd. `k3s server --secrets-encryption`
protects this credential, the repo deploy key and every synced app secret at
once, for far less effort than any option here.