# infrastructure

Cluster-level components. Each directory is a thin **umbrella Helm chart**: a
`Chart.yaml` pinning the upstream chart version and a `values.yaml` holding the
overrides. Nothing is templated by hand unless it has to be.

Values for a dependency are nested under its chart name:

```yaml
# infrastructure/traefik/values.yaml
traefik:          # <- dependency name from Chart.yaml
  service:
    type: LoadBalancer
```

ArgoCD's repo-server runs `helm dependency build` on these directories, so no
`charts/` directory or `Chart.lock` needs to be committed.

## Upgrading a component

Bump `version` in `Chart.yaml`, diff the upstream release notes against
`values.yaml`, commit. ArgoCD picks it up on the next reconciliation.

To preview locally:

```bash
helm dependency update infrastructure/traefik
helm template traefik infrastructure/traefik -n traefik
```

## Components

| Directory          | Upstream chart                            | Namespace          |
|--------------------|-------------------------------------------|--------------------|
| `argocd/`          | `argo-cd` (argoproj.github.io/argo-helm)  | `argocd`           |
| `cert-manager/`    | `cert-manager` (charts.jetstack.io)       | `cert-manager`     |
| `external-secrets/`| `external-secrets` (charts.external-secrets.io) | `external-secrets` |
| `traefik/`         | `traefik` (traefik.github.io/charts)      | `traefik`          |

`cert-manager/templates/cluster-issuers.yaml` adds the Let's Encrypt staging and
production `ClusterIssuer`s on top of the upstream chart.

Pinned versions were resolved against the upstream repositories on 2026-08-05
and all four charts render cleanly with these values.