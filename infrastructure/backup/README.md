# backup — restic REST gateway to the Hetzner Storage Box

Daily backups run as K8up Jobs in each app's namespace (operator:
`infrastructure/k8up/`). They all write through one gateway in the `backup`
namespace, and the gateway stores to a Hetzner Storage Box.

```
app namespace                        backup namespace                 off-VM
┌───────────────────────┐   HTTP    ┌──────────────────────┐  SFTP   ┌──────────────────────┐
│ K8up backup Job        │ ────────► │ restic-gateway       │ ──────► │ Storage Box          │
│ (restic, PVC mounted   │ basic     │ rclone serve restic  │ :23,    │ sub-account, chroot  │
│  read-only)            │ auth      │ ClusterIP :8080      │ ssh key │ restic/<app>/…       │
└───────────────────────┘           └──────────────────────┘         └──────────────────────┘
```

**Why a gateway at all.** K8up's backends are local, s3, gcs, azure, swift, b2
and rest — there is no SFTP — and a Storage Box speaks nothing but SFTP (and
FTP/SMB/WebDAV). `rclone serve restic` speaks restic's REST protocol on one side
and any rclone remote on the other, so it bridges the two without anything
running on the Storage Box.

## Contract with charts/app

Everything below is relied on by the app chart. Changing any of it breaks every
app's backups at once, and a broken backup is silent until the restore.

| What | Value |
|---|---|
| Gateway URL | `http://restic-gateway.backup.svc.cluster.local:8080` |
| Repository per app | `rest:http://restic-gateway.backup.svc.cluster.local:8080/<name>/` (`<name>` = the chart's `name`) |
| Where that lands on the box | `<sub-account home>/restic/<name>/` |
| Credentials | Infisical `/backup`: `RESTIC_REST_USERNAME`, `RESTIC_REST_PASSWORD`, `RESTIC_PASSWORD` |
| Store for reading them | `ClusterSecretStore/infisical-backup` (rendered here; reference it, do not render another of that name) |

Repositories are created on first use: K8up runs `restic init` when the path is
empty, and the gateway serves any number of `/<path>/` repositories under one
endpoint.

**`RESTIC_REST_PASSWORD` must be URL-safe — letters and digits only.** K8up does
not pass REST credentials as restic's `RESTIC_REST_*` variables; it splices them
into the repository URL (`rest:http://$(USER):$(PASSWORD)@host/…`) without
escaping. A `/`, `@`, `:` or `%` in the password makes restic fail to parse the
URL. `openssl rand -hex 32` produces a safe one.

All apps share one REST user and one `RESTIC_PASSWORD`. That means any app
namespace holding them can read or delete any other app's repository. It is a
deliberate simplification for one owner on one cluster. Per-app credentials
would need `--htpasswd` plus `--private-repos` on the gateway and a key per app
in Infisical.

## Infisical `/backup`

| Key | Used by | Value |
|---|---|---|
| `STORAGEBOX_HOST` | gateway | `uXXXXXX-subN.your-storagebox.de` — the **sub-account's** hostname |
| `STORAGEBOX_USER` | gateway | `uXXXXXX-subN` |
| `STORAGEBOX_SSH_PRIVATE_KEY` | gateway | the whole OpenSSH private key, `-----BEGIN…` to `-----END…-----`, no passphrase |
| `STORAGEBOX_KNOWN_HOSTS` | gateway | one line: `[uXXXXXX-subN.your-storagebox.de]:23 ssh-ed25519 AAAA…` |
| `RESTIC_REST_USERNAME` | gateway, every backup Job | any name, e.g. `k8up` |
| `RESTIC_REST_PASSWORD` | gateway, every backup Job | letters and digits only (see above) |
| `RESTIC_PASSWORD` | every backup Job, restores | repository encryption password. **Losing it loses every backup.** Keep a copy outside Infisical, which runs on the same VM. |

The gateway's ExternalSecret lists the six keys it needs explicitly. Until all six
exist, it reports `SecretSyncedError` and the Pod stays in
`CreateContainerConfigError`. `RESTIC_PASSWORD` is not copied into the `backup`
namespace, because the gateway only ever handles ciphertext.

## Settled decisions

- **SSH key authentication on port 23.** Port 23 is the Storage Box's extended
  SSH service and takes keys in normal OpenSSH format. Port 22 wants RFC4716,
  so don't mix the two up. No password is stored anywhere.
- **Host key pinned, never skipped.** `known_hosts_file` plus
  `host_key_algorithms: ssh-ed25519`. The algorithm pin matters: without it Go's
  SSH client may negotiate RSA or ECDSA and reject an ed25519-only known_hosts
  with `knownhosts: key mismatch`. A wrong key makes rclone exit at startup, so
  the symptom is a crash-looping Pod, never backups quietly sent to an
  impostor.
- **Not append-only.** K8up's prune deletes through the gateway, which is how
  retention works. Protection against deletion and ransomware comes from
  **Storage Box snapshots**, which are taken by Hetzner, outside the reach of
  anything holding these credentials.
- **Basic auth via `--user`/`--pass`**, fed as `RCLONE_USER`/`RCLONE_PASS` from
  the Secret, not an htpasswd file. On the wire it is the same thing, but an
  htpasswd means bcrypt, and bcrypt verification on each of the thousands of
  requests a backup makes is CPU this VM does not have.
- **`connections: 4`.** Hetzner allows 10 simultaneous connections per Storage
  Box account, and rclone's default is unlimited.
- **Image `docker.io/rclone/rclone:1.75.1`**, run as `nobody` with a read-only
  root filesystem. Requests are 10m CPU and 48Mi, with a 256Mi limit. It
  measured about 32Mi streaming a 300 MB backup.

## First-time setup (manual, outside git)

1. **Sub-account.** Hetzner Console → Storage Box → *Sub-accounts* → create one.
   Set its base directory to a dedicated one, e.g. `/kovostack`. Enable **SSH**
   (SFTP) for it. Leave Samba, WebDAV and external reachability off unless
   something else needs them. Note the username `uXXXXXX-subN`; its hostname is
   `uXXXXXX-subN.your-storagebox.de`. Activation can take a few minutes.
2. **Key pair** (on your machine, no passphrase — the Pod cannot type one):
   ```bash
   ssh-keygen -t ed25519 -N '' -C restic-gateway -f storagebox-restic
   cat storagebox-restic.pub | ssh -p 23 uXXXXXX-subN@uXXXXXX-subN.your-storagebox.de install-ssh-key
   ```
   `install-ssh-key` asks for the sub-account password once and adds the key
   without overwriting existing ones. Check it with
   `sftp -P 23 -i storagebox-restic uXXXXXX-subN@uXXXXXX-subN.your-storagebox.de`.
   Then create the repository root there: `mkdir restic`. rclone would create
   it on its own, but checking now proves the write path.
3. **Host key.**
   ```bash
   ssh-keyscan -p 23 -t ed25519 uXXXXXX-subN.your-storagebox.de > storagebox-known_hosts
   ssh-keygen -lf storagebox-known_hosts
   ```
   The fingerprint must be `SHA256:XqONwb1S0zuj5A1CDxpOSuD2hnAArV1A3wKY7Z3sdgM`,
   the ED25519 fingerprint Hetzner publishes for Storage Boxes. If it is not,
   stop. The line starts with `[host]:23`, which is correct for a non-22 port.
4. **Infisical** → project `kovostack`, environment `prod`, folder `/backup`:
   the seven keys in the table above. Paste the private key and the known_hosts
   line as multi-line values. A missing trailing newline is fine; that was
   tested.
5. **Snapshots.** Storage Box → *Snapshots* → *Automatic snapshots*: daily, some
   time after the backups finish (backups run at night, e.g. 03:00 → snapshot
   at 06:00). Keep as many as the plan allows (BX11: 10 slots). This is the
   deletion/ransomware protection. It covers the whole box, sub-accounts
   included.
6. Then shred the local private key, or keep it in a password manager. It is in
   Infisical now.

## Checking it works

```bash
kubectl -n backup get externalsecret,pods
kubectl -n backup logs deploy/restic-gateway
#   NOTICE: sftp://uXXXXXX-subN@…:23/restic: Serving restic REST API on [http://[::]:8080/]
```

rclone connects to the box before it starts listening. A Ready Pod therefore
already proves the key, the host key and the sub-account. What it does not prove
is a backup — see the restore test below.

## Restore

A backup that has never been restored is a guess. Do procedure A once per app
after its first backup.

K8up takes one snapshot per PVC, with path `/data/<pvc>`. A database dump
streamed from a `PreBackupPod` or backup-command annotation is its own snapshot
holding a single file, `/<namespace>-<container><file-extension>`. The
namespace is the app name.

### A. restic CLI through the gateway (inspect, fetch files, test)

From your machine, with the admin kubeconfig:

```bash
kubectl -n backup port-forward svc/restic-gateway 8080:8080 &

export RESTIC_REPOSITORY=rest:http://localhost:8080/<app>/
export RESTIC_REST_USERNAME=…   # Infisical /backup
export RESTIC_REST_PASSWORD=…   # Infisical /backup
export RESTIC_PASSWORD=…        # Infisical /backup

restic snapshots
restic ls <snapshot-id>
restic restore <snapshot-id> --target ./restore-<app>
restic dump <snapshot-id> /<app>-<container>.sql > dump.sql    # a DB stdin backup
restic check --read-data-subset=5%                               # occasional integrity check
```

restic reads `RESTIC_REST_USERNAME`/`PASSWORD` itself (restic ≥ 0.17), so
the URL needs no credentials here. For SQLite, check a restored file with
`sqlite3 restored.db 'PRAGMA integrity_check'`.

### B. K8up `Restore` into a PVC (put data back in the cluster)

Stop the app first. `selfHeal` reverts a `kubectl scale`, so this is a git
change: set the app's `replicas: 0` in `applications/<app>/values.yaml` and
push. That push is a deploy, so it needs the usual permission. Restore into the
existing claim, then revert the commit.

```yaml
apiVersion: k8up.io/v1
kind: Restore
metadata:
  name: restore-<app>-<yyyymmdd>
  namespace: <app>
spec:
  # Always name the snapshot: every PVC has its own, so "latest" may be a
  # different volume's.
  snapshot: <snapshot-id>
  restoreMethod:
    folder:
      claimName: <pvc>
  backend:
    repoPasswordSecretRef:
      name: <secret the chart renders with the /backup keys>
      key: RESTIC_PASSWORD
    rest:
      url: http://restic-gateway.backup.svc.cluster.local:8080/<app>/
      userSecretRef:
        name: <same secret>
        key: RESTIC_REST_USERNAME
      passwordSecretReg:          # sic — K8up's field name has this typo
        name: <same secret>
        key: RESTIC_REST_PASSWORD
```

`kubectl apply` this by hand: it is a one-shot operation, not desired state, and
ArgoCD neither tracks nor prunes it. Files land at the claim's root; K8up strips
the `/data/<pvc>` prefix. Existing files are overwritten but extra files are
kept unless you set `delete: true`. When it is done,
`kubectl -n <app> delete restore restore-<app>-<yyyymmdd>`.

A database is restored from its dump (`restic dump`, procedure A) with the
database's own tools. K8up does not restore it.

### Losing the whole VM

You need, from outside the VM: this repo, the Storage Box credentials, and
`RESTIC_PASSWORD`. Infisical runs on the same VM, so keep those three in a
password manager as well. Rebuild the cluster from `bootstrap/`, recreate
`/backup` in Infisical, then do B for each app.

## Adding the Raspberry Pi later

Planned, not built. The Pi runs restic's own `rest-server` on the home network,
reachable from the VM over WireGuard/Tailscale set up on the host. The Pi
speaks the REST API directly, so it needs no gateway:

1. **Here:** a selector-less Service `restic-pi` in this chart plus a
   hand-written EndpointSlice pointing at the Pi's tunnel address. That is the
   same pattern charts/app uses for `externalServices`. The URL then stays
   in-cluster:
   `http://restic-pi.backup.svc.cluster.local:8000/<name>/`. Pod traffic leaves
   through the node, so the host's tunnel route has to cover it. Check that with
   a `curl` from a Pod before relying on it.
2. **Infisical `/backup`:** `PI_RESTIC_REST_USERNAME`,
   `PI_RESTIC_REST_PASSWORD` (URL-safe, same reason), matching the Pi's
   `rest-server --htpasswd-file`. Reuse `RESTIC_PASSWORD`, or use a second one
   if the Pi should be independently recoverable.
3. **charts/app:** a second destination — a second K8up `Schedule` with the Pi's
   URL and credential keys, offset by an hour so the two don't contend for the
   PVC. The chart only has to accept a list of destinations instead of one.

Decide on the Pi whether `rest-server` runs `--append-only`. If it does, K8up's
prune fails for that destination and retention must run on the Pi itself
(`restic forget --prune` from a cron job there). In exchange, the Pi copy cannot
be deleted from the cluster.
