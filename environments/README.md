# environments

Which app runs in which environment, and at which chart version. One file per
app per environment; every workload Application on the cluster is generated from
these by the ApplicationSet in `applicationset.yaml`.

```
environments/
  applicationset.yaml              <- the ApplicationSet (the only manifest here)
  prod/
    new-tab-links-backend.yaml     <- Application `new-tab-links-backend`
    kovo.yaml                      <- Application `kovo`
  dev/
    new-tab-links-backend.yaml     <- Application `new-tab-links-backend-dev`
```

`applicationset.yaml` is applied by `clusters/production/applications.yaml`
(project `infra`, sync-wave `30`), which reads that one file and nothing else in
this directory. The subdirectories are generator input, not Kubernetes objects.

## An environment file

```yaml
# environments/dev/new-tab-links-backend.yaml
chartRevision: chart-app-1.5.0   # the chart tag this app runs in this env
envValuesFile: true              # applications/<app>/dev.yaml exists
initTagsFile: true               # versions/<name>-init.yaml exists
```

All three keys are required — a missing one fails the render (`missingkey=error`)
rather than guessing. Everything else is derived from the path:

| | prod | any other env, e.g. `dev` |
|---|---|---|
| Application, namespace, chart `name` | `<app>` | `<app>-<env>` |
| AppProject | `applications` | `applications-<env>` |
| Infisical folder / Secret | `/<app>`, `<app>-secrets` | `/<app>-<env>`, `<app>-<env>-secrets` |
| value files, in order | `applications/<app>/values.yaml`<br>`applications/<app>/prod.yaml` *(if `envValuesFile`)*<br>`versions/<app>.yaml`<br>`versions/<app>-init.yaml` *(if `initTagsFile`)* | `applications/<app>/values.yaml`<br>`applications/<app>/<env>.yaml` *(if `envValuesFile`)*<br>`versions/<app>-<env>.yaml`<br>`versions/<app>-<env>-init.yaml` *(if `initTagsFile`)* |

prod keeps the bare names because the Applications that existed before the
ApplicationSet were adopted in place — renaming them would have meant a new
namespace, new certificates and new, empty volumes.

The chart's `name` still has to be written in the values (the chart requires
it); the ApplicationSet only decides the Application and the destination
namespace. For an app that runs in more than one environment, `name` goes in
each `<env>.yaml`, never in the shared `values.yaml` — see
`applications/README.md`.

## Adding an app to an environment

One file here, plus its values and versions files. `/new-app` writes all of them.

## Adding an environment

1. A directory, `environments/<env>/`, with one file per app.
2. An AppProject `applications-<env>` in `clusters/production/projects.yaml`,
   a copy of `applications-dev` with the suffix changed. Without it the
   generated Applications report *project not found* and deploy nothing.
3. Per app: `applications/<app>/<env>.yaml` (with `name: <app>-<env>` and every
   environment-specific key), `versions/<app>-<env>.yaml`, an Infisical folder
   `/<app>-<env>`, and DNS for its hosts — convention: subdomains of
   `<env>.matejkovac.sk`.

`applicationset.yaml` does not change.

## Removing an app, or renaming a file

Deleting or renaming a file here does **not** delete anything. The
ApplicationSet runs `create-update` — it never deletes an Application — so the
old one keeps running, and a renamed file generates a *second* Application
beside it. Remove the leftover by hand once git no longer generates it:

```bash
kubectl -n argocd delete application <name>
```

Generated Applications carry no resources finalizer
(`preserveResourcesOnDeletion: true`), so that deletes the Application object
only. The Deployment, PVCs and Namespace stay; delete the namespace yourself if
the app is really gone (`namespaces/README.md` explains why nothing prunes a
namespace automatically).

## Promotion

**A chart change** (a new `chart-app-<semver>` tag): bump `chartRevision` in
`dev/<app>.yaml`, watch it, then bump `prod/<app>.yaml`. One app at a time, as
before — the pin is per app *and* per environment.

**A configuration change**: put it in `applications/<app>/dev.yaml`, watch it,
then move it to wherever prod reads it — `applications/<app>/prod.yaml` if it is
environment-specific, or the shared `applications/<app>/values.yaml` (removing
it from `dev.yaml`) if every environment should have it.

**An image**: dev and prod have separate versions files, written by separate
pipelines (`versions/README.md`). Promoting a build means writing the same tag
into the prod file.

Anything pushed to `main` goes live in its environment — dev included. The
dev environment currently shares prod's database, mailer and Google OAuth
client (see `applications/new-tab-links-backend/dev.yaml`), so a dev change is
not automatically a harmless one.
