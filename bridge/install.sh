#!/bin/bash
# Installs intellifire-bridge into /Users/Shared/intellifire-bridge and loads it
# under launchd. Run this on the Savant host.
#
#   ./install.sh            per-user LaunchAgent (starts at GUI login)
#   ./install.sh --daemon   system LaunchDaemon  (starts at boot, needs sudo)
#
# --daemon still runs the bridge as the invoking user, not root; it only needs
# sudo to place the plist in /Library/LaunchDaemons. Use it on a host that must
# come back on its own after an unattended reboot.
#
# Re-running is safe: code is refreshed, credentials.json is left alone.
set -euo pipefail

PREFIX="${INTELLIFIRE_PREFIX:-/Users/Shared/intellifire-bridge}"
LABEL="com.intellifire-bridge"
SOURCE="$(cd "$(dirname "$0")" && pwd)"
MODE="agent"

for arg in "$@"; do
  case "$arg" in
    --daemon) MODE="daemon" ;;
    --agent)  MODE="agent" ;;
    *) echo "usage: $0 [--daemon|--agent]" >&2; exit 2 ;;
  esac
done

# When invoked under sudo, install for the human who typed it, not for root.
RUN_USER="${SUDO_USER:-$(id -un)}"

echo "Installing intellifire-bridge into $PREFIX ($MODE, running as $RUN_USER)"

mkdir -p "$PREFIX/log"
rsync -a --delete "$SOURCE/bin" "$SOURCE/lib" "$PREFIX/"
chmod +x "$PREFIX/bin/intellifire-bridge" "$PREFIX/bin/intellifire-credentials"

if [ ! -f "$PREFIX/credentials.json" ]; then
  cat <<EOF

No credentials.json yet. Fetch one now with:

    $PREFIX/bin/intellifire-credentials --out $PREFIX/credentials.json

That asks for your IntelliFire app email and password, reads the fireplace's
API key from iftapi.net, and writes it locally. It is the only time the cloud
is involved.

EOF
  read -r -p "Run it now? [Y/n] " answer
  if [[ ! "$answer" =~ ^[Nn] ]]; then
    "$PREFIX/bin/intellifire-credentials" --out "$PREFIX/credentials.json"
  else
    echo "Skipped. The bridge will not start until credentials.json exists."
    exit 0
  fi
fi

# The daemon runs as RUN_USER, so everything it reads must belong to RUN_USER —
# including credentials.json if a root-run installer just created it.
chown -R "$RUN_USER" "$PREFIX" 2>/dev/null || true

if [ "$MODE" = "daemon" ]; then
  PLIST="/Library/LaunchDaemons/$LABEL.plist"
  TMP_PLIST="$(mktemp -t "$LABEL")"
  sed "s/__RUN_USER__/$RUN_USER/" \
    "$SOURCE/launchd/$LABEL.daemon.plist" > "$TMP_PLIST"

  # bootout is expected to fail the first time; that is not an error.
  sudo launchctl bootout "system/$LABEL" 2>/dev/null || true

  # bootout returns before the job is actually gone. Bootstrapping into that
  # window fails with "Bootstrap failed: 5: Input/output error", so wait for
  # the label to disappear first.
  for _ in $(seq 1 10); do
    sudo launchctl print "system/$LABEL" >/dev/null 2>&1 || break
    sleep 1
  done

  sudo cp "$TMP_PLIST" "$PLIST"
  sudo chown root:wheel "$PLIST"
  sudo chmod 644 "$PLIST"
  rm -f "$TMP_PLIST"

  # If the job outlived the wait, restart it in place instead: the code on
  # disk is already refreshed, so a kickstart picks it up.
  if ! sudo launchctl bootstrap system "$PLIST" 2>/dev/null; then
    echo "Job still loaded; restarting it in place."
    sudo launchctl kickstart -k "system/$LABEL"
  fi
else
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  mkdir -p "$(dirname "$PLIST")"
  cp "$SOURCE/launchd/$LABEL.plist" "$PLIST"

  # bootout is expected to fail the first time; that is not an error.
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
fi

echo "Waiting for the bridge to come up..."
for _ in $(seq 1 15); do
  if curl -fsS "http://127.0.0.1:4568/health" >/dev/null 2>&1; then
    echo
    echo "Bridge is up:"
    curl -fsS "http://127.0.0.1:4568/health"
    echo
    echo
    echo "Status:"
    curl -fsS "http://127.0.0.1:4568/status"
    echo
    echo
    echo "launchd job: $PLIST"
    exit 0
  fi
  sleep 1
done

echo "Bridge did not answer on port 4568. Check the log:" >&2
echo "  tail -n 50 $PREFIX/log/intellifire-bridge.log" >&2
echo "  tail -n 50 $PREFIX/log/intellifire-bridge.err.log" >&2
exit 1
