# applications

Workloads. Picked up by `clusters/production/applications.yaml` at sync-wave
`30`, after the infrastructure layer is healthy.

```
applications/
  whoami.yaml           <- Application manifest  (top level, *.yaml)
  whoami/
    values.yaml         <- the app's configuration
```

The directory scan is **not recursive**, so only top-level `*.yaml` are treated
as manifests; the per-app subdirectories are reached through the Application's
`$values` source ref instead. Adding a values file to the top level would make
ArgoCD try to apply it as a Kubernetes object.

## Chart version pinning

The chart source is pinned to a tag, **not** `main`:

```yaml
- repoURL: git@github.com:Kovospace/kovostack-infra-gitops.git
  targetRevision: chart-app-1.0.0     # ← chart, pinned
  path: charts/app
- repoURL: git@github.com:Kovospace/kovostack-infra-gitops.git
  targetRevision: main                 # ← values, live
  ref: values
```

Tag convention: **`chart-<chart_name>-<semver>`**.

Only the chart is pinned; the values source stays on `main` so configuration
and image-tag changes still apply immediately. Upgrading a chart is a
per-app decision — bump one app's `targetRevision`, watch it, then move the
next. Without this, a chart edit reaches every app on the next reconcile, which
is how a single bad annotation took down every workload at once.

Releasing a chart change:

```bash
# bump version: in charts/app/Chart.yaml, commit, then
git tag chart-app-1.1.0 && git push --tags
```

Then raise `targetRevision` per app, one at a time.

## Adding an app

1. `cp -r whoami myapp && mv whoami.yaml myapp.yaml`
2. Replace `whoami` with `myapp` in both files (Application `metadata.name`,
   the `$values` path, `destination.namespace`, and `name` in the values file).
3. Create the Infisical folder `/myapp` and put the app's secrets in it — they
   arrive as env vars, no git change needed.
4. Point DNS at the VM and commit.

`charts/app/README.md` covers what the chart renders and which values switch
parts of it off. Render before pushing:

```bash
helm template myapp charts/app -f applications/myapp/values.yaml
```

## When the chart does not fit

An app with its own Helm chart can still use the convention for the glue: leave
`image` empty so no workload is rendered, and deploy the workload from a second
Application. The namespace, secrets and ingress still come from here.