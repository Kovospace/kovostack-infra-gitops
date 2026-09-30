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
infisicalEnv: prod               # optional: Infisical environment, if not <env>
```

`chartRevision`, `envValuesFile` and `initTagsFile` are required, and a
missing one fails the render (`missingkey=error`) rather than guessing. The
template also fails on an unknown key (a typo such as `infisicalenv`), on a
quoted boolean (`"false"` would count as true), and on an `infisicalEnv` that is
not a slug. A failed render stops the ApplicationSet from updating **any**
Application until it is fixed; nothing is deleted. After editing a file here,
check `kubectl -n argocd get applicationset workloads -o yaml` for an
`ErrorOccurred` condition.

`infisicalEnv` is the one optional key. Without it the app reads the Infisical
environment named after its directory (`prod`, `dev`). The NewTabLinks dev files
set `infisicalEnv: prod` because Infisical's `dev` environment is not populated
yet. Deleting that line is the whole switch to real dev secrets, once the same
folder is filled in Infisical `dev` and the machine identity in the
`infisical-credentials` Secret can read that environment.

Everything else is derived from the path:

| | prod | any other env, e.g. `dev` |
|---|---|---|
| Application, namespace, chart `name` | `<app>` | `<app>-<env>` |
| AppProject | `applications` | `applications-<env>` |
| Infisical folder | `/<app>` in Infisical env `prod` | `/<app>` (the base name, same as prod) in Infisical env `<env>`, or `infisicalEnv` |
| synced Secret / ClusterSecretStore | `<app>-secrets` / `infisical-<app>` | `<app>-<env>-secrets` / `infisical-<app>-<env>` |
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
   environment-specific key), `versions/<app>-<env>.yaml`, its secrets in
   Infisical folder `/<app>` of an Infisical environment named `<env>` (or set
   `infisicalEnv` in the env file), and DNS for its hosts. Convention: subdomains
   of `<env>.matejkovac.sk`. The machine identity must be able to read that
   Infisical environment.

`applicationset.yaml` does not change.

## Secrets are set here, not in values files

The ApplicationSet passes two Helm **parameters** to every Application:

```yaml
parameters:
  - {name: secrets.path, value: /<app>, forceString: true}
  - {name: secrets.infisical.environmentSlug, value: <env or infisicalEnv>, forceString: true}
```

Parameters override every value file, so an app cannot point itself at
another app's folder or another Infisical environment from `values.yaml` or
`<env>.yaml`. A `secrets.path` or `environmentSlug` written there is silently
ignored. The rest of `secrets` (`enabled`, `refreshInterval`, …) still comes from
the values files. The parameters change nothing for an app with
`secrets.enabled: false`, because the chart renders no store for it.

Why parameters rather than `valuesObject`: both beat the value files, but
parameters also beat `valuesObject`, which leaves no second layer above them.
They are flat name/value pairs that `argocd app get` and the UI list as
overrides. `forceString` keeps a slug such as `true` or `1` from being coerced by
`--set`.

**No app needs an exception today.** If one ever does (an app that must read a
folder other than `/<app>`), add a second optional key to the environment file,
e.g. `infisicalPath`, handled the way `infisicalEnv` is. That means a
`hasKey` default in the templatePatch, the key added to the known-keys list,
and the exception documented in that one file. Do not add a `secrets.path` to a
values file: it will not work, and that is the point.

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
NewTabLinks dev environment currently shares prod's database, mailer, Google
OAuth client and Infisical secrets (see `applications/new-tab-links-*/dev.yaml`),
so a dev change is not automatically a harmless one.
