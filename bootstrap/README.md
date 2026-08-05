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

If the repository is private, register credentials before applying the root app:

```bash
argocd repo add https://github.com/Kovospace/kovostack-infra-gitops.git \
  --username <user> --password <token>
```