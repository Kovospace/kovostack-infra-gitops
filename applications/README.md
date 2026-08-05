# applications

Workload Applications, one YAML per app. Picked up automatically (recursively)
by `clusters/production/applications.yaml` at sync-wave `30`, after the
infrastructure layer is healthy.

Example — `applications/my-api.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-api
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/Kovospace/kovostack-infra-gitops.git
    targetRevision: main
    path: applications/my-api
    helm:
      valueFiles:
        - values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: my-api
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

Add `namespaces/my-api.yaml` for the target namespace. Chart sources can live
in a subdirectory next to the Application manifest, or point `repoURL` at an
external chart repository.