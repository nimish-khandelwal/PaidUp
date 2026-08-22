#!/bin/bash
# Builds PaidUpKit.xcframework (iOS device + simulator) for attaching to a
# GitHub release. Requires full Xcode and XcodeGen (`brew install xcodegen`).
#
# SPM packages archive as bare object files, so this generates a throwaway
# framework project around the same sources (Scripts/xcframework-project.yml)
# and archives that with library evolution enabled.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=build/xcframework
rm -rf "$OUT"
mkdir -p "$OUT"

xcodegen generate --spec Scripts/xcframework-project.yml --project "$OUT"

for DEST in "generic/platform=iOS" "generic/platform=iOS Simulator"; do
  case "$DEST" in
    *Simulator*) NAME=iphonesimulator ;;
    *)           NAME=iphoneos ;;
  esac
  xcodebuild archive \
    -project "$OUT/PaidUpKitFramework.xcodeproj" \
    -scheme PaidUpKit \
    -destination "$DEST" \
    -archivePath "$OUT/$NAME.xcarchive" \
    SKIP_INSTALL=NO \
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES
done

xcodebuild -create-xcframework \
  -archive "$OUT/iphoneos.xcarchive" -framework PaidUpKit.framework \
  -archive "$OUT/iphonesimulator.xcarchive" -framework PaidUpKit.framework \
  -output "$OUT/PaidUpKit.xcframework"

(cd "$OUT" && zip -r -q PaidUpKit.xcframework.zip PaidUpKit.xcframework)
echo "Done: $OUT/PaidUpKit.xcframework.zip"
VERSION=$(sed -n "s/.*s.version *= *'\(.*\)'.*/\1/p" PaidUp.podspec)
echo "Attach it to the GitHub release, e.g.:"
echo "  gh release upload v$VERSION $OUT/PaidUpKit.xcframework.zip"
