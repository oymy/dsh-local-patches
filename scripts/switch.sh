#!/usr/bin/env bash
# 把 DSH 全局安装切到指定版本，并在切换后换回两个本地修复产物。
#
# 前置：clone 里对应分支已完成移植 + 测试 + 构建（README §4.2–4.4）。
# 影响：**会替换正在运行的 dsh web 所使用的文件**，必须重启宿主才生效。
# 回滚：scripts/rollback.sh <上一个版本>
#
# 用法：
#   bash scripts/switch.sh 0.1.7-rc.3
#   DSH_CLONE=/path DSH_GLOBAL=/path bash scripts/switch.sh 0.1.7-rc.3
set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "用法: switch.sh <目标版本>   例如: switch.sh 0.1.7-rc.3" >&2
  exit 2
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLONE="${DSH_CLONE:-$HOME/work/guardian/git/deepseek-harness}"
GLOBAL="${DSH_GLOBAL:-$(npm root -g 2>/dev/null)/@deepseek-ai/dsh}"
BACKUP_ROOT="${DSH_BACKUP:-$HOME/.cache/dsh-local-patches}"
NPM_CACHE="${DSH_NPM_CACHE:-/tmp/dsh-npm-cache}"
PROFILE_PKG="${DSH_PROFILE_PKG:-$HOME/.dsh/profiles/web/package.json}"
# 该行在 0.1.7 起就不存在于任何包版本中，保留检查以防回退到更老的版本
DROP_BUNDLE="@deepseek-ai/dsh-experimental-agent-team-web-profile"

WS_SRC="$CLONE/packages/api/workspace-controller/lib/client.js"
PI_SRC="$CLONE/packages/llm/llm-pi-ai/lib/index.js"
WS_DST="$GLOBAL/node_modules/@deepseek-ai/dsh-api-workspace-controller/lib/client.js"
PI_DST="$GLOBAL/node_modules/@deepseek-ai/dsh-llm-pi-ai/lib/index.js"

say() { printf '\n=== %s ===\n' "$*"; }
require_symbol() { # file symbol label
  if ! grep -q "$2" "$1" 2>/dev/null; then echo "FAIL: $3 缺少修复符号 $2 -> $1" >&2; exit 1; fi
  echo "  ok: $3 含 $2"
}

say "0. 前置校验（确认 clone 里是构建好的、带修复的产物）"
[ -f "$WS_SRC" ] || { echo "缺少 ${WS_SRC}，先构建 workspace-controller" >&2; exit 1; }
[ -f "$PI_SRC" ] || { echo "缺少 ${PI_SRC}，先构建 llm-pi-ai" >&2; exit 1; }
require_symbol "$WS_SRC" "REBUILD_BASE_MS" "待覆盖的 client.js"
require_symbol "$PI_SRC" "repeatReasoningBeforeEachToolCall" "待覆盖的 index.js"
CURRENT="$(node -p "require('${GLOBAL}/package.json').version" 2>/dev/null || echo unknown)"
echo "  当前全局版本: $CURRENT"
echo "  目标版本    : $VERSION"

say "1. 备份当前状态（供 rollback.sh 使用）"
mkdir -p "$BACKUP_ROOT/backup-$CURRENT-patched"
BK="$BACKUP_ROOT/backup-$CURRENT-patched"
[ -f "$BK/dsh-api-workspace-controller-client.js" ] || \
  cp "$WS_DST" "$BK/dsh-api-workspace-controller-client.js"
[ -f "$BK/dsh-llm-pi-ai-index.js" ] || \
  cp "$PI_DST" "$BK/dsh-llm-pi-ai-index.js"
[ -f "$BK/profile-web-package.json" ] || \
  cp "$PROFILE_PKG" "$BK/profile-web-package.json"
echo "  已备份到 $BK"

say "2. 清理 profile 里不存在于新版本的 bundle 行"
node -e '
const fs = require("fs"), p = process.argv[1], drop = process.argv[2];
let j; try { j = JSON.parse(fs.readFileSync(p, "utf8")); } catch { console.log("  跳过（profile 不可读）"); process.exit(0) }
if (!j?.dsh?.profile?.bundles) { console.log("  跳过（结构不含 bundles）"); process.exit(0) }
const before = j.dsh.profile.bundles;
j.dsh.profile.bundles = before.filter(b => b !== drop);
if (j.dsh.profile.bundles.length === before.length) console.log("  该行本来就不在，无需改动");
else { fs.writeFileSync(p, JSON.stringify(j, null, 2) + "\n"); console.log("  bundles ->", j.dsh.profile.bundles.join(", ")) }
' "$PROFILE_PKG" "$DROP_BUNDLE"

say "3. 安装全局 $VERSION"
npm i -g --cache "$NPM_CACHE" "@deepseek-ai/dsh@$VERSION" 2>&1 | tail -4
INSTALLED="$(node -p "require('${GLOBAL}/package.json').version")"
echo "  全局版本现在是: $INSTALLED"
[ "$INSTALLED" = "$VERSION" ] || { echo "FAIL: 期望 ${VERSION}，实际 $INSTALLED" >&2; exit 1; }

say "4. 覆盖两个修复产物并验收"
cp "$WS_SRC" "$WS_DST"; cp "$PI_SRC" "$PI_DST"
require_symbol "$WS_DST" "REBUILD_BASE_MS" "全局 client.js"
require_symbol "$WS_DST" "workspace-controller.client.generation" "全局 client.js"
require_symbol "$WS_DST" "replacePinned" "全局 client.js"
require_symbol "$PI_DST" "repeatReasoningBeforeEachToolCall" "全局 index.js"

say "5. 重启前预检（用真实 DSH_HOME 组合 profile）"
export PATH="$(dirname "$(command -v node)"):$PATH"
if command -v dsh >/dev/null 2>&1 && dsh --profile web --dump-config > /tmp/dsh-switch-dump.yml 2>/tmp/dsh-switch-dump.err; then
  echo "  ok: --dump-config 退出 0，$(wc -l < /tmp/dsh-switch-dump.yml | tr -d ' ') 行"
  [ -n "${DSH_DUMP_EXPECT:-}" ] && grep -q "$DSH_DUMP_EXPECT" /tmp/dsh-switch-dump.yml \
    && echo "  ok: 命中期望串 $DSH_DUMP_EXPECT"
else
  echo "  ⚠️ --dump-config 失败或 dsh 不在 PATH。先别重启，stderr:" >&2
  head -15 /tmp/dsh-switch-dump.err 2>/dev/null >&2 || true
  exit 1
fi

say "结果"
echo "  全局安装版本: $INSTALLED"
cat <<'NEXT'

下一步：
  1. bash scripts/restart-web.sh 30     # 延迟 30 秒、自我脱离地重启
  2. 浏览器硬刷新（Cmd+Shift+R）——宿主需重算 client bundle rev
  3. 验证：dsh --version 对得上；页面能开；Agent Teams 面板在；两个 bug 场景各走一遍
出问题：bash scripts/rollback.sh <上一个版本>
NEXT
