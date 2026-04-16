#!/usr/bin/env bash
# ============================================================
# Verdaccio preheat script (Bash 版本)
#   - 在多个 Node 版本 (18 / 20 / 22 / 24) 下串行运行，覆盖不同 engines
#     可能解析出来的包版本，把它们都灌进 Verdaccio 缓存
#   - 每个 Node 版本内部：遍历 stable/ 与 latest/ 下的子项目执行 pnpm install
#   - 单个项目失败不会中断整体流程
#   - 输出每 Node 版本 / 每项目日志、耗时统计与汇总 JSON
# 用法：
#   ./run-preheat.sh                                    # 默认 18,20,22,24 四个 Node 版本全跑
#   ./run-preheat.sh --node-versions 20,22              # 只跑指定的 Node 版本
#   ./run-preheat.sh --node-manager fnm                 # 强制使用 fnm（默认 auto: fnm -> nvm）
#   ./run-preheat.sh --skip-node-switch                 # 不切 Node，使用当前 shell 的 node
#   ./run-preheat.sh --categories stable                # 只跑 stable 分类
#   ./run-preheat.sh --categories stable,latest         # 多个分类
#   ./run-preheat.sh --only stable-react                # 只跑指定子项目（可叠加 --categories 缩小范围）
#   ./run-preheat.sh --only stable-react,latest-node    # 多个子项目
#   ./run-preheat.sh --parallel                         # 单个 Node 版本内并发执行
#   ./run-preheat.sh --registry https://...             # 自定义 registry
#   ./run-preheat.sh --keep-lock                        # 保留 pnpm-lock.yaml
#   ./run-preheat.sh --keep-node-modules                # 保留 node_modules
# ============================================================

set -u

# ---- 默认参数 ----
REGISTRY="https://npm.home.ueyeseas.com:8443/"
CATEGORIES_RAW="stable,latest"
NODE_VERSIONS_RAW="18,20,22,24"
NODE_MANAGER="auto"        # auto | fnm | nvm
SKIP_NODE_SWITCH=0
PARALLEL=0
KEEP_LOCK=0
KEEP_NODE_MODULES=0
PARALLEL_JOBS=4
ONLY_RAW=""                # 空=不过滤；逗号分隔子项目名，如 "stable-react,latest-node"

# ---- 颜色 ----
if [ -t 1 ]; then
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_CYAN=$'\033[36m'
    C_MAGENTA=$'\033[35m'
    C_BLUE=$'\033[34m'
    C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_MAGENTA=""; C_BLUE=""; C_RESET=""
fi

# ---- 参数解析 ----
while [ $# -gt 0 ]; do
    case "$1" in
        -r|--registry)
            REGISTRY="$2"; shift 2 ;;
        -c|--categories)
            CATEGORIES_RAW="$2"; shift 2 ;;
        -n|--node-versions)
            NODE_VERSIONS_RAW="$2"; shift 2 ;;
        -m|--node-manager)
            NODE_MANAGER="$2"; shift 2 ;;
        --skip-node-switch)
            SKIP_NODE_SWITCH=1; shift ;;
        -o|--only)
            ONLY_RAW="$2"; shift 2 ;;
        -p|--parallel)
            PARALLEL=1; shift ;;
        -j|--jobs)
            PARALLEL_JOBS="$2"; shift 2 ;;
        --keep-lock)
            KEEP_LOCK=1; shift ;;
        --keep-node-modules)
            KEEP_NODE_MODULES=1; shift ;;
        -h|--help)
            sed -n '2,22p' "$0"; exit 0 ;;
        *)
            echo "${C_RED}[ERROR] 未知参数: $1${C_RESET}" >&2
            exit 1 ;;
    esac
done

# 将逗号分隔的列表转成数组
IFS=',' read -r -a CATEGORIES <<< "$CATEGORIES_RAW"
IFS=',' read -r -a NODE_VERSIONS <<< "$NODE_VERSIONS_RAW"
if [ -n "$ONLY_RAW" ]; then
    IFS=',' read -r -a ONLY_PROJECTS <<< "$ONLY_RAW"
else
    ONLY_PROJECTS=()
fi

# 判断项目名是否在 --only 白名单里（空白名单视为放行）
project_allowed() {
    local name="$1"
    if [ "${#ONLY_PROJECTS[@]}" -eq 0 ]; then
        return 0
    fi
    local wanted
    for wanted in "${ONLY_PROJECTS[@]}"; do
        if [ "$wanted" = "$name" ]; then
            return 0
        fi
    done
    return 1
}

BASE_DIR="$(pwd)"
LOG_DIR="$BASE_DIR/logs"
STAMP="$(date +%Y%m%d-%H%M%S)"
SUMMARY_FILE="$LOG_DIR/.summary-$STAMP.tsv"   # 中间结果 TSV: node_ver\tcat\tname\tok\tseconds\tlog

mkdir -p "$LOG_DIR"
: > "$SUMMARY_FILE"

# ---- Node manager 探测 ----
detect_node_manager() {
    # 优先 fnm（跨平台单二进制、快），fallback nvm
    if command -v fnm >/dev/null 2>&1; then
        echo "fnm"
        return 0
    fi
    # nvm 是 shell 函数，需要 source
    local nvm_dir="${NVM_DIR:-$HOME/.nvm}"
    if [ -s "$nvm_dir/nvm.sh" ]; then
        echo "nvm"
        return 0
    fi
    echo ""
}

if [ "$SKIP_NODE_SWITCH" -eq 0 ]; then
    if [ "$NODE_MANAGER" = "auto" ]; then
        NODE_MANAGER="$(detect_node_manager)"
        if [ -z "$NODE_MANAGER" ]; then
            echo "${C_RED}[ERROR] 未检测到 fnm 或 nvm。请安装其一，或使用 --skip-node-switch${C_RESET}" >&2
            exit 1
        fi
    fi

    # 若选了 nvm，提前 source
    if [ "$NODE_MANAGER" = "nvm" ]; then
        export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
        if [ ! -s "$NVM_DIR/nvm.sh" ]; then
            echo "${C_RED}[ERROR] 无法在 $NVM_DIR/nvm.sh 找到 nvm 脚本${C_RESET}" >&2
            exit 1
        fi
        # shellcheck disable=SC1091
        . "$NVM_DIR/nvm.sh"
    fi
fi

# ---- 切换 Node 版本 ----
switch_node_version() {
    local target="$1"

    if [ "$SKIP_NODE_SWITCH" -eq 1 ]; then
        echo "${C_YELLOW}[skip] --skip-node-switch 开启，沿用当前 Node $(node -v 2>/dev/null || echo '未知')${C_RESET}"
        return 0
    fi

    case "$NODE_MANAGER" in
        fnm)
            # fnm 支持 `fnm use 20` 解析为已安装的最新 20.x，未装时加 --install-if-missing
            if ! fnm use --install-if-missing "$target" >/dev/null 2>&1; then
                echo "${C_RED}[ERROR] fnm use $target 失败${C_RESET}" >&2
                return 1
            fi
            ;;
        nvm)
            # nvm 直接接 major 即可，找不到时尝试安装
            if ! nvm use "$target" >/dev/null 2>&1; then
                echo "${C_YELLOW}[info] 本地未安装 Node $target，尝试 nvm install${C_RESET}"
                if ! nvm install "$target" >/dev/null 2>&1; then
                    echo "${C_RED}[ERROR] nvm install $target 失败${C_RESET}" >&2
                    return 1
                fi
                nvm use "$target" >/dev/null 2>&1 || return 1
            fi
            ;;
        *)
            echo "${C_RED}[ERROR] 未知 NODE_MANAGER=$NODE_MANAGER${C_RESET}" >&2
            return 1 ;;
    esac
    return 0
}

# ---- 确保当前 Node 环境下有 pnpm ----
ensure_pnpm() {
    if command -v pnpm >/dev/null 2>&1; then
        return 0
    fi
    echo "${C_YELLOW}[info] 当前 Node 环境缺少 pnpm，尝试通过 corepack 激活${C_RESET}"
    if ! command -v corepack >/dev/null 2>&1; then
        echo "${C_RED}[ERROR] 未找到 corepack，请手动在此 Node 下安装 pnpm (npm i -g pnpm)${C_RESET}" >&2
        return 1
    fi
    corepack enable >/dev/null 2>&1 || true
    if ! corepack prepare pnpm@latest --activate >/dev/null 2>&1; then
        echo "${C_RED}[ERROR] corepack prepare pnpm@latest 失败${C_RESET}" >&2
        return 1
    fi
    command -v pnpm >/dev/null 2>&1
}

# ---- 单项目预热函数 ----
invoke_preheat() {
    local node_ver="$1"
    local category="$2"
    local folder_path="$3"
    local folder_name="$4"

    local log_file="$LOG_DIR/node${node_ver}-${category}-${folder_name}.log"
    local start_ts end_ts elapsed exit_code ok tag color

    start_ts="$(date +%s)"
    echo "${C_CYAN}>>> [node${node_ver}/${category}/${folder_name}] start${C_RESET}"

    (
        cd "$folder_path" || exit 1

        if [ "$KEEP_LOCK" -eq 0 ]; then
            rm -f pnpm-lock.yaml package-lock.json yarn.lock
        fi
        if [ "$KEEP_NODE_MODULES" -eq 0 ]; then
            rm -rf node_modules
        fi

        pnpm install --no-frozen-lockfile --ignore-scripts 2>&1 | tee "$log_file"
        exit "${PIPESTATUS[0]}"
    )
    exit_code=$?

    end_ts="$(date +%s)"
    elapsed=$(( end_ts - start_ts ))

    if [ "$exit_code" -eq 0 ]; then
        ok=1; tag="OK"; color="$C_GREEN"
    else
        ok=0; tag="FAIL"; color="$C_RED"
    fi
    echo "${color}<<< [node${node_ver}/${category}/${folder_name}] ${tag}  elapsed=${elapsed}s${C_RESET}"
    echo

    # 追加到汇总文件（多进程并发时使用 flock 防止竞争）
    {
        flock 9
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$node_ver" "$category" "$folder_name" "$ok" "$elapsed" "$log_file" >> "$SUMMARY_FILE"
    } 9>>"$SUMMARY_FILE.lock"
}

export -f invoke_preheat
export LOG_DIR KEEP_LOCK KEEP_NODE_MODULES SUMMARY_FILE
export C_RED C_GREEN C_YELLOW C_CYAN C_MAGENTA C_BLUE C_RESET

# ---- 启动横幅 ----
echo "${C_GREEN}========================================${C_RESET}"
echo "${C_GREEN}Verdaccio preheat | registry = $REGISTRY${C_RESET}"
echo "${C_GREEN}node versions: ${NODE_VERSIONS[*]}    node manager: ${NODE_MANAGER}    skip-switch=${SKIP_NODE_SWITCH}${C_RESET}"
echo "${C_GREEN}categories   : ${CATEGORIES[*]}    parallel=$PARALLEL    jobs=$PARALLEL_JOBS${C_RESET}"
if [ "${#ONLY_PROJECTS[@]}" -gt 0 ]; then
    echo "${C_GREEN}only projects: ${ONLY_PROJECTS[*]}${C_RESET}"
fi
echo "${C_GREEN}log dir      : $LOG_DIR${C_RESET}"
echo "${C_GREEN}========================================${C_RESET}"
echo

# ---- 主循环：外层 Node 版本矩阵（串行），内层分类 + 项目（可并发） ----
TOTAL_START="$(date +%s)"

for node_ver in "${NODE_VERSIONS[@]}"; do
    echo "${C_BLUE}################################################${C_RESET}"
    echo "${C_BLUE}#  Node matrix: switching to Node ${node_ver}${C_RESET}"
    echo "${C_BLUE}################################################${C_RESET}"

    if ! switch_node_version "$node_ver"; then
        echo "${C_RED}[WARN] 跳过 Node ${node_ver}（切换失败）${C_RESET}"
        # 将所有子项目记为失败，便于 summary 体现（尊重 --only 过滤）
        for cat in "${CATEGORIES[@]}"; do
            cat_path="$BASE_DIR/$cat"
            [ -d "$cat_path" ] || continue
            while IFS= read -r -d '' d; do
                fname="$(basename "$d")"
                project_allowed "$fname" || continue
                printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                    "$node_ver" "$cat" "$fname" "0" "0" \
                    "$LOG_DIR/node${node_ver}-switch-failed.log" >> "$SUMMARY_FILE"
                echo "Node ${node_ver} switch failed" > "$LOG_DIR/node${node_ver}-switch-failed.log"
            done < <(find "$cat_path" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
        done
        continue
    fi

    if ! ensure_pnpm; then
        echo "${C_RED}[WARN] Node ${node_ver} 下 pnpm 不可用，跳过${C_RESET}"
        continue
    fi

    current_node="$(node -v 2>/dev/null || echo unknown)"
    current_pnpm="$(pnpm --version 2>/dev/null || echo unknown)"
    echo "${C_GREEN}[info] active node=${current_node}  pnpm=${current_pnpm}${C_RESET}"
    pnpm config set registry "$REGISTRY" >/dev/null

    for cat in "${CATEGORIES[@]}"; do
        cat_path="$BASE_DIR/$cat"
        if [ ! -d "$cat_path" ]; then
            echo "${C_YELLOW}[WARN] 跳过缺失分类: $cat_path${C_RESET}"
            continue
        fi

        folders=()
        while IFS= read -r -d '' d; do
            fname="$(basename "$d")"
            project_allowed "$fname" || continue
            folders+=("$d")
        done < <(find "$cat_path" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

        if [ "${#folders[@]}" -eq 0 ]; then
            if [ "${#ONLY_PROJECTS[@]}" -gt 0 ]; then
                echo "${C_YELLOW}[WARN] 分类 $cat 下没有匹配 --only (${ONLY_RAW}) 的子项目${C_RESET}"
            else
                echo "${C_YELLOW}[WARN] 分类 $cat 下没有子项目${C_RESET}"
            fi
            continue
        fi

        if [ "$PARALLEL" -eq 1 ] && [ "${#folders[@]}" -gt 1 ]; then
            printf '%s\0' "${folders[@]}" | \
                xargs -0 -n 1 -P "$PARALLEL_JOBS" -I{} \
                bash -c 'invoke_preheat "$1" "$2" "$3" "$(basename "$3")"' _ "$node_ver" "$cat" {}
        else
            for f in "${folders[@]}"; do
                invoke_preheat "$node_ver" "$cat" "$f" "$(basename "$f")"
            done
        fi
    done
done

TOTAL_END="$(date +%s)"
TOTAL_ELAPSED=$(( TOTAL_END - TOTAL_START ))
rm -f "$SUMMARY_FILE.lock"

# ---- 汇总输出 ----
echo
echo "${C_MAGENTA}========== preheat summary ==========${C_RESET}"

if [ -s "$SUMMARY_FILE" ]; then
    {
        printf 'NodeVersion\tCategory\tName\tSuccess\tSeconds\tLogFile\n'
        sort -t$'\t' -k1,1 -k2,2 -k3,3 "$SUMMARY_FILE" | \
            awk -F'\t' '{
                printf "%s\t%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, ($4=="1"?"True":"False"), $5, $6
            }'
    } | column -t -s $'\t'
fi

ok_count=$(awk -F'\t' '$4=="1"{n++} END{print n+0}' "$SUMMARY_FILE")
fail_count=$(awk -F'\t' '$4=="0"{n++} END{print n+0}' "$SUMMARY_FILE")

echo
echo "${C_MAGENTA}total=${TOTAL_ELAPSED}s  ok=${ok_count}  fail=${fail_count}${C_RESET}"

if [ "$fail_count" -gt 0 ]; then
    echo "${C_RED}failures:${C_RESET}"
    awk -F'\t' '$4=="0"{printf "  - node%s/%s/%s  ->  %s\n", $1, $2, $3, $6}' "$SUMMARY_FILE" | \
        while IFS= read -r line; do
            echo "${C_RED}${line}${C_RESET}"
        done
fi

# ---- 写出 JSON 汇总 ----
SUMMARY_JSON="$LOG_DIR/summary-$STAMP.json"
{
    printf '['
    first=1
    while IFS=$'\t' read -r nv c n ok sec log; do
        [ -z "$nv" ] && continue
        if [ "$first" -eq 1 ]; then first=0; else printf ','; fi
        esc_log="${log//\\/\\\\}"
        esc_log="${esc_log//\"/\\\"}"
        if [ "$ok" = "1" ]; then ok_json="true"; else ok_json="false"; fi
        printf '\n  {"NodeVersion":"%s","Category":"%s","Name":"%s","Success":%s,"Seconds":%s,"LogFile":"%s"}' \
            "$nv" "$c" "$n" "$ok_json" "$sec" "$esc_log"
    done < <(sort -t$'\t' -k1,1 -k2,2 -k3,3 "$SUMMARY_FILE")
    printf '\n]\n'
} > "$SUMMARY_JSON"

echo
echo "${C_GREEN}summary saved: $SUMMARY_JSON${C_RESET}"

rm -f "$SUMMARY_FILE"
cd "$BASE_DIR" || true

if [ "$fail_count" -gt 0 ]; then
    exit 1
else
    exit 0
fi
