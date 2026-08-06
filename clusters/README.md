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
|   30 | `applications`    | Workloads, after infrastructure is healthy        |

## Projects

`projects.yaml` defines two AppProjects, which is what makes the UI's Project
filter useful — plumbing in one bucket, your own workloads in the other.

| Project | Applications | Source repos | Cluster-scoped resources |
|---|---|---|---|
| `infra` | argocd, cert-manager, external-secrets, traefik, namespaces, storage, applications | any | any |
| `applications` | everything using `charts/app` | this repo only | `Namespace` only |
| `default` | `root` alone | — | — |

The asymmetry is deliberate. `infra` installs CRDs, ClusterRoles, webhooks and
StorageClasses, and upstream charts add resource kinds between releases without
asking — narrowing it there buys nothing and breaks upgrades. Workloads have no
business creating any of that, so `applications` is restricted to `Namespace`,
which `charts/app` needs for the namespace it renders. It is also pinned to
this repository, so no app can be pointed at an arbitrary chart repo without a
commit here first.

`root` stays in the built-in `default` project: it is what creates these two,
so it cannot belong to either.

Both carry sync-wave `-20`, ahead of everything else, because an Application
naming a project that does not exist yet is rejected outright.

## Adding a cluster

Copy `production/` to e.g. `staging/`, adjust `spec.destination.server` (or
`name`) to the registered cluster, point the per-app `path` at cluster-specific
values, and add a second root app in `bootstrap/` for it.