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
SUPPORT_ROOT="$HOME/Library/Application Support/Songizer"
DESTINATION="$SUPPORT_ROOT/Repeatizer/Repeatizer.app"
BACKUP="$SUPPORT_ROOT/Development Archive/$(date +%Y%m%d-%H%M%S)/Repeatizer/Repeatizer.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

codesign --force --options runtime --sign "$SIGN_IDENTITY" --entitlements "$ROOT/AUv3Extension/RepeatizerExtension.entitlements" "$EXTENSION"
codesign --force --options runtime --sign "$SIGN_IDENTITY" --entitlements "$ROOT/RepeatizerHost/RepeatizerHost.entitlements" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

if [[ -d "$DESTINATION" ]]; then
  pluginkit -r "$DESTINATION/Contents/PlugIns/RepeatizerExtension.appex" || true
  "$LSREGISTER" -u "$DESTINATION" || true
  mkdir -p "${BACKUP:h}"
  mv "$DESTINATION" "$BACKUP"
fi
mkdir -p "${DESTINATION:h}"
ditto "$APP" "$DESTINATION"
xattr -dr com.apple.quarantine "$DESTINATION" 2>/dev/null || true
codesign --verify --deep --strict --verbose=2 "$DESTINATION"
killall AudioComponentRegistrar 2>/dev/null || true
"$LSREGISTER" -f "$DESTINATION"
pluginkit -a "$DESTINATION/Contents/PlugIns/RepeatizerExtension.appex"
for attempt in {1..10}; do
  if pluginkit -m -A -D -i com.santismo.repeatizer.auv3.extension | grep -q com.santismo.repeatizer.auv3.extension; then
    exit 0
  fi
  sleep 1
done
echo "Repeatizer was installed, but macOS did not finish registering the Audio Unit."
exit 1
