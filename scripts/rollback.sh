#!/usr/bin/env bash
# 回滚：把 DSH 全局安装退回指定版本，并恢复该版本对应的两个修复产物。
#
# 依赖 switch.sh 当时留下的备份目录。若要回滚到的版本没有备份，
# 请改用 switch.sh 重新构建并切换（它会现场生成备份）。
#
# 用法：
#   bash scripts/rollback.sh 0.1.7-rc.2
set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "用法: rollback.sh <要回滚到的版本>   例如: rollback.sh 0.1.7-rc.2" >&2
  exit 2
fi

GLOBAL="${DSH_GLOBAL:-$(npm root -g 2>/dev/null)/@deepseek-ai/dsh}"
BACKUP_ROOT="${DSH_BACKUP:-$HOME/.cache/dsh-local-patches}"
NPM_CACHE="${DSH_NPM_CACHE:-/tmp/dsh-npm-cache}"
PROFILE_PKG="${DSH_PROFILE_PKG:-$HOME/.dsh/profiles/web/package.json}"
BK="$BACKUP_ROOT/backup-$VERSION-patched"

say() { printf '\n=== %s ===\n' "$*"; }

say "0. 可用备份"
ls -1 "$BACKUP_ROOT" 2>/dev/null | sed 's/^/  /' || echo "  (还没有任何备份)"
[ -d "$BK" ] || {
  echo "FAIL: 找不到 $BK" >&2
  echo "      该版本的修复产物没有备份；请用 switch.sh 重新构建并切换。" >&2
  exit 1
}
for f in dsh-api-workspace-controller-client.js dsh-llm-pi-ai-index.js profile-web-package.json; do
  [ -f "$BK/$f" ] || { echo "FAIL: 缺少 $BK/$f" >&2; exit 1; }
done
grep -q "REBUILD_BASE_MS" "$BK/dsh-api-workspace-controller-client.js" \
  || { echo "FAIL: 备份的 client.js 不含修复符号" >&2; exit 1; }
grep -q "repeatReasoningBeforeEachToolCall" "$BK/dsh-llm-pi-ai-index.js" \
  || { echo "FAIL: 备份的 index.js 不含修复符号" >&2; exit 1; }
echo "  ✅ 备份齐全且含修复符号"

say "1. 装回全局 $VERSION"
npm i -g --cache "$NPM_CACHE" "@deepseek-ai/dsh@$VERSION" 2>&1 | tail -4
echo "  全局版本现在是: $(node -p "require('${GLOBAL}/package.json').version")"

say "2. 覆盖回修复产物"
cp "$BK/dsh-api-workspace-controller-client.js" \
   "$GLOBAL/node_modules/@deepseek-ai/dsh-api-workspace-controller/lib/client.js"
cp "$BK/dsh-llm-pi-ai-index.js" \
   "$GLOBAL/node_modules/@deepseek-ai/dsh-llm-pi-ai/lib/index.js"
grep -q "REBUILD_BASE_MS" \
  "$GLOBAL/node_modules/@deepseek-ai/dsh-api-workspace-controller/lib/client.js" \
  && echo "  ok: client.js 修复已恢复"
grep -q "repeatReasoningBeforeEachToolCall" \
  "$GLOBAL/node_modules/@deepseek-ai/dsh-llm-pi-ai/lib/index.js" \
  && echo "  ok: index.js 修复已恢复"

say "3. 恢复 profile manifest"
cp "$BK/profile-web-package.json" "$PROFILE_PKG"
node -p "JSON.parse(require('fs').readFileSync('$PROFILE_PKG','utf8')).dsh.profile.bundles.join(', ')" \
  | sed 's/^/  bundles: /'

say "4. 重启前预检"
if command -v dsh >/dev/null 2>&1 && dsh --profile web --dump-config > /tmp/dsh-rollback-dump.yml 2>/tmp/dsh-rollback-dump.err; then
  echo "  ok: --dump-config 退出 0，$(wc -l < /tmp/dsh-rollback-dump.yml | tr -d ' ') 行"
else
  echo "  ⚠️ --dump-config 失败，stderr:" >&2
  head -15 /tmp/dsh-rollback-dump.err 2>/dev/null >&2 || true
  exit 1
fi

say "结果"
echo "  已回滚到 $VERSION + 本地修复。重启生效：bash scripts/restart-web.sh 30"
