# mirrord — running a local process inside this cluster

[mirrord](https://metalbear.com/mirrord/) lets a process on a developer's laptop behave as
though it were a Pod in this cluster. The local process gets the target Pod's **environment
variables**, its **DNS**, and its **outgoing network**; optionally it also receives the Pod's
**incoming traffic**.

That is why it is used here. The website is developed against real backend data without
recreating on a laptop what only the cluster has: the Infisical-synced secrets, the Postgres
instance on the VM's Docker, and the Brevo SMTP relay.

## What is installed — nothing

**No manifest in this repository has anything to do with mirrord.** The open-source CLI runs
entirely from the developer's machine, against their kubeconfig. There is no Helm chart to add,
no `infrastructure/` directory, no Application, and no sync wave to fit into.

The paid **mirrord Operator** (mirrord for Teams, $40/seat/month) was considered and declined:
its value is concurrent sessions, traffic filtering between developers and RBAC that spares
users privileged-pod rights — all of which pay off for a team sharing a cluster, and none of
which apply to one person on their own. See `TODOS.md`; it is deliberately deferred, not
overlooked.

## Manual setup — done once, by hand

These steps are not GitOps and cannot be. They configure a laptop, not the cluster.

> **Every command below runs on the laptop, not on the VM.** The point of mirrord is that a
> local process behaves like a Pod; nothing is installed server-side. The one command that
> executes remotely does so through `ssh`, and its output is redirected into a *local* file —
> running it while logged into the VM would write the file there instead.
>
> `vm` stands for your SSH destination. There is no `~/.ssh/config` on this machine, so it is a
> placeholder, not a working alias: substitute the real `user@host`, or define it once —
>
> ```
> # ~/.ssh/config
> Host vm
>     HostName <the VM's address>
>     User <your user>
> ```

### 1. A kubeconfig that reaches the API server

The k3s API server is not published to the internet. Reach it over an SSH tunnel to the VM:

```bash
mkdir -p ~/.kube
# `sudo cat` runs on the VM; the redirect writes the file here.
ssh vm sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config-kovostack
chmod 600 ~/.kube/config-kovostack
```

It comes out pointing at `https://127.0.0.1:6443`, which is exactly right for a tunnel — leave
it alone and open the tunnel in a terminal you keep running:

```bash
ssh -N -L 6443:127.0.0.1:6443 vm
```

Then, in the shell that runs mirrord:

```bash
export KUBECONFIG=~/.kube/config-kovostack
```

`kubectl` is **not installed on the laptop**, and mirrord does not need it — it reads the
kubeconfig file itself. If you want a check before trusting the tunnel, install kubectl and run
`kubectl get nodes`; otherwise the first `mirrord exec` is the test.

The k3s server certificate carries `127.0.0.1` as a SAN, so the tunnel validates without
`insecure-skip-tls-verify`.

> Not verified from here: this repository has no cluster access, so whether port 6443 is also
> reachable directly (skipping the tunnel) is unknown. The tunnel needs nothing opened, so it is
> the route to try first.

This kubeconfig is the **k3s admin** credential — it can do anything to the cluster. That is
acceptable for the one person who already has root on the VM, and it is why no ServiceAccount or
RBAC is committed here. If mirrord ever needs to be handed to someone who should not be cluster
admin, that changes: they need a ServiceAccount allowed to create pods (privileged), exec into
them and port-forward, in the target namespaces only — and *that* would belong in
`infrastructure/`.

### 2. The mirrord CLI

```bash
curl -fsSL https://raw.githubusercontent.com/metalbear-co/mirrord/main/scripts/install.sh | bash
mirrord --version
```

JetBrains and VS Code plugins exist and read the same `.mirrord/mirrord.json` files; the CLI is
what the documented loops below use.

### 3. Confirm it can see the target

```bash
mirrord ls -n new-tab-links-backend      # lists targetable workloads in that namespace
```

`deployment/new-tab-links-backend` appearing in that list means mirrord has everything it needs. There is no
`mirrord install`, no operator status to check, and nothing to sync. (With kubectl installed,
`kubectl -n new-tab-links-backend get deployment new-tab-links-backend` is the same check.)

## What mirrord does to this cluster while it runs

- It **creates a Pod imperatively** in the target's namespace, named `mirrord-agent-*`. The Pod
  is privileged and short-lived (`agent.ttl` seconds after the session ends).
- That Pod carries **none of ArgoCD's tracking labels**, so `prune` ignores it and no Application
  is reported `OutOfSync` because of it. This is the one place where something exists in the
  cluster that git does not describe, and it is fine — it is ephemeral and owned by a human
  session, not by the desired state.
- A lingering `mirrord-agent-*` Pod means a session that was killed uncleanly. Deleting it is
  safe.
- The app namespaces carry **no Pod Security labels** — `charts/app`'s `namespace.yaml` sets only
  `app.labels` and `kubernetes.io/metadata.name` — so nothing at the namespace level stops a
  privileged agent Pod. Whether a cluster-wide `PodSecurity` admission default exists on this
  k3s install was **not verified** (this repository has no cluster access). If an agent Pod is
  ever rejected on admission, that is the first thing to check, and the fix is a
  `pod-security.kubernetes.io/enforce: privileged` label on the target namespace — which would
  mean a chart change, not an edit here.

## The two loops

Both configs live in the application repositories, next to the code they run.

### Mirror — the default, non-disruptive

`new-tab-links-backend/.mirrord/mirrord.json`. The local JVM inherits the deployed Pod's
environment, DNS and network; production traffic is **copied** to it while the real Pod keeps
serving every request.

```bash
cd ~/IdeaProjects/new-tab-links-backend && mirrord exec -- ./mvnw spring-boot:run
cd ~/IdeaProjects/new-tab-links-frontend && npm start          # no mirrord needed
```

The website talks to `http://localhost:8080` exactly as it does against the compose stack, so
nothing in the frontend repository changes.

### Steal — opt-in, and an outage while it lasts

`.mirrord/steal.json` in either repository. Requests arriving at the real Ingress are **rerouted
to the laptop**; the deployed Pod serves nothing for the duration.

```bash
mirrord exec -f .mirrord/steal.json -- ./mvnw spring-boot:run   # backend
mirrord exec -f .mirrord/steal.json -- npm start                # website, on the real domain
```

Stealing the website is the way to develop with real TLS, the real origin and no CORS at all.
Stealing the backend is how a deployed website or a published extension is pointed at local
server code. Neither is a cluster change and neither leaves a trace in git — but while it runs,
`new-tab-links.matejkovac.sk` or `api.new-tab-links.matejkovac.sk` is being served from someone's
laptop. If an app looks down and nothing changed in git, ask this before investigating anything
else.

## What mirrord does not sandbox

The local process is inside the production environment, not beside it:

- **The database is the production database.** Every write the local process makes is real.
- **Mail is really sent.** `NEWTABLINKS_MAIL_ENABLED` is `true` in the deployment and the Brevo
  credentials come with the environment, so a registration test emails a real address.
- **The secrets are the production secrets** — the JWT signing key, the Google OAuth client
  secret, the admin password. They are in the local process's memory and, if it dumps its
  environment, in its logs.

There is no flag that fixes this; the fix is a second environment. The `.mirrord/README.md` in
each repository says the same thing at the point of use, and the config files override the few
values (CORS origins, the web base URL) that would otherwise point a locally-served page at
production.

## The extension

mirrord does not apply to `NewTabGroupedLinks`. It relocates a *local process*; the extension
runs inside Chrome. Point it at `http://localhost:8080` with a local backend under mirrord, or
call the public API directly — the deployed backend already allows `chrome-extension://*` as a
CORS origin.
