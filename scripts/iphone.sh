#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
action="${1:-build}"
team="${2:?DEVELOPMENT_TEAM is required; see CLAUDE.local.md}"
device="${3:-}"
configuration="${4:-Debug}"
build_options=("${@:5}")

case "$configuration" in Debug|Release) ;; *) echo 'configuration must be Debug or Release' >&2; exit 2 ;; esac
case "$action" in build|install) ;; *) echo 'usage: iphone.sh build|install <TEAM> [UDID] [Debug|Release]' >&2; exit 2 ;; esac
if [ "$action" = install ] && [ -z "$device" ]; then
  echo 'install requires an explicit iPhone UDID' >&2
  exit 2
fi

cd "$project_dir"
xcodebuild -project iphone/jj-remind.xcodeproj -scheme jj-remind \
  -configuration "$configuration" -derivedDataPath build/iphone \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic "DEVELOPMENT_TEAM=$team" ${build_options[@]+"${build_options[@]}"} build

app="$project_dir/build/iphone/Build/Products/$configuration-iphoneos/jj-remind.app"
codesign --verify --strict "$app"
if [ "$action" = install ]; then
  xcrun devicectl device install app --device "$device" "$app"
fi
