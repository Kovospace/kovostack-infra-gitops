# versions

One file per app, containing **only** the deployed image tag. Written by build
pipelines, not by hand.

```yaml
# versions/nsr.yaml
imageTag: sha-a4acb4c
```

Each Application loads it after the app's own values, so it wins:

```yaml
valueFiles:
  - $values/applications/nsr/values.yaml   # config, edited by humans
  - $values/versions/nsr.yaml              # image tag, written by CI
```

The split exists so that a deploy and a configuration change can never touch
the same file. An automated commit landing on `applications/nsr/values.yaml`
would sooner or later collide with an edit in flight, and the resolution would
be someone's config change silently reverted by a pipeline.

`imageTag` therefore lives **only** here. Setting it in the app's values file as
well creates two sources of truth where the quieter one always wins.

## Deploying from another repository's pipeline

The app's build job commits the new tag here. In GitHub Actions:

```yaml
- name: Deploy
  run: |
    git clone --depth 1 git@github.com:Kovospace/kovostack-infra-gitops.git gitops
    cd gitops
    printf 'imageTag: %s\n' "$TAG" > versions/${APP}.yaml
    git commit -am "deploy ${APP} ${TAG}" && git push
```

ArgoCD sees the commit and syncs. Nothing else is needed — that push *is* the
deployment.

### Credentials

The existing deploy key is **read-only**, and must stay that way: it is what
the cluster authenticates with, and write access there would let a compromised
node rewrite its own desired state. Give the pipeline its own credential:

- a second **deploy key with write access** on this repo, or
- a **GitHub App** installation token, scoped to this repo only.

Prefer the GitHub App if you will have several pipelines — its tokens are
short-lived and it does not consume the one-deploy-key-per-repo limit, which a
second write key would.

### Concurrency

Two pipelines pushing at once will race, and the loser gets a rejected push.
Either retry with `git pull --rebase`, or set `concurrency:` in the workflow so
deploys serialise.

## Alternatives worth knowing

- **ArgoCD Image Updater** watches the registry directly and writes the tag
  back itself — no pipeline changes at all, at the cost of another controller
  and a less obvious deployment trigger.
- **Renovate** opens a PR instead of pushing, if you want a human in the loop
  for production deploys.

Commit-back is the most explicit of the three: the deployment is a commit, by a
known actor, that can be reverted.
