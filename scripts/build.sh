#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
destination="${1:-$PWD/dist}"
mkdir -p "$destination"
destination="$(cd "$destination" && pwd)"
stage="$(mktemp -d "$destination/.bundle-XXXXXX")"
trap 'rm -rf "$stage"' EXIT
bundle="$stage/Monitor Controls.app/Contents"
mkdir -p "$bundle/MacOS" "$bundle/Resources/Licenses"
minimum_os="$(plutil -extract LSMinimumSystemVersion raw Resources/Info.plist)"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
# The app is built for Apple silicon only.
# The downloadable binary needs no local linker symbols. Debug builds
# retain them for development and profiling.
# Keep the deployment floor and linked SDK distinct. AppKit uses the
# latter to select its appearance on newer systems.
args=(--configuration release --arch arm64 -Xlinker -x
      -Xlinker -platform_version -Xlinker macos -Xlinker "$minimum_os" -Xlinker "$sdk_version")
swift build "${args[@]}" --product MonitorControls
binary_dir="$(swift build "${args[@]}" --show-bin-path)"
cp "$binary_dir/MonitorControls" "$bundle/MacOS/MonitorControls"
if [[ "$(lipo -archs "$bundle/MacOS/MonitorControls")" != arm64 ]]; then
    echo "The binary is not an arm64-only build." >&2
    exit 1
fi
cp Resources/Info.plist "$bundle/Info.plist"
cp Resources/MonitorControls.icns "$bundle/Resources/MonitorControls.icns"
cp LICENSE Licenses/* "$bundle/Resources/Licenses/"
plutil -lint "$bundle/Info.plist"
# macOS ties Accessibility access to the signature. The ad-hoc default changes
# with every build. A certificate named in CODESIGN_IDENTITY keeps the grant.
bundle_id="$(plutil -extract CFBundleIdentifier raw Resources/Info.plist)"
identity="${CODESIGN_IDENTITY:--}"
codesign --force --sign "$identity" --identifier "$bundle_id" "$stage/Monitor Controls.app"
if [[ "$identity" == - ]]; then
    codesign --verify --strict "$stage/Monitor Controls.app"
else
    # --verify can reject a self-signed certificate the build machine does not
    # trust. The grant only needs the requirement to name the certificate.
    requirement="$(codesign --display --requirements - "$stage/Monitor Controls.app" 2>&1)"
    if [[ "$requirement" != *certificate* ]]; then
        echo "The signature is not bound to a certificate: $requirement" >&2
        exit 1
    fi
fi
ditto -c -k --sequesterRsrc --keepParent "$stage/Monitor Controls.app" "$stage/MonitorControls.zip"
unzip -tq "$stage/MonitorControls.zip"
mv -f "$stage/MonitorControls.zip" "$destination/MonitorControls.zip"
echo "$destination/MonitorControls.zip"
