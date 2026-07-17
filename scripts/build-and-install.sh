#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/build"
SIGN_IDENTITY="${REPEATIZER_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)}"

if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "No Apple Development signing identity is available."
  exit 1
fi

xcodebuild -project "$ROOT/Repeatizer.xcodeproj" -scheme Repeatizer -configuration Release -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO build

APP="$DERIVED/Build/Products/Release/Repeatizer.app"
EXTENSION="$APP/Contents/PlugIns/RepeatizerExtension.appex"
codesign --force --options runtime --sign "$SIGN_IDENTITY" --entitlements "$ROOT/AUv3Extension/RepeatizerExtension.entitlements" "$EXTENSION"
codesign --force --options runtime --sign "$SIGN_IDENTITY" --entitlements "$ROOT/RepeatizerHost/RepeatizerHost.entitlements" "$APP"
pkill -x Repeatizer 2>/dev/null || true
if [[ -d /Applications/Repeatizer.app ]]; then
  pluginkit -r /Applications/Repeatizer.app || true
fi
rm -rf /Applications/Repeatizer.app
ditto "$APP" /Applications/Repeatizer.app
killall AudioComponentRegistrar 2>/dev/null || true
pluginkit -a /Applications/Repeatizer.app
pluginkit -a /Applications/Repeatizer.app/Contents/PlugIns/RepeatizerExtension.appex
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Repeatizer.app
for attempt in {1..10}; do
  if pluginkit -m -A -D -i com.repeatizer.app.RepeatizerExtension | grep -q com.repeatizer; then
    exit 0
  fi
  sleep 1
done
echo "Repeatizer was installed, but macOS did not finish registering the Audio Unit."
exit 1
