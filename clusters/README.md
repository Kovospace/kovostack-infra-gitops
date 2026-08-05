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

## Adding a cluster

Copy `production/` to e.g. `staging/`, adjust `spec.destination.server` (or
`name`) to the registered cluster, point the per-app `path` at cluster-specific
values, and add a second root app in `bootstrap/` for it.