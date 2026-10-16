#!/bin/bash
# Who is listening on a local TCP port? Sourced, not executed.
#
# Two things can both want a localhost port: the Kubernetes demos reach their UI and gateway
# through `kubectl port-forward` (4000, 8080, ...), and a Docker container may publish the
# same port (8080, say). On macOS a port-forward binds
# 127.0.0.1 and [::1], and Docker publishes on *, and the OS lets a specific bind sit next to
# a wildcard one WITHOUT an error. Nothing fails at start; a browser or curl then reaches
# whichever listener it resolves first, so a demo can quietly talk to the wrong service.
# A "is something answering on this port?" probe cannot tell the difference. This asks the OS
# which PROCESS holds the port.
#
# Needs lsof (present on macOS and most Linux). Without it every function reports "nobody",
# so a missing lsof never blocks a demo; it just skips the check.
#
# Functions:
#   port_listeners <port>                     one "COMMAND PID" line per process listening on the port
#   port_foreign_listeners <port> <regex>     the listeners whose command does NOT match <regex>
#   port_holder_hint <command>                one line of advice for a known holder (docker, kubectl)
#   port_forward_conflict <port>              for a demo about to use a kubectl/ssh port-forward on
#                                             <port>: prints why and returns 1 if any OTHER process
#                                             holds it, else returns 0

# Every listener on the port, any address, as "COMMAND PID" lines. lsof truncates command
# names, so match on a prefix (Docker Desktop shows as "com.docke").
port_listeners() {
  command -v lsof >/dev/null 2>&1 || return 0
  # lsof exits 1 when NOTHING listens. That is an answer, not a failure: the callers run under
  # `set -e -o pipefail`, where a non-zero status here would abort the whole script silently.
  { lsof -nP -iTCP:"$1" -sTCP:LISTEN -Fpc 2>/dev/null || true; } \
    | awk '/^p/ {pid = substr($0, 2)} /^c/ {print substr($0, 2) " " pid}' \
    | sort -u
}

# Listeners that are not one of the expected commands (an extended regex over the command name).
port_foreign_listeners() {
  port_listeners "$1" | awk -v re="$2" '$1 !~ re'
}

# Advice for the holders we know about. $1 is a command name from port_listeners.
port_holder_hint() {
  case "$1" in
    com.docke*|docker*|vpnkit*|OrbStack*|colima*|lima*)
      echo "a Docker container is publishing this port (another demo or dev stack?). Find it with: docker ps --format '{{.Names}} {{.Ports}}'" ;;
    kubectl*)
      echo "a kubectl port-forward (the Kubernetes demos). Stop it with Ctrl-C in the demo that started it, or: pkill -f 'kubectl.* port-forward'" ;;
    *)
      echo "something else; find it with: lsof -nP -iTCP:<port> -sTCP:LISTEN" ;;
  esac
}

# A demo that reaches a service through `kubectl port-forward` on <port> needs that port to be
# held by kubectl (or an ssh tunnel) and nothing else. Anything else listening next to it, such
# as a Docker container, can silently take the connections .
port_forward_conflict() {
  local port="$1" foreign first
  foreign="$(port_foreign_listeners "${port}" '^(kubectl|ssh)$')"
  [ -z "${foreign}" ] && return 0
  first="$(echo "${foreign}" | head -1 | awk '{print $1}')"
  {
    echo "ERROR: localhost:${port} is already held by $(echo "${foreign}" | awk '{printf "%s (pid %s)  ", $1, $2}')"
    echo "       $(port_holder_hint "${first}")"
    echo "       This demo's port-forward would be shadowed, and requests could reach the wrong service."
  } >&2
  return 1
}
