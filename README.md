# dsh-local-patches

让 **DeepSeek Harness (DSH)** 升级时保住两个本地修复，并且让这件事变得可重复、可验证、可回滚。

本仓库**只装补丁和脚本，不装 DSH 源码**。升级时从上游拉取，打完补丁再构建。

> **`patches/` 当前面向 `0.2.0-rc.1`**（`next` 通道；`latest` 当时仍停在 `0.1.7-rc.2`）。
> 历史版本补丁在 `patches/archive/<version>/`。补丁只对各自目标版本有效，跨版本用前先 `probe.sh`。

---

## 1. 为什么需要这个仓库

上游 `deepseek-ai/deepseek-harness` **不接受外部 PR**，两条独立证据：

**GitHub API**（`https://api.github.com/repos/deepseek-ai/deepseek-harness`）

```
has_pull_requests : false     ← PR 功能在仓库层面关闭
has_issues        : false     ← Issues 也关闭
has_discussions   : true      ← 只开 Discussions
allow_forking     : true
forks_count       : 28574
topics            : ai-agents, cordis, dsh, dsh-plugin
```

**仓库自带的 `CONTRIBUTING.md`（中英双语）**

> DeepSeek Harness is still at an early stage and under active development. We are sorry that
> **we cannot accept external pull requests at the moment**.

官方给的替代通道只有三条：**GitHub Discussions 报 bug**、**做插件**（给自己的仓库打 `dsh-plugin` topic）、写博客/回答社区问题。

所以这两个修复只能长期留在本地。既然上游不收，就别把时间花在"提 PR"上——本仓库解决的是另一件事：**怎么在每次上游发布时，低成本且可验证地把修复带过去。**

---

## 2. 两个修复是什么

| 补丁 | 目标包 | 修什么 |
|---|---|---|
| `0001-workspace-stream-rebuild` | `@deepseek-ai/dsh-api-workspace-controller`（client 面） | 工作区状态流在收到 opening snapshot 之前断掉，UI 卡死。补丁在载体重试耗尽后**重建流**，退避基数 `REBUILD_BASE_MS` |
| `0002-responses-reasoning-replay` | `@deepseek-ai/dsh-llm-pi-ai` | OpenAI **Responses** 协议下，历史里签名过的 reasoning/text 序言需要在**每次工具调用前重放**，且配对的 tool output 必须相邻。由 `repeatReasoningBeforeEachToolCallModels` 开关按模型启用 |
| `0003-docs-and-notes` | `docs/`、`.agents/notes/` | 让上游的 doc-sync / i18n 一致性门禁通过 |

> **两者性质不同，这点很重要。**
> `0002` 的注释自己写着 *"Some DeepSeek-compatible gateways require every call/output pair to be adjacent"* ——
> 这是**为第三方网关做的兼容，不是上游 bug**，大概率永远留在本地。
> `0001` 是**货真价实的 bug**（状态流在开帧前中断），值得提 Discussions。

---

## 3. 关键机制：改动为什么能生效

别误判成"浏览器包是发布时预构建的，替换 `lib/client.js` 没用"——这个怀疑是错的：

- `dsh-web-frontend/dist` **只是外壳**（Vite shell + vendor），里面既没有 `workspace-controller` 也没有 `conversation` 字样。
- 真正的 client 模块由宿主**运行时下发**：`dsh-client-modules/lib/index.js:718-723` 解析包 `exports["./client"]` → `<pkg>/lib/client.js`，
  按该文件的 **mtime/ctime/size** 算 `rev`（`artifactRevision`），再以 `/plugins/??<id>/client.js&rev=<rev>` 的 combo 形式发给浏览器。
- 所以**「替换 `lib/client.js` + 重启宿主」正是生效路径**：重启既重新注册模块表，也因文件元数据变化让 `rev` 改变，浏览器不会吃旧缓存。

**验证时别踩这两个坑**：不要 `grep` dist 找模块级常量（压缩后会改名）；也不要在 dist 里找包名字符串（它本来就不在那儿）。

---

## 4. 快速开始

### 4.0 先问：这次真的值得升吗

**上游发布节奏接近每天一次**（0.1.5-rc.2 → 0.1.7-rc.2 之间两周内出了 8 个版本），
而一次完整的移植+构建+验证切换大约 **25 分钟**。所以**不要追每个 release**：

| 情况 | 建议 |
|---|---|
| 上游只动了 commit、两个目标包无关 | **跳过**，没收益 |
| 碰到实际 bug / 需要某个新功能 | 升 |
| **月级巡检一次** | 升到当时最新的稳定 tag 即可 |
| 紧急（安全或阻断性问题） | 立刻升 |

`probe.sh` 会明确告诉你"两个目标包是否被上游改到"——**上一轮 alpha.2→rc.1 两个包源码一行没动**，
重建产物与上一版 **sha256 完全相同**，那次升级纯粹是把同样的字节拷回去。
所以先跑 probe，再决定要不要花那 25 分钟。

> 前提是这台机器内存够。整仓 `pnpm install` 在 16 GB 机器上会 OOM（见 §6.2），
> 靠"跳过整仓 install、只补 workspace 链接"绕过。

### 4.1 先判断这次升级是轻松还是艰难

```bash
bash scripts/probe.sh 0.1.7-rc.3
```

**全程只读**，不动工作区、不装包、不重启。输出：

- 是否 fast-forward（上游会定期 force-rewrite `master`）
- 提交数 / 改动文件数 / 增删行
- **两个目标包是否被上游改到**（决定要不要做适配）
- 三个补丁 `git apply --check` 逐个结果

这一步通常 1 分钟内给出结论：**"直接应用"** 还是 **"需要适配 N 处"**。

### 4.2 移植

```bash
cd <deepseek-harness clone>
git fetch origin tag dsh-v0.1.7-rc.3          # 只拉需要的 tag，别用 --tags
git checkout -b port/0.1.7-rc.3 dsh-v0.1.7-rc.3

git apply <repo>/patches/0001-workspace-stream-rebuild.patch
git apply --exclude='*README.i18n.yaml'        <repo>/patches/0002-responses-reasoning-replay.patch
git apply --exclude='docs/config-catalog*'     <repo>/patches/0003-docs-and-notes.patch
```

被 `--exclude` 掉的是**生成文件**，不要手工改，重新生成即可（见 4.4）。

### 4.3 测试 + 构建

```bash
node_modules/.bin/vitest run packages/api/workspace-controller/tests/ packages/llm/llm-pi-ai/tests/
```

构建两个包并**验收修复符号**——这是确认补丁真的进了产物的唯一标准：

| 产物 | 必须命中的符号 |
|---|---|
| `packages/api/workspace-controller/lib/client.js` | `REBUILD_BASE_MS`、`workspace-controller.client.generation`、`replacePinned` |
| `packages/llm/llm-pi-ai/lib/index.js` | `repeatReasoningBeforeEachToolCall` |

### 4.4 重新生成文档（`--exclude` 掉的部分）

```bash
node_modules/.bin/tsx scripts/gen-config-catalog.ts                                  # 会同时写 .md 和 .zh.md
node_modules/.bin/tsx scripts/verify-translation-pairing.ts --write docs/config-catalog.md
node_modules/.bin/tsx scripts/verify-translation-pairing.ts --write packages/llm/llm-pi-ai/README.md
node_modules/.bin/tsx scripts/gen-config-catalog.ts --check                          # 必须 up to date
```

### 4.5 提交 + 出补丁

```bash
LEFTHOOK=0 git commit -m "fix(local): port both fixes onto 0.1.7-rc.3"
git diff dsh-v0.1.7-rc.3 HEAD -- packages/api/workspace-controller > patches/0001-....patch
git diff dsh-v0.1.7-rc.3 HEAD -- packages/llm/llm-pi-ai             > patches/0002-....patch
git diff dsh-v0.1.7-rc.3 HEAD -- docs/config-catalog.md docs/config-catalog.zh.md \
  '.agents/notes/implemented/bug-fix/*'                             > patches/0003-....patch
```

**必做自检**：分支改动文件数 == 三个补丁里 `^diff --git` 的行数。
这 1 秒的检查防的是"路径 glob 漏文件导致补丁集静默少东西"这个真实风险。

### 4.6 切换 + 重启

```bash
bash scripts/switch.sh 0.1.7-rc.3     # 备份 → 装全局 → 覆盖产物 → 验收符号 → --dump-config 预检
bash scripts/restart-web.sh 30        # 延迟 30 秒自我脱离重启（让消息先发出去）
```

切换后**浏览器要硬刷新**（`Cmd+Shift+R`），否则页面还跑着旧版本的 client 代码。

> ⚠️ **装 DSH 永远要带明确版本号。** 上游的 RC 走 `next` 通道，`latest` 可能**落后**。
> `0.2.0-rc.1` 发布时 `latest` 还是 `0.1.7-rc.2`——此时执行
> `npm i -g @deepseek-ai/dsh`（或 `@latest`）会**把已升好的版本静默降级回去**，
> 而补丁产物还留着，结果是一个版本错配的混合体，非常难查。
> `switch.sh` 内部用的是 `@deepseek-ai/dsh@$VERSION`，是安全的；**手敲命令时别偷懒**。
> 升级前先 `npm view @deepseek-ai/dsh dist-tags` 看清三个通道各指向哪里。

出问题就 `bash scripts/rollback.sh 0.1.7-rc.2`。

### 4.7 检查 profile 的 bundles 是否还够用（**别跳过**）

上游会在版本之间把功能在 bundle 之间**搬家**，而且不打招呼。搬家后 profile 若仍只列老 bundle，
**功能会静默消失**——不报错、不崩溃，就是界面里少了一块。

**`probe.sh` 的第 4 步已经自动检测这一条**，所以正常流程是**读它的输出**，不用手工 diff：

```bash
bash scripts/probe.sh <新版本>
# === 4. bundle 依赖有没有「搬家」 ===
#   ✅ 没有依赖被移出任何 bundle——profile 的 bundles 不用动
# 或
#   ⚠️  @deepseek-ai/dsh-client-ui-schedule
#         从 @deepseek-ai/dsh-web-app 移出
#         现在在 @deepseek-ai/dsh-experimental-schedule-bundle   (…/schedule-bundle/package.json)
#   ⇒ 把上面「现在在」列的 bundle 加进 profile 的 dsh.profile.bundles
```

手工复核（脚本报⚠️ 或你想自己确认时）：

```bash
cd ~/work/guardian/git/deepseek-harness
git diff <旧tag> <新tag> -- packages/bundle/web-app/package.json packages/bundle/base/package.json
```

> 检测逻辑有个容易踩的坑：**不能只看 `-` 侧的行**。追加一个依赖会让上一行多一个逗号，
> 于是同一个包在 `-`/`+` 两侧都出现——只看 `-` 会把 `@deepseek-ai/dsh-settings` 这类
> **没搬家**的包报成"移出"。`probe.sh` 用 `comm -23` 减掉了 `+` 侧的名字。

**真实案例**：`0.2.0-rc.1` 把自动化任务整体挪走了，`dsh-web-app` 里**移除了**三个包

```
- @deepseek-ai/dsh-client-ui-schedule
- @deepseek-ai/dsh-schedule
- @deepseek-ai/dsh-time-context
```

它们被打包成新的可选 bundle `@deepseek-ai/dsh-experimental-schedule-bundle`（已发布到 npm）。
**不把新 bundle 加进 profile，自动化任务就会从界面消失。** 改 `~/.dsh/profiles/web/package.json`：

```json
"dsh": { "profile": { "bundles": [
  "@deepseek-ai/dsh-base",
  "@deepseek-ai/dsh-web-app",
  "@deepseek-ai/dsh-experimental-agent-team-profile",
  "@deepseek-ai/dsh-experimental-schedule-bundle",
  "dsh-plugin-tetris"
] } }
```

**顺序很重要**：先跑 `switch.sh`（它会备份旧的 profile），**再**改 bundles。
反过来的话，回滚会 restore 出一份"旧版本 + 新 bundle"的 profile，导致功能重复注册。

改完用 `dsh --profile web --dump-config`（**必须带 `--profile`**）复核：
退出码 0、行数合理、被搬走的功能关键字确实出现在输出里。行数是有用的信号——
本次 rc.2 = 1393 行 → 裸装 0.2.0-rc.1 = 1406 行 → 补 bundle 后 = 1413 行。

---

## 5. 版本矩阵

| DSH 版本 | 补丁集 | 移植分支 | 测试 |
|---|---|---|---|
| `0.2.0-rc.1`（当前，`next`） | `patches/` | `port/0.2.0-rc.1` @ `7c3e08e3e0` | 20 文件 / 417 用例 |
| `0.1.7-rc.2` | `patches/archive/0.1.7-rc.2` | `port/0.1.7-rc.2` @ `973dbf43ed` | 20 文件 / 417 用例 |
| `0.1.7-rc.1` | `patches/archive/0.1.7-rc.1` | `port/0.1.7-rc.1` @ `071343ae62` | 20 文件 / 429 用例 |
| `0.1.7-alpha.2` | `patches/archive/0.1.7-alpha.2` | `port/0.1.7` @ `58cd6438cba` | 86 + 343 用例 |

**补丁只对各自的目标版本有效**，跨版本用之前先 `probe.sh` 或 `git apply --check`。

历次升级的规模差异很大，别假设"上次很顺这次也顺"：

| 升级 | commits / 文件 | 目标包有改动吗 | 补丁冲突 |
|---|---|---|---|
| rc.2 → 0.2.0-rc.1 | 261 / 1109 | ❌ 只改 `package.json` + 无关文件 | 无 |
| alpha.2 → rc.1 | 156 / 933 | ❌ 只改 `package.json` | 无 |
| rc.1 → rc.2 | 346 / 3429 | ✅ workspace-controller 17 文件 | 仅生成文件 |

> **有两次升级的目标包源码一行没动，重建产物与上一版 `sha256` 完全相同**——`0.2.0-rc.1` 和 `0.1.7-rc.1`。
> 也就是升级只是把同样的字节拷回去。`probe.sh` §3 那一步就是为了提前发现这种情况。

> ⚠️ **别看 diff 的总行数判断规模。** `rc.2 → 0.2.0-rc.1` 号称 `−77957` 行删除，
> 其中 96% 来自**一个生成文件** `docs/persistence-schema.json`（−75173）。
> 真实代码改动只有 `+17k / −2.8k`。按目录 `--numstat` 拆开看，别被总数吓到。

---

## 6. 环境坑（都真实踩过）

1. **`git` 突然不可用**：`xcode-select -p` 指向 `Xcode.app` 但许可证未接受，`/usr/bin/git`（xcrun 壳）直接报
   `You have not agreed to the Xcode license agreements`。解法是**建一个只含 git 符号链接的目录前置 PATH**，
   不要整体前置 CLT bin（会遮蔽别的工具）：
   ```bash
   mkdir -p /tmp/clt-git && ln -sf /Library/Developer/CommandLineTools/usr/bin/git /tmp/clt-git/git
   export PATH="/tmp/clt-git:$PATH"
   ```
   注意 `verify-translation-pairing` 内部也会 shell 调 git，必须带上这个 PATH。

2. **`pnpm install` 在内存紧张时必 OOM**（`node::worker::Worker::Run` → SIGABRT 134），`--offline` 也走不通。
   务实的替代是**跳过整仓 install，只补缺失的 workspace 链接**。
   **但先确认机器是否真的超订**——别用错指标（见下一条），确认了就先解决内存，不要给一个可消除的问题建工具。

   **macOS 上判断内存压力，不要看 `free`，也不要用 `ps` 的 RSS：**
   - `vm_stat` 的 `Pages free` 低是**设计使然**（macOS 拿空闲 RAM 做缓存）。它**不是**压力指标。
   - `ps` 的 RSS **严重低报**已被压缩/映射的页。实测：Docker 的 VM 进程 `ps` 报 348 MB，
     macOS 自己的 `top` 算是 **8198 MB**——差 23 倍。用 RSS 找内存大户会得出完全错误的结论。
   - 正确的两把尺子：`top -l 1 -o mem -n 15 -stats pid,command,mem`（按 macOS 口径排序），
     以及 `vm_stat` 里 **Pages occupied by compressor** / **Pages stored in compressor** 的比值。
   - 典型超订症状：压缩器占物理内存数 GB、且「压缩前原始大小」是物理内存的 2–3 倍。
     实测这台 16 GB 的机器工作集 **44.5 GB**、压缩比 5.5:1、累计换出 **569 GB**，
     最大单一贡献是 **Docker Desktop VM 分配了 7.75 GiB 而容器只用 1.2 GB**。

3. **补 workspace 链接时，相对路径要从符号链接所在的 `@scope/` 目录算，不是从 `node_modules/` 算。**
   链接落在 `pkg/node_modules/@deepseek-ai/<name>`，正确目标形如 `../../../../llm/llm-pi-ai`（4 层）；
   写成 3 层会指向 `packages/bundle/llm/...` 这种不存在的路径，而且**断链不报错**，只在解析时表现为
   `Cannot find module`，极易误判成上游改坏了。
   ```python
   rel = os.path.relpath(target_dir, start=str(link.parent))   # 不是 start=str(node_modules)
   ```
   建完立刻自检，1 秒的事：
   ```bash
   node --input-type=module -e "import{createRequire}from'node:module';console.log(createRequire('<anchor>/package.json').resolve('<name>/package.json'))"
   ```

4. **找依赖缺口别用递归 glob**（会遍历 `node_modules` 卡死）。用 `git ls-files 'packages/**/package.json'`
   建「包名 → 目录」映射，再对每个有 `node_modules/` 的包比对 `dependencies`/`peerDependencies`；
   跳过名字含 `linux|darwin|win32|x64|arm64` 的平台包。

5. **重启脚本必须自我脱离**。由 DSH 会话触发的重启脚本，父进程就是宿主；宿主退出会带走同一进程组，
   脚本会在 `kill $OLD` 之后立刻消失（日志停在 `old pid`）。用 `os.setsid()` 重开会话后 `PGID == PID`，
   宿主被杀不再影响它。`scripts/restart-web.sh` 已修好。

6. **别走 `pnpm exec`**：每次都触发 "modules directories will be removed and reinstalled" 交互提示。
   直接调 `node_modules/.bin/tsx` / `.bin/tsc` / `.bin/tsdown`。

7. **`npm i -g` 可能因 `~/.npm` 属主问题报 EPERM**。脚本里统一带 `--cache /tmp/dsh-npm-cache` 绕开。
   代价是每次安装都会重新下载，慢几十秒；如果 `~/.npm` 属主正常可以覆盖 `DSH_NPM_CACHE` 去掉它。

8. **提交必须加 `LEFTHOOK=0`**，否则 pre-commit 的 `third-party notices` 钩子会失败：
   ```
   Error: browser notices: cannot resolve clsx from
     packages/client/ui-schedule/src/client/TaskManagerPage.tsx
   ```
   **这不是补丁问题，也不是运行时问题。** 该钩子要扫描浏览器 bundle，而我们的源码树 `node_modules`
   不完整（跳过了整仓 install）；`clsx` 只是 `ui-schedule` 的 **devDependency**，发布出去的全局 npm
   安装里根本不装它，所以运行时完全不受影响。**别去追这个错误，加 `LEFTHOOK=0` 跳过即可。**
   （linter、whitespace、translation pairing 那几个钩子是过得的，失败只出在这一条。）

9. **每次升级都会冒出新的缺失 workspace 链接**，因为是按"目标版本改过的 package.json"新引入的包。
   `0.2.0-rc.1` 新增了 **9 个**（`dsh-otel`、`dsh-skill`、`dsh-client-product-analytics`、
   `dsh-host-product-telemetry-otel`、`dsh-client-ui-settings-session-log`、`dsh-deepseek-account`、
   `dsh-experimental-schedule-bundle` 等）。**建完必须逐个主动验证能否解析**——断链不报错，
   只在真正加载时表现为 `Cannot find module`，极易误判成上游改坏了（见第 3 条）。

10. **`git ls-tree` 的 pathspec 里 `*` 不跨 `/`，而且失败是静默的。**
    `git ls-tree -r --name-only <tag> -- 'packages/bundle/*/package.json'` 返回**空**，不报错。
    而 `git grep` 用另一套匹配规则，**同样的 pathspec 能正常匹配**——别把 grep 的经验套过来。
    可靠写法是给目录前缀再加 `grep` 过滤：
    ```bash
    git ls-tree -r --name-only <tag> -- packages/bundle packages/experimental \
      | grep -E '(^packages/bundle/[^/]+/package\.json$)'
    ```

11. **`git grep -l <模式> <tree-ish> -- <路径>` 的输出路径带 `<tree-ish>:` 前缀。**
    例如 `dsh-v0.2.0-rc.1:apps/cli/package.json`。若直接拼成 `git show "$TAG:$h"` 就变成
    `tag:tag:path` → `fatal: invalid object name`，**exit 128**；在 `set -e` 的脚本里
    会把整个脚本杀掉，且**只打印出前半截结果**，看起来像"检查正常做完了一部分"。
    必须 `sed "s|^${TAG}:||"` 剥掉前缀。

> 第 10、11 条是同一个毛病：**命令的「没找到」和「没成功」长得一样**。
> 凡是要断言"X 不存在"，先确认自己的枚举是完整的、且失败会响。

---

## 7. 验证：怎么证明"前端真的拿到了修复"

仅仅"磁盘上文件对"是**推断**，不是证据。硬证据的做法：

```bash
BASE=http://127.0.0.1:3080
TOKEN=$(grep -o 'token=[A-Za-z0-9_-]*' ~/.dsh/dsh-web.log | tail -1 | cut -d= -f2)
# 1) token 换会话 cookie（首页会 303 跳转，必须跟随）
curl -s -L -c /tmp/cj -b /tmp/cj -o /tmp/idx.html "$BASE/?token=$TOKEN"
# 2) 从 boot payload 解出 workspace-controller 的 combo 地址
grep -o 'plugins/??@deepseek-ai/dsh-api-workspace-controller/client\.js&rev=[a-f0-9]*' /tmp/idx.html
# 3) 把这份代码抓下来，grep 修复符号
curl -s -g -b /tmp/cj -o /tmp/served.js "$BASE/<上面的 combo>"
grep -c REBUILD_BASE_MS /tmp/served.js          # 期望 2
```

顺便可以确认模块表里 Agent Teams / tetris 还在、宿主**只有一个实例**。

**注意**：`~/.dsh/dsh-web.log` 里有登录 token，记得 `chmod 600`。

### 读 boot payload 的两个坑（都真实踩过）

1. **boot payload 里有 74 个 combo，不是 1 个。** 除了那个 57 模块的 `bootstrap` 大批次，
   每个模块还有自己的**单模块 combo**（HMR fallback / batch 失败时的回退地址）。
   **只读第一个（最大的）combo 会得到一份残缺的模块表**——我曾据此误判
   "`dsh-api-workspace-controller` 没被加载，修复①可能失效"，其实它在自己的单模块 combo 里。
   正确做法：把所有 `plugins/??` 都抓出来取并集（本次合并后 **68 个**唯一模块）。

2. **`grep -c` 数的是匹配行数，不是匹配次数。** HTML 是压缩的，`grep -c plugins` 会返回 `1`。
   要数次数用 `grep -o ... | wc -l`，或者在 Python/脚本里用 `str.count()`。

3. **单模块 combo 不能自己拼 URL。** `/plugins/??<pkg>/client.js` 一律 404，
   连确定存在的模块也 404——**每个 combo 的 `rev` 是各自算的**，
   必须原样用 boot payload 里那一条的完整 URL（含它自己的 `&rev=`）。

> 这三条合起来是个通用教训：**验证脚本自己出错时，比不验证更危险**——它会给出
> 一份看起来有依据的错误结论。规则是：**任何"X 不在列表里"的结论，先确认自己的
> 列表是完整的**，再下判断。本次因此走了三段弯路。

---

## 8. 目录结构

```
patches/                     当前有效的补丁集（面向 README 顶部标明的版本）
patches/archive/<version>/   历史版本补丁集
scripts/probe.sh             只读：判断一次升级轻松还是艰难
scripts/switch.sh            切换全局安装到目标版本并保留修复
scripts/rollback.sh          回滚到上一版本并恢复修复
scripts/restart-web.sh       延迟 + 自我脱离的重启
```

脚本里的路径可以用环境变量覆盖，默认值按这台机器的实际布局：`DSH_GLOBAL`、`DSH_CLONE`、`DSH_BACKUP`。

---

## 9. 上游政策备忘

- **不要把时间花在提 PR 上**：PR 功能在仓库层面关闭，`CONTRIBUTING.md` 也明确拒绝。
- **报 bug 走 Discussions**，不是 Issues（Issues 关闭）。
- 想让修复真正"消失"，唯一的路径是上游自己修；`0001` 值得报，`0002` 是网关兼容、大概率被拒。
- 也可以考虑把修复做成 **profile 级插件**：`~/.dsh/profiles/<name>/` 自带 `node_modules`，
  本地插件（如 tetris）就是通过 `"link:/abs/path"` 装进去的。若补丁能以插件形式存在，
  以后升级就只剩 `npm i -g @deepseek-ai/dsh@latest`。
  ⚠️ **此路未经验证**：解析走 Node ESM resolver + `parentURL`（`app-boot/src/package-meta.ts:50`），
  profile 与 CLI 的优先级需要实测；在 profile `node_modules` 里放个假包看 `--dump-config` 加载谁即可。

## License

MIT（见 [`LICENSE`](LICENSE)）。

补丁源自 MIT 许可的 [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)
（Copyright (c) 2026 DeepSeek），本仓库以同样的 MIT 条款发布。

> 派生声明刻意放在 README 而**不是** `LICENSE` 里：GitHub 用文本模板匹配许可证，
> 在标准 MIT 正文前后插入任何段落都会让它识别失败并显示 `NOASSERTION`。
