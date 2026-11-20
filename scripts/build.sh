#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
destination="${1:-$PWD/dist}"
mkdir -p "$destination"
destination="$(cd "$destination" && pwd)"
stage="$(mktemp -d "$destination/.bundle-XXXXXX")"
trap 'rm -rf "$stage"' EXIT
bundle="$stage/Desk Controls.app/Contents"
mkdir -p "$bundle/MacOS" "$bundle/Resources/Licenses"
binaries=()
minimum_os="$(plutil -extract LSMinimumSystemVersion raw Resources/Info.plist)"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
for arch in arm64 x86_64; do
    # The downloadable binary needs no local linker symbols. Debug builds
    # retain them for development and profiling.
    # Keep the deployment floor and linked SDK distinct. AppKit uses the
    # latter to select its appearance on newer systems.
    args=(--configuration release --arch "$arch" -Xlinker -x
          -Xlinker -platform_version -Xlinker macos -Xlinker "$minimum_os" -Xlinker "$sdk_version")
    swift build "${args[@]}" --product DeskControls
    binary_dir="$(swift build "${args[@]}" --show-bin-path)"
    cp "$binary_dir/DeskControls" "$stage/DeskControls-$arch"
    lipo "$stage/DeskControls-$arch" -verify_arch "$arch"
    binaries+=("$stage/DeskControls-$arch")
done
lipo -create "${binaries[@]}" -output "$bundle/MacOS/DeskControls"
lipo "$bundle/MacOS/DeskControls" -verify_arch arm64
lipo "$bundle/MacOS/DeskControls" -verify_arch x86_64
cp Resources/Info.plist "$bundle/Info.plist"
cp Resources/DeskControls.icns "$bundle/Resources/DeskControls.icns"
cp LICENSE Licenses/* "$bundle/Resources/Licenses/"
plutil -lint "$bundle/Info.plist"
# macOS ties Accessibility access to the signature. The ad-hoc default changes
# with every build. A certificate named in CODESIGN_IDENTITY keeps the grant.
bundle_id="$(plutil -extract CFBundleIdentifier raw Resources/Info.plist)"
identity="${CODESIGN_IDENTITY:--}"
codesign --force --sign "$identity" --identifier "$bundle_id" "$stage/Desk Controls.app"
if [[ "$identity" == - ]]; then
    codesign --verify --strict "$stage/Desk Controls.app"
else
    # --verify can reject a self-signed certificate the build machine does not
    # trust. The grant only needs the requirement to name the certificate.
    requirement="$(codesign --display --requirements - "$stage/Desk Controls.app" 2>&1)"
    if [[ "$requirement" != *certificate* ]]; then
        echo "The signature is not bound to a certificate: $requirement" >&2
        exit 1
    fi
fi
ditto -c -k --sequesterRsrc --keepParent "$stage/Desk Controls.app" "$stage/DeskControls.zip"
unzip -tq "$stage/DeskControls.zip"
mv -f "$stage/DeskControls.zip" "$destination/DeskControls.zip"
echo "$destination/DeskControls.zip"
