#!/usr/bin/env bash
# Read-only filesystem preflight for the split systemd deployment.
# Run as root on the actual deployment host; no keys are opened or printed.
set -euo pipefail
if [[ $# != 3 || $(id -u) != 0 ]]; then
  echo 'Usage (root): bash deploy/check-split-permissions.sh ISSUER_KEY EDGE_KEY DB_DIRECTORY' >&2
  exit 2
fi
issuer_key=$1
edge_key=$2
db_dir=$3
failures=0
check() {
  local label=$1
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'PASS %s\n' "$label"
  else
    printf 'FAIL %s\n' "$label"
    failures=$((failures+1))
  fi
}
is_regular_private() {
  [[ -f "$1" && ! -L "$1" ]] &&
    [[ $(stat -c '%a' -- "$1") = 600 ]] &&
    [[ $(stat -c '%U' -- "$1") = "$2" ]]
}
distinct_users() {
  local edge issuer
  edge=$(id -u commerce-edge) || return 1
  issuer=$(id -u commerce-issuer) || return 1
  [[ $edge != 0 && $issuer != 0 && $edge != "$issuer" ]]
}
as_user() {
  runuser -u "$1" -- test "${@:2}"
}
denied_read() {
  # Distinguish an unavailable identity / runuser error from a denied access.
  local status=0
  runuser -u "$1" -- test -r "$2" || status=$?
  [[ $status = 1 ]]
}
command -v runuser >/dev/null
check distinct-nonroot-identities distinct_users
check issuer-key-owner-mode is_regular_private "$issuer_key" commerce-issuer
check edge-key-owner-mode is_regular_private "$edge_key" commerce-edge
check issuer-can-read-own-key as_user commerce-issuer -r "$issuer_key"
check edge-can-read-own-key as_user commerce-edge -r "$edge_key"
check edge-cannot-read-issuer-key denied_read commerce-edge "$issuer_key"
check issuer-cannot-read-edge-key denied_read commerce-issuer "$edge_key"
check shared-db-directory test -d "$db_dir"
for role in commerce-edge commerce-issuer; do
  check "$role-db-readable" as_user "$role" -r "$db_dir"
  check "$role-db-searchable" as_user "$role" -x "$db_dir"
  check "$role-db-writable" as_user "$role" -w "$db_dir"
done
if (( failures > 0 )); then
  echo 'NO-GO: filesystem permission preflight failed'
  exit 1
fi
echo 'PASS filesystem preflight only; shared SQLite remains writable by both roles.'
echo 'NOT a production approval: inspect service sandbox, evidence verification, sockets and recovery separately.'
