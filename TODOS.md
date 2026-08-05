# TODOS

## Nice to have in the future

### Infisical Kubernetes auth instead of a static machine identity

Today the `ClusterSecretStore` authenticates with Universal Auth — a long-lived
`clientId`/`clientSecret` pair held in the `infisical-credentials` Secret and
applied by hand (`bootstrap/infisical-credentials.example.yaml`). It is the one
credential in the cluster that cannot come from external-secrets, because it is
what external-secrets authenticates with.

The ESO Infisical provider also supports `kubernetesAuthCredentials`, where the
cluster proves its identity with its own ServiceAccount token instead:

```yaml
auth:
  kubernetesAuthCredentials:
    identityId:                 # not a secret — an Infisical identity UUID
      name: infisical-identity
      key: identityId
      namespace: external-secrets
    serviceAccountTokenPath: {} # defaults to the projected token path
```

**Why it would be nice**

- No long-lived shared secret to store, rotate, or leak.
- Credentials become short-lived and automatically rotated by Kubernetes.
- The bootstrap stops depending on a manual step that git does not record — a
  cluster rebuild would need only the identity UUID, which is not sensitive.

**Why it was not done now**

It inverts the dependency. Infisical must validate the ServiceAccount token by
calling the cluster's TokenReview API, but Infisical runs in Docker on the host,
outside the cluster. Making that work means:

- routing Infisical → k3s API server (`:6443`) from inside its container, the
  same host-gateway problem that `CLUSTER_INGRESS_IP` solves in the other
  direction;
- giving Infisical credentials and CA trust for the k3s API;
- accepting that Infisical then needs the cluster to be reachable in order to
  serve secrets, coupling two systems that are currently independent.

That is a substantial integration to remove a single credential, and it makes
the platform's secret store depend on the cluster it is meant to bootstrap.

**Revisit when** Infisical moves into the cluster, or a second cluster/consumer
makes one static credential per consumer genuinely burdensome.

**Cheaper alternative if the goal is only "reproducible from git":** SOPS + age
or Sealed Secrets, committing the credential as ciphertext. Cost is a
decryption key that must be backed up outside the cluster.

**Related, and independent of all of the above:** Kubernetes Secrets are
base64-encoded, not encrypted, in etcd. `k3s server --secrets-encryption`
protects this credential, the repo deploy key and every synced app secret at
once, for far less effort than any option here.