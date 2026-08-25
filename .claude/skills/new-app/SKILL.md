---
name: new-app
description: Scaffold a new application into this GitOps repo — asks for the namespace, Postgres, ingress host, external secrets and container port, then writes the Application, its values and its versions file. Use when someone wants to add a new app, a new workload, or a new service to the cluster.
---

# Add a new app

Collect five answers, run one script, report what still has to be done by hand.
`.claude/scripts/new-app.sh` holds all the conventions — do not hand-write the
YAML, and do not re-read the chart to remember how a values file looks.

## 1. Collect the answers

Anything the user already said (`/new-app paster-api on api.paster.cloud`)
counts as answered — do not ask it again. Ask for the rest with
`AskUserQuestion`, at most four per call, offering derived defaults as options
so the common case is one keypress. "Other" covers free text.

| Ask | Offer as options | Becomes |
|---|---|---|
| **Name** — also the namespace, Infisical folder, Secret and TLS Secret | — (free text; skip the question if given) | `--name` |
| **Postgres?** | No · Yes, database `<name with - as _>` | `--postgres <db>` / `--no-postgres` |
| **Ingress host** | `<name>.matejkovac.sk` · `api.<name>.matejkovac.sk` · No public route | `--host` / omit |
| **External secrets?** | Yes, sync Infisical `/<name>` (default) · No | omit / `--no-secrets` |
| **Container port** | 8080 · 3000 · 4000 | `--port` |

Two things worth saying while you ask, because they are easy to get wrong:

- **Postgres is not in the cluster.** It is a Docker container on the VM. Answering
  yes renders a selector-less Service so the app reaches it at `postgres:5432`;
  it does **not** create the database — that step is printed at the end.
- **Answering no to external secrets** only switches off the app's own
  `<name>-secrets` sync. Pulling from the private registry keeps working; that
  credential is a separate Secret. But the app then has nowhere to read a
  password from, so it is the wrong answer for anything with a database.

The image defaults to the app name (`registry.matejkovac.sk/apps/<name>`). Pass
`--image` only if the user names a different one.

## 2. Generate

```bash
.claude/scripts/new-app.sh --name <name> --port <port> [--host <host>] \
  [--postgres <db>] [--no-secrets] [--image <image>] [--dry-run]
```

Use `--dry-run` first if anything was ambiguous and show the user the result.
The script validates its own input, refuses to overwrite an existing app, and
picks the newest `chart-app-*` version already in use here. It writes:

```
applications/<name>.yaml          the Application
applications/<name>/values.yaml   the config
versions/<name>.yaml              imageTag: change_me, CI's file from now on
```

It does **not** commit, push, or touch the cluster.

## 3. Report

Relay the numbered manual steps the script printed — Infisical folder, database,
DNS, first image build — they are the part that cannot be automated, and the app
will not start without them.

Then offer to commit. **Do not push to `main` without asking for that specific
push**: main is synced by ArgoCD, so the push is the deployment, and the app
will come up before its database, DNS or secrets exist unless those were done
first. Pushing a branch instead is fine and needs no permission.

If the user wants the app adjusted beyond these five answers — volumes, init
containers, `wwwAlias`, resources — edit `applications/<name>/values.yaml`
afterwards; `../kovostack-helm-charts/charts/app/values.yaml` documents every
key, and `applications/README.md` covers the repo-side conventions.
