#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product DeployStatus
binary_dir=$(swift build -c release --show-bin-path)
app="dist/Deploy Status.app"
mkdir -p "$app/Contents/MacOS"
install -m 755 "$binary_dir/DeployStatus" "$app/Contents/MacOS/DeployStatus"
cp Info.plist "$app/Contents/Info.plist"
if [[ -n "${DEPLOY_STATUS_CLIENT_ID:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Add :GitHubClientID string $DEPLOY_STATUS_CLIENT_ID" "$app/Contents/Info.plist"
fi
codesign --force --sign "${CODE_SIGN_IDENTITY:--}" "$app"
codesign --verify --strict "$app"
echo "$PWD/$app"
