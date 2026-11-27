#!/usr/bin/env bash
# pose 数值 oracle runner（W5-A 2026-11-17；--selfcheck 机制自检 2026-11-27）
#
# 纪律：真实模型/运行时永不入库；本脚本只接受仓库外本地路径 + SHA-256 登记。
# 任何缺失项一律输出 SKIPPED 并以退出码 78 结束，绝不计入 moon test 通过数。
# 哈希不符、登记文件缺失、比较命令失败均为硬失败（非 78）。
#
# 用法：
#   bash tools/numeric-oracle.sh --model <仓库外模型路径> \
#       --registry tools/numeric-oracle.sha256 \
#       [--compare "<比较命令>"]
#   bash tools/numeric-oracle.sh --selfcheck   # runner 机制自检（非真实模型差分）
#
# 比较命令通过环境变量接收：MODEL_PATH / MODEL_SHA256 / ORACLE_DIR / ORACLE_TMP。
# 未提供 --compare 时脚本完成哈希门禁后显式 SKIPPED（不伪造数值结论）。
#
# --selfcheck：用确定性自产探针（临时目录内固定 ASCII 字节；非第三方模型、入库零资产）
# 走完整链路——SHA-256 计算 → 登记表 grep 门禁 → 比较命令执行 → 报告，证明 runner
# 契约可跑通。它**不**证明与任何推理运行时的数值一致（那需要用户提供仓库外真实模型）。

set -uo pipefail

MODEL=""
REGISTRY="tools/numeric-oracle.sha256"
COMPARE=""
SELFCHECK=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SC_DIR=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --model) MODEL="$2"; shift 2 ;;
    --registry) REGISTRY="$2"; shift 2 ;;
    --compare) COMPARE="$2"; shift 2 ;;
    --selfcheck) SELFCHECK=1; shift ;;
    --help|-h)
      sed -n '2,22p' "$0"
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

# SHA-256 计算：sha256sum 优先，回退 python3 hashlib；均不可用则输出空串。
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
  else
    echo ""
  fi
}

# 确定性自产探针内容（固定字符串；零第三方资产、可完全复现）。
PROBE_TEXT='pose-oracle-selfcheck-probe-v1'

if [ "$SELFCHECK" -eq 1 ]; then
  command -v mktemp >/dev/null 2>&1 || skip "no mktemp available"
  SC_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pose-oracle-selfcheck.XXXXXX")" ||
    fail "cannot create temp dir"
  trap 'rm -rf "${SC_DIR:-}" "${ORACLE_TMP:-}"' EXIT
  MODEL="$SC_DIR/probe.bin"
  REGISTRY="$SC_DIR/registry.sha256"
  printf '%s' "$PROBE_TEXT" >"$MODEL" || fail "cannot write selfcheck probe"
  PROBE_SHA="$(sha256_of "$MODEL")"
  [ -n "$PROBE_SHA" ] || skip "no SHA-256 tool available"
  printf '%s  pose-oracle-selfcheck-probe (self-produced; not a third-party model)\n' \
    "$PROBE_SHA" >"$REGISTRY" || fail "cannot write selfcheck registry"
  # 比较命令用独立复验（比内容，不比哈希），避免与哈希门禁同源自证。
  COMPARE='[ "$(cat "$MODEL_PATH")" = "pose-oracle-selfcheck-probe-v1" ]'
fi

[ -n "$MODEL" ] || skip "no external model path supplied"
[ -f "$MODEL" ] || skip "external model path does not exist"
[ -f "$REGISTRY" ] || fail "registry file missing: $REGISTRY"

MODEL_SHA256="$(sha256_of "$MODEL")"
[ -n "$MODEL_SHA256" ] || skip "no SHA-256 tool available"

# 登记格式：<sha256>  <任意标签>；忽略 # 注释与空行。
if ! grep -Eq "^[[:space:]]*${MODEL_SHA256}[[:space:]]+" "$REGISTRY"; then
  fail "model SHA-256 not registered: $MODEL_SHA256"
fi

ORACLE_TMP=""
if command -v mktemp >/dev/null 2>&1; then
  ORACLE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/pose-oracle.XXXXXX")" ||
    fail "cannot create temp dir"
else
  skip "no mktemp available"
fi
trap 'rm -rf "${ORACLE_TMP:-}" "${SC_DIR:-}"' EXIT

[ -n "$COMPARE" ] || skip "no comparison command supplied; hash gate passed but no numeric result"

export MODEL_PATH="$MODEL"
export MODEL_SHA256="$MODEL_SHA256"
export ORACLE_DIR="$SCRIPT_DIR"
export ORACLE_TMP

LABEL="local comparison"
if [ "$SELFCHECK" -eq 1 ]; then
  LABEL="selfcheck 机制自检（非真实模型差分）"
  echo "oracle: [selfcheck] probe hash registered ($MODEL_SHA256)"
else
  echo "oracle: model hash registered ($MODEL_SHA256)"
fi

bash -c "$COMPARE"
rc=$?
if [ "$rc" -eq 0 ]; then
  echo "oracle: PASS ($LABEL; hash $MODEL_SHA256; $(date -u +%Y-%m-%dT%H:%M:%SZ))"
else
  echo "oracle: FAIL ($LABEL; comparison exit $rc; hash $MODEL_SHA256; $(date -u +%Y-%m-%dT%H:%M:%SZ))" >&2
fi
exit "$rc"
