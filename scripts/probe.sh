#!/usr/bin/env bash
# 只读探测：判断一次 DSH 升级是「轻松」还是「艰难」。
#
# 不做任何修改——不动工作区、不装包、不重启宿主。唯一副作用是拉一个 git tag，
# 以及一个用完即删的临时 worktree。
#
# 用法：
#   bash scripts/probe.sh 0.1.7-rc.3
#   DSH_CLONE=/path/to/deepseek-harness bash scripts/probe.sh 0.1.7-rc.3
#
# 输出结论：三个补丁各自「可直接应用 / 冲突」，以及两个目标包是否被上游改到。
set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "用法: probe.sh <version>   例如: probe.sh 0.1.7-rc.3" >&2
  exit 2
fi

CLONE="${DSH_CLONE:-$HOME/work/guardian/git/deepseek-harness}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCHES="$REPO/patches"
TAG="dsh-v$VERSION"
TARGETS=(packages/api/workspace-controller packages/llm/llm-pi-ai)

say() { printf '\n=== %s ===\n' "$*"; }

# --- git 可用性：本机 /usr/bin/git 可能被 Xcode 许可证挡住 ---
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  if [ ! -x /Library/Developer/CommandLineTools/usr/bin/git ]; then
    echo "FAIL: git 不可用" >&2; exit 1
  fi
  CLT_GIT=/Library/Developer/CommandLineTools/usr/bin/git
  mkdir -p /tmp/clt-git && ln -sf "$CLT_GIT" /tmp/clt-git/git
  export PATH="/tmp/clt-git:$PATH"
  echo "note: 已临时启用 ${CLT_GIT}（Xcode 许可证挡住了 /usr/bin/git）"
fi

cd "$CLONE"
say "0. 环境"
echo "  clone    : $CLONE"
echo "  补丁集   : $PATCHES"
echo "  目标标签 : $TAG"
echo "  当前版本 : $(git describe --tags --abbrev=0 --match 'dsh-v*' HEAD 2>/dev/null || echo '(未知)')"

say "1. 拉取标签（只拉这一个，不用 --tags）"
if ! git fetch --quiet origin "tag" "$TAG" 2>/dev/null; then
  echo "  ❌ 拉取失败：上游没有 ${TAG}，或网络不通" >&2
  exit 1
fi
git rev-parse --verify --quiet "$TAG^{commit}" >/dev/null || { echo "  ❌ 标签无法解析" >&2; exit 1; }
echo "  ✅ $TAG = $(git rev-parse --short "$TAG")   $(git log -1 --format=%ci "$TAG")"

# --- 找上一个发布标签作为对比基线 ---
PREV_TAG="$(git describe --tags --abbrev=0 --match 'dsh-v*' "${TAG}^" 2>/dev/null || true)"
if [ -z "$PREV_TAG" ]; then
  PREV_TAG="$(git describe --tags --abbrev=0 --match 'dsh-v*' HEAD 2>/dev/null || true)"
fi
if [ -z "$PREV_TAG" ]; then echo "  ⚠️ 找不到对比基线标签，改用手工指定"; exit 1; fi

say "2. 与上一个发布标签对比（基线 ${PREV_TAG}）"
if git merge-base --is-ancestor "$PREV_TAG" "$TAG"; then
  echo "  ✅ fast-forward（上游没有 force-rewrite 到不兼容的历史）"
else
  echo "  ⚠️ 不是 fast-forward——上游可能 rewrite 过 master，移植时要格外小心"
fi
echo "  提交数 : $(git rev-list --count "$PREV_TAG..$TAG")"
echo "  改动量 : $(git diff --shortstat "$PREV_TAG" "$TAG")"

say "3. 两个目标包是否被上游改到（决定要不要做适配）"
for p in "${TARGETS[@]}"; do
  n=$(git diff --name-only "$PREV_TAG" "$TAG" -- "$p" | wc -l | tr -d ' ')
  if [ "$n" = "0" ]; then
    printf "  %-40s ✅ 未改动（源码不变 ⇒ 产物预期逐字节相同）\n" "$p"
  else
    printf "  %-40s ⚠️  %s 个文件改动\n" "$p" "$n"
    git diff --name-only "$PREV_TAG" "$TAG" -- "$p" | sed 's/^/        /'
  fi
done

say "4. 三个补丁在该版本上能否直接应用"
WT="$(mktemp -d /tmp/dsh-probe.XXXXXX)"
cleanup() { git worktree remove --force "$WT" >/dev/null 2>&1 || true; rm -rf "$WT"; }
trap cleanup EXIT
rm -rf "$WT"; git worktree add --quiet --detach "$WT" "$TAG"

READY=0; CONFLICT=0
for f in "$PATCHES"/*.patch; do
  name="$(basename "$f" .patch)"
  printf "  %-42s " "$name"
  if (cd "$WT" && git apply --check "$f" 2>/tmp/probe-apply.err); then
    echo "✅ 可直接应用"; READY=$((READY+1))
  else
    echo "❌ 冲突"; CONFLICT=$((CONFLICT+1))
    grep -E "^error:" /tmp/probe-apply.err | head -4 | sed 's/^/        /'
  fi
done

say "结论"
if [ "$CONFLICT" = "0" ]; then
  echo "  ✅ 三个补丁全部可直接应用——这次升级是机械的，按 README §4.2 往下走即可。"
else
  echo "  ⚠️ $CONFLICT 个补丁冲突（$READY 个干净）。"
  echo "     若冲突只在 README.i18n.yaml / docs/config-catalog.*，那是生成文件，"
  echo "     用 --exclude 排除后按 README §4.4 重新生成，属于机械冲突。"
  echo "     若冲突落在 src/ 下的代码，才需要真正的手工适配。"
fi
