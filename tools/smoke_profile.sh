#!/usr/bin/env bash
set -u

log_path="${OPENMW_LOG:-${XDG_CONFIG_HOME:-$HOME/.config}/openmw/openmw.log}"
launch=0

usage() {
  cat <<'EOF'
Usage: tools/smoke_profile.sh [--launch] [--log PATH]

Inspects the normal OpenMW profile log for MOM release-smoke signals.

Options:
  --launch    Run system `openmw --no-intro` first, then inspect the log after it exits.
  --log PATH  Inspect PATH instead of the default OpenMW log.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --launch)
      launch=1
      ;;
    --log)
      shift
      if [ "$#" -eq 0 ] || [ -z "$1" ]; then
        echo "ERROR: --log requires a path" >&2
        exit 2
      fi
      log_path="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

fail=0

if [ "$launch" -eq 1 ]; then
  echo "Launching normal OpenMW profile: openmw --no-intro"
  openmw --no-intro
  openmw_status=$?
  if [ "$openmw_status" -ne 0 ]; then
    echo "FAIL: openmw exited with status $openmw_status" >&2
    fail=1
  fi
fi

if [ ! -f "$log_path" ]; then
  echo "FAIL: OpenMW log not found: $log_path" >&2
  exit 1
fi

if command -v rg >/dev/null 2>&1; then
  search_quiet() { rg -q "$1" "$log_path"; }
  search_lines() { rg -n "$1" "$log_path"; }
else
  search_quiet() { grep -Eq "$1" "$log_path"; }
  search_lines() { grep -En "$1" "$log_path"; }
fi

require_log() {
  local label="$1"
  local pattern="$2"
  if search_quiet "$pattern"; then
    echo "PASS: $label"
  else
    echo "FAIL: missing $label" >&2
    fail=1
  fi
}

echo "Inspecting MOM normal-profile log: $log_path"
require_log "MOM runtime bootstrap" \
  "\\[MOM\\]\\[INFO\\]\\[bootstrap\\] MOM runtime active: manifest=.* actions=[0-9]+ owners=[0-9]+"
require_log "MOM runtime self-check" \
  "\\[MOM\\]\\[INFO\\]\\[selfcheck\\] status=running frame=[0-9]+ ledger=true manifest=true"

if search_quiet "\\[MOM\\]\\[ERROR\\]|Bootstrap failed|MOM disabled|scripts/mom.*Lua error"; then
  echo "FAIL: MOM failure entries found:" >&2
  search_lines "\\[MOM\\]\\[ERROR\\]|Bootstrap failed|MOM disabled|scripts/mom.*Lua error" >&2
  fail=1
else
  echo "PASS: no MOM failure entries"
fi

if search_quiet "\\[MOM\\]\\[WARN\\]"; then
  echo "MOM warnings found for review:"
  search_lines "\\[MOM\\]\\[WARN\\]"
else
  echo "PASS: no MOM warnings"
fi

echo "Recent MOM log lines:"
search_lines "\\[MOM\\]" | tail -n 40

exit "$fail"
