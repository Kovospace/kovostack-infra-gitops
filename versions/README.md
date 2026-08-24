# versions

Image tags, and nothing else. Written by build pipelines, not by hand. One file
per app, plus a second one for any init container image that is released on its
own cadence.

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

`imageTag` therefore lives **only** here, and so does `initImageTags` below.
Setting either in the app's values file as well creates two sources of truth
where the quieter one always wins.

## Init container images

A step that runs before the app usually ships in the app's own image and needs
nothing here: an init container with no tag of its own rides `imageTag`, because
the same pipeline built both, and one bump moves the pair.

When that is not true, it gets a second file. `new-tab-links-migrations` is its
own repository publishing a schema version on its own cadence, so pinning it to
the backend's tag would name a version that does not exist in its registry:

```yaml
# versions/new-tab-links-backend-init.yaml
initImageTags:
  migrations: "1.2.3"
```

```yaml
valueFiles:
  - $values/applications/new-tab-links-backend/values.yaml    # config, humans
  - $values/versions/new-tab-links-backend.yaml               # app tag, CI
  - $values/versions/new-tab-links-backend-init.yaml          # init tags, CI
```

A file of its own, rather than another key in the app's, for exactly the reason
the app's tag is not in `applications/`: two pipelines writing one file race,
and the loser's push is rejected.

It is a **map**, keyed by the init container's name. The list stays where humans
edit it:

```yaml
# applications/new-tab-links-backend/values.yaml
initContainers:
  - name: migrations
    image: new-tab-links-migrations
```

The map is what makes the split possible at all. Helm merges values files as
maps but replaces **lists** wholesale, so a file setting `initContainers` would
have to restate every entry — image, command, resources — leaving a pipeline to
rewrite configuration it knows nothing about. `initImageTags` is also a
different key from `imageTag`, so the two version files merge instead of the
second overwriting the first.

The key is the name the chart resolves for that container: the entry's `name`,
or `init-<image>` when it has none. A key matching no container is **not** an
error — the tag is ignored and the container falls back to the app's — so have
the pipeline write the key rather than leave it to be derived.

Quote the value. An unquoted `1.2` is a YAML float, not a tag.

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

An init container's pipeline writes its own file the same way. Note `git add`:
`commit -a` stages modifications, and the first run creates the file.

```yaml
- name: Pin the migration image
  run: |
    git clone --depth 1 git@github.com:Kovospace/kovostack-infra-gitops.git gitops
    cd gitops
    printf 'initImageTags:\n  %s: "%s"\n' "$CONTAINER" "$VERSION" \
      > versions/${APP}-init.yaml
    git add versions/${APP}-init.yaml
    git commit -m "pin ${APP} ${CONTAINER} ${VERSION}" && git push
```

That makes the concurrency note below a real case rather than a hypothetical
one: two pipelines now push here for a single app.

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
