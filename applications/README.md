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

Run `/new-app` in Claude Code and answer five questions — name, Postgres,
ingress host, external secrets, container port. It calls
`.claude/scripts/new-app.sh`, which can also be run directly:

```bash
.claude/scripts/new-app.sh --name myapp --host myapp.matejkovac.sk --port 8080 \
  --postgres myapp_db          # or --no-postgres, --no-secrets, --dry-run
```

It writes three files and stops there — no commit, no push, no cluster access:

| File | What it is |
|---|---|
| `applications/myapp.yaml` | the Application, pinned to the newest `chart-app-*` already in use here |
| `applications/myapp/values.yaml` | the app's config |
| `versions/myapp.yaml` | `imageTag: change_me` — written by CI from then on |

### The steps it cannot do

The app will not start until these are done, so do them **before** pushing to
`main` — that push is the deployment.

1. **Infisical folder `/myapp`** — put the app's secrets in it. They arrive as
   env vars via `myapp-secrets`; adding one later needs no commit. Skipped if
   the app was created with `--no-secrets`.
2. **The database**, if the app uses Postgres. Postgres runs in **Docker on the
   VM, not in the cluster** — the chart only renders a selector-less Service
   pointing at the docker0 gateway, so the app can reach it as `postgres:5432`.
   Create the database and a user with rights on it, and put that user and
   password in Infisical `/myapp`:

   ```bash
   createdb -h <vm> -U postgres myapp_db
   ```
3. **DNS** for the host, pointing at the VM. The certificate is issued by an
   HTTP-01 challenge, so the record has to resolve *before* the first sync —
   otherwise the challenge fails and Let's Encrypt rate-limits at 5 failures per
   hour. Use `clusterIssuer: letsencrypt-staging` while testing.
4. **Build and push the image** to `registry.matejkovac.sk/apps/myapp`, then put
   its tag in `versions/myapp.yaml`. `versions/README.md` has the pipeline that
   writes that file on every deploy.
5. **Render it** before pushing:

   ```bash
   helm template myapp ../kovostack-helm-charts/charts/app \
     -f applications/myapp/values.yaml -f versions/myapp.yaml
   ```

Anything beyond those five answers — volumes, init containers, `wwwAlias`,
resources — is a normal edit to `applications/myapp/values.yaml` afterwards.
`charts/app/values.yaml` in the charts repo documents every key and which ones
switch parts of the chart off.

## When the chart does not fit

An app with its own Helm chart can still use the convention for the glue: leave
`image` empty so no workload is rendered, and deploy the workload from a second
Application. The namespace, secrets and ingress still come from here.