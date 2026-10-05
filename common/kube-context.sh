#!/usr/bin/env bash
# Shared kube-context confirmation + pinning for the Solo product walkthroughs.
#
# Goals:
#   1. Show the current context + the list of available contexts before any
#      install/cleanup touches a cluster.
#   2. Default to the current context, but let the operator confirm or pick
#      another — so you never install into the wrong cluster by accident.
#   3. PIN the chosen context: every kubectl/helm call is run with an explicit
#      --context/--kube-context, so switching the default context mid-run can't
#      affect an in-flight install.
#
# How pinning works: we define shell-function wrappers for `kubectl` and `helm`
# that inject `--context ${SOLO_KUBE_CONTEXT}` (resp. --kube-context). kubectl
# and helm both honor the LAST context flag, so a script line that already
# passes an explicit --context still wins — the pin only fills in calls that would
# otherwise use the ambient/default context. `kubectl config ...` is passed
# through untouched so context discovery keeps working.
#
# Usage:
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")/common" && pwd)/kube-context.sh"
#   solo_kube_init            # prompts (unless already confirmed by a parent)
#
# install-all.sh / cleanup-all.sh call the same init ONCE, then export
# SOLO_KUBE_CONTEXT + SOLO_CONTEXT_CONFIRMED=1 (done inside init) so the
# per-step child scripts reuse the choice instead of re-prompting.
#
# Skips the prompt (uses the default) when stdin is not a TTY or DEMO_AUTO=1,
# so install-all and CI stay non-interactive past the first confirmation.

_SKC_BLUE='\033[0;34m'; _SKC_GREEN='\033[0;32m'; _SKC_RED='\033[0;31m'
_SKC_YELLOW='\033[0;33m'; _SKC_NC='\033[0m'

# True when a context exists in the kubeconfig.
_skc_context_exists() {
  command kubectl config get-contexts -o name 2>/dev/null | grep -qxF "$1"
}

# Prompt for one context. $1 = proposed default. Echoes the chosen context.
# Non-interactive (no TTY / DEMO_AUTO): echoes the default unchanged.
_skc_prompt_one() {
  local proposed="$1" ans orig
  if [ ! -t 0 ] || [ "${DEMO_AUTO:-}" = "1" ]; then
    printf '%s' "${proposed}"
    return 0
  fi
  while :; do
    printf '%bUse context (name or number) [%s]: %b' "${_SKC_BLUE}" "${proposed:-<none>}" "${_SKC_NC}" >&2
    read -r ans
    ans="${ans:-$proposed}"; orig="${ans}"
    # A bare number picks that entry from the numbered list shown above.
    case "${ans}" in
      ''|*[!0-9]*) ;;
      *) ans="$(command kubectl config get-contexts -o name 2>/dev/null | sed -n "${ans}p")" ;;
    esac
    if [ -z "${ans}" ]; then
      printf '%bNo context chosen — type a name or number from the list above.%b\n' "${_SKC_RED}" "${_SKC_NC}" >&2
      continue
    fi
    if _skc_context_exists "${ans}"; then
      printf '%s' "${ans}"
      return 0
    fi
    printf '%bContext "%s" not found in kubeconfig. Pick a name or number from the list.%b\n' \
      "${_SKC_RED}" "${orig}" "${_SKC_NC}" >&2
  done
}

# Show the available contexts + the current one.
_skc_show_contexts() {
  echo "" >&2
  printf '%b%s%b\n' "${_SKC_BLUE}" "Available kube-contexts (* = current default):" "${_SKC_NC}" >&2
  local cur n=0 name; cur="$(command kubectl config current-context 2>/dev/null || true)"
  while IFS= read -r name; do
    [ -n "${name}" ] || continue
    n=$((n + 1))
    if [ "${name}" = "${cur}" ]; then
      printf '  %2d) * %s\n' "${n}" "${name}" >&2
    else
      printf '  %2d)   %s\n' "${n}" "${name}" >&2
    fi
  done < <(command kubectl config get-contexts -o name 2>/dev/null)
  echo "" >&2
}

# Define the kubectl/helm wrappers that pin SOLO_KUBE_CONTEXT. No-op injection
# when SOLO_KUBE_CONTEXT is unset, so sourcing without init is harmless.
_skc_define_wrappers() {
  kubectl() {
    if [ -n "${SOLO_KUBE_CONTEXT:-}" ]; then
      case "${1:-}" in
        # Subcommands that must NOT get --context (kubeconfig discovery, local).
        config|version|api-resources|api-versions|completion|options|kustomize)
          command kubectl "$@" ;;
        *) command kubectl --context "${SOLO_KUBE_CONTEXT}" "$@" ;;
      esac
    else
      command kubectl "$@"
    fi
  }
  helm() {
    local sub="${1:-}"
    if [ -n "${SOLO_KUBE_CONTEXT:-}" ]; then
      case "${sub}" in
        # Cluster-affecting subcommands accept --kube-context. Inject it right
        # after the subcommand so any explicit later --kube-context still wins.
        install|upgrade|uninstall|delete|status|list|ls|history|get|rollback|test)
          shift; command helm "${sub}" --kube-context "${SOLO_KUBE_CONTEXT}" "$@" ;;
        *) command helm "$@" ;;
      esac
    else
      command helm "$@"
    fi
  }
}

# --- single-cluster init (CLUSTER_CONTEXT) -----------------------------------
# Confirms the context, sets CLUSTER_CONTEXT + SOLO_KUBE_CONTEXT, and defines
# the pinning wrappers. Reuses an already-confirmed choice from a parent
# install-all/cleanup-all without re-prompting.
solo_kube_init() {
  _skc_define_wrappers
  if [ "${SOLO_CONTEXT_CONFIRMED:-}" = "1" ] && [ -n "${SOLO_KUBE_CONTEXT:-}" ]; then
    CLUSTER_CONTEXT="${SOLO_KUBE_CONTEXT}"
    export CLUSTER_CONTEXT
    return 0
  fi
  local default="${CLUSTER_CONTEXT:-$(command kubectl config current-context 2>/dev/null)}"
  _skc_show_contexts
  local chosen; chosen="$(_skc_prompt_one "${default}")"
  CLUSTER_CONTEXT="${chosen}"
  SOLO_KUBE_CONTEXT="${chosen}"
  SOLO_CONTEXT_CONFIRMED=1
  export CLUSTER_CONTEXT SOLO_KUBE_CONTEXT SOLO_CONTEXT_CONFIRMED
  printf '%b%s%b\n' "${_SKC_GREEN}" "Using kube-context: ${chosen}" "${_SKC_NC}" >&2
}

