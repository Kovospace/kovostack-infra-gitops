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

The chart lives in
[kovostack-helm-charts](https://github.com/Kovospace/kovostack-helm-charts) and
each Application pins a tag:

```yaml
sources:
  - repoURL: git@github.com:Kovospace/kovostack-helm-charts.git
    targetRevision: chart-app-1.1.0     # chart, pinned
    path: charts/app
    helm:
      valueFiles:
        - $values/applications/nsr/values.yaml
        - $values/versions/nsr.yaml
  - repoURL: git@github.com:Kovospace/kovostack-infra-gitops.git
    targetRevision: main                 # values, live
    ref: values
```

**Separate repositories is what makes this work.** ArgoCD rejects a multi-source
Application referencing two revisions of the *same* repo, so while the chart sat
in `charts/app` here it could not be pinned at all — the `$values` source has to
stay on `main` for CI deploys to take effect:

```
cannot reference a different revision of the same repository
```

Upgrading a chart is now per-app: bump one app's `targetRevision`, watch it,
then move the next. Previously every app tracked the chart at `main`, which is
how a single bad annotation broke every workload at once.

Releasing a new chart version is documented in the charts repo. Tag convention
is **`chart-<chart_name>-<semver>`**.

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