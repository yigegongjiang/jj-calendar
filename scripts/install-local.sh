#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
built_app="$project_dir/build/Build/Products/Release/jj-calendar.app"
installed_app="/Applications/jj-calendar.app"

cd "$project_dir"
xcodebuild -project jj-calendar.xcodeproj -scheme jj-calendar \
  -configuration Release -derivedDataPath build -destination 'platform=macOS' \
  ${1:+CODE_SIGN_STYLE=Automatic} ${1:+"CODE_SIGN_IDENTITY=Apple Development"} ${1:+"DEVELOPMENT_TEAM=$1"} \
  build

# 构建 / 产物检查失败时保留旧版。
test -x "$built_app/Contents/MacOS/jj-calendar"
codesign --verify --strict "$built_app"

quit_app() {
  osascript <<'APPLESCRIPT'
if application id "com.yigegongjiang.jj-calendar" is running then
    tell application id "com.yigegongjiang.jj-calendar" to quit
    repeat 50 times
        if application id "com.yigegongjiang.jj-calendar" is not running then return
        delay 0.1
    end repeat
    error "jj-calendar did not quit."
end if
APPLESCRIPT
}

quit_app

rm -rf -- "$installed_app"
ditto "$built_app" "$installed_app"
codesign --verify --strict "$installed_app"
trap quit_app EXIT
open "$installed_app"
osascript <<'APPLESCRIPT'
repeat 50 times
    if application id "com.yigegongjiang.jj-calendar" is running then
        tell application id "com.yigegongjiang.jj-calendar" to get version
        return
    end if
    delay 0.1
end repeat
error "jj-calendar did not start."
APPLESCRIPT
trap - EXIT
printf '已安装并打开: %s\n' "$installed_app"
