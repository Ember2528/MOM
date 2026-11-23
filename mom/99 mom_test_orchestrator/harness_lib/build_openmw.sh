#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PACKAGE_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(cd -- "$PACKAGE_ROOT/.." && pwd)

OPENMW_SOURCE_URL=${MOM_HARNESS_OPENMW_SOURCE_URL:-https://gitlab.com/OursCodeur/openmw.git}
OPENMW_SOURCE_REF=${MOM_HARNESS_OPENMW_SOURCE_REF:-clockwork-alpha}
if [[ -n ${MOM_HARNESS_OPENMW_SOURCE_DIR+x} ]]; then
  OPENMW_SOURCE_DIR=$MOM_HARNESS_OPENMW_SOURCE_DIR
  OPENMW_SOURCE_DIR_EXPLICIT=1
else
  OPENMW_SOURCE_DIR=
  OPENMW_SOURCE_DIR_EXPLICIT=0
fi
OPENMW_PATCH_DIR=${MOM_HARNESS_OPENMW_PATCH_DIR:-$SCRIPT_DIR/openmw_patches}
OPENMW_BUILD_ROOT=${MOM_HARNESS_OPENMW_BUILD_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/mom-openmw-harness/openmw}
OPENMW_BUILD_TYPE=${MOM_HARNESS_OPENMW_BUILD_TYPE:-RelWithDebInfo}
OPENMW_BUILD_JOBS=${MOM_HARNESS_OPENMW_BUILD_JOBS:-}
DRY_RUN=0
RESULT_FILE=

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

source "$SCRIPT_DIR/harness_lib/openmw_environment.sh"

while (($# > 0)); do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --result-file)
      shift
      [[ $# -gt 0 ]] || die "--result-file needs a path"
      RESULT_FILE=$1
      ;;
    *)
      die "unknown build option: $1"
      ;;
  esac
  shift
done

if [[ -n $RESULT_FILE ]]; then
  [[ $RESULT_FILE == /* ]] || die "result path must be absolute: $RESULT_FILE"
fi
if [[ $DRY_RUN -eq 1 ]]; then
  validate_openmw_build_root
  printf 'OpenMW build plan: cache=%s source=%s ref=%s type=%s\n' \
    "$OPENMW_BUILD_ROOT" "${OPENMW_SOURCE_DIR:-$OPENMW_SOURCE_URL}" \
    "$OPENMW_SOURCE_REF" "$OPENMW_BUILD_TYPE"
  exit 0
fi
[[ -n $RESULT_FILE ]] || die "--result-file is required"
ensure_patched_openmw_binary
mkdir -p -- "$(dirname -- "$RESULT_FILE")"
printf '%s\n' "$OPENMW_BUILT_BIN" > "$RESULT_FILE"
