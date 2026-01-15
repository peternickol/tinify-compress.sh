#!/usr/bin/env bash
# compress-images.sh
# Recursively compress images in a directory using Tinify API via a local Python venv.
#
# Usage:
#   ./compress-images.sh --setup
#   ./compress-images.sh -d /path/to/images [-b] [-n]
#
# Notes:
# - Uses a venv at: <script_dir>/.venv-tinify (override with --venv <path>)
# - Overwrites files in-place safely (temp file then mv).
# - Supported extensions: png, jpg, jpeg, webp, avif

set -Eeuo pipefail

# -------------------------------------------------------------------
# CONFIGURATION
# -------------------------------------------------------------------
# >>>>>>>>> SET YOUR TINIFY API KEY HERE <<<<<<<<<
readonly TINIFY_API_KEY="Vgv26H0v7N5B9Y1f6cwmRyWvLv4WLknX"

readonly IMAGE_EXTENSIONS=("png" "jpg" "jpeg" "webp" "avif")

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
VENV_PY=""  # resolved after setup/checks

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
  -d <dir>       Directory to crawl recursively
  -b             Backup originals to <file>.bak before overwrite
  -n             Dry-run (no changes)
  --venv <path>  Virtualenv directory (default: $VENV_DIR)
  --setup        Install deps + create venv + install tinify (Debian/Ubuntu)
  -h             Show help

Examples:
  $SCRIPT_NAME --setup
  $SCRIPT_NAME -d ./assets -b
  $SCRIPT_NAME -d ./assets -n
  $SCRIPT_NAME --venv /opt/tinify-venv --setup

Exit codes:
  0 success
  1 general error
  2 bad arguments
  3 missing dependency
  4 runtime error
EOF
}

# -------------------------------------------------------------------
# Setup (Debian/Ubuntu) using venv to avoid PEP 668 issues
# -------------------------------------------------------------------
setup_environment() {
  log "INFO" "Running setup for Debian/Ubuntu (venv + tinify)"

  local SUDO=""
  if [[ "$(id -u)" -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die $ERR_MISSING_DEP "sudo not found (required for setup)"
    SUDO="sudo"
  fi

  $SUDO apt-get update -y
  # python3-venv ensures `python3 -m venv` works on Debian/Ubuntu
  $SUDO apt-get install -y \
    ca-certificates \
    findutils \
    coreutils \
    python3 \
    python3-venv

  # Create venv if needed
  if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    log "INFO" "Creating venv at: $VENV_DIR"
    python3 -m venv "$VENV_DIR"
  fi

  VENV_PY="$VENV_DIR/bin/python"

  # Upgrade pip inside venv and install tinify
  log "INFO" "Installing tinify into venv"
  "$VENV_PY" -m pip install --upgrade pip >/dev/null
  "$VENV_PY" -m pip install --upgrade tinify >/dev/null

  # Verify
  "$VENV_PY" -c "import tinify; print('tinify OK')" >/dev/null 2>&1 \
    || die $ERR_MISSING_DEP "Tinify install failed inside venv"

  log "INFO" "Setup completed successfully"
  exit $ERR_SUCCESS
}

check_deps() {
  command -v find   >/dev/null 2>&1 || die $ERR_MISSING_DEP "Missing dependency: find"
  command -v mktemp >/dev/null 2>&1 || die $ERR_MISSING_DEP "Missing dependency: mktemp"

  VENV_PY="$VENV_DIR/bin/python"
  [[ -x "$VENV_PY" ]] || die $ERR_MISSING_DEP "Venv python not found at $VENV_PY (run --setup)"

  "$VENV_PY" -c "import tinify" >/dev/null 2>&1 \
    || die $ERR_MISSING_DEP "Python dependency 'tinify' missing in venv (run --setup)"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d) DIR="${2:-}"; shift 2 ;;
      -b) BACKUP=true; shift ;;
      -n) DRY_RUN=true; shift ;;
      --venv) VENV_DIR="${2:-}"; shift 2 ;;
      --setup) SETUP=true; shift ;;
      -h) usage; exit $ERR_SUCCESS ;;
      *) die $ERR_BAD_ARGS "Unknown option: $1" ;;
    esac
  done

  $SETUP && setup_environment

  [[ -n "$DIR" ]] || die $ERR_BAD_ARGS "Directory (-d) is required"
  [[ -d "$DIR" ]] || die $ERR_BAD_ARGS "Not a directory: $DIR"
  [[ "$TINIFY_API_KEY" != "PUT_YOUR_API_KEY_HERE" ]] || die $ERR_BAD_ARGS "TINIFY_API_KEY is not set in script"
}

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
import sys
import tinify

src, dst, key = sys.argv[1], sys.argv[2], sys.argv[3]
tinify.key = key

# Compress
source = tinify.from_file(src)
source.to_file(dst)
PY
  then
    rm -f "$tmp"
    log "ERROR" "Compression failed: $src"
    return 1
  fi

  $BACKUP && cp -p -- "$src" "$src.bak"
  chmod --reference="$src" "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$src"

  log "INFO" "Compressed: $src"
}

main() {
  log "INFO" "Starting $SCRIPT_NAME"
  log "INFO" "Directory: $DIR"
  log "INFO" "Venv: $VENV_DIR"
  log "INFO" "Backup: $BACKUP | Dry-run: $DRY_RUN"

  check_deps

  local find_expr=()
  for ext in "${IMAGE_EXTENSIONS[@]}"; do
    find_expr+=( -iname "*.${ext}" -o )
  done
  unset 'find_expr[${#find_expr[@]}-1]'

  mapfile -d '' files < <(
    find "$DIR" -type f \( "${find_expr[@]}" \) -print0
  )

  if [[ "${#files[@]}" -eq 0 ]]; then
    log "INFO" "No images found"
    exit $ERR_SUCCESS
  fi

  log "INFO" "Found ${#files[@]} file(s)"

  local failures=0
  for f in "${files[@]}"; do
    compress_one "$f" || failures=$((failures + 1))
  done

  [[ "$failures" -eq 0 ]] || die $ERR_GENERAL "$failures file(s) failed"
  log "INFO" "Completed successfully"
}

parse_args "$@"
main

