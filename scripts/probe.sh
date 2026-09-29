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
# 输出结论：三个补丁各自「可直接应用 / 冲突」、两个目标包是否被上游改到、
#           以及 bundle 依赖有没有搬家（功能静默消失的预警）。
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

say "4. bundle 依赖有没有「搬家」（决定 profile 的 bundles 要不要改）"
# 上游会在版本之间把功能在 bundle 之间搬走，而且不打招呼。搬走后 profile 若仍只列老
# bundle，功能会**静默消失**——不报错、不崩溃，就是界面里少一块。这一步把它变成显式信号。
# 注意：这里不能用 'packages/bundle/*/package.json' 当 pathspec——`git ls-tree` 的
# pathspec 里 `*` **不跨 `/`**，会静默返回空列表（`git grep` 是另一套规则，能匹配，
# 所以别拿 grep 的经验套过来）。必须用目录前缀 + grep 过滤，见下一行。
BUNDLE_FILES="$(git ls-tree -r --name-only "$TAG" -- packages/bundle packages/experimental 2>/dev/null \
                | grep -E '(^packages/bundle/[^/]+/package\.json$)|(^packages/experimental/[^/]*bundle[^/]*/package\.json$)' \
                || true)"
if [ -z "$BUNDLE_FILES" ]; then
  echo "  ⚠️ 没枚举到任何 bundle 文件——检查路径或上游目录结构是否变了（别当成「无搬家」）"
fi
MOVED=0
for bf in $BUNDLE_FILES; do
  # 取「真正被移除」的 @deepseek-ai/* 依赖。
  # 关键：必须减掉同时出现在 `+` 侧的名字——追加依赖会让上一行多一个逗号，
  # 于是同一个包在 `-`/`+` 两侧都出现，只看 `-` 会得到一堆假阳性。
  REMOVED="$(git diff "$PREV_TAG" "$TAG" -- "$bf" 2>/dev/null \
    | grep -E '^-[[:space:]]*"@deepseek-ai/' | sed -E 's/^-[[:space:]]*"([^"]+)".*/\1/' | sort -u || true)"
  ADDED="$(git diff "$PREV_TAG" "$TAG" -- "$bf" 2>/dev/null \
    | grep -E '^\+[[:space:]]*"@deepseek-ai/' | sed -E 's/^\+[[:space:]]*"([^"]+)".*/\1/' | sort -u || true)"
  gone="$(comm -23 <(printf '%s\n' "$REMOVED") <(printf '%s\n' "$ADDED") || true)"
  [ -z "$gone" ] && continue
  src="$(git show "$TAG:$bf" 2>/dev/null | sed -n 's/.*"name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)"
  [ -z "$src" ] && src="$bf"
  while IFS= read -r pkg; do
    [ -z "$pkg" ] && continue
    MOVED=1
    printf '  ⚠️  %s\n        从 %s 移出\n' "$pkg" "$src"
    # 这个包在新版本里被谁收走了？报 bundle 的 name，可直接填进 profile。
    # 注意：给 git grep 传 tree-ish 时，输出路径带 `<tree-ish>:` 前缀，必须剥掉，
    # 否则拿去 `git show "$TAG:$h"` 会拼成 `tag:tag:path` 而 fatal（exit 128）。
    holders="$(git grep -l "\"$pkg\"" "$TAG" -- 'packages/bundle/*/package.json' \
                 'packages/experimental/*bundle*/package.json' 'apps/cli/package.json' 2>/dev/null \
               | sed "s|^${TAG}:||" || true)"
    if [ -n "$holders" ]; then
      for h in $holders; do
        hn="$(git show "$TAG:$h" 2>/dev/null | sed -n 's/.*"name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)"
        printf '        现在在 %s   (%s)\n' "${hn:-$h}" "$h"
      done
    else
      printf '        现在没有被任何 bundle 引用——可能已改由其他机制提供，需人工确认\n'
    fi
  done <<< "$gone"
done
if [ "$MOVED" = "0" ]; then
  echo "  ✅ 没有依赖被移出任何 bundle——profile 的 bundles 不用动"
else
  echo "  ⇒ 把上面「现在在」列的 bundle 加进 ~/.dsh/profiles/web/package.json 的"
  echo "     dsh.profile.bundles，否则对应功能会静默消失。详见 README §4.7。"
  echo "     ⚠️ 顺序：先跑 switch.sh（它会备份 profile），再改 bundles。"
fi

say "5. 三个补丁在该版本上能否直接应用"
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
