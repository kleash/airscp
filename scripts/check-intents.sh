#!/bin/bash
# Checks that a built AirSCP.app has App Intents metadata (Xcode's processor makes it; build.sh runs it when Xcode is
# there) and that it lists every intent in the sources: an intent missing from it doesn't show in Shortcuts, Siri or
# Spotlight. Used by ci.yml's xcode job.
#   scripts/check-intents.sh [path/to/AirSCP.app]
set -euo pipefail
cd "$(dirname "$0")/.."
app=${1:-build/AirSCP.app}
data=$app/Contents/Resources/Metadata.appintents/extract.actionsdata
[ -f "$data" ] || { echo "No App Intents metadata in $app (build with Xcode installed: ./build.sh)" >&2; exit 1; }

# Every type that conforms to an intent protocol, as `struct Name: …Intent` in the app's sources.
intents=$(grep -hoE '^(struct|final class) [A-Za-z0-9_]+: ([A-Za-z]+, )*(AppIntent|OpenIntent|SetValueIntent|ControlConfigurationIntent)\b' \
          Sources/AirSCP/*.swift | awk '{print $2}' | tr -d ':' | sort -u)
[ -n "$intents" ] || { echo "No intents found in Sources/AirSCP" >&2; exit 1; }
missing=0
for intent in $intents; do
    if plutil -extract "actions.$intent.identifier" raw -o - "$data" >/dev/null 2>&1; then
        echo "✔ $intent"
    else
        echo "✘ $intent isn't in $data" >&2
        missing=1
    fi
done
exit $missing
