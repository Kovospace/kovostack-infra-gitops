# k8up — backup operator

[K8up](https://k8up.io) runs restic as Kubernetes Jobs. An app declares a
`Schedule` in its own namespace (rendered by charts/app). The operator then
starts backup, prune and check Jobs there. The Jobs mount the app's PVCs
read-only and push to the restic REST gateway in `infrastructure/backup/`, which
is where the Storage Box, the credentials and the **restore procedure** are
documented.

| | |
|---|---|
| Chart | `k8up` 4.10.0 from `https://k8up-io.github.io/k8up` |
| Operator / backup image | `ghcr.io/k8up-io/k8up:v2.16.0` |
| Namespace | `k8up` (`restricted` Pod Security) |
| Sync wave | `15` — after external-secrets, before `applications` (30) |

**CRDs** ship in the chart's `crds/` directory (`Schedule`, `Backup`, `Restore`,
`Prune`, `Check`, `Archive`, `PreBackupPod`, `PodConfig`, `Snapshot`). ArgoCD
renders them with the chart and applies them with `ServerSideApply`, the same
way it handles the cert-manager and external-secrets CRDs. Unlike a plain
`helm upgrade`, it also *updates* them when the chart version moves.

**What the operator does outside its namespace.** In each app namespace it
creates, on demand, a `pod-executor` ServiceAccount and a
`pod-executor-namespaced` RoleBinding (for `PreBackupPod`/backup-command exec),
the Jobs, and `Snapshot` objects. None of these carry ArgoCD tracking labels,
so no Application goes OutOfSync and `prune` leaves them alone. The chart's
`k8up-cleanup` Job (a Helm post-install/upgrade hook, run by ArgoCD as
PostSync) deletes those RoleBindings cluster-wide after each sync of this
Application. The operator recreates them before the next backup, so this is
harmless.

**Settings worth knowing** (see `values.yaml` for why):

- `timezone: Europe/Bratislava` — Schedule cron expressions use it.
- `skipWithoutAnnotation: false` (upstream default) — a Schedule backs up
  *every* RWO/RWX PVC in its namespace. Opt a claim out with the annotation
  `k8up.io/backup: "false"`.
- Default Job resources: requests 50m / 128Mi, memory limit 1Gi.

## AppProjects

No change was needed. `infra` accepts any source repo, and `applications`
already allows every namespaced kind, so `Schedule`, `PreBackupPod` and the
rest are allowed. An app that also needs a store for `/backup` must reference
`ClusterSecretStore/infisical-backup` from `infrastructure/backup/`. That kind
is already on the `applications` cluster-scoped whitelist.

## Monitoring and alerting — not built yet

Nothing in this cluster can alert today. There is no Prometheus, Alertmanager or
Grafana, the Traefik and cert-manager metrics endpoints are switched off, and
the Docker platform on the host runs no notifier either. What K8up offers:

- **Operator metrics** on the `k8up-metrics` Service, port 8080:
  `k8up_jobs_failed_counter`, `k8up_schedule_last_job_succeeded`, and more. The
  chart can install `PrometheusRule`s for failed jobs (`metrics.prometheusRule`).
  They need a Prometheus + Alertmanager, a few hundred MiB on a VM that has none
  to spare.
- **`statsURL`** on a Schedule's `backup` (and `promURL` for a pushgateway).
  The backup Job POSTs a JSON summary there **after restic completes a
  snapshot**, once per PVC and once per database dump. A failed or never-started
  backup sends nothing.

**Cheapest reliable option:** a dead-man's switch. Point `statsURL` at a
[healthchecks.io](https://healthchecks.io) ping URL (free tier: 20 checks, email
alerts), one check per app, period 1 day and grace a few hours. Any POST counts
as a ping. It then alerts on the failure modes that matter: Job failing, Job
never starting, operator down, gateway down, Storage Box unreachable. That is a
charts/app value, not anything here. One caveat: restic reports a snapshot
with some unreadable files as completed, so the ping proves "a snapshot was
written", not "every file was in it". Pair it with the restore test in
`infrastructure/backup/README.md`.

## Upgrading

Bump `version` in `Chart.yaml`, read the
[release notes](https://github.com/k8up-io/k8up/releases) for renamed values
and CRD changes, render, commit. The operator restarts, and backup Jobs already
running finish on the old image.
