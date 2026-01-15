#!/usr/bin/env bash
# tinify-compress.sh
# Recursively compress images using Tinify API via a local Python venv.
#
# Per-directory change tracking:
#   - Creates .tinify-compress.log in each directory containing images processed
#   - Stores: sha256<TAB>relative_path (relative to that directory)
#   - Skips recompression if hash matches
#   - Prunes deleted files from the log automatically
#
# Flags:
#   --no-log            Disable log read/write; recompress everything
#   --rebuild-log       Recompress everything and rewrite logs from scratch
#   --rebuild-log-only  Recompute hashes and rewrite logs from scratch WITHOUT compressing

set -Eeuo pipefail

# -------------------------------------------------------------------
# CONFIGURATION
# -------------------------------------------------------------------
readonly TINIFY_API_KEY="PUT_YOUR_API_KEY_HERE"
readonly IMAGE_EXTENSIONS=("png" "jpg" "jpeg" "webp" "avif")
readonly LOG_FILENAME=".tinify-compress.log"

# -------------------------------------------------------------------
# Exit codes
# -------------------------------------------------------------------
readonly ERR_SUCCESS=0
readonly ERR_GENERAL=1
readonly ERR_BAD_ARGS=2
readonly ERR_MISSING_DEP=3
readonly ERR_RUNTIME=4

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# -------------------------------------------------------------------
# Defaults / inputs
# -------------------------------------------------------------------
DIR=""
BACKUP=false
DRY_RUN=false
SETUP=false
VENV_DIR="$SCRIPT_DIR/.venv-tinify"
VENV_PY=""

# Logging behavior flags
USE_CHANGE_LOG=true
REBUILD_LOG=false
REBUILD_LOG_ONLY=false

# -------------------------------------------------------------------
# Logging
# -------------------------------------------------------------------
log() { printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2"; }
die() { local code="$1"; shift; log "ERROR" "$*"; exit "$code"; }
trap 'die '"$ERR_RUNTIME"' "Unexpected error on line $LINENO"' ERR

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Options:
  -d <dir>             Directory to crawl recursively
  -b                   Backup originals to <file>.bak before overwrite
  -n                   Dry-run (no changes)
  --venv <path>        Virtualenv directory (default: $VENV_DIR)
  --setup              Install deps + create venv + install tinify (Debian/Ubuntu)

Change tracking (per-directory $LOG_FILENAME):
  --no-log             Disable log read/write; recompress everything
  --rebuild-log        Ignore existing logs and rewrite logs from scratch (no skipping)
  --rebuild-log-only   Recompute hashes and rewrite logs from scratch WITHOUT compressing
                       (implies logging enabled)

  -h                   Show help

Examples:
  $SCRIPT_NAME --setup
  $SCRIPT_NAME -d ./assets
  $SCRIPT_NAME -d ./assets --no-log
  $SCRIPT_NAME -d ./assets --rebuild-log
  $SCRIPT_NAME -d ./assets --rebuild-log-only
EOF
}

# -------------------------------------------------------------------
# Setup (Debian/Ubuntu) — uses venv to avoid PEP 668
# -------------------------------------------------------------------
setup_environment() {
  log "INFO" "Running setup for Debian/Ubuntu (venv + tinify)"

  local SUDO=""
  if [[ "$(id -u)" -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die $ERR_MISSING_DEP "sudo not found (required for setup)"
    SUDO="sudo"
  fi

  $SUDO apt-get update -y
  $SUDO apt-get install -y \
    ca-certificates \
    findutils \
    coreutils \
    python3 \
    python3-venv

  if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    log "INFO" "Creating venv at: $VENV_DIR"
    python3 -m venv "$VENV_DIR"
  fi

  VENV_PY="$VENV_DIR/bin/python"

  log "INFO" "Installing tinify into venv"
  "$VENV_PY" -m pip install --upgrade pip >/dev/null
  "$VENV_PY" -m pip install --upgrade tinify >/dev/null

  "$VENV_PY" -c "import tinify" >/dev/null 2>&1 \
    || die $ERR_MISSING_DEP "Tinify install failed inside venv"

  log "INFO" "Setup completed successfully"
  exit $ERR_SUCCESS
}

# -------------------------------------------------------------------
# Dependency checks
# -------------------------------------------------------------------
check_deps() {
  command -v find >/dev/null 2>&1 || die $ERR_MISSING_DEP "Missing dependency: find"
  command -v mktemp >/dev/null 2>&1 || die $ERR_MISSING_DEP "Missing dependency: mktemp"
  command -v sort >/dev/null 2>&1 || die $ERR_MISSING_DEP "Missing dependency: sort"
  command -v awk >/dev/null 2>&1 || die $ERR_MISSING_DEP "Missing dependency: awk"

  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    die $ERR_MISSING_DEP "Missing dependency: sha256sum (or shasum)"
  fi

  # Only require Python/Tinify when we might compress
  if ! $REBUILD_LOG_ONLY; then
    VENV_PY="$VENV_DIR/bin/python"
    [[ -x "$VENV_PY" ]] || die $ERR_MISSING_DEP "Venv python not found at $VENV_PY (run --setup)"
    "$VENV_PY" -c "import tinify" >/dev/null 2>&1 \
      || die $ERR_MISSING_DEP "Python dependency 'tinify' missing in venv (run --setup)"
  fi
}

# -------------------------------------------------------------------
# Helpers: hashing and log IO
# -------------------------------------------------------------------
sha256_file() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$f" | awk '{print $1}'
  else
    shasum -a 256 -- "$f" | awk '{print $1}'
  fi
}

# List image files in a directory (non-recursive), returned as relative file names.
list_images_in_dir() {
  local dir="$1"
  local expr=()

  for ext in "${IMAGE_EXTENSIONS[@]}"; do
    expr+=( -iname "*.${ext}" -o )
  done
  unset 'expr[${#expr[@]}-1]'

  # Print filenames relative to dir (no leading ./), one per line
  find "$dir" -maxdepth 1 -type f ! -name '*.bak' \( "${expr[@]}" \) -printf '%f\n'
}

# LOG_MAP["relpath"]=hash (per current directory)
load_dir_log() {
  local dir="$1"
  local logfile="$dir/$LOG_FILENAME"

  declare -gA LOG_MAP=()

  $USE_CHANGE_LOG || return 0
  $REBUILD_LOG && return 0
  $REBUILD_LOG_ONLY && return 0

  [[ -f "$logfile" ]] || return 0

  # Format: <hash><TAB><relpath>
  while IFS=$'\t' read -r hash relpath; do
    [[ -n "${hash:-}" && -n "${relpath:-}" ]] || continue
    LOG_MAP["$relpath"]="$hash"
  done < "$logfile"
}

# Remove log entries that point to files that no longer exist in this directory.
prune_dir_log_entries() {
  local dir="$1"
  $USE_CHANGE_LOG || return 0

  declare -A present=()

  while IFS= read -r fname; do
    [[ -n "$fname" ]] && present["$fname"]=1
  done < <(list_images_in_dir "$dir")

  local relpath
  for relpath in "${!LOG_MAP[@]}"; do
    # If the file isn't present anymore, prune it from the log map
    if [[ -z "${present[$relpath]:-}" ]]; then
      unset 'LOG_MAP[$relpath]'
    fi
  done
}

write_dir_log() {
  local dir="$1"
  local logfile="$dir/$LOG_FILENAME"

  $USE_CHANGE_LOG || return 0

  # Prune deleted files before writing
  prune_dir_log_entries "$dir"

  if $DRY_RUN; then
    log "INFO" "DRY-RUN: would write log $logfile"
    return 0
  fi

  local tmp
  tmp="$(mktemp -t tinifylog.XXXXXX)"

  for relpath in "${!LOG_MAP[@]}"; do
    printf '%s\t%s\n' "${LOG_MAP[$relpath]}" "$relpath"
  done | sort -k2,2 > "$tmp"

  mv -f -- "$tmp" "$logfile"
}

needs_processing() {
  local base="$1"
  local file="$2"
  local rel="${file#"$base"/}"

  # If rebuild-log-only: never compress.
  $REBUILD_LOG_ONLY && { echo "skip"; return 0; }

  # If logging disabled: always process.
  $USE_CHANGE_LOG || { echo "process"; return 0; }

  # If rebuild requested: always process.
  $REBUILD_LOG && { echo "process"; return 0; }

  local current logged
  current="$(sha256_file "$file")"
  logged="${LOG_MAP[$rel]:-}"

  if [[ -n "$logged" && "$logged" == "$current" ]]; then
    echo "skip"
  else
    echo "process"
  fi
}

update_log_entry() {
  local base="$1"
  local file="$2"
  local rel="${file#"$base"/}"
  $USE_CHANGE_LOG || return 0
  LOG_MAP["$rel"]="$(sha256_file "$file")"
}

set_log_entry_from_current_hash() {
  local base="$1"
  local file="$2"
  local rel="${file#"$base"/}"
  LOG_MAP["$rel"]="$(sha256_file "$file")"
}

# -------------------------------------------------------------------
# Argument parsing
# -------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d) DIR="${2:-}"; shift 2 ;;
      -b) BACKUP=true; shift ;;
      -n) DRY_RUN=true; shift ;;
      --venv) VENV_DIR="${2:-}"; shift 2 ;;
      --setup) SETUP=true; shift ;;
      --no-log) USE_CHANGE_LOG=false; shift ;;
      --rebuild-log) REBUILD_LOG=true; shift ;;
      --rebuild-log-only) REBUILD_LOG_ONLY=true; USE_CHANGE_LOG=true; shift ;;
      -h) usage; exit $ERR_SUCCESS ;;
      *) die $ERR_BAD_ARGS "Unknown option: $1" ;;
    esac
  done

  # Normalize incompatible combinations
  if $REBUILD_LOG_ONLY; then
    REBUILD_LOG=false
    BACKUP=false
  fi
  if ! $USE_CHANGE_LOG; then
    REBUILD_LOG=false
    REBUILD_LOG_ONLY=false
  fi

  $SETUP && setup_environment

  [[ -n "$DIR" ]] || die $ERR_BAD_ARGS "Directory (-d) is required"
  [[ -d "$DIR" ]] || die $ERR_BAD_ARGS "Not a directory: $DIR"
  [[ "$TINIFY_API_KEY" != "PUT_YOUR_API_KEY_HERE" ]] || die $ERR_BAD_ARGS "TINIFY_API_KEY is not set in script"
}

# -------------------------------------------------------------------
# Compress one file safely (in-place)
# -------------------------------------------------------------------
compress_one() {
  local src="$1"
  local tmp
  tmp="$(mktemp -t tinify.XXXXXX)"

  if $DRY_RUN; then
    log "INFO" "DRY-RUN: compress $src"
    rm -f "$tmp"
    return 0
  fi

  if ! "$VENV_PY" - "$src" "$tmp" "$TINIFY_API_KEY" <<'PY'
import sys, tinify
src, dst, key = sys.argv[1], sys.argv[2], sys.argv[3]
tinify.key = key
tinify.from_file(src).to_file(dst)
PY
  then
    rm -f "$tmp"
    return 1
  fi

  $BACKUP && cp -p -- "$src" "$src.bak"
  chmod --reference="$src" "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$src"
  return 0
}

# -------------------------------------------------------------------
# Main
# -------------------------------------------------------------------
main() {
  log "INFO" "Starting $SCRIPT_NAME"
  log "INFO" "Root directory: $DIR"
  log "INFO" "Venv: $VENV_DIR"
  log "INFO" "Backup: $BACKUP | Dry-run: $DRY_RUN"
  log "INFO" "Log enabled: $USE_CHANGE_LOG | Rebuild log: $REBUILD_LOG | Rebuild log only: $REBUILD_LOG_ONLY"
  $USE_CHANGE_LOG && log "INFO" "Per-directory log: $LOG_FILENAME"

  check_deps

  # Find matching files (recursive); ignore *.bak
  local find_expr=()
  for ext in "${IMAGE_EXTENSIONS[@]}"; do
    find_expr+=( -iname "*.${ext}" -o )
  done
  unset 'find_expr[${#find_expr[@]}-1]'

  mapfile -d '' files < <(
    find "$DIR" -type f \
      ! -name '*.bak' \
      \( "${find_expr[@]}" \) \
      -print0
  )

  if [[ "${#files[@]}" -eq 0 ]]; then
    log "INFO" "No images found"
    exit $ERR_SUCCESS
  fi

  log "INFO" "Found ${#files[@]} file(s)"

  local failures=0 processed=0 skipped=0 logged_only=0

  # Sort files by directory for stable per-dir log handling
  IFS=$'\n' read -r -d '' -a files_sorted < <(
    printf '%s\0' "${files[@]}" | xargs -0 -n1 printf '%s\n' | sort && printf '\0'
  )

  local current_dir=""

  for f in "${files_sorted[@]}"; do
    local base_dir
    base_dir="$(dirname "$f")"

    if [[ "$base_dir" != "$current_dir" ]]; then
      if [[ -n "$current_dir" ]]; then
        write_dir_log "$current_dir"
      fi
      current_dir="$base_dir"
      load_dir_log "$current_dir"

      # If rebuilding logs (either mode), start clean for this directory
      if $USE_CHANGE_LOG && ( $REBUILD_LOG || $REBUILD_LOG_ONLY ); then
        declare -gA LOG_MAP=()
      fi
    fi

    if $REBUILD_LOG_ONLY; then
      if $DRY_RUN; then
        log "INFO" "DRY-RUN: would hash+log: $f"
      else
        set_log_entry_from_current_hash "$current_dir" "$f"
        log "INFO" "Logged: $f"
      fi
      logged_only=$((logged_only + 1))
      continue
    fi

    case "$(needs_processing "$current_dir" "$f")" in
      skip)
        log "INFO" "Skip (unchanged): $f"
        skipped=$((skipped + 1))
        ;;
      process)
        if $DRY_RUN; then
          log "INFO" "Would compress: $f"
          processed=$((processed + 1))
        else
          if compress_one "$f"; then
            update_log_entry "$current_dir" "$f"
            log "INFO" "Compressed: $f"
            processed=$((processed + 1))
          else
            log "ERROR" "Compression failed: $f"
            failures=$((failures + 1))
          fi
        fi
        ;;
    esac
  done

  if [[ -n "$current_dir" ]]; then
    write_dir_log "$current_dir"
  fi

  if $REBUILD_LOG_ONLY; then
    log "INFO" "Summary: logged=$logged_only failures=$failures"
  else
    log "INFO" "Summary: processed=$processed skipped=$skipped failures=$failures"
  fi

  [[ "$failures" -eq 0 ]] || die $ERR_GENERAL "$failures file(s) failed"
  exit $ERR_SUCCESS
}

parse_args "$@"
main

