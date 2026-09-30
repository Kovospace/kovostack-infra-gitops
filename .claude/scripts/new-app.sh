#!/usr/bin/env bash
# Scaffold a new application into this GitOps repo, in one or more environments.
#
# Writes, and nothing else:
#   environments/<env>/<name>.yaml     per env: the chart pin; the ApplicationSet
#                                      turns it into an Application
#   applications/<name>/values.yaml    the app's configuration (shared)
#   applications/<name>/<env>.yaml     per env, only when there is more than one
#                                      environment or it is not prod: name, host,
#                                      database URL — what differs per env
#   versions/<app>.yaml                per env, the image tag, thereafter written
#                                      by CI (<app> = <name> in prod,
#                                      <name>-<env> elsewhere)
#
# It does not commit, does not push, and does not touch the cluster. The manual
# steps it cannot do (Infisical folders, DNS, databases) are printed at the end.
#
# Usage:
#   .claude/scripts/new-app.sh --name myapp --port 8080 \
#       [--env prod[=HOST]] [--env dev[=HOST]] [--host HOST] \
#       [--image myapp] [--postgres mydb | --no-postgres] [--no-secrets] \
#       [--db-style spring|url] [--chart-version 1.4.1] [--dry-run]
#
#   --env ENV[=HOST]  an environment to put the app in; repeatable. Default: prod.
#                     HOST is that environment's public host; `ENV=` means no
#                     public route there. Without `=`, prod takes --host and any
#                     other env derives <name>.<env>.matejkovac.sk if the app has
#                     a host at all.
#   --host HOST       prod's host (kept for the single-environment case).
set -euo pipefail

REPO=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$REPO"

name=""; host=""; port=""; image=""; db=""; secrets=true
db_style="spring"; chart_version=""; dry_run=false
envs=(); declare -A env_host=() env_host_set=()

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

while (( $# )); do
  case $1 in
    --name)          name=${2:-}; shift 2 ;;
    --host)          host=${2:-}; shift 2 ;;
    --port)          port=${2:-}; shift 2 ;;
    --image)         image=${2:-}; shift 2 ;;
    --env)           e=${2:-}; shift 2
                     if [[ $e == *=* ]]; then
                       env_host[${e%%=*}]=${e#*=}; env_host_set[${e%%=*}]=1; e=${e%%=*}
                     fi
                     envs+=("$e") ;;
    --postgres)      db=${2:-}; shift 2 ;;
    --no-postgres)   db=""; shift ;;
    --no-secrets)    secrets=false; shift ;;
    --db-style)      db_style=${2:-}; shift 2 ;;
    --chart-version) chart_version=${2:-}; shift 2 ;;
    --dry-run)       dry_run=true; shift ;;
    -h|--help)       sed -n '2,31p' "$0"; exit 0 ;;
    *)               die "unknown argument: $1" ;;
  esac
done

# --- validate ----------------------------------------------------------------
(( ${#envs[@]} )) || envs=(prod)

[[ -n $name ]] || die "--name is required (it is also the prod namespace)"
[[ $name =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || \
  die "--name '$name' is not a valid namespace: lowercase letters, digits and '-', starting and ending alphanumeric"

[[ -n $port ]] || die "--port is required (the port your container listens on)"
[[ $port =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || die "--port '$port' is not a port number"

valid_host() {
  [[ $1 =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && $1 == *.* ]] || \
    die "host '$1' is not a hostname. Pass no host for an app with no public route."
}
[[ -n $host ]] && valid_host "$host"

declare -A seen=()
for e in "${envs[@]}"; do
  [[ $e =~ ^[a-z0-9]+$ ]] || die "--env '$e' must be lowercase letters and digits — it becomes a name suffix"
  [[ -z ${seen[$e]:-} ]] || die "--env '$e' given twice"; seen[$e]=1
done

# Split the values per environment unless this is the one case that needs no
# split — prod alone. Anything environment-specific must then stay out of the
# shared values.yaml, or an env whose own file forgets it would inherit prod's.
split=true
[[ ${#envs[@]} -eq 1 && ${envs[0]} == prod ]] && split=false

app_name() { [[ $1 == prod ]] && printf '%s' "$name" || printf '%s-%s' "$name" "$1"; }

resolve_host() {  # resolve_host <env>
  local e=$1
  if [[ -n ${env_host_set[$e]:-} ]]; then printf '%s' "${env_host[$e]}"; return; fi
  if [[ $e == prod ]]; then printf '%s' "$host"; return; fi
  # Convention for every non-prod environment: subdomains of <env>.matejkovac.sk,
  # covered by the *.matejkovac.sk wildcard record.
  if [[ -n $host || -n ${env_host[prod]:-} ]]; then printf '%s.%s.matejkovac.sk' "$name" "$e"; fi
}

declare -A hosts=()
for e in "${envs[@]}"; do
  a=$(app_name "$e")
  (( ${#a} <= 63 )) || die "'$a' is longer than 63 characters"
  hosts[$e]=$(resolve_host "$e")
  [[ -n ${hosts[$e]} ]] && valid_host "${hosts[$e]}"
  if [[ $e != prod ]] && ! grep -q "^  name: applications-${e}\$" clusters/production/projects.yaml; then
    die "no AppProject 'applications-${e}' in clusters/production/projects.yaml — adding an environment is a deliberate step, see environments/README.md"
  fi
done

if [[ -n $db ]]; then
  [[ $db =~ ^[a-z_][a-z0-9_]*$ ]] || \
    die "--postgres '$db' is not a usable database name: lowercase letters, digits and '_'"
fi
# One database per environment; prod keeps the name it was given.
db_for() { [[ $1 == prod ]] && printf '%s' "$db" || printf '%s_%s' "$db" "$1"; }

case $db_style in spring|url) ;; *) die "--db-style must be 'spring' or 'url'" ;; esac

image=${image:-$name}

# Default the chart to the newest tag any app here already runs, so a new app
# never lands on a version nothing else has been through.
if [[ -z $chart_version ]]; then
  chart_version=$(grep -ho 'chartRevision: chart-app-[0-9.]*' environments/*/*.yaml 2>/dev/null \
    | sed 's/.*chart-app-//' | sort -V | tail -1)
  [[ -n $chart_version ]] || die "could not detect a chart version; pass --chart-version"
fi

values_file="applications/${name}/values.yaml"
files=("$values_file")
for e in "${envs[@]}"; do
  files+=("environments/${e}/${name}.yaml" "versions/$(app_name "$e").yaml")
  $split && files+=("applications/${name}/${e}.yaml")
done
[[ -e $values_file ]] && die "$values_file already exists — this script creates new apps only; to add an environment to an existing app, see environments/README.md"
for f in "${files[@]}"; do
  [[ -e $f ]] && die "$f already exists — pick another name, or remove it first"
done

# --- render ------------------------------------------------------------------
render_env_file() {  # render_env_file <env>
  local gate="Bump chartRevision here before prod's file."
  [[ $1 == prod ]] && gate="If the app runs in another environment too, bump chartRevision there first."
cat <<YAML
---
# ${name} in ${1} (Application $(app_name "$1")) — see environments/README.md.
# ${gate}
chartRevision: chart-app-${chart_version}
envValuesFile: ${split}
initTagsFile: false
YAML
}

db_url_lines() {  # db_url_lines <database> <indent>
  local d=$1
  if [[ $db_style == spring ]]; then
    printf '  SPRING_DATASOURCE_URL: jdbc:postgresql://postgres:5432/%s\n' "$d"
  else
    printf '  DATABASE_URL: postgresql://postgres:5432/%s\n' "$d"
  fi
}

host_lines() {  # host_lines <host>
  if [[ -n $1 ]]; then
    printf 'host: %s\n' "$1"
  else
cat <<'YAML'
# No public route — no Ingress and no certificate are rendered.
host: ""
YAML
  fi
}

render_values() {
  printf -- '---\n'
  if $split; then
cat <<YAML
# Shared by every environment. name, host and the database URL differ per
# environment and live in the <env>.yaml files next to this one — do not add
# them here, or an environment whose file forgets one inherits another's.
image: ${image}
YAML
  else
    printf 'name: %s\nimage: %s\n' "$name" "$image"
  fi
cat <<YAML
# imageTag lives in versions/ — written by CI, loaded after this file. Setting
# it here too would create a second source of truth that always loses.

# Nastavenie domény
containerPort: ${port}
YAML
  $split || host_lines "$host"

  if [[ $secrets == false ]]; then
cat <<YAML

# Bez external-secrets: nesynchronizuje sa žiadny <name>-secrets.
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
    if $split; then
      printf '  # The URL is per environment — see the <env>.yaml files.\n'
    else
      db_url_lines "$db"
    fi
    if [[ $db_style == spring ]]; then
      printf '  SPRING_DATASOURCE_DRIVER_CLASS_NAME: org.postgresql.Driver\n'
      printf '  SPRING_JPA_HIBERNATE_DIALECT: org.hibernate.dialect.PostgreSQLDialect\n'
      printf '  # Non-JVM stack? Use DATABASE_URL: postgresql://postgres:5432/<db>\n'
      printf '  # instead of SPRING_DATASOURCE_URL and delete the two lines above.\n'
    else
      printf '  # JVM stack? Use SPRING_DATASOURCE_URL: jdbc:postgresql://postgres:5432/<db>\n'
      printf '  # instead, plus SPRING_DATASOURCE_DRIVER_CLASS_NAME: org.postgresql.Driver\n'
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

render_env_values() {  # render_env_values <env>
  local e=$1 a; a=$(app_name "$1")
cat <<YAML
---
# ${name} — ${e} only. Loaded after values.yaml, so these win.

# Namespace, Secret and Ingress all derive from this. Must equal the
# Application name. (Not the Infisical folder: the ApplicationSet reads
# /${name} in Infisical environment '${e}'.)
name: ${a}

# Nastavenie domény
YAML
  host_lines "${hosts[$e]}"
  if [[ -n $db ]]; then
    printf '\nenv:\n'
    db_url_lines "$(db_for "$e")"
  fi
}

render_version() {
cat <<'YAML'
# Written by the app's build pipeline from here on — see versions/README.md.
# `change_me` is a placeholder: the first deploy replaces it with a real tag.
YAML
printf 'imageTag: change_me\n'
}

# --- write -------------------------------------------------------------------
emit() {  # emit <file> <renderer> [args]
  local f=$1; shift
  if $dry_run; then printf '\n=== %s ===\n' "$f"; "$@"; else mkdir -p "$(dirname "$f")"; "$@" > "$f"; fi
}

emit "$values_file" render_values
for e in "${envs[@]}"; do
  $split && emit "applications/${name}/${e}.yaml" render_env_values "$e"
  emit "environments/${e}/${name}.yaml" render_env_file "$e"
  emit "versions/$(app_name "$e").yaml" render_version
done
$dry_run && exit 0

printf 'Created:\n'; printf '  %s\n' "${files[@]}"; printf '\n'

# --- what the script cannot do ----------------------------------------------
step=0
next() { step=$((step+1)); printf '%d. %s\n' "$step" "$1"; }

printf 'Before this can go to main:\n'
for e in "${envs[@]}"; do
  a=$(app_name "$e")
  if [[ $secrets == true ]]; then
    next "[${e}] Create the Infisical folder /${name} in Infisical environment
   '${e}' and put the app's secrets in it. The ApplicationSet always reads
   /${name}, in the Infisical environment named after the env directory
   (an env file may override that with infisicalEnv). They arrive as env
   vars automatically — adding one later needs no commit."
  fi
  if [[ -n $db ]]; then
    next "[${e}] Create the database on the VM's Postgres, and a user with rights on it:
     createdb -h <vm> -U postgres $(db_for "$e")
   Put that user and password in Infisical /${name}, environment '${e}'."
  fi
  if [[ -n ${hosts[$e]} ]]; then
    next "[${e}] Point DNS for ${hosts[$e]} at the VM (*.matejkovac.sk is already a
   wildcard). The certificate is issued by an HTTP-01 challenge, so the record
   must resolve BEFORE the first sync."
  fi
done
next "Build and push the image to registry.matejkovac.sk/apps/${image},
   then write its tag into each versions file (\`imageTag: change_me\` now).
   From then on the pipelines write those files — see versions/README.md."
next "Render it before pushing, e.g. for ${envs[0]}:
     helm template $(app_name "${envs[0]}") ../kovostack-helm-charts/charts/app \\
       -f applications/${name}/values.yaml$($split && printf ' -f applications/%s/%s.yaml' "$name" "${envs[0]}") \\
       -f versions/$(app_name "${envs[0]}").yaml"
next "Commit, then ask before pushing to main — that push is the deploy. The
   ApplicationSet picks the new file(s) up within ~3 minutes."
