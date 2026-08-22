#!/bin/bash
# Builds EntitledKit.xcframework (iOS device + simulator) for attaching to a
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
    -project "$OUT/EntitledKitFramework.xcodeproj" \
    -scheme EntitledKit \
    -destination "$DEST" \
    -archivePath "$OUT/$NAME.xcarchive" \
    SKIP_INSTALL=NO \
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES
done

xcodebuild -create-xcframework \
  -archive "$OUT/iphoneos.xcarchive" -framework EntitledKit.framework \
  -archive "$OUT/iphonesimulator.xcarchive" -framework EntitledKit.framework \
  -output "$OUT/EntitledKit.xcframework"

(cd "$OUT" && zip -r -q EntitledKit.xcframework.zip EntitledKit.xcframework)
echo "Done: $OUT/EntitledKit.xcframework.zip"
echo "Attach it to the GitHub release, e.g.:"
echo "  gh release upload v0.1.0 $OUT/EntitledKit.xcframework.zip"
