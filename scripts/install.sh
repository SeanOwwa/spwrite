#!/usr/bin/env bash
#
# Spwrite installer for macOS, Linux, and Web.
#
# What it does:
#   1. Verifies the Flutter SDK is installed (and prints how to get it if not).
#   2. Enables the target platform in Flutter.
#   3. Installs all build/runtime dependencies (`flutter pub get`, plus the
#      SQLite WASM assets for web).
#   4. Builds and launches the app -- either immediately in the foreground
#      (terminal) or detached in the background.
#
# Usage:
#   ./scripts/install.sh [PLATFORM] [MODE]
#
#   PLATFORM : macos | linux | web        (default: web)
#   MODE     : now | background           (default: now)
#
# Examples:
#   ./scripts/install.sh web now          # build + run web in this terminal
#   ./scripts/install.sh macos background  # build + run macOS detached
#   ./scripts/install.sh linux now
#
set -euo pipefail

PLATFORM="${1:-web}"
MODE="${2:-now}"
WEB_PORT="${WEB_PORT:-8080}"

# Resolve the project root (the parent of this scripts/ directory) so the
# installer works no matter where it is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# --- 1. Flutter SDK check -------------------------------------------------
if ! command -v flutter >/dev/null 2>&1; then
  die "Flutter SDK not found on PATH.
     Install it from https://docs.flutter.dev/get-started/install
     (macOS: 'brew install --cask flutter'), then re-run this script."
fi
log "Flutter found: $(flutter --version | head -n 1)"

# --- 2. Enable the target platform ---------------------------------------
case "$PLATFORM" in
  macos) flutter config --enable-macos-desktop >/dev/null ;;
  linux) flutter config --enable-linux-desktop >/dev/null ;;
  web)   flutter config --enable-web >/dev/null ;;
  *)     die "Unknown platform '$PLATFORM'. Use: macos | linux | web" ;;
esac
log "Platform enabled: $PLATFORM"

# --- 3. Install dependencies ---------------------------------------------
log "Installing Dart/Flutter package dependencies..."
flutter pub get

if [ "$PLATFORM" = "web" ]; then
  # Regenerate the SQLite WASM worker + binary the web build needs. Idempotent.
  log "Setting up SQLite WASM assets for web..."
  dart run sqflite_common_ffi_web:setup || warn "sqflite web setup reported a non-zero status; existing web/ assets will be used."
fi

# --- 4. Build ------------------------------------------------------------
log "Building the app for $PLATFORM (this can take a few minutes on first run)..."
case "$PLATFORM" in
  macos) flutter build macos ;;
  linux) flutter build linux ;;
  web)   flutter build web ;;
esac
log "Build complete."

# --- 5. Launch -----------------------------------------------------------
run_cmd() {
  case "$PLATFORM" in
    web)   flutter run -d chrome --web-port "$WEB_PORT" ;;
    macos) flutter run -d macos ;;
    linux) flutter run -d linux ;;
  esac
}

if [ "$MODE" = "background" ]; then
  LOG_FILE="$PROJECT_ROOT/writepad-$PLATFORM.log"
  log "Launching $PLATFORM in the background. Logs: $LOG_FILE"
  # nohup + & detaches the process from this terminal session.
  nohup bash -c "$(declare -f run_cmd); PLATFORM='$PLATFORM' WEB_PORT='$WEB_PORT' run_cmd" >"$LOG_FILE" 2>&1 &
  echo $! > "$PROJECT_ROOT/writepad-$PLATFORM.pid"
  log "Started (PID $(cat "$PROJECT_ROOT/writepad-$PLATFORM.pid")). Tail logs with: tail -f \"$LOG_FILE\""
  [ "$PLATFORM" = "web" ] && log "Once compiled, open http://localhost:$WEB_PORT"
else
  log "Launching $PLATFORM in this terminal (Ctrl+C to stop)..."
  [ "$PLATFORM" = "web" ] && log "Once compiled, open http://localhost:$WEB_PORT"
  run_cmd
fi
