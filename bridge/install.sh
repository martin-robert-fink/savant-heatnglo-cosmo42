#!/bin/bash
# Installs intellifire-bridge into /Users/Shared/intellifire-bridge and loads it
# under launchd. Run this on the Savant host.
#
#   ./install.sh
#
# Re-running is safe: code is refreshed, credentials.json is left alone.
set -euo pipefail

PREFIX="${INTELLIFIRE_PREFIX:-/Users/Shared/intellifire-bridge}"
LABEL="com.intellifire-bridge"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SOURCE="$(cd "$(dirname "$0")" && pwd)"

echo "Installing intellifire-bridge into $PREFIX"

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

mkdir -p "$(dirname "$PLIST")"
cp "$SOURCE/launchd/$LABEL.plist" "$PLIST"

# bootout is expected to fail the first time; that is not an error.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

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
    exit 0
  fi
  sleep 1
done

echo "Bridge did not answer on port 4568. Check the log:" >&2
echo "  tail -n 50 $PREFIX/log/intellifire-bridge.log" >&2
echo "  tail -n 50 $PREFIX/log/intellifire-bridge.err.log" >&2
exit 1
