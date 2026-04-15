#!/usr/bin/env bash
# ============================================================
# Verdaccio preheat script (Bash 版本)
#   - 遍历 stable/ 与 latest/ 下的子项目，执行 pnpm install
#   - 单个项目失败不会中断整体流程
#   - 输出每项目日志、耗时统计与汇总 JSON
# 用法：
#   ./run-preheat.sh                              # 默认串行，全部分类
#   ./run-preheat.sh --categories stable          # 仅 stable
#   ./run-preheat.sh --categories stable,latest   # 多个分类
#   ./run-preheat.sh --parallel                   # 并发执行（同一分类内）
#   ./run-preheat.sh --registry https://...       # 自定义 registry
#   ./run-preheat.sh --keep-lock                  # 保留 pnpm-lock.yaml
#   ./run-preheat.sh --keep-node-modules          # 保留 node_modules
# ============================================================

set -u

# ---- 默认参数 ----
REGISTRY="https://npm.home.ueyeseas.com:8443/"
CATEGORIES_RAW="stable,latest"
PARALLEL=0
KEEP_LOCK=0
KEEP_NODE_MODULES=0
PARALLEL_JOBS=4

# ---- 颜色 ----
if [ -t 1 ]; then
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_CYAN=$'\033[36m'
    C_MAGENTA=$'\033[35m'
    C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_MAGENTA=""; C_RESET=""
fi

# ---- 参数解析 ----
while [ $# -gt 0 ]; do
    case "$1" in
        -r|--registry)
            REGISTRY="$2"; shift 2 ;;
        -c|--categories)
            CATEGORIES_RAW="$2"; shift 2 ;;
        -p|--parallel)
            PARALLEL=1; shift ;;
        -j|--jobs)
            PARALLEL_JOBS="$2"; shift 2 ;;
        --keep-lock)
            KEEP_LOCK=1; shift ;;
        --keep-node-modules)
            KEEP_NODE_MODULES=1; shift ;;
        -h|--help)
            sed -n '2,16p' "$0"; exit 0 ;;
        *)
            echo "${C_RED}[ERROR] 未知参数: $1${C_RESET}" >&2
            exit 1 ;;
    esac
done

# 将逗号分隔的分类列表转成数组
IFS=',' read -r -a CATEGORIES <<< "$CATEGORIES_RAW"

BASE_DIR="$(pwd)"
LOG_DIR="$BASE_DIR/logs"
STAMP="$(date +%Y%m%d-%H%M%S)"
SUMMARY_FILE="$LOG_DIR/.summary-$STAMP.tsv"   # 中间结果（TSV：cat\tname\tok\tseconds\tlog）

mkdir -p "$LOG_DIR"
: > "$SUMMARY_FILE"

# ---- preflight ----
if ! command -v pnpm >/dev/null 2>&1; then
    echo "${C_RED}[ERROR] 未找到 pnpm，请先安装：npm i -g pnpm${C_RESET}" >&2
    exit 1
fi

echo "${C_GREEN}========================================${C_RESET}"
echo "${C_GREEN}Verdaccio preheat | registry = $REGISTRY${C_RESET}"
echo "${C_GREEN}pnpm version : $(pnpm --version)${C_RESET}"
echo "${C_GREEN}categories   : ${CATEGORIES[*]}  parallel=$PARALLEL  jobs=$PARALLEL_JOBS${C_RESET}"
echo "${C_GREEN}log dir      : $LOG_DIR${C_RESET}"
echo "${C_GREEN}========================================${C_RESET}"
echo

pnpm config set registry "$REGISTRY" >/dev/null

# ---- 单项目预热函数 ----
invoke_preheat() {
    local category="$1"
    local folder_path="$2"
    local folder_name="$3"

    local log_file="$LOG_DIR/${category}-${folder_name}.log"
    local start_ts end_ts elapsed exit_code ok tag color

    start_ts="$(date +%s)"
    echo "${C_CYAN}>>> [${category}/${folder_name}] start${C_RESET}"

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
    echo "${color}<<< [${category}/${folder_name}] ${tag}  elapsed=${elapsed}s${C_RESET}"
    echo

    # 追加到汇总文件（多进程并发时使用 flock 防止竞争）
    {
        flock 9
        printf '%s\t%s\t%s\t%s\t%s\n' "$category" "$folder_name" "$ok" "$elapsed" "$log_file" >> "$SUMMARY_FILE"
    } 9>>"$SUMMARY_FILE.lock"
}

export -f invoke_preheat
export LOG_DIR KEEP_LOCK KEEP_NODE_MODULES SUMMARY_FILE
export C_RED C_GREEN C_YELLOW C_CYAN C_MAGENTA C_RESET

# ---- 主循环 ----
TOTAL_START="$(date +%s)"

for cat in "${CATEGORIES[@]}"; do
    cat_path="$BASE_DIR/$cat"
    if [ ! -d "$cat_path" ]; then
        echo "${C_YELLOW}[WARN] 跳过缺失分类: $cat_path${C_RESET}"
        continue
    fi

    # 收集一级子目录
    folders=()
    while IFS= read -r -d '' d; do
        folders+=("$d")
    done < <(find "$cat_path" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

    if [ "${#folders[@]}" -eq 0 ]; then
        echo "${C_YELLOW}[WARN] 分类 $cat 下没有子项目${C_RESET}"
        continue
    fi

    if [ "$PARALLEL" -eq 1 ] && [ "${#folders[@]}" -gt 1 ]; then
        # 使用 xargs -P 实现并发
        printf '%s\0' "${folders[@]}" | \
            xargs -0 -n 1 -P "$PARALLEL_JOBS" -I{} \
            bash -c 'invoke_preheat "$1" "$2" "$(basename "$2")"' _ "$cat" {}
    else
        for f in "${folders[@]}"; do
            invoke_preheat "$cat" "$f" "$(basename "$f")"
        done
    fi
done

TOTAL_END="$(date +%s)"
TOTAL_ELAPSED=$(( TOTAL_END - TOTAL_START ))
rm -f "$SUMMARY_FILE.lock"

# ---- 汇总输出 ----
echo
echo "${C_MAGENTA}========== preheat summary ==========${C_RESET}"

if [ -s "$SUMMARY_FILE" ]; then
    {
        printf 'Category\tName\tSuccess\tSeconds\tLogFile\n'
        sort -t$'\t' -k1,1 -k2,2 "$SUMMARY_FILE" | \
            awk -F'\t' '{
                printf "%s\t%s\t%s\t%s\t%s\n", $1, $2, ($3=="1"?"True":"False"), $4, $5
            }'
    } | column -t -s $'\t'
fi

ok_count=$(awk -F'\t' '$3=="1"{n++} END{print n+0}' "$SUMMARY_FILE")
fail_count=$(awk -F'\t' '$3=="0"{n++} END{print n+0}' "$SUMMARY_FILE")

echo
echo "${C_MAGENTA}total=${TOTAL_ELAPSED}s  ok=${ok_count}  fail=${fail_count}${C_RESET}"

if [ "$fail_count" -gt 0 ]; then
    echo "${C_RED}failures:${C_RESET}"
    awk -F'\t' '$3=="0"{printf "  - %s/%s  ->  %s\n", $1, $2, $5}' "$SUMMARY_FILE" | \
        while IFS= read -r line; do
            echo "${C_RED}${line}${C_RESET}"
        done
fi

# ---- 写出 JSON 汇总 ----
SUMMARY_JSON="$LOG_DIR/summary-$STAMP.json"
{
    printf '['
    first=1
    while IFS=$'\t' read -r c n ok sec log; do
        [ -z "$c" ] && continue
        if [ "$first" -eq 1 ]; then first=0; else printf ','; fi
        # 简易 JSON 转义：反斜杠 + 双引号
        esc_log="${log//\\/\\\\}"
        esc_log="${esc_log//\"/\\\"}"
        if [ "$ok" = "1" ]; then ok_json="true"; else ok_json="false"; fi
        printf '\n  {"Category":"%s","Name":"%s","Success":%s,"Seconds":%s,"LogFile":"%s"}' \
            "$c" "$n" "$ok_json" "$sec" "$esc_log"
    done < <(sort -t$'\t' -k1,1 -k2,2 "$SUMMARY_FILE")
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
