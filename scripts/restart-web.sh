#!/usr/bin/env bash
# 延迟重启 dsh web 后端。
#
# 为什么延迟：本脚本由 dsh web 自身的会话触发，立即重启会打断那条最终消息的投递。
# 为什么必须脱离：脚本的父进程就是 dsh web；只有 nohup + 重定向 + 后台化，才能在
#                 父进程被杀之后继续把新实例拉起来。启动方式见本文件末尾注释。
#
# 用法：nohup bash restart-web.sh [延迟秒数] >/dev/null 2>&1 &   （然后 disown）
#
# 日志：~/.dsh/dsh-web.log
set -uo pipefail

# 自我脱离：必须在新会话/新进程组里跑，否则杀掉旧宿主时会被同一进程组连带清掉。
# （实测：宿主退出会带走同组进程，脚本在 `kill $OLD` 之后立即消失，日志停在 old pid。）
# 用 os.setsid() 重开会话后 re-exec 自身，于是脚本的 pgid == 自己的 pid。
if [ "${DSH_RESTART_DETACHED:-}" != "1" ]; then
  export DSH_RESTART_DETACHED=1
  exec python3 -c 'import os,sys; os.setsid(); os.execv("/bin/bash", ["/bin/bash"] + sys.argv[1:])' "$0" "$@"
fi

DELAY="${1:-20}"
LOG="${DSH_LOG:-$HOME/.dsh/dsh-web.log}"
NODE_BIN="${DSH_NODE_BIN:-$(dirname "$(command -v node)")}"
WORKDIR="${DSH_WORKDIR:-$PWD}"
PORT="${DSH_PORT:-3080}"

exec >> "$LOG" 2>&1

sleep "$DELAY"

echo ""
echo "======== dsh web restart $(date '+%F %T') (after ${DELAY}s delay) ========"

OLD="$(lsof -nP -iTCP:$PORT -sTCP:LISTEN -t 2>/dev/null | head -1)"
echo "old pid: ${OLD:-none}"

if [ -n "${OLD:-}" ]; then
  kill "$OLD" 2>/dev/null || true
  for _ in $(seq 1 60); do kill -0 "$OLD" 2>/dev/null || break; sleep 0.25; done
  if kill -0 "$OLD" 2>/dev/null; then
    echo "graceful stop timed out; sending SIGKILL"
    kill -9 "$OLD" 2>/dev/null || true
    sleep 1
  fi
fi

# 等端口彻底释放
for _ in $(seq 1 60); do
  lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 || break
  sleep 0.25
done

cd "$WORKDIR" || { echo "FAIL: cannot cd $WORKDIR"; exit 1; }
export PATH="$NODE_BIN:$PATH"
export HOME="${HOME:-$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)}"

echo "starting: node $NODE_BIN/dsh web   (cwd=$WORKDIR)"
nohup node "$NODE_BIN/dsh" web >> "$LOG" 2>&1 &
NEW=$!
echo "new pid: $NEW"

for i in $(seq 1 180); do
  if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
    echo "OK: listening on 127.0.0.1:$PORT after $((i / 2))s; version=$(node "$NODE_BIN/dsh" --version 2>/dev/null)"
    exit 0
  fi
  if ! kill -0 "$NEW" 2>/dev/null; then
    echo "FAIL: new process exited before binding $PORT — see log above"
    exit 1
  fi
  sleep 0.5
done

echo "FAIL: port $PORT not listening after 90s (process still alive?)"
exit 1
