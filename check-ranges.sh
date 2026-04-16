#!/usr/bin/env bash
# ============================================================
# check-ranges.sh
#   扫描 stable/ 与 latest/ 下所有 package.json，检测每个依赖的版本范围
#   能否在 registry 上解析到。用于在触发漫长的 pnpm install 预热之前，
#   先找出"范围本身无解"的条目（典型场景：手写 seed 时写错版本号）。
# 用法：
#   ./check-ranges.sh                                  # 默认对着 Verdaccio 扫所有
#   ./check-ranges.sh --registry https://registry.npmjs.org/
#   ./check-ranges.sh --categories stable              # 只扫 stable
#   ./check-ranges.sh --only stable-react              # 只扫指定子项目
#   ./check-ranges.sh --jobs 16                        # 并发路数
# 退出码：有任意条无解返回 1，全部 OK 返回 0
# ============================================================

set -u

REGISTRY="https://npm.home.ueyeseas.com:8443/"
CATEGORIES_RAW="stable,latest"
ONLY_RAW=""
PARALLEL_JOBS=8

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

# ---- 参数 ----
while [ $# -gt 0 ]; do
    case "$1" in
        -r|--registry)    REGISTRY="$2"; shift 2 ;;
        -c|--categories)  CATEGORIES_RAW="$2"; shift 2 ;;
        -o|--only)        ONLY_RAW="$2"; shift 2 ;;
        -j|--jobs)        PARALLEL_JOBS="$2"; shift 2 ;;
        -h|--help)        sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "${C_RED}[ERROR] 未知参数: $1${C_RESET}" >&2; exit 1 ;;
    esac
done

IFS=',' read -r -a CATEGORIES <<< "$CATEGORIES_RAW"
if [ -n "$ONLY_RAW" ]; then
    IFS=',' read -r -a ONLY_PROJECTS <<< "$ONLY_RAW"
else
    ONLY_PROJECTS=()
fi

# ---- preflight ----
command -v pnpm    >/dev/null 2>&1 || { echo "${C_RED}[ERROR] 需要 pnpm${C_RESET}" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "${C_RED}[ERROR] 需要 python3（用于解析 package.json）${C_RESET}" >&2; exit 1; }

# ---- 判断 --only 白名单 ----
project_allowed() {
    local name="$1"
    [ "${#ONLY_PROJECTS[@]}" -eq 0 ] && return 0
    local w
    for w in "${ONLY_PROJECTS[@]}"; do
        [ "$w" = "$name" ] && return 0
    done
    return 1
}

BASE_DIR="$(pwd)"
JOBS_FILE=$(mktemp)
RESULT_FILE=$(mktemp)
trap 'rm -f "$JOBS_FILE" "$RESULT_FILE"' EXIT

# ---- 收集 (project, pkg, range) 三元组 ----
collect_deps_one() {
    local project="$1" pj="$2"
    python3 - "$project" "$pj" <<'PY'
import json, sys
project, pj = sys.argv[1], sys.argv[2]
with open(pj) as f:
    data = json.load(f)
deps = {}
deps.update(data.get('dependencies', {}) or {})
deps.update(data.get('devDependencies', {}) or {})
for name, rng in deps.items():
    if not rng: continue
    # 跳过 workspace 协议、file:、link:、git+、http:、catalog: 等
    if any(rng.startswith(p) for p in ('workspace:', 'file:', 'link:', 'git+', 'http', 'catalog:', 'npm:')):
        continue
    if rng == '*' or rng.lower() == 'latest':
        continue
    # 用 TAB 作分隔，避免包名/range 内部的其它字符冲突
    print(f"{project}\t{name}\t{rng}")
PY
}

echo "${C_GREEN}========================================${C_RESET}"
echo "${C_GREEN}check-ranges | registry = $REGISTRY${C_RESET}"
echo "${C_GREEN}categories   : ${CATEGORIES[*]}${C_RESET}"
[ "${#ONLY_PROJECTS[@]}" -gt 0 ] && echo "${C_GREEN}only projects: ${ONLY_PROJECTS[*]}${C_RESET}"
echo "${C_GREEN}parallel jobs: $PARALLEL_JOBS${C_RESET}"
echo "${C_GREEN}========================================${C_RESET}"

for cat in "${CATEGORIES[@]}"; do
    cat_path="$BASE_DIR/$cat"
    [ -d "$cat_path" ] || { echo "${C_YELLOW}[WARN] 跳过缺失分类: $cat_path${C_RESET}"; continue; }
    for pj in "$cat_path"/*/package.json; do
        [ -f "$pj" ] || continue
        project="$(basename "$(dirname "$pj")")"
        project_allowed "$project" || continue
        collect_deps_one "$project" "$pj" >> "$JOBS_FILE"
    done
done

TOTAL=$(wc -l < "$JOBS_FILE" | tr -d ' ')
if [ "$TOTAL" -eq 0 ]; then
    echo "${C_YELLOW}[WARN] 没有要检查的依赖${C_RESET}"
    exit 0
fi

# 去重：相同 (pkg, range) 无需查询多次（不同 project 共用）
UNIQ_FILE=$(mktemp)
trap 'rm -f "$JOBS_FILE" "$RESULT_FILE" "$UNIQ_FILE"' EXIT
awk -F'\t' '{print $2 "\t" $3}' "$JOBS_FILE" | sort -u > "$UNIQ_FILE"
UNIQ_TOTAL=$(wc -l < "$UNIQ_FILE" | tr -d ' ')

echo "${C_CYAN}[info] total deps=$TOTAL  unique (pkg,range)=$UNIQ_TOTAL${C_RESET}"
echo "${C_CYAN}[info] querying registry...${C_RESET}"

# ---- 单条检查（子 shell 调用） ----
check_one() {
    local pkg="$1" range="$2" registry="$3"
    local out
    if out=$(pnpm view "${pkg}@${range}" version --registry "$registry" 2>&1); then
        if [ -n "$out" ]; then
            printf 'OK\t%s\t%s\t\n' "$pkg" "$range"
        else
            printf 'FAIL\t%s\t%s\t%s\n' "$pkg" "$range" "empty response"
        fi
    else
        # 取第一条非空错误消息，压成单行
        local first
        first=$(echo "$out" | grep -E 'No match|ERR_PNPM|404|ETARGET|E404' | head -1 | tr -d '\t' | sed 's/^ *//')
        [ -z "$first" ] && first=$(echo "$out" | head -1 | tr -d '\t')
        printf 'FAIL\t%s\t%s\t%s\n' "$pkg" "$range" "$first"
    fi
}
export -f check_one

# 并发跑
awk -F'\t' '{printf "%s|%s\n", $1, $2}' "$UNIQ_FILE" | \
    xargs -P "$PARALLEL_JOBS" -I{} bash -c '
        line="$1"
        pkg="${line%%|*}"
        range="${line#*|}"
        check_one "$pkg" "$range" "$2"
    ' _ {} "$REGISTRY" > "$RESULT_FILE"

# ---- 汇总：把 FAIL 结果展开回每个 project ----
echo
echo "${C_MAGENTA}========== check-ranges summary ==========${C_RESET}"

FAIL_UNIQ=$(awk -F'\t' '$1=="FAIL"' "$RESULT_FILE" | wc -l | tr -d ' ')

if [ "$FAIL_UNIQ" -eq 0 ]; then
    echo "${C_GREEN}  ✓ all $UNIQ_TOTAL unique (pkg,range) resolvable on $REGISTRY${C_RESET}"
    exit 0
fi

# 把 FAIL 的 pkg|range 映射回用到它们的 project
echo "${C_RED}  ✗ $FAIL_UNIQ unresolvable range(s):${C_RESET}"
python3 - "$JOBS_FILE" "$RESULT_FILE" <<'PY'
import sys, collections
jobs_path, result_path = sys.argv[1], sys.argv[2]

# (pkg, range) -> err
fails = {}
with open(result_path) as f:
    for line in f:
        parts = line.rstrip('\n').split('\t')
        if len(parts) < 4 or parts[0] != 'FAIL':
            continue
        _, pkg, rng, err = parts[0], parts[1], parts[2], '\t'.join(parts[3:])
        fails[(pkg, rng)] = err

# (pkg, range) -> [projects]
users = collections.defaultdict(list)
with open(jobs_path) as f:
    for line in f:
        parts = line.rstrip('\n').split('\t')
        if len(parts) < 3: continue
        project, pkg, rng = parts
        if (pkg, rng) in fails:
            users[(pkg, rng)].append(project)

RED = '\033[31m'
RESET = '\033[0m'
DIM = '\033[2m'
for (pkg, rng), err in sorted(fails.items()):
    projs = ', '.join(sorted(set(users.get((pkg, rng), []))))
    print(f"{RED}    - {pkg}@{rng}{RESET}  used by: {projs}")
    print(f"{DIM}        registry says: {err}{RESET}")
PY

exit 1
