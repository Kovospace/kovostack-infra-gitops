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