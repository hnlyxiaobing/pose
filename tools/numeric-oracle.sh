#!/usr/bin/env bash
# pose 数值 oracle runner（W5-A，2026-11-17）
#
# 纪律：真实模型/运行时永不入库；本脚本只接受仓库外本地路径 + SHA-256 登记。
# 任何缺失项一律输出 SKIPPED 并以退出码 78 结束，绝不计入 moon test 通过数。
# 哈希不符、登记文件缺失、比较命令失败均为硬失败（非 78）。
#
# 用法：
#   bash tools/numeric-oracle.sh --model <仓库外模型路径> \
#       --registry tools/numeric-oracle.sha256 \
#       [--compare "<比较命令>"]
#
# 比较命令通过环境变量接收：MODEL_PATH / MODEL_SHA256 / ORACLE_DIR / ORACLE_TMP。
# 未提供 --compare 时脚本完成哈希门禁后显式 SKIPPED（不伪造数值结论）。

set -uo pipefail

MODEL=""
REGISTRY="tools/numeric-oracle.sha256"
COMPARE=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --model) MODEL="$2"; shift 2 ;;
    --registry) REGISTRY="$2"; shift 2 ;;
    --compare) COMPARE="$2"; shift 2 ;;
    --help|-h)
      sed -n '2,20p' "$0"
      exit 0 ;;
    *)
      echo "SKIPPED: unknown argument '$1' (exit 78)" >&2
      exit 78 ;;
  esac
done

skip() {
  echo "SKIPPED: $1 (exit 78; not counted as passed)" >&2
  exit 78
}

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

[ -n "$MODEL" ] || skip "no external model path supplied"
[ -f "$MODEL" ] || skip "external model path does not exist"
[ -f "$REGISTRY" ] || fail "registry file missing: $REGISTRY"

# 计算 SHA-256：优先 sha256sum，回退 python3 hashlib；两者都无则 SKIPPED。
if command -v sha256sum >/dev/null 2>&1; then
  MODEL_SHA256="$(sha256sum "$MODEL" | awk '{print $1}')"
elif command -v python3 >/dev/null 2>&1; then
  MODEL_SHA256="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$MODEL")"
else
  skip "no SHA-256 tool available"
fi

# 登记格式：<sha256>  <任意标签>；忽略 # 注释与空行。
if ! grep -Eq "^[[:space:]]*${MODEL_SHA256}[[:space:]]+" "$REGISTRY"; then
  fail "model SHA-256 not registered: $MODEL_SHA256"
fi

ORACLE_TMP=""
if command -v mktemp >/dev/null 2>&1; then
  ORACLE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/pose-oracle.XXXXXX")" || fail "cannot create temp dir"
else
  skip "no mktemp available"
fi
trap 'rm -rf "$ORACLE_TMP"' EXIT

[ -n "$COMPARE" ] || skip "no comparison command supplied; hash gate passed but no numeric result"

export MODEL_PATH="$MODEL"
export MODEL_SHA256="$MODEL_SHA256"
export ORACLE_DIR="$SCRIPT_DIR"
export ORACLE_TMP

echo "oracle: model hash registered ($MODEL_SHA256)"
bash -c "$COMPARE"
rc=$?
if [ "$rc" -eq 0 ]; then
  echo "oracle: PASS (local comparison; hash $MODEL_SHA256; $(date -u +%Y-%m-%dT%H:%M:%SZ))"
else
  echo "oracle: FAIL (comparison exit $rc; hash $MODEL_SHA256; $(date -u +%Y-%m-%dT%H:%M:%SZ))" >&2
fi
exit "$rc"
