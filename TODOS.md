# TODOS

## High priority

### Messaging infrastructure (a message broker)

The new-tab-links-backend replicas talk to each other through a messaging port
(`common/messaging` in that repository: `MessagePublisher`, `MessageSubscriber`,
`MessageTopic`), carried today by PostgreSQL `NOTIFY`/`LISTEN` on the
application's own database. That is enough for fan-out hints - the websocket
"your data changed" signal - and nothing more: no durability, no
acknowledgement, no work queues, payloads under 8 KB. More than that one use
will need a real broker, and nothing needing guaranteed delivery or competing
consumers should be built on the PostgreSQL transport meanwhile.

- **RabbitMQ** (its STOMP plugin is what Spring's broker relay speaks, should the
  websocket ever move there too) in its own namespace, `messaging`, run by the
  RabbitMQ Cluster Operator from an Application under `infrastructure/`.
- **One replica while the cluster is one node.** Write the pod anti-affinity
  anyway, and go to three replicas (quorum queues need a majority) once there
  are nodes to spread them over. Three replicas on one VM survive nothing but a
  pod crash and cost three times the memory.
- A **NetworkPolicy** letting only application namespaces reach it; a vhost and
  a user per application, credentials in Infisical; Prometheus metrics; memory
  limits (RabbitMQ blocks publishers at its memory watermark).
- The backend switches over with a new `newtablinks.messaging.transport` value
  and a transport implementation - no caller changes. Nothing here has to move
  in step with that beyond an env var.

## Nice to have in the future

### Publish charts/app to the OCI registry

Pinning itself is **already solved** — the chart moved to `kovostack-helm-charts`
and Applications pin git tags there. This is now only about publishing built
artifacts rather than consuming a git path: `helm search`, consumption from
outside these repos, and immutable packaged versions.

The original blocker, for the record — tagging the chart while it lived in this
repo failed because ArgoCD refuses a multi-source Application that references two
revisions of the same repository:

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

**What it would still add**, now that pinning works via git tags: `helm search`,
consumption from outside these repositories, immutable packaged artifacts rather
than a mutable git tag, and a natural home if a second chart appears. Worth
doing when a pipeline exists anyway — not urgent.

What it needs:

- zot already reserves `charts/**` in its `accessControl`.
- A **push robot** — the existing `k8s` identity is read-only and must stay so.
- CI: `helm package` + `helm push oci://registry.matejkovac.sk/charts` on tags
  matching `chart-<name>-<semver>`, the convention already in use.
- The registry registered in ArgoCD as a Helm repo (`type: helm`,
  `enableOCI: true`) with credentials — another bootstrap secret, same shape as
  the Infisical and deploy-key ones.

The chart already lives in `kovostack-helm-charts`, so this is purely about
publishing an artifact from it — the source does not move again.

### Backups for persistent volumes and databases — K8up, in progress

Nothing currently backs up PVC contents. `local-path-retain` protects against a
deleted claim, but not against a lost VM or a corrupted file — and neither does
git. **Restoring the cluster from this repo produces a healthy app with an empty
database and no uploads.** Infisical covers the secrets; nothing covers the data.

**Decided: K8up, not a hand-rolled CronJob in `charts/app`.** K8up runs restic
as Jobs from a per-namespace `Schedule`, handles repository init, retention
(prune) and checks, and streams database dumps through `PreBackupPod` /
backup-command annotations. Destination: a **Hetzner Storage Box** over SFTP,
through an in-cluster `rclone serve restic` gateway, because K8up has no SFTP
backend. A home Raspberry Pi running `rest-server` is a planned **second**
destination, not now. Design and procedures: `infrastructure/backup/README.md`.

**Done** (branch `feature/backups-k8up`):

- K8up operator, `infrastructure/k8up/` (chart 4.10.0, operator v2.16.0), wave 15.
- restic REST gateway, `infrastructure/backup/`: SSH key on port 23, pinned
  host key, basic auth, credentials from Infisical `/backup`, wave 15.
- Contract for the chart:
  `rest:http://restic-gateway.backup.svc.cluster.local:8080/<name>/`.
- Restore procedures written (restic CLI via the gateway; K8up `Restore`).

**Remaining:**

- `charts/app`: render the `Schedule` (backup + prune + check), the `/backup`
  ExternalSecret, and the database dump. The helm-chart-devops agent is doing
  this in parallel. Then raise `targetRevision` app by app.
- Manual: Storage Box sub-account, key, host key, Infisical `/backup`, automatic
  snapshots (listed in `infrastructure/backup/README.md`).
- The requirements below that are not met yet.

**Requirements, unchanged:**

- **SQLite must not be copied live.** A copy taken mid-transaction restores as
  a corrupt database, and the failure is silent until the restore. K8up backs
  up the PVC's files as they are, so an app on SQLite needs SQLite's own
  snapshot first — `sqlite3 /app/data/payload.db ".backup '/tmp/snapshot.db'"`
  as a backup command streamed to K8up, or a pre-backup step writing the
  snapshot into the volume — and must not rely on the raw `.db` file in the PVC
  snapshot.
- **Off-VM destination.** Met by the Storage Box once the manual steps are done.
- **Restore tested, not assumed.** An untested backup is a guess. Do procedure A
  in `infrastructure/backup/README.md` for every app after its first backup, and
  again periodically.
- **Retention**, so it neither grows forever nor keeps only yesterday's
  corruption: K8up `prune` in each Schedule (e.g. 7 daily, 4 weekly, 6 monthly),
  plus Storage Box snapshots for deletion/ransomware protection, since the
  gateway is deliberately not append-only.
- **Alert on failure.** Not built. Nothing in the cluster can alert today. The
  cheapest reliable option is a healthchecks.io dead-man's switch fed by the
  Schedule's `statsURL` (see `infrastructure/k8up/README.md`). A silently
  broken backup is worse than none, because it stops anyone worrying about it.

**Still worth considering:** the platform already runs Postgres, and Payload has
a Postgres adapter. Moving the database there removes the SQLite problem
entirely and leaves only uploads on the PVC.

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
### mirrord Operator — declined, use the open-source CLI

Developers run local processes inside this cluster with **mirrord**, set up as described in
`docs/mirrord.md`. That is the free, open-source CLI: it runs entirely from the developer's
machine against their kubeconfig and **installs nothing in the cluster**, which is why this
repository contains no mirrord manifests.

The **mirrord Operator** (mirrord for Teams, **$40/seat/month**, free trial at
app.metalbear.com) was evaluated and deliberately not installed. What it would add:

- concurrent sessions against one target, with HTTP header filtering so two developers can steal
  different requests from the same Pod;
- RBAC and policies, so a user no longer needs permission to create privileged Pods — only the
  Operator does;
- queue splitting (SQS, Kafka, RabbitMQ, …) and database branching;
- session management and audit.

Every one of those is a *team* feature. One developer on their own cluster, already holding the
k3s admin kubeconfig, gains nothing from any of them and pays a seat fee for it.

**Do not re-propose this** unless something concrete changes: a second person needs cluster
access without being cluster admin, or two sessions need the same Pod at once. It would install
as an umbrella chart in `infrastructure/mirrord-operator/` with its own namespace and a
sync-wave alongside the other cluster components, plus a license key — which, being a secret,
would go in Infisical and reach the namespace through external-secrets rather than into git.
