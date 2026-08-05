# namespaces

Namespaces are declared here rather than relying on `CreateNamespace=true`, so
labels (pod-security, mesh injection, quotas) stay under version control and
there is exactly one owner per namespace.

Synced by `clusters/production/namespaces.yaml` at sync-wave `-10`, i.e. before
any infrastructure Application. `prune` is disabled — removing a Namespace
deletes everything inside it, so do that deliberately with `kubectl`.

Adding a namespace: drop a manifest in here, then point the workload's
Application at it with `syncOptions: [CreateNamespace=false]`.