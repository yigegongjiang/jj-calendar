#!/bin/bash
# 用法: debug.sh [DEVELOPMENT_TEAM]  构建 + 重启本 worktree 的 Debug 实例
#       debug.sh quit                退出本 worktree 的 Debug 实例
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
built_app="$project_dir/build/Build/Products/Debug/jj-calendar Debug.app"
executable="$built_app/Contents/MacOS/jj-calendar Debug"
tag="$(basename "$project_dir")"

# 各 worktree 产物路径唯一: 按可执行文件路径精确匹配, 只处理本 worktree 的实例, 不影响其他 worktree。
instance_pids() {
  ps -axo pid=,comm= | awk -v exe="$executable" '{ pid = $1; sub(/^ *[0-9]+ /, ""); if ($0 == exe) print pid }'
}

quit_instances() {
  local pids
  pids="$(instance_pids)"
  [ -z "$pids" ] && return 0
  kill $pids
  for _ in $(seq 50); do
    [ -z "$(instance_pids)" ] && return 0
    sleep 0.1
  done
  echo "jj-calendar Debug ($tag) did not quit." >&2
  return 1
}

if [ "${1:-}" = quit ]; then
  quit_instances
  exit
fi

cd "$project_dir"
xcodebuild -project jj-calendar.xcodeproj -scheme jj-calendar \
  -configuration Debug -derivedDataPath build -destination 'platform=macOS' \
  ${1:+CODE_SIGN_STYLE=Automatic} ${1:+"CODE_SIGN_IDENTITY=Apple Development"} ${1:+"DEVELOPMENT_TEAM=$1"} \
  build

quit_instances
# -n: 同一 bundle id 允许多实例并存; -g: 后台启动, 不抢占前台。
open -n -g --env "JJCAL_DEBUG_TAG=$tag" "$built_app"
for _ in $(seq 50); do
  pid="$(instance_pids)"
  if [ -n "$pid" ]; then
    echo "pid=$pid tag=$tag"
    exit 0
  fi
  sleep 0.1
done
echo "jj-calendar Debug ($tag) did not start." >&2
exit 1
