#!/usr/bin/env bash
# PreToolUse/Bash guard for kovostack-infra-gitops.
#
# A push to this repository's `main` IS a production deployment: ArgoCD syncs
# main continuously. So every push that lands on main must be confirmed by a
# human, every single time — no batching, no "already approved once".
#
# Pushes to any other branch pass silently. The guard resolves the push's
# remote first and exits silently for any other repository, so it is safe to
# install globally.
#
# Registered twice on purpose (see .claude/settings.json and ~/.claude/settings.json):
# the project-level copy runs with no argument, the global one with --global.
# The global copy stands down inside this project so the prompt appears once.
set -uo pipefail

GUARDED_REPO_RE='kovostack-infra-gitops(\.git)?$'
PROTECTED_RE='^(main|master)$'
THIS_REPO='/home/kovo/IdeaProjects/kovostack-infra-gitops'

# The global registration defers to the project one when we are inside the repo.
if [[ ${1:-} == --global && ${CLAUDE_PROJECT_DIR:-} == "$THIS_REPO" ]]; then
  exit 0
fi

decide() {  # decide <ask|deny> <reason>
  jq -n --arg d "$1" --arg r "$2" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: $d,
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

check_dest() {
  local dest=$1 what=$2
  case $dest in
    "") decide ask "Could not work out which branch this push lands on (detached HEAD?), so it may reach main — which ArgoCD syncs straight to production. Confirm, or push explicitly: git push origin HEAD:<branch>" ;;
    refs/tags/*) return 0 ;;
  esac
  if [[ $dest =~ $PROTECTED_RE ]]; then
    decide ask "This push lands on kovostack-infra-gitops '${dest}' (from '${what}'). main is the cluster's desired state — ArgoCD syncs it automatically, so this push deploys. Approval is required for each individual push to main."
  fi
  return 0
}

check_segment() {
  local seg=$1
  local -a t
  read -ra t <<<"$seg" || return 0
  (( ${#t[@]} >= 2 )) || return 0
  case ${t[0]} in git|*/git) ;; *) return 0 ;; esac

  # Walk the pre-subcommand options to find `push` and any `-C <dir>`.
  local i=1 dir=$PWD sub=""
  while (( i < ${#t[@]} )); do
    case ${t[i]} in
      -C)             dir=${t[i+1]:-$PWD}; (( i += 2 )) ;;
      -c|--namespace) (( i += 2 )) ;;
      -*)             (( i++ )) ;;
      *)              sub=${t[i]}; (( i++ )); break ;;
    esac
  done
  [[ $sub == push ]] || return 0

  local -a refspecs=()
  local remote="" bulk_flag="" tags_only="" a
  while (( i < ${#t[@]} )); do
    a=${t[i]}
    case $a in
      --all|--mirror)                          bulk_flag=$a ;;
      --tags)                                  tags_only=1 ;;
      --repo)                                  remote=${t[i+1]:-}; (( i++ )) ;;
      --repo=*)                                remote=${a#--repo=} ;;
      -o|--push-option|--receive-pack|--exec)  (( i++ )) ;;
      -*)                                      ;;
      *) if [[ -z $remote ]]; then remote=$a; else refspecs+=("$a"); fi ;;
    esac
    (( i++ ))
  done

  # Only guard this one repository — resolve the remote name to its URL.
  local url
  remote=${remote:-origin}
  url=$(git -C "$dir" remote get-url "$remote" 2>/dev/null) || url=$remote
  [[ $url =~ $GUARDED_REPO_RE ]] || return 0

  [[ $bulk_flag == --mirror ]] && decide deny "'--mirror' rewrites every ref on the remote, including main, and deletes refs that are missing locally. Push one branch by name instead."
  [[ -n $bulk_flag ]] && decide ask "'${bulk_flag}' pushes refs in bulk and can reach main, which ArgoCD deploys. Confirm, or push one branch by name."

  local rs dest branch
  if (( ${#refspecs[@]} == 0 )); then
    # `git push --tags` with no refspec pushes tags and no branch.
    [[ -n $tags_only ]] && return 0
    branch=$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=""
    check_dest "$branch" "current branch"
    return 0
  fi

  for rs in "${refspecs[@]}"; do
    dest=${rs##*:}
    dest=${dest#+}
    dest=${dest#refs/heads/}
    if [[ $dest == HEAD ]]; then
      dest=$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null) || dest=""
    fi
    check_dest "$dest" "$rs"
  done
}

payload=$(cat)
cmd=$(jq -r '.tool_input.command // empty' <<<"$payload" 2>/dev/null) || exit 0
[[ -n $cmd ]] || exit 0
[[ $cmd == *push* ]] || exit 0

while IFS= read -r segment; do
  segment=${segment#"${segment%%[![:space:]]*}"}
  [[ -n $segment ]] || continue
  check_segment "$segment"
done < <(printf '%s\n' "$cmd" | sed -E 's/&&|\|\||;|\|/\n/g')

exit 0
