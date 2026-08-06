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

## Chart version pinning — not currently possible

Both sources track `main`, so **every app picks up a chart change on the next
reconcile**. That is a real risk: a single bad annotation in `charts/app` hits
every workload at once, which has already happened.

It cannot be fixed by pinning the chart source to a tag. ArgoCD rejects a
multi-source Application that references two revisions of the same repository:

```
cannot reference a different revision of the same repository
($values references "…" while the application references "chart-app-1.0.0")
```

So the three options are:

| | Pinning | CI deploys |
|---|---|---|
| both sources on `main` — **current** | ❌ | ✅ |
| both sources on the tag | ✅ | ❌ `versions/` needs a new tag each deploy |
| chart in a separate repo or OCI registry | ✅ | ✅ |

Pinning both would break deployment, since `versions/<app>.yaml` has to take
effect the moment CI pushes it. **Getting both requires the chart to live
somewhere other than this repo** — see `TODOS.md`.

Tags are still cut on every chart change, using the convention
**`chart-<chart_name>-<semver>`**, so the history is there and the move to OCI
is a change of `repoURL` rather than a re-versioning exercise:

```bash
# bump version: in charts/app/Chart.yaml, commit, then
git tag chart-app-1.1.0 && git push --tags
```

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