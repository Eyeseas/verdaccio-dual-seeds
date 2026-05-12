#!/usr/bin/env bash
# ============================================================
# fetch-all-versions.sh
#   两阶段全版本预热脚本：
#     Phase 1: 对 seed 项目执行 pnpm install 生成 lockfile，从中提取
#              所有包名（含传递依赖），合并 package.json 直接依赖
#     Phase 2: 对每个包查询 npm 上所有已发布版本，通过 Verdaccio 逐一
#              拉取 tarball 使其缓存全部版本
#
# 原理：npm cache add <pkg>@<version> --registry <verdaccio>
#   会让 Verdaccio 从上游拉取并缓存该版本的 tarball。
#
# 用法：
#   ./fetch-all-versions.sh                              # 默认：拉所有版本
#   ./fetch-all-versions.sh --recent 50                  # 每个包只拉最近 50 个版本
#   ./fetch-all-versions.sh --skip-prerelease            # 跳过预发布版本
#   ./fetch-all-versions.sh --jobs 8                     # 并发数（默认 4）
#   ./fetch-all-versions.sh --categories stable          # 只扫 stable 分类
#   ./fetch-all-versions.sh --only stable-node           # 只扫指定子项目
#   ./fetch-all-versions.sh --packages @nestjs/core,pg   # 只拉指定包（跳过 Phase 1）
#   ./fetch-all-versions.sh --registry https://...       # 自定义 Verdaccio 地址
#   ./fetch-all-versions.sh --upstream https://...       # 自定义上游 registry
#   ./fetch-all-versions.sh --dry-run                    # 只列出要拉的版本，不实际下载
#   ./fetch-all-versions.sh --resume                     # 跳过已成功的包（基于日志）
#   ./fetch-all-versions.sh --skip-install               # 跳过 Phase 1（复用已有 lockfile）
#   ./fetch-all-versions.sh --direct-only                # 只拉 package.json 直接依赖（不解析 lockfile）
# ============================================================

set -u

# ---- 默认参数 ----
REGISTRY="https://npm.home.ueyeseas.com:8443/"
UPSTREAM="https://registry.npmjs.org/"
CATEGORIES_RAW="stable,latest"
ONLY_RAW=""
PACKAGES_RAW=""
PARALLEL_JOBS=4
RECENT=0          # 0 = 全部版本
SKIP_PRERELEASE=0
DRY_RUN=0
RESUME=0
SKIP_INSTALL=0
DIRECT_ONLY=0

# ---- 颜色 ----
if [ -t 1 ]; then
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_CYAN=$'\033[36m'
    C_MAGENTA=$'\033[35m'
    C_DIM=$'\033[2m'
    C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_MAGENTA=""; C_DIM=""; C_RESET=""
fi

# ---- 参数解析 ----
while [ $# -gt 0 ]; do
    case "$1" in
        -r|--registry)       REGISTRY="$2"; shift 2 ;;
        --upstream)          UPSTREAM="$2"; shift 2 ;;
        -c|--categories)     CATEGORIES_RAW="$2"; shift 2 ;;
        -o|--only)           ONLY_RAW="$2"; shift 2 ;;
        --packages)          PACKAGES_RAW="$2"; shift 2 ;;
        -j|--jobs)           PARALLEL_JOBS="$2"; shift 2 ;;
        --recent)            RECENT="$2"; shift 2 ;;
        --skip-prerelease)   SKIP_PRERELEASE=1; shift ;;
        --dry-run)           DRY_RUN=1; shift ;;
        --resume)            RESUME=1; shift ;;
        --skip-install)      SKIP_INSTALL=1; shift ;;
        --direct-only)       DIRECT_ONLY=1; shift ;;
        -h|--help)           sed -n '2,24p' "$0"; exit 0 ;;
        *) echo "${C_RED}[ERROR] 未知参数: $1${C_RESET}" >&2; exit 1 ;;
    esac
done

IFS=',' read -r -a CATEGORIES <<< "$CATEGORIES_RAW"
if [ -n "$ONLY_RAW" ]; then
    IFS=',' read -r -a ONLY_PROJECTS <<< "$ONLY_RAW"
else
    ONLY_PROJECTS=()
fi
if [ -n "$PACKAGES_RAW" ]; then
    IFS=',' read -r -a FILTER_PACKAGES <<< "$PACKAGES_RAW"
else
    FILTER_PACKAGES=()
fi

# ---- preflight ----
command -v npm >/dev/null 2>&1 || { echo "${C_RED}[ERROR] 需要 npm${C_RESET}" >&2; exit 1; }
command -v pnpm >/dev/null 2>&1 || { echo "${C_RED}[ERROR] 需要 pnpm${C_RESET}" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "${C_RED}[ERROR] 需要 python3${C_RESET}" >&2; exit 1; }

project_allowed() {
    local name="$1"
    [ "${#ONLY_PROJECTS[@]}" -eq 0 ] && return 0
    local w; for w in "${ONLY_PROJECTS[@]}"; do [ "$w" = "$name" ] && return 0; done
    return 1
}

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$BASE_DIR/logs"
STAMP="$(date +%Y%m%d-%H%M%S)"
PROGRESS_DIR="$LOG_DIR/fetch-all-versions"
DONE_FILE="$PROGRESS_DIR/.done-packages"

mkdir -p "$LOG_DIR" "$PROGRESS_DIR"
[ "$RESUME" -eq 1 ] && [ ! -f "$DONE_FILE" ] && : > "$DONE_FILE"

# ============================================================
# Phase 1: 生成 lockfile 并提取所有包名（含传递依赖）
# ============================================================

PKGS_FILE=$(mktemp)
trap 'rm -f "$PKGS_FILE"' EXIT

if [ "${#FILTER_PACKAGES[@]}" -gt 0 ]; then
    # 手动指定包名，跳过 Phase 1
    printf '%s\n' "${FILTER_PACKAGES[@]}" > "$PKGS_FILE"
else
    echo "${C_CYAN}══════════════════════════════════════════${C_RESET}"
    echo "${C_CYAN}  Phase 1: 收集包名（含传递依赖）${C_RESET}"
    echo "${C_CYAN}══════════════════════════════════════════${C_RESET}"
    echo

    DIRECT_PKGS_FILE=$(mktemp)
    LOCKFILE_PKGS_FILE=$(mktemp)
    trap 'rm -f "$PKGS_FILE" "$DIRECT_PKGS_FILE" "$LOCKFILE_PKGS_FILE"' EXIT

    # Step 1a: 从 package.json 收集直接依赖
    for cat in "${CATEGORIES[@]}"; do
        cat_path="$BASE_DIR/$cat"
        [ -d "$cat_path" ] || continue
        for pj in "$cat_path"/*/package.json; do
            [ -f "$pj" ] || continue
            project="$(basename "$(dirname "$pj")")"
            project_allowed "$project" || continue
            python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
deps = {}
deps.update(data.get('dependencies', {}) or {})
deps.update(data.get('devDependencies', {}) or {})
for name in sorted(deps.keys()):
    print(name)
" "$pj"
        done
    done | sort -u > "$DIRECT_PKGS_FILE"

    DIRECT_COUNT=$(wc -l < "$DIRECT_PKGS_FILE" | tr -d ' ')
    echo "${C_GREEN}[info] 直接依赖: $DIRECT_COUNT 个唯一包${C_RESET}"

    if [ "$DIRECT_ONLY" -eq 1 ]; then
        cp "$DIRECT_PKGS_FILE" "$PKGS_FILE"
        echo "${C_YELLOW}[info] --direct-only 模式，跳过 lockfile 解析${C_RESET}"
    else
        # Step 1b: 对每个子项目执行 pnpm install 生成 lockfile
        if [ "$SKIP_INSTALL" -eq 0 ]; then
            echo "${C_CYAN}[info] 执行 pnpm install 生成 lockfile...${C_RESET}"
            pnpm config set registry "$REGISTRY" >/dev/null 2>&1

            for cat in "${CATEGORIES[@]}"; do
                cat_path="$BASE_DIR/$cat"
                [ -d "$cat_path" ] || continue
                for proj_dir in "$cat_path"/*/; do
                    [ -f "$proj_dir/package.json" ] || continue
                    project="$(basename "$proj_dir")"
                    project_allowed "$project" || continue

                    echo "${C_DIM}  installing $project ...${C_RESET}"
                    (
                        cd "$proj_dir"
                        rm -f pnpm-lock.yaml
                        pnpm install --no-frozen-lockfile --ignore-scripts --lockfile-only \
                            >"$LOG_DIR/phase1-${project}.log" 2>&1
                    )
                    if [ $? -eq 0 ]; then
                        echo "${C_GREEN}  ✓ $project${C_RESET}"
                    else
                        echo "${C_YELLOW}  △ $project (install 失败，将仅使用直接依赖)${C_RESET}"
                    fi
                done
            done
        else
            echo "${C_YELLOW}[info] --skip-install 模式，复用已有 lockfile${C_RESET}"
        fi

        # Step 1c: 从 pnpm-lock.yaml 提取所有包名
        echo "${C_CYAN}[info] 解析 lockfile 提取传递依赖...${C_RESET}"

        for cat in "${CATEGORIES[@]}"; do
            cat_path="$BASE_DIR/$cat"
            [ -d "$cat_path" ] || continue
            for lockfile in "$cat_path"/*/pnpm-lock.yaml; do
                [ -f "$lockfile" ] || continue
                project="$(basename "$(dirname "$lockfile")")"
                project_allowed "$project" || continue

                python3 -c "
import sys, re

lockfile_path = sys.argv[1]
packages = set()

with open(lockfile_path, 'r') as f:
    content = f.read()

# pnpm lockfile v9+ (lockfileVersion: '9.0') 格式:
#   packages:
#     '@nestjs/common@10.3.0':
#     'rxjs@7.8.1':
# 也可能是:
#   packages:
#     '@scope/name': {version: ...}
# 或 snapshots 区域

# 匹配 packages 区域中的包名@版本
# 格式1 (v9): '@scope/name@version': 或 'name@version':
pattern_v9 = re.compile(r\"^\\s+'?(@?[^@'\\s][^@']*?)@[^':]+\", re.MULTILINE)

# 格式2 (v6/v5): /@scope/name/version: 或 /name/version:
pattern_v5 = re.compile(r'^\\s+/(@?[^/\\s]+(?:/[^/]+)?)/[\\d]', re.MULTILINE)

# 格式3 (v6 flat): 'package@version' as key under packages:
pattern_v6_flat = re.compile(r\"^\\s+(?:'|\\\")?(@?[a-zA-Z0-9][-a-zA-Z0-9._]*(?:/[a-zA-Z0-9][-a-zA-Z0-9._]*)?)@\", re.MULTILINE)

in_packages = False
for line in content.split('\\n'):
    stripped = line.strip()

    # 检测进入 packages: 或 snapshots: 区域
    if stripped == 'packages:' or stripped == 'snapshots:':
        in_packages = True
        continue
    # 检测离开（遇到新的顶级 key）
    if in_packages and line and not line[0].isspace() and ':' in line:
        in_packages = False
        continue

    if not in_packages:
        continue

    # 尝试匹配 v9 格式: '  @scope/name@version:'
    m = re.match(r\"^\\s+'?(@?[a-zA-Z0-9][-a-zA-Z0-9._]*(?:/[a-zA-Z0-9][-a-zA-Z0-9._]*)?)@\", line)
    if m:
        packages.add(m.group(1))
        continue

    # 尝试匹配 v5/v6 格式: '  /@scope/name/version:'
    m = re.match(r'^\\s+/(@?[^/\\s]+(?:/[^/\\s]+)?)/[\\d]', line)
    if m:
        packages.add(m.group(1))
        continue

for pkg in sorted(packages):
    # 过滤掉明显不是包名的条目
    if pkg and not pkg.startswith('file:') and not pkg.startswith('link:'):
        print(pkg)
" "$lockfile"
            done
        done | sort -u > "$LOCKFILE_PKGS_FILE"

        LOCKFILE_COUNT=$(wc -l < "$LOCKFILE_PKGS_FILE" | tr -d ' ')
        echo "${C_GREEN}[info] lockfile 中提取到: $LOCKFILE_COUNT 个唯一包${C_RESET}"

        # Step 1d: 合并直接依赖 + lockfile 传递依赖
        sort -u "$DIRECT_PKGS_FILE" "$LOCKFILE_PKGS_FILE" > "$PKGS_FILE"
    fi
fi

TOTAL_PKGS=$(wc -l < "$PKGS_FILE" | tr -d ' ')

if [ "$TOTAL_PKGS" -eq 0 ]; then
    echo "${C_YELLOW}[WARN] 没有找到任何包${C_RESET}"
    exit 0
fi

# ============================================================
# Phase 2: 对每个包拉取所有版本
# ============================================================

echo
echo "${C_CYAN}══════════════════════════════════════════${C_RESET}"
echo "${C_CYAN}  Phase 2: 拉取全部版本${C_RESET}"
echo "${C_CYAN}══════════════════════════════════════════${C_RESET}"
echo "${C_GREEN}  verdaccio : $REGISTRY${C_RESET}"
echo "${C_GREEN}  upstream  : $UPSTREAM${C_RESET}"
echo "${C_GREEN}  packages  : $TOTAL_PKGS unique (直接 + 传递)${C_RESET}"
echo "${C_GREEN}  jobs      : $PARALLEL_JOBS${C_RESET}"
echo "${C_GREEN}  recent    : $([ "$RECENT" -eq 0 ] && echo all || echo "$RECENT")${C_RESET}"
echo "${C_GREEN}  prerelease: $([ "$SKIP_PRERELEASE" -eq 1 ] && echo skip || echo include)${C_RESET}"
echo "${C_GREEN}  dry-run   : $([ "$DRY_RUN" -eq 1 ] && echo yes || echo no)${C_RESET}"
echo "${C_GREEN}  resume    : $([ "$RESUME" -eq 1 ] && echo yes || echo no)${C_RESET}"
echo

# ---- 单包拉取函数 ----
fetch_all_for_package() {
    local pkg="$1"
    local registry="$2"
    local upstream="$3"
    local recent="$4"
    local skip_pre="$5"
    local dry_run="$6"
    local resume="$7"
    local done_file="$8"
    local progress_dir="$9"

    # resume 模式：跳过已完成的包
    if [ "$resume" -eq 1 ] && grep -qxF "$pkg" "$done_file" 2>/dev/null; then
        return 0
    fi

    local pkg_log="$progress_dir/${pkg//\//__}.log"

    # 查询所有版本
    local versions_json
    versions_json=$(npm view "$pkg" versions --json --registry "$upstream" 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$versions_json" ]; then
        echo "${C_RED}[FAIL] $pkg — 无法获取版本列表${C_RESET}"
        echo "FAIL: cannot fetch version list" > "$pkg_log"
        return 1
    fi

    # 过滤版本
    local versions
    versions=$(python3 -c "
import json, sys, re

raw = sys.stdin.read().strip()
data = json.loads(raw)
if isinstance(data, str):
    data = [data]

recent = int(sys.argv[1])
skip_pre = int(sys.argv[2])

if skip_pre:
    data = [v for v in data if '-' not in v]

if recent > 0:
    data = data[-recent:]

for v in data:
    print(v)
" "$recent" "$skip_pre" <<< "$versions_json")

    local ver_count
    ver_count=$(echo "$versions" | grep -c . || echo 0)

    if [ "$ver_count" -eq 0 ]; then
        echo "${C_YELLOW}[WARN] $pkg — 过滤后无版本${C_RESET}"
        return 0
    fi

    if [ "$dry_run" -eq 1 ]; then
        echo "${C_CYAN}[dry-run] $pkg — $ver_count versions${C_RESET}"
        echo "$versions" | sed "s/^/  $pkg@/"
        return 0
    fi

    echo "${C_CYAN}[fetch] $pkg — $ver_count versions${C_RESET}"

    local ok=0 fail=0
    while IFS= read -r ver; do
        [ -z "$ver" ] && continue
        if npm cache add "${pkg}@${ver}" --registry "$registry" >>"$pkg_log" 2>&1; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
        fi
    done <<< "$versions"

    if [ "$fail" -eq 0 ]; then
        echo "${C_GREEN}  ✓ $pkg — $ok/$ver_count OK${C_RESET}"
        if [ "$resume" -eq 1 ]; then
            # 加锁写入
            if command -v flock &>/dev/null; then
                { flock 9; echo "$pkg" >> "$done_file"; } 9>>"$done_file.lock"
            else
                echo "$pkg" >> "$done_file"
            fi
        fi
    else
        echo "${C_YELLOW}  △ $pkg — ok=$ok fail=$fail / $ver_count${C_RESET}"
    fi
}

export -f fetch_all_for_package
export C_RED C_GREEN C_YELLOW C_CYAN C_MAGENTA C_DIM C_RESET

TOTAL_START="$(date +%s)"

cat "$PKGS_FILE" | xargs -P "$PARALLEL_JOBS" -I{} bash -c \
    'fetch_all_for_package "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"' \
    _ {} "$REGISTRY" "$UPSTREAM" "$RECENT" "$SKIP_PRERELEASE" "$DRY_RUN" "$RESUME" "$DONE_FILE" "$PROGRESS_DIR"

TOTAL_END="$(date +%s)"
TOTAL_ELAPSED=$(( TOTAL_END - TOTAL_START ))

# ---- 汇总 ----
echo
echo "${C_MAGENTA}══════════════════════════════════════════${C_RESET}"
echo "${C_MAGENTA}  fetch-all-versions 完成${C_RESET}"
echo "${C_MAGENTA}  总包数: $TOTAL_PKGS${C_RESET}"
echo "${C_MAGENTA}  耗时: ${TOTAL_ELAPSED}s${C_RESET}"
echo "${C_MAGENTA}  日志: $PROGRESS_DIR${C_RESET}"

if [ "$RESUME" -eq 1 ] && [ -f "$DONE_FILE" ]; then
    DONE_COUNT=$(wc -l < "$DONE_FILE" | tr -d ' ')
    echo "${C_MAGENTA}  已完成: $DONE_COUNT / $TOTAL_PKGS${C_RESET}"
fi

echo "${C_MAGENTA}══════════════════════════════════════════${C_RESET}"
echo

# 导出包列表供参考
PKGS_LIST_OUT="$LOG_DIR/all-packages-$STAMP.txt"
cp "$PKGS_FILE" "$PKGS_LIST_OUT"
echo "${C_GREEN}包列表已保存: $PKGS_LIST_OUT${C_RESET}"

rm -f "$DONE_FILE.lock"
