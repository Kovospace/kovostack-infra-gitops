# bootstrap

The one manual step. Everything after this is driven by ArgoCD from git.

```bash
# 1. Minimal ArgoCD, just enough to run the root app.
kubectl create namespace argocd
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd \
  --version 10.2.3 \
  --set configs.params."server\.insecure"=true

# 2. Hand over control to git.
kubectl apply -f bootstrap/root-app.yaml
```

The `argocd` Application in `clusters/production/` then adopts the Helm release
installed in step 1 and manages it from `infrastructure/argocd/` — after the
first sync, changes to ArgoCD itself go through git, not `helm upgrade`.

Initial admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

## Private repository

Register credentials **before** step 2, or the root app sits at `SYNC STATUS:
Unknown` — it stays `Healthy` because an app with no manifests has nothing
unhealthy in it, which makes the failure easy to misread. The real reason is in
the conditions:

```bash
kubectl -n argocd get app root \
  -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}'
```

This repo authenticates with a **deploy key**, so every `repoURL` uses the SSH
form. A deploy key cannot authenticate over HTTPS — the two go together.

Register the key without it ever touching a file in this repo or your shell
history:

```bash
kubectl -n argocd create secret generic repo-kovostack-infra-gitops \
  --from-literal=type=git \
  --from-literal=url=git@github.com:Kovospace/kovostack-infra-gitops.git \
  --from-file=sshPrivateKey=$HOME/.ssh/argocd-deploy-key

kubectl -n argocd label secret repo-kovostack-infra-gitops \
  argocd.argoproj.io/secret-type=repository
```

The key must have **no passphrase** — ArgoCD has no ssh-agent and cannot
prompt, so a key that works fine for you interactively will still fail here:

```bash
ssh-keygen -y -P '' -f $HOME/.ssh/argocd-deploy-key >/dev/null \
  && echo 'no passphrase - usable'
```

`repo-credentials.example.yaml` has the same thing as a manifest, plus the
fine-grained-PAT variant if you ever move back to HTTPS.

Credentials can be added at any time; the root app retries on its own and no
re-apply is needed.

Equivalent via the CLI, if you have it logged in:

```bash
argocd repo add git@github.com:Kovospace/kovostack-infra-gitops.git \
  --ssh-private-key-path ./argocd-deploy-key
```