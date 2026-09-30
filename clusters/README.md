# clusters

One directory per cluster. Each holds the ArgoCD `Application` manifests that
define what that cluster runs — the cluster's desired state in one place.

`production/` is synced by `bootstrap/root-app.yaml`, which recurses the
directory and picks up every `*.yaml`.

## Sync waves

| Wave | Application       | Why                                              |
|-----:|-------------------|--------------------------------------------------|
| -10  | `namespaces`      | Target namespaces must exist first                |
|    0 | `argocd`          | Self-manages the controller running all of this   |
|   10 | `cert-manager`    | Issues certs the ingress layer needs              |
|   10 | `external-secrets`| Populates Secrets workloads depend on             |
|   20 | `traefik`         | Ingress, after issuers exist                      |
|   30 | `applications`    | The `workloads` ApplicationSet, after infrastructure is healthy |

`applications` applies exactly one object, `environments/applicationset.yaml`;
the ApplicationSet then generates one Application per
`environments/<env>/<app>.yaml` (see `environments/README.md`). The generated
Applications carry no sync-wave of their own — the ApplicationSet only exists
once wave 30 is reached.

## Projects

`projects.yaml` defines the AppProjects, which is what makes the UI's Project
filter useful — plumbing in one bucket, prod workloads in another, each other
environment in its own.

| Project | Applications | Source repos | Destinations | Cluster-scoped resources |
|---|---|---|---|---|
| `infra` | argocd, cert-manager, external-secrets, traefik, namespaces, storage, coredns, applications | any | any | any |
| `applications` | prod workloads (`environments/prod/`) | this repo + kovostack-helm-charts | any namespace | `Namespace`, `ClusterSecretStore` |
| `applications-dev` | dev workloads (`environments/dev/`) | this repo + kovostack-helm-charts | `*-dev` only | `Namespace` named `*-dev`, `ClusterSecretStore` named `infisical-*-dev` |
| `default` | `root` alone | — | — | — |

`applications-<env>` is fenced by name on purpose. A dev values file that
forgot its `name`, or copied prod's, would render the prod Namespace and the
prod secret store; in `applications` ArgoCD would take them over, in
`applications-dev` the sync is refused. The ApplicationSet picks the project
from the directory (`prod` → `applications`, anything else →
`applications-<env>`), and a templatePatch cannot override it.

The asymmetry is deliberate. `infra` installs CRDs, ClusterRoles, webhooks and
StorageClasses, and upstream charts add resource kinds between releases without
asking — narrowing it there buys nothing and breaks upgrades. Workloads have no
business creating any of that, so `applications` is restricted to `Namespace`,
which `charts/app` needs for the namespace it renders (plus the per-app
`ClusterSecretStore`). It is also pinned to
the two repos it legitimately needs — this one for values, kovostack-helm-charts
for the chart — so no app can be pointed at an arbitrary chart repo without a
commit here first.

`root` stays in the built-in `default` project: it is what creates these,
so it cannot belong to any of them.

All carry sync-wave `-20`, ahead of everything else, because an Application
naming a project that does not exist yet is rejected outright.

## Adding an environment (same cluster)

Not a cluster: a directory `environments/<env>/` and an `applications-<env>`
AppProject here. `environments/README.md` has the steps; the ApplicationSet does
not change.

## Adding a cluster

Copy `production/` to e.g. `staging/` and add a second root app in
`bootstrap/` for it. Workloads no longer have per-app manifests to repoint, so
the part that changes is the ApplicationSet: the copy's `applications.yaml`
should apply its own ApplicationSet whose template sets
`destination.server` (or `name`) to the registered cluster and whose files
generator reads only that cluster's environments — e.g.
`environments/<env>/*.yaml` for the environments that cluster runs, or a
`clusters/<cluster>/environments/` tree of its own. Two ApplicationSets must
never generate the same Application name; a clash is a fight between them.
Register the cluster in ArgoCD first, and add it to the AppProjects'
`destinations` (they currently allow only `https://kubernetes.default.svc`).