#!/usr/bin/env bash
# Scaffold a new application into this GitOps repo.
#
# Writes three files and nothing else:
#   applications/<name>.yaml          the ArgoCD Application
#   applications/<name>/values.yaml   the app's configuration
#   versions/<name>.yaml              the image tag, thereafter written by CI
#
# It does not commit, does not push, and does not touch the cluster. The manual
# steps it cannot do (Infisical folder, DNS, the database) are printed at the end.
#
# Usage:
#   .claude/scripts/new-app.sh --name myapp --host myapp.matejkovac.sk --port 8080 \
#       [--image myapp] [--postgres mydb | --no-postgres] [--no-secrets] \
#       [--db-style spring|url] [--chart-version 1.4.1] [--dry-run]
set -euo pipefail

REPO=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$REPO"

name=""; host=""; port=""; image=""; db=""; secrets=true
db_style="spring"; chart_version=""; dry_run=false

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

while (( $# )); do
  case $1 in
    --name)          name=${2:-}; shift 2 ;;
    --host)          host=${2:-}; shift 2 ;;
    --port)          port=${2:-}; shift 2 ;;
    --image)         image=${2:-}; shift 2 ;;
    --postgres)      db=${2:-}; shift 2 ;;
    --no-postgres)   db=""; shift ;;
    --no-secrets)    secrets=false; shift ;;
    --db-style)      db_style=${2:-}; shift 2 ;;
    --chart-version) chart_version=${2:-}; shift 2 ;;
    --dry-run)       dry_run=true; shift ;;
    -h|--help)       sed -n '2,20p' "$0"; exit 0 ;;
    *)               die "unknown argument: $1" ;;
  esac
done

# --- validate ----------------------------------------------------------------
[[ -n $name ]] || die "--name is required (it is also the namespace)"
[[ $name =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || \
  die "--name '$name' is not a valid namespace: lowercase letters, digits and '-', starting and ending alphanumeric"
(( ${#name} <= 63 )) || die "--name is longer than 63 characters"

[[ -n $port ]] || die "--port is required (the port your container listens on)"
[[ $port =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || die "--port '$port' is not a port number"

if [[ -n $host ]]; then
  [[ $host =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && $host == *.* ]] || \
    die "--host '$host' is not a hostname. Pass no --host for an app with no public route."
fi

if [[ -n $db ]]; then
  [[ $db =~ ^[a-z_][a-z0-9_]*$ ]] || \
    die "--postgres '$db' is not a usable database name: lowercase letters, digits and '_'"
fi

case $db_style in spring|url) ;; *) die "--db-style must be 'spring' or 'url'" ;; esac

image=${image:-$name}

# Default the chart to the newest tag any app here already runs, so a new app
# never lands on a version nothing else has been through.
if [[ -z $chart_version ]]; then
  chart_version=$(grep -ho 'targetRevision: chart-app-[0-9.]*' applications/*.yaml 2>/dev/null \
    | sed 's/.*chart-app-//' | sort -V | tail -1)
  [[ -n $chart_version ]] || die "could not detect a chart version; pass --chart-version"
fi

app_manifest="applications/${name}.yaml"
values_file="applications/${name}/values.yaml"
version_file="versions/${name}.yaml"

for f in "$app_manifest" "$values_file" "$version_file"; do
  [[ -e $f ]] && die "$f already exists — pick another name, or remove it first"
done

# --- render ------------------------------------------------------------------
render_manifest() {
cat <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application

metadata:
  name: ${name}
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io

spec:

  project: applications

  sources:

    ### Základné Kubernetes resources
    # Pinned. Upgrading the chart is a per-app decision: bump this, watch it,
    # then move the next app.
    - repoURL: git@github.com:Kovospace/kovostack-helm-charts.git
      targetRevision: chart-app-${chart_version}
      path: charts/app
      helm:
        # Order matters — later files win. versions/ is written by CI and
        # carries only the image tag, so a deploy never touches the file a
        # human edits.
        valueFiles:
          - \$values/applications/${name}/values.yaml
          - \$values/versions/${name}.yaml

    ### Pointer na referencovaý values.yaml
    - repoURL: git@github.com:Kovospace/kovostack-infra-gitops.git
      targetRevision: main
      ref: values

  destination:
    server: https://kubernetes.default.svc
    # Must match \`name\` in the values file — the chart renders the Namespace,
    # so CreateNamespace stays off.
    namespace: ${name}

  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=false
YAML
}

render_values() {
cat <<YAML
---
name: ${name}
image: ${image}
# imageTag lives in versions/${name}.yaml — written by CI, loaded after this
# file. Setting it here too would create a second source of truth that always
# loses.

# Nastavenie domény
containerPort: ${port}
YAML

  if [[ -n $host ]]; then
    printf 'host: %s\n' "$host"
  else
    cat <<'YAML'
# No public route — no Ingress and no certificate are rendered.
host: ""
YAML
  fi

  if [[ $secrets == false ]]; then
cat <<YAML

# Bez external-secrets: nesynchronizuje sa žiadny ${name}-secrets.
# The app gets no env vars from Infisical — everything it needs must be in
# \`env:\` below, in git. Note that pulling from the private registry still
# works: that credential is a separate Secret and is not switched off here.
secrets:
  enabled: false
YAML
  fi

  if [[ -n $db ]]; then
cat <<YAML

# Pripojenie na postgres databázu
# Postgres runs in Docker on the VM, not in the cluster. This renders a
# selector-less Service so the app can reach it as \`postgres:5432\`.
externalServices:
  postgres:
    address: 172.17.0.1 # docker0 gateway — must be an IP, not a hostname
    port: 5432
YAML
  fi

cat <<'YAML'

# Volumes
# nie sú
YAML

  if [[ -z $db ]]; then
    # Nothing to put here yet. `{}` and not a bare `env:`, which YAML reads as
    # null and which would override the chart's default with nothing.
    printf '\n# Plain, non-sensitive settings only. Anything secret belongs in Infisical.\nenv: {}\n'
  else
    printf '\nenv:\n'
    if [[ $secrets == true ]]; then
cat <<'YAML'
  ### Database settings
  # Credentials come from Infisical, not from git:
  # SPRING_DATASOURCE_USER: ${DB_USER} # presunuté do vault
  # SPRING_DATASOURCE_PASS: ${DB_USER_PASSWORD} # presunuté do vault
YAML
    else
cat <<'YAML'
  ### Database settings
  # external-secrets is off for this app, so the database user and password
  # have nowhere secret to come from. Do NOT put them here — turn secrets back
  # on, or inject them another way.
YAML
    fi
    if [[ $db_style == spring ]]; then
      printf '  SPRING_DATASOURCE_URL: jdbc:postgresql://postgres:5432/%s\n' "$db"
      printf '  SPRING_DATASOURCE_DRIVER_CLASS_NAME: org.postgresql.Driver\n'
      printf '  SPRING_JPA_HIBERNATE_DIALECT: org.hibernate.dialect.PostgreSQLDialect\n'
      printf '  # Non-JVM stack? Use this instead and delete the three lines above:\n'
      printf '  # DATABASE_URL: postgresql://postgres:5432/%s\n' "$db"
    else
      printf '  DATABASE_URL: postgresql://postgres:5432/%s\n' "$db"
      printf '  # JVM stack? Use these instead and delete the line above:\n'
      printf '  # SPRING_DATASOURCE_URL: jdbc:postgresql://postgres:5432/%s\n' "$db"
      printf '  # SPRING_DATASOURCE_DRIVER_CLASS_NAME: org.postgresql.Driver\n'
    fi
  fi

cat <<'YAML'

resources:
  requests:
    cpu: 250m
    memory: 128Mi
  limits:
    memory: 512Mi
YAML
}

render_version() {
cat <<'YAML'
# Written by the app's build pipeline from here on — see versions/README.md.
# `change_me` is a placeholder: the first deploy replaces it with a real tag.
YAML
printf 'imageTag: change_me\n'
}

# --- write -------------------------------------------------------------------
if $dry_run; then
  printf '=== %s ===\n' "$app_manifest";  render_manifest
  printf '\n=== %s ===\n' "$values_file"; render_values
  printf '\n=== %s ===\n' "$version_file"; render_version
  exit 0
fi

mkdir -p "applications/${name}"
render_manifest > "$app_manifest"
render_values   > "$values_file"
render_version  > "$version_file"

printf 'Created:\n  %s\n  %s\n  %s\n\n' "$app_manifest" "$values_file" "$version_file"

# --- what the script cannot do ----------------------------------------------
step=0
next() { step=$((step+1)); printf '%d. %s\n' "$step" "$1"; }

printf 'Before this can go to main:\n'
if [[ $secrets == true ]]; then
  next "Create the Infisical folder /${name} and put the app's secrets in it.
   They arrive as env vars automatically — adding one later needs no commit."
fi
if [[ -n $db ]]; then
  next "Create the database on the VM's Postgres, and a user with rights on it:
     createdb -h <vm> -U postgres ${db}
   Put that user and password in Infisical /${name}."
fi
if [[ -n $host ]]; then
  next "Point DNS for ${host} at the VM. The certificate is issued by an
   HTTP-01 challenge, so the record must resolve BEFORE the first sync."
fi
next "Build and push the image to registry.matejkovac.sk/apps/${image},
   then write its tag into versions/${name}.yaml (\`imageTag: change_me\` now).
   From then on the pipeline writes that file — see versions/README.md."
next "Render it before pushing:
     helm template ${name} ../kovostack-helm-charts/charts/app \\
       -f applications/${name}/values.yaml -f versions/${name}.yaml"
next "Commit, then ask before pushing to main — that push is the deploy."
