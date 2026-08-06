# kovostack-infra-gitops

Kubernetes & ArgoCD manifests and Helm templates. Single source of truth for
cluster state, driven by the app-of-apps pattern.

## Layout

```
bootstrap/          root-app.yaml — the only manifest applied by hand
clusters/           one directory per cluster, holding its Applications
  production/
infrastructure/     cluster components as umbrella Helm charts
  argocd/
  cert-manager/
  external-secrets/
  traefik/
namespaces/         Namespace manifests, synced before everything else
applications/       one Application per workload + its values
versions/           image tags, written by CI
```

The `app` chart lives in a separate repository,
[kovostack-helm-charts](https://github.com/Kovospace/kovostack-helm-charts), so
Applications can pin a chart version — ArgoCD refuses two revisions of one
repository in a multi-source Application.

## Adding an app

`charts/app` turns one value into everything an app repeats — namespace,
secrets, ingress, certificate, and optionally the workload itself. `name`
derives the lot, including the Infisical folder it reads:

```yaml
# applications/myapp/values.yaml — the whole app
name: myapp
image: ghcr.io/kovospace/myapp
host: myapp.matejkovac.sk
```

Secrets follow the same convention: everything in Infisical `/myapp` is synced
into `myapp-secrets` and mounted as env vars, so **adding a secret needs no
commit**. See `charts/app/README.md`.

## How it fits together

```
bootstrap/root-app.yaml
        │  (recurses)
        ▼
clusters/production/*.yaml          ← Application per component, sync-waved
        │
        ├─► namespaces/             wave -10
        ├─► infrastructure/argocd/            wave  0
        ├─► infrastructure/cert-manager/      wave 10
        ├─► infrastructure/external-secrets/  wave 10
        ├─► infrastructure/traefik/           wave 20
        └─► applications/*.yaml               wave 30
```

`clusters/` answers *what runs where*; `infrastructure/` and `applications/`
answer *how it is configured*. Adding a component means one Application in
`clusters/production/` plus its chart directory — no changes to the root app.

See `bootstrap/README.md` to bring up a cluster, and the README in each
directory for local conventions.

## Before the first sync

- Replace the placeholders: `argo-cd.global.domain` in
  `infrastructure/argocd/values.yaml`, `acme.email` in
  `infrastructure/cert-manager/values.yaml`, and the `infisical.*` block in
  `infrastructure/external-secrets/values.yaml`.
- Apply the two hand-managed credentials in `bootstrap/`: the repo deploy key
  and the Infisical machine identity. Neither can come from git or from
  external-secrets — they are what makes those work in the first place.
- `repoURL` in every Application points at
  `https://github.com/Kovospace/kovostack-infra-gitops.git` — update it if the
  repository moves.
- The issuers default to Let's Encrypt **staging** being available alongside
  production; use `letsencrypt-staging` while testing to avoid rate limits.

## Validating changes locally

```bash
helm dependency update infrastructure/<component>
helm template <component> infrastructure/<component> -n <namespace>
```