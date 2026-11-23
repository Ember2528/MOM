# Harness-owned OpenMW source and build cache.

require_path() {
  local path=$1 description=$2
  [[ -e $path ]] || die "$description missing: $path"
}

collect_openmw_patches() {
  local patch_dir=$OPENMW_PATCH_DIR
  if [[ $patch_dir == "$SCRIPT_DIR/openmw_patches" && -d $OPENMW_SOURCE_DIR/components/luau ]]; then
    patch_dir=$patch_dir/luau
  fi
  [[ -d $patch_dir ]] || die "OpenMW patch directory missing: $patch_dir"
  OPENMW_PATCH_FILES=()
  shopt -s nullglob
  OPENMW_PATCH_FILES=("$patch_dir"/*.patch)
  shopt -u nullglob
}

validate_openmw_build_root() {
  local protected source
  [[ $OPENMW_BUILD_ROOT == /* ]] || die "OpenMW build root must be absolute: $OPENMW_BUILD_ROOT"
  OPENMW_BUILD_ROOT=$(realpath -m -- "$OPENMW_BUILD_ROOT")
  for protected in / /tmp /var/tmp "$HOME" "$REPO_ROOT" "$SCRIPT_DIR"; do
    protected=$(realpath -m -- "$protected")
    if [[ $OPENMW_BUILD_ROOT == "$protected" || $protected == "$OPENMW_BUILD_ROOT/"* ]]; then
      die "refusing unsafe OpenMW build root: $OPENMW_BUILD_ROOT"
    fi
  done
  if [[ $OPENMW_BUILD_ROOT == "$(realpath -m -- "$REPO_ROOT")/"* ]]; then
    die "OpenMW build cache must be outside the mod repository: $OPENMW_BUILD_ROOT"
  fi
  if [[ ${OPENMW_SOURCE_DIR_EXPLICIT:-0} -eq 1 ]]; then
    source=$(realpath -m -- "$OPENMW_SOURCE_DIR")
    if [[ $OPENMW_BUILD_ROOT == "$source" || $source == "$OPENMW_BUILD_ROOT/"* \
        || $OPENMW_BUILD_ROOT == "$source/"* ]]; then
      die "OpenMW build cache must not overlap explicit source dir: $source"
    fi
  fi
  if [[ -e $OPENMW_BUILD_ROOT ]]; then
    [[ -d $OPENMW_BUILD_ROOT && -f $OPENMW_BUILD_ROOT/.mom_openmw_build_root \
        && ! -L $OPENMW_BUILD_ROOT/.mom_openmw_build_root ]] \
      || die "OpenMW build root exists without harness marker, refusing to use: $OPENMW_BUILD_ROOT"
  fi
}

prepare_openmw_build_root() {
  local initial parent
  validate_openmw_build_root
  if [[ ! -e $OPENMW_BUILD_ROOT ]]; then
    # Publish the marker together with the directory. Concurrent first builders
    # never observe a newly created but still unmarked root.
    parent=$(dirname -- "$OPENMW_BUILD_ROOT")
    mkdir -p -- "$parent"
    initial=$(mktemp -d -- "$parent/.mom-openmw-init.XXXXXX")
    : > "$initial/.mom_openmw_build_root"
    if ! mv -T --no-clobber -- "$initial" "$OPENMW_BUILD_ROOT"; then
      rm -f -- "$initial/.mom_openmw_build_root"
      rmdir -- "$initial"
      die "cannot initialize OpenMW build cache: $OPENMW_BUILD_ROOT"
    fi
    if [[ -d $initial ]]; then
      rm -- "$initial/.mom_openmw_build_root"
      rmdir -- "$initial"
    fi
  fi
  validate_openmw_build_root
}

require_owned_openmw_path() {
  local path=$1 resolved
  [[ -f $OPENMW_BUILD_ROOT/.mom_openmw_build_root \
      && ! -L $OPENMW_BUILD_ROOT/.mom_openmw_build_root ]] \
    || die "OpenMW cache marker missing: $OPENMW_BUILD_ROOT"
  resolved=$(realpath -m -- "$path")
  [[ $resolved == "$OPENMW_BUILD_ROOT/"* && $resolved == "$path" && ! -L $path ]] \
    || die "refusing path outside owned OpenMW cache: $path"
}

lock_openmw_build_root() {
  prepare_openmw_build_root
  if [[ ${OPENMW_CACHE_LOCK_ROOT:-} == "$OPENMW_BUILD_ROOT" ]]; then return 0; fi
  command -v flock >/dev/null 2>&1 || die "flock missing; cannot lock OpenMW build cache"
  local lock=$OPENMW_BUILD_ROOT/.mom_openmw_build.lock
  require_owned_openmw_path "$lock"
  exec {OPENMW_CACHE_LOCK_FD}>"$lock"
  flock --exclusive "$OPENMW_CACHE_LOCK_FD"
  OPENMW_CACHE_LOCK_ROOT=$OPENMW_BUILD_ROOT
}

openmw_build_jobs() {
  if [[ -n $OPENMW_BUILD_JOBS ]]; then
    [[ $OPENMW_BUILD_JOBS =~ ^[1-9][0-9]*$ ]] || die "OpenMW build jobs must be positive"
    printf '%s' "$OPENMW_BUILD_JOBS"
    return 0
  fi
  local jobs=1
  if command -v nproc >/dev/null 2>&1; then jobs=$(nproc); fi
  if ((jobs > 8)); then jobs=8; fi
  printf '%s' "$jobs"
}

configure_openmw_options() {
  OPENMW_CMAKE_OPTIONS=(
    "-DCMAKE_BUILD_TYPE=$OPENMW_BUILD_TYPE"
    -DOPENMW_LOCAL_INSTALL=ON
    -DOPENMW_USE_SYSTEM_RECASTNAVIGATION=ON
    -DUSE_SYSTEM_TINYXML=OFF
    -DBUILD_OPENMW=ON
    -DBUILD_LAUNCHER=OFF
    -DBUILD_WIZARD=OFF
    -DBUILD_MWINIIMPORTER=OFF
    -DBUILD_OPENCS=OFF
    -DBUILD_ESSIMPORTER=OFF
    -DBUILD_BSATOOL=OFF
    -DBUILD_ESMTOOL=OFF
    -DBUILD_NIFTEST=OFF
    -DBUILD_NAVMESHTOOL=OFF
    -DBUILD_BULLETOBJECTTOOL=OFF
    -DBUILD_COMPONENTS_TESTS=OFF
    -DBUILD_OPENMW_TESTS=OFF
    -DBUILD_OPENCS_TESTS=OFF
  )
}

compute_openmw_build_identity() {
  local source_head=$1 patch option helper mode=managed
  shift
  helper=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../host" && pwd)/build_identity.py
  if [[ ${OPENMW_SOURCE_DIR_EXPLICIT:-0} -eq 1 ]]; then mode=explicit; fi
  configure_openmw_options
  local arguments=(
    --source-commit "$source_head"
    --source-url "${OPENMW_RESOLVED_SOURCE_URL:-${OPENMW_SOURCE_URL:-}}"
    --source-ref "${OPENMW_RESOLVED_SOURCE_REF:-${OPENMW_SOURCE_REF:-HEAD}}"
    --source-mode "$mode"
    --build-type "$OPENMW_BUILD_TYPE"
  )
  for patch in "$@"; do arguments+=(--patch "$patch"); done
  for option in "${OPENMW_CMAKE_OPTIONS[@]}"; do arguments+=("--cmake-option=$option"); done
  "${PYTHON:-python3}" "$helper" "${arguments[@]}"
}

compute_openmw_build_key() {
  compute_openmw_build_identity "$@" | sha256sum
}

remove_openmw_cache_path() {
  local path=$1
  require_owned_openmw_path "$path"
  rm -rf -- "$path"
}

remove_openmw_cached_worktree() {
  local source_dir=$1
  require_owned_openmw_path "$source_dir"
  [[ -e $source_dir ]] || return 0
  git -C "$OPENMW_SOURCE_DIR" worktree remove --force "$source_dir" >/dev/null 2>&1 \
    || remove_openmw_cache_path "$source_dir"
}

ensure_openmw_source_checkout() {
  local current_head pinned_head
  lock_openmw_build_root
  if [[ $OPENMW_SOURCE_DIR_EXPLICIT -eq 1 ]]; then
    OPENMW_SOURCE_DIR=$(realpath -e -- "$OPENMW_SOURCE_DIR")
    require_path "$OPENMW_SOURCE_DIR/.git" "OpenMW source git directory"
    OPENMW_RESOLVED_SOURCE_URL=$(git -C "$OPENMW_SOURCE_DIR" remote get-url origin 2>/dev/null || true)
    OPENMW_RESOLVED_SOURCE_REF=HEAD
    return 0
  fi

  OPENMW_SOURCE_DIR=$OPENMW_BUILD_ROOT/source-cache/openmw
  require_owned_openmw_path "$OPENMW_SOURCE_DIR"
  command -v git >/dev/null 2>&1 || die "git missing; cannot prepare patched OpenMW"
  if [[ ! -d $OPENMW_SOURCE_DIR/.git ]]; then
    remove_openmw_cache_path "$OPENMW_SOURCE_DIR"
    mkdir -p -- "$(dirname -- "$OPENMW_SOURCE_DIR")"
    git clone "$OPENMW_SOURCE_URL" "$OPENMW_SOURCE_DIR"
  fi
  require_owned_openmw_path "$OPENMW_SOURCE_DIR/.git"
  OPENMW_RESOLVED_SOURCE_URL=$OPENMW_SOURCE_URL
  OPENMW_RESOLVED_SOURCE_REF=$OPENMW_SOURCE_REF
  git -C "$OPENMW_SOURCE_DIR" remote set-url origin "$OPENMW_SOURCE_URL"

  if [[ $OPENMW_SOURCE_REF =~ ^[0-9a-fA-F]{40}$ ]] \
      && git -C "$OPENMW_SOURCE_DIR" cat-file -e "$OPENMW_SOURCE_REF^{commit}" 2>/dev/null; then
    current_head=$(git -C "$OPENMW_SOURCE_DIR" rev-parse HEAD)
    pinned_head=$(git -C "$OPENMW_SOURCE_DIR" rev-parse "$OPENMW_SOURCE_REF^{commit}")
    if [[ $current_head != "$pinned_head" ]]; then
      git -C "$OPENMW_SOURCE_DIR" checkout --detach --force "$pinned_head"
    fi
    return 0
  fi

  git -C "$OPENMW_SOURCE_DIR" fetch --no-tags origin "$OPENMW_SOURCE_REF"
  git -C "$OPENMW_SOURCE_DIR" checkout --detach --force FETCH_HEAD
}

ensure_patched_openmw_binary() {
  local source_head identity key key_short source_dir build_dir stamp_file identity_file jobs patch staged helper
  local staged_patches=()
  ensure_openmw_source_checkout
  require_path "$OPENMW_PATCH_DIR" "OpenMW patch directory"
  command -v git >/dev/null 2>&1 || die "git missing; cannot prepare patched OpenMW"
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum missing; cannot prepare patched OpenMW"
  collect_openmw_patches
  source_head=$(git -C "$OPENMW_SOURCE_DIR" rev-parse --verify 'HEAD^{commit}')
  identity=$(compute_openmw_build_identity "$source_head" "${OPENMW_PATCH_FILES[@]}")
  key=$(printf '%s\n' "$identity" | sha256sum)
  key=${key%% *}
  key_short=${key:0:16}
  source_dir=$OPENMW_BUILD_ROOT/source-$key_short
  build_dir=$OPENMW_BUILD_ROOT/build-$key_short
  stamp_file=$build_dir/.mom_openmw_patch_key
  identity_file=$build_dir/mom-build-identity.json
  helper=$SCRIPT_DIR/host/build_identity.py
  OPENMW_BUILT_BIN=$build_dir/openmw
  require_owned_openmw_path "$source_dir"
  require_owned_openmw_path "$build_dir"

  if [[ -x $OPENMW_BUILT_BIN && -f $build_dir/openmw.cfg \
      && -f $build_dir/defaults.bin && -d $build_dir/resources/vfs-mw \
      && -f $stamp_file && $(<"$stamp_file") == "$key" \
      && -f $identity_file ]] \
      && printf '%s\n' "$identity" | "${PYTHON:-python3}" "$helper" --verify-binary "$OPENMW_BUILT_BIN"; then
    printf 'Using cached patched OpenMW: %s\n' "$OPENMW_BUILT_BIN"
    return 0
  fi

  command -v cmake >/dev/null 2>&1 || die "cmake missing; cannot build patched OpenMW"
  jobs=$(openmw_build_jobs)
  printf 'Building patched OpenMW (%s) in %s\n' "$OPENMW_BUILD_TYPE" "$build_dir"
  remove_openmw_cache_path "$build_dir"
  remove_openmw_cached_worktree "$source_dir"
  git -C "$OPENMW_SOURCE_DIR" worktree add --detach "$source_dir" "$source_head"
  # Apply the bytes whose hashes formed the key, even if an editor changes the
  # original patch files while CMake is running.
  mkdir -- "$source_dir/.mom-harness-patches"
  for patch in "${OPENMW_PATCH_FILES[@]}"; do
    staged=$source_dir/.mom-harness-patches/$(basename -- "$patch")
    cp -- "$patch" "$staged"
    staged_patches+=("$staged")
  done
  [[ $(compute_openmw_build_identity "$source_head" "${staged_patches[@]}") == "$identity" ]] \
    || die "OpenMW build inputs changed while preparing the build"
  for patch in "${staged_patches[@]}"; do
    git -C "$source_dir" apply --check "$patch"
    git -C "$source_dir" apply "$patch"
  done

  configure_openmw_options
  cmake -S "$source_dir" -B "$build_dir" "${OPENMW_CMAKE_OPTIONS[@]}"
  cmake --build "$build_dir" --target openmw --parallel "$jobs"
  [[ -x $OPENMW_BUILT_BIN ]] || die "patched OpenMW binary missing after build: $OPENMW_BUILT_BIN"
  require_path "$build_dir/openmw.cfg" "built OpenMW base config"
  require_path "$build_dir/defaults.bin" "built OpenMW settings defaults"
  require_path "$build_dir/resources/vfs-mw" "built OpenMW resources"
  printf '%s\n' "$identity" \
    | "${PYTHON:-python3}" "$helper" --bind-binary "$OPENMW_BUILT_BIN" > "$identity_file.tmp"
  mv -- "$identity_file.tmp" "$identity_file"
  printf '%s\n' "$key" > "$stamp_file"
}
