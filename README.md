# Verdaccio Dual Seeds

在本地或 CI 上把 **stable / latest** 两套依赖 seed，跨多个 Node 版本矩阵化地灌进自建 Verdaccio 私服，让团队拉包时命中缓存，避开漫长的 uplink 穿透。

---

## 背景

团队用 Verdaccio 做 npm 代理 + 缓存。维护两套"种子"工程，用预热脚本周期性 `pnpm install`，让所有常用包的 tarball 都落到 Verdaccio 的存储上。

- `stable/`：旧版本快照（React 18 + antd 5 + Next 14 + slate 0.10x + ...）
- `latest/`：滚动最新版（React 19 + antd 6 + Next 16 + slate 0.124 + ...）

每套各有 12 个子项目：

| 子项目 | 覆盖范围 |
|---|---|
| `*-infra`    | 构建 / lint / 打包 / CSS 工具链（TypeScript、eslint、vite、webpack、rollup、esbuild、swc、turbo、Tailwind v3/v4、PostCSS 插件全家桶、cssnano、stylelint…） |
| `*-node`     | 后端、ORM、HTTP、队列、校验（Nest/Fastify/Koa、Prisma/TypeORM、bullmq、zod…） |
| `*-react`    | React 全家桶（antd、MUI、TanStack、dnd-kit、tiptap、framer-motion…） |
| `*-vue`      | Vue 生态（element-plus、ant-design-vue、naive-ui、vueuse、tanstack-vue…） |
| `*-testing`  | 测试矩阵（vitest、jest、playwright、cypress、puppeteer、msw、storybook、testcontainers、faker、fast-check、stryker…） |
| `*-ai`       | AI/LLM 生态（Vercel AI SDK、OpenAI、Anthropic、Google/Gemini、LangChain、LlamaIndex、ONNX、transformers、Pinecone/Weaviate/Qdrant/Chroma、MCP…） |
| `*-mobile`   | Expo / React Native 全家桶（expo-router、reanimated、skia、flash-list、nativewind、tamagui、firebase、navigation…） |
| `*-realtime` | 实时 / 协作（Yjs、Automerge、Liveblocks、Hocuspocus、socket.io、PartyKit、tldraw-sync、Replicache、TinyBase、Loro、y-sweet…） |
| `*-docs`     | 文档 / 站点生成（vitepress、docusaurus、nextra、astro+starlight、rspress、fumadocs、typedoc、slidev、algolia/docsearch、pagefind…） |
| `*-viz`      | 可视化全家桶：地图（mapbox-gl、maplibre-gl、deck.gl、leaflet、openlayers、pmtiles）、地理计算（turf、proj4、topojson、supercluster）、图表（echarts、chart.js、recharts、plotly、apexcharts、highcharts、nivo、visx、victory、billboard）、AntV 全套（G2/G6/L7/S2/X6/F2/G/Graphin）、3D（three.js、@react-three/\*、postprocessing、gsap）、图/网络（cytoscape、sigma、graphology、dagre、elkjs、reactflow、@xyflow）、D3 全套… |
| `*-scaffold` | 项目脚手架：`create-*`（next/vite/vue/astro/svelte/solid/qwik/t3/tauri/electron-vite/turbo/nx/cloudflare/strapi/payload）、框架 CLI（@angular/cli、@nestjs/cli、@vue/cli、nuxi、astro、@remix-run/dev、gatsby-cli、quasar、storybook、shadcn/shadcn-vue/shadcn-svelte）、模板拉取（degit、tiged、giget）、通用生成器（yo、yeoman-generator、plop、hygen、scaffdog） |
| `*-devops`   | 日常脚本/发版/部署：monorepo（nx、turbo、lerna、rush、moonrepo）、发版（changesets、semantic-release、np、release-it、release-please、conventional-changelog）、git hooks/提交（husky、lefthook、simple-git-hooks、lint-staged、commitlint、commitizen、cz-git）、脚本运行（cross-env、dotenv-cli、dotenvx、npm-run-all、concurrently、wait-on、tsx、ts-node、esno、nodemon、pm2）、文件/静态（rimraf、del-cli、shx、cpy-cli、http-server、serve、sirv-cli）、部署 CLI（vercel、netlify-cli、wrangler、firebase-tools、serverless、sst）、桌面打包（electron、electron-builder、@electron-forge/cli、@tauri-apps/cli） |

### 为什么要做 Node 版本矩阵

同一条 `^x.y.z` 范围，在不同 Node 版本下 pnpm 解析出的具体版本可能不同（受 `engines.node`、peer 策略、pnpm 版本影响）。为了让 Verdaccio 尽量覆盖"任意开发者在任意 Node 版本下可能解析到的包版本"，预热默认在 **Node 18 / 20 / 22 / 24** 下依次跑一遍。

---

## 目录结构

```
verdaccio-dual-seeds/
├── run-preheat.sh           # bash 预热脚本（macOS / Linux）
├── run-preheat.ps1          # PowerShell 预热脚本（Windows）
├── check-ranges.sh          # 诊断：扫描所有版本范围是否可解析
├── stable/
│   ├── stable-infra/package.json
│   ├── stable-node/package.json
│   ├── stable-react/package.json
│   ├── stable-vue/package.json
│   ├── stable-testing/package.json
│   ├── stable-ai/package.json
│   ├── stable-mobile/package.json
│   ├── stable-realtime/package.json
│   ├── stable-docs/package.json
│   ├── stable-viz/package.json
│   ├── stable-scaffold/package.json
│   └── stable-devops/package.json
├── latest/
│   ├── latest-infra/package.json
│   ├── latest-node/package.json
│   ├── latest-react/package.json
│   ├── latest-vue/package.json
│   ├── latest-testing/package.json
│   ├── latest-ai/package.json
│   ├── latest-mobile/package.json
│   ├── latest-realtime/package.json
│   ├── latest-docs/package.json
│   ├── latest-viz/package.json
│   ├── latest-scaffold/package.json
│   └── latest-devops/package.json
└── logs/                    # 运行时自动生成，含每项目日志 + summary JSON
```

---

## 先决条件

| 工具 | 必须？ | 用途 |
|---|---|---|
| **pnpm** ≥ 8 | 是 | 预热 install（切 Node 后可由 corepack 自动补） |
| **Node** ≥ 18 | 是 | 运行 pnpm |
| **fnm** 或 **nvm** | 默认需要 | 矩阵切换 Node 版本。也可用 `--skip-node-switch` 跳过 |
| **corepack** | 可选 | 切 Node 后自动激活 pnpm（Node ≥ 16.10 自带） |
| **python3** | 是 | `check-ranges.sh` 解析 package.json（macOS 自带） |
| **PowerShell 7+** | Windows 用户 | 跑 `run-preheat.ps1`（PS 5.1 也能跑但没有 `-Parallel`） |

安装建议：

```bash
# macOS
brew install pnpm fnm
# 并在 shell rc 里加 fnm 初始化：
# eval "$(fnm env --use-on-cd)"

# 预装四个 Node 大版本
for v in 18 20 22 24; do fnm install $v; done
```

---

## 快速开始

```bash
# 1) 扫一遍依赖范围，确保没有"写错的版本号"（~10s）
./check-ranges.sh

# 2) 全矩阵预热（4 × 24 = 96 次 pnpm install，首次会久）
./run-preheat.sh

# 3) 看 summary
jq '.' logs/summary-*.json | less
```

---

## `run-preheat.sh` / `run-preheat.ps1`

跨 Node 版本的预热主脚本。两份脚本参数名对齐，行为一致。

### 参数

| bash | PowerShell | 默认值 | 说明 |
|---|---|---|---|
| `-r, --registry <url>` | `-Registry <url>` | `https://npm.home.ueyeseas.com:8443/` | Verdaccio registry |
| `-c, --categories <list>` | `-Categories <list>` | `stable,latest` | 分类目录（逗号分隔） |
| `-n, --node-versions <list>` | `-NodeVersions <list>` | `18,20,22,24` | Node 版本矩阵 |
| `-m, --node-manager <auto\|fnm\|nvm>` | `-NodeManager` | `auto` | 版本管理器，auto 优先 fnm 回落 nvm |
| `--skip-node-switch` | `-SkipNodeSwitch` | off | 不切 Node，使用当前 shell |
| `-o, --only <list>` | `-Only <list>` | 空 | 仅跑指定子项目（逗号分隔） |
| `-p, --parallel` | `-Parallel` | off | 单个 Node 版本内并发执行子项目 |
| `-j, --jobs <n>` | —（PS 硬编码 4）| `4` | 并发路数（仅 bash） |
| `--keep-lock` | `-KeepLock` | off | 保留 `pnpm-lock.yaml` 不删 |
| `--keep-node-modules` | `-KeepNodeModules` | off | 保留 `node_modules` 不删 |
| `-h, --help` | — | | 打印用法 |

### 执行流程

1. 启动时检测 Node 版本管理器（除非 `--skip-node-switch`）
2. 外层**串行**循环 Node 版本（全局 shell 状态不能并发）
   - `fnm use --install-if-missing <ver>` 或 `nvm use` / 失败则 `nvm install`
   - 若当前 Node 下缺 `pnpm`，用 `corepack prepare pnpm@latest --activate` 兜底
   - `pnpm config set registry <REGISTRY>`
3. 内层循环分类 → 子项目，每个项目：
   - 删 `pnpm-lock.yaml` 和 `node_modules`（除非 `--keep-*`）
   - `pnpm install --no-frozen-lockfile --ignore-scripts`
   - 日志写到 `logs/node<ver>-<category>-<project>.log`
4. 所有项目跑完后写 `logs/summary-<timestamp>.json`

### 使用示例

```bash
# 全矩阵 + 单版本内并发
./run-preheat.sh --parallel -j 4

# 只跑 Node 20 和 22，验证用
./run-preheat.sh --node-versions 20,22

# 只跑某一个子项目（修包后快速复测）
./run-preheat.sh --only stable-react

# 结合：只 stable-react × Node 20
./run-preheat.sh --only stable-react --categories stable --node-versions 20

# 跳过 Node 切换（CI 里已用 matrix job 预切）
./run-preheat.sh --skip-node-switch
```

PowerShell：

```powershell
.\run-preheat.ps1                                          # 默认
.\run-preheat.ps1 -NodeVersions 20,22
.\run-preheat.ps1 -Only stable-react -Categories stable
.\run-preheat.ps1 -SkipNodeSwitch
.\run-preheat.ps1 -Parallel                                # 单 Node 版本内并发（PS7+）
```

### 日志与退出码

- 每个 `(NodeVersion, Category, Project)` 组合生成一份 `.log`
- 汇总 TSV 在终端打印为 `NodeVersion | Category | Name | Success | Seconds | LogFile`
- 结构化汇总 JSON：`logs/summary-<timestamp>.json`
- 有任意项目失败 → 退出码 `1`，其它 → `0`

---

## `check-ranges.sh`

在触发漫长预热之前，先扫所有 `package.json`，判定每条依赖的版本范围能否在 registry 上解析到。典型场景：手写 seed 时写进了 registry 里不存在的版本号（`^0.103.0` 但这个 minor 没发布过）。

### 参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| `-r, --registry <url>` | `https://npm.home.ueyeseas.com:8443/` | 要校验的 registry |
| `-c, --categories <list>` | `stable,latest` | 要扫的分类 |
| `-o, --only <list>` | 空 | 只扫指定子项目 |
| `-j, --jobs <n>` | `8` | 并发路数 |
| `-h, --help` | | 打印用法 |

### 工作原理

对每条 `(pkg, range)`，调用 `pnpm view "<pkg>@<range>" version` —— 借用 pnpm 自身的 semver 实现做判定，预发布（`^1.0.0-rc.15`）也能正确匹配。

- 跨 project 去重：多个 project 共用的范围只查一次
- 自动跳过 `workspace:` / `file:` / `git+` / `link:` / `catalog:` / `npm:` 协议
- 并发查询，600+ 依赖通常 10 秒内跑完
- 有任意 FAIL → 退出码 `1`

### 使用示例

```bash
# 默认对着 Verdaccio 扫全部
./check-ranges.sh

# 对着公网比对：用于区分"Verdaccio 没代理"还是"范围本身无解"
./check-ranges.sh --registry https://registry.npmjs.org/

# 缩窄到某个子项目
./check-ranges.sh --only stable-react

# 两步诊断：先 Verdaccio，再 npmjs，交叉看问题
./check-ranges.sh --registry https://npm.home.ueyeseas.com:8443/ --only stable-react
./check-ranges.sh --registry https://registry.npmjs.org/          --only stable-react
```

### 输出示例

```
========== check-ranges summary ==========
  ✗ 2 unresolvable range(s):
    - slate-react@^0.103.0  used by: stable-react
        registry says: npm error code E404
    - @ant-design/x-markdown@^1.0.0  used by: stable-react
        registry says: npm error code E404
```

全绿时：

```
  ✓ all 420 unique (pkg,range) resolvable on https://npm.home.ueyeseas.com:8443/
```

---

## 推荐工作流

### 改完 seed → 预热前护栏

```bash
./check-ranges.sh && ./run-preheat.sh
```

`check-ranges.sh` 10 秒出结果，把半小时才会暴露的 seed 写错问题前置掉。

### 修复某个子项目后的快速复测

```bash
# 先诊断
./check-ranges.sh --only stable-react

# 单 Node 冒烟
./run-preheat.sh --only stable-react --categories stable --node-versions 20

# 通过后补齐矩阵
./run-preheat.sh --only stable-react --categories stable
```

### Verdaccio 代理故障排查

如果某条范围在 npmjs.org 上 OK，但在 Verdaccio 上 FAIL，说明是私服的代理/缓存策略漏了版本，不是 seed 写错：

```bash
./check-ranges.sh --registry https://registry.npmjs.org/ --only <project>
./check-ranges.sh --registry https://npm.home.ueyeseas.com:8443/ --only <project>
```

两者结果差异 = Verdaccio 需要排查的条目。

### CI 集成（示意）

```yaml
# GitHub Actions 例子
jobs:
  preheat:
    strategy:
      matrix:
        node: [18, 20, 22, 24]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: ${{ matrix.node }}
      - run: corepack enable
      - run: ./check-ranges.sh
      - run: ./run-preheat.sh --skip-node-switch --node-versions ${{ matrix.node }}
```

`--skip-node-switch` 把 Node 切换交给 CI 的 matrix job，脚本只负责预热。

---

## 常见问题

### `ERR_PNPM_NO_MATCHING_VERSION`

seed 里写了 registry 上不存在的版本范围。先跑 `./check-ranges.sh` 定位；典型修复是把 `^x.y.z` 改到一个真实存在的 minor，或者同步升到其它相关包的 minor。

### `Neither fnm nor nvm found`

没装 Node 版本管理器。装一个（`brew install fnm` 最省事），或者加 `--skip-node-switch` 沿用当前 shell 的 Node。

### 切 Node 后 `pnpm: command not found`

脚本会自动用 corepack 兜底：`corepack enable && corepack prepare pnpm@latest --activate`。如果 Node < 16.10 没 corepack，需要手动 `npm i -g pnpm`。

### Windows 下 `-Parallel` 不生效

需要 PowerShell 7+。PS 5.1 下会打 WARN 并退回串行。

### 矩阵为什么不能并发 Node 版本

`nvm use` / `fnm use` 改的是当前 shell 的 `PATH` 和 `node` 二进制指向，是全局状态。并发切换会互相污染（一个 job 切到 20，另一个切到 22，之后执行哪个项目取决于谁最后赢了竞争）。所以外层矩阵**必须串行**，单版本内的项目才可并发。
