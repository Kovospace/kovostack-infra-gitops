# kovostack-infra-gitops

Desired state for one cluster, reconciled by ArgoCD (app-of-apps). Everything is
declarative YAML. **A commit on `main` is the deployment** — nothing is applied
by hand after `bootstrap/`.

## Where to look — read one file, not the repo

Every directory has a README that already answers the usual questions. Open the
one for the area you are touching and stop there. Do not sweep the tree to
rediscover conventions that are written down.

| Working on | Read |
|---|---|
| adding a **new** app | run `/new-app` — never hand-write the three files |
| a workload: change, pin a chart version | `applications/README.md` |
| image tags, CI deploys, init-container tags | `versions/README.md` |
| a cluster component (argocd, traefik, cert-manager, external-secrets) | `infrastructure/README.md` |
| what runs where, sync waves, AppProjects | `clusters/README.md` |
| namespaces | `namespaces/README.md` |
| cluster bring-up, deploy key, Infisical identity | `bootstrap/README.md` |
| the `app` chart's values and rendering switches | `../kovostack-helm-charts/charts/app/README.md` |
| work deliberately deferred (don't re-propose it) | `TODOS.md` |

Layout: `bootstrap/` (the one manual apply) → `clusters/production/` (an
Application per component, sync-waved) → `namespaces/`, `infrastructure/`,
`applications/`, with image tags in `versions/`.

## Facts that are expensive to rediscover

- **The `app` chart is not in this repo.** It lives in
  `Kovospace/kovostack-helm-charts` (locally `/home/kovo/IdeaProjects/kovostack-helm-charts`).
  Each Application pins a `chart-app-<semver>` **tag**; the `$values` source
  tracks `main`. Two repos are required — ArgoCD refuses two revisions of the
  same repo. Chart changes are *not* made here: delegate to the
  `helm-chart-devops` agent, then bump `targetRevision` one app at a time.
- **`imageTag` lives only in `versions/<app>.yaml`**, written by pipelines.
  Init-container tags go in `versions/<app>-init.yaml` under `initImageTags`, a
  **map** keyed by container name, values **quoted**. Setting either in
  `applications/<app>/values.yaml` creates a second source of truth that always
  loses.
- **A values key the chart does not define is silently ignored** — no error,
  the default renders. "It templated without error" is not verification; render
  and grep for the effect.
- **Helm merges maps but replaces lists wholesale.** That is why `initContainers`
  (a list) stays in the human-edited values file and only the tag map is split out.
- **Adding an app secret needs no commit.** Everything in Infisical `/<name>` is
  synced into `<name>-secrets` and mounted as env vars.
- `applications/` is scanned **non-recursively** — only top-level `*.yaml` are
  Application manifests; a stray values file there would be applied as a K8s object.
- `namespaces/` has `prune` disabled on purpose: deleting a Namespace deletes
  everything in it.
- Apps run under the `applications` AppProject, which may only create
  `Namespace` cluster-scoped resources and may only source from these two repos.

## This environment

`helm`, `kubectl`, `gh` and `argocd` are **not on PATH** here, and there is no
cluster access. Check with `command -v` before planning around one. If you could
not render or verify something, say so plainly — never report a check you did not run.

## Git

- Commit subjects are lowercase and imperative, one logical change each
  (`add flyway init container`, `move values to vault`).
- `<app>: sha-xxxxxxx` commits are written by pipelines. Never hand-write one.
- **Pushing to `main` deploys.** It requires the user's explicit permission
  **every single time** — a hook (`.claude/hooks/main-push-guard.sh`) forces the
  prompt, and that prompt is not a formality. One approval covers one push.
  Other branches push freely.
- Never `kubectl apply`, `helm upgrade`, or `argocd app sync` against the
  cluster. The commit is the deploy; anything applied by hand gets reverted by
  `selfHeal` and leaves the cluster disagreeing with git.

## Agent and skill

- **`devops-engineer`** (`.claude/agents/devops-engineer.md`) owns changes here,
  impact analysis for a backend service or cluster component, and CI/CD pipeline
  guidance. Delegate that work rather than re-deriving it.
- **`/new-app`** (`.claude/skills/new-app/`) scaffolds a new app from five
  answers via `.claude/scripts/new-app.sh`. The script holds the conventions —
  writing the Application, values and versions files by hand is a bug, not a
  shortcut.
