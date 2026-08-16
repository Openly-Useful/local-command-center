#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="CommandCenter"
DISPLAY_NAME="Command Center"
BUNDLE_ID="local.commandcenter.mac"
MIN_SYSTEM_VERSION="14.0"
CONFIGURATION="${COMMAND_CENTER_CONFIGURATION:-release}"

if [[ "$MODE" == "--debug" || "$MODE" == "debug" ]]; then
  CONFIGURATION="debug"
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$DISPLAY_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

find_app_pids() {
  local candidate_pid
  local candidate_command
  while read -r candidate_pid candidate_command; do
    if [[ "$candidate_pid" =~ ^[0-9]+$ && "$candidate_command" == "$APP_BINARY" ]]; then
      printf '%s\n' "$candidate_pid"
    fi
  done < <(/bin/ps -axo pid=,command=)
}

stop_existing_app() {
  local existing_pid
  local existing_pids=()
  while IFS= read -r existing_pid; do
    [[ -n "$existing_pid" ]] && existing_pids+=("$existing_pid")
  done < <(find_app_pids)

  # macOS ships Bash 3.2; with `set -u`, expanding an empty array in the
  # following loops raises "unbound variable". A no-instance launch is the
  # normal first-run path, so return before either expansion.
  [[ "${#existing_pids[@]}" -eq 0 ]] && return 0

  for existing_pid in "${existing_pids[@]}"; do
    /bin/kill -TERM "$existing_pid" 2>/dev/null || true
  done

  for _ in {1..50}; do
    local any_running=0
    for existing_pid in "${existing_pids[@]}"; do
      if /bin/kill -0 "$existing_pid" 2>/dev/null; then
        any_running=1
        break
      fi
    done
    [[ "$any_running" -eq 0 ]] && return 0
    /bin/sleep 0.1
  done

  echo "Command Center did not terminate within 5 seconds; refusing to replace its bundle." >&2
  return 1
}

stop_existing_app

cd "$ROOT_DIR"
SWIFT_BUILD_ARGS=()
if [[ "${COMMAND_CENTER_DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]]; then
  SWIFT_BUILD_ARGS+=(--disable-sandbox)
fi
if [[ "${#SWIFT_BUILD_ARGS[@]}" -gt 0 ]]; then
  swift build "${SWIFT_BUILD_ARGS[@]}" -c "$CONFIGURATION" --product "$APP_NAME"
  BUILD_BINARY="$(swift build "${SWIFT_BUILD_ARGS[@]}" -c "$CONFIGURATION" --show-bin-path)/$APP_NAME"
else
  swift build -c "$CONFIGURATION" --product "$APP_NAME"
  BUILD_BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/$APP_NAME"
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Command Center can be brought to the front by local automation.</string>
</dict>
</plist>
PLIST

/usr/bin/codesign --force --deep --sign - "$APP_BUNDLE"

open_app() {
  /usr/bin/open "$APP_BUNDLE"
}

find_app_pid() {
  find_app_pids | head -1
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    test -n "$(find_app_pid)"
    ;;
  --profile|profile)
    open_app
    sleep 5
    APP_PID="$(find_app_pid)"
    test -n "$APP_PID"
    ps -o pid=,rss=,command= -p "$APP_PID"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--profile]" >&2
    exit 2
    ;;
esac
