---
name: new-app
description: Scaffold a new application into this GitOps repo — asks for the name, environment(s), Postgres, ingress host, external secrets and container port, then writes the environment file(s) the ApplicationSet turns into Applications, the values and the versions files. Use when someone wants to add a new app, a new workload, or a new service to the cluster.
---

# Add a new app

Collect six answers, run one script, report what still has to be done by hand.
`.claude/scripts/new-app.sh` holds all the conventions — do not hand-write the
YAML, and do not re-read the chart to remember how a values file looks.

There is no Application manifest to write any more: the ApplicationSet in
`environments/applicationset.yaml` generates one per
`environments/<env>/<name>.yaml`. `environments/README.md` explains the naming.

## 1. Collect the answers

Anything the user already said (`/new-app paster-api on api.paster.cloud`)
counts as answered — do not ask it again. Ask for the rest with
`AskUserQuestion`, at most four per call, offering derived defaults as options
so the common case is one keypress. "Other" covers free text.

| Ask | Offer as options | Becomes |
|---|---|---|
| **Name** — also the prod namespace, the Infisical folder (every env), Secret and TLS Secret | — (free text; skip the question if given) | `--name` |
| **Environments** | prod only (default) · prod and dev · dev only | `--env prod` / `--env prod --env dev` / `--env dev` |
| **Postgres?** | No · Yes, database `<name with - as _>` | `--postgres <db>` / `--no-postgres` |
| **Ingress host** (prod's) | `<name>.matejkovac.sk` · `api.<name>.matejkovac.sk` · No public route | `--host` / omit |
| **External secrets?** | Yes, sync Infisical `/<name>` (default) · No | omit / `--no-secrets` |

Secrets always come from folder `/<name>`, in the Infisical environment named
after the env directory (`prod`, `dev`) — the ApplicationSet sets both, so
nothing about them is written into values files. An environment file can read
another Infisical environment with `infisicalEnv:`; the script never writes it.
| **Container port** | 8080 · 3000 · 4000 | `--port` |

For a non-prod environment the host defaults to `<name>.<env>.matejkovac.sk`
(convention: dev apps are subdomains of `dev.matejkovac.sk`, covered by the
`*.matejkovac.sk` wildcard). If the user wants another, pass it as
`--env dev=<host>`; `--env dev=` means no public route in dev.

Things worth saying while you ask, because they are easy to get wrong:

- **Postgres is not in the cluster.** It is a Docker container on the VM. Answering
  yes renders a selector-less Service so the app reaches it at `postgres:5432`;
  it does **not** create the database — that step is printed at the end. Each
  non-prod environment gets its own database, `<db>_<env>`.
- **Answering no to external secrets** only switches off the app's own
  `<name>-secrets` sync. Pulling from the private registry keeps working; that
  credential is a separate Secret. But the app then has nowhere to read a
  password from, so it is the wrong answer for anything with a database.
- **An environment other than prod needs its AppProject** (`applications-<env>`
  in `clusters/production/projects.yaml`). `dev` has one; the script refuses an
  environment that does not, because adding one is a deliberate decision.

The image defaults to the app name (`registry.matejkovac.sk/apps/<name>`). Pass
`--image` only if the user names a different one.

## 2. Generate

```bash
.claude/scripts/new-app.sh --name <name> --port <port> [--host <host>] \
  [--env prod] [--env dev[=<host>]] \
  [--postgres <db>] [--no-secrets] [--image <image>] [--dry-run]
```

Use `--dry-run` first if anything was ambiguous and show the user the result.
The script validates its own input, refuses to overwrite an existing app, and
picks the newest `chart-app-*` version already pinned in `environments/`. It
writes:

```
environments/<env>/<name>.yaml     per env — chart pin; becomes the Application
applications/<name>/values.yaml    the config, shared by all environments
applications/<name>/<env>.yaml     per env — name, host, database URL; only
                                   written when the app is not prod-only
versions/<name>.yaml               prod's image tag — CI's file from now on
versions/<name>-<env>.yaml         another environment's image tag
```

A prod-only app keeps everything in `values.yaml`, as before. As soon as there
is a second environment, name, host and database URL go into the per-env files
and must stay out of `values.yaml`.

It does **not** commit, push, or touch the cluster. It only creates new apps —
adding an environment to an app that already exists is a manual change,
described in `environments/README.md`.

## 3. Report

Relay the numbered manual steps the script printed — Infisical folder per
Infisical environment,
database(s), DNS, first image build — they are the part that cannot be
automated, and the app will not start without them.

Then offer to commit. **Do not push to `main` without asking for that specific
push**: main is synced by ArgoCD, so the push is the deployment — for dev as
much as for prod — and the app will come up before its database, DNS or
secrets exist unless those were done first. Pushing a branch instead is fine
and needs no permission.

If the user wants the app adjusted beyond these answers — volumes, init
containers, `wwwAlias`, resources — edit `applications/<name>/values.yaml` (or
the `<env>.yaml` if it differs per environment) afterwards. An init container
with its own tag also needs `initTagsFile: true` in the environment file and a
`versions/<app>-init.yaml`. `../kovostack-helm-charts/charts/app/values.yaml`
documents every chart key, and `applications/README.md` covers the repo-side
conventions.
