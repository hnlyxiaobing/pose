#!/usr/bin/env bash
# pose 交付校验 runner（W2，2026-11-27）
#
# 仓库自包含：不引用工作区路径、不引用兄弟模块、不依赖第三方运行时。
# 串联：五门禁 + native parity + 截断/变异自检 + 错误簿记 8/8 + 引用实存性
#       + oracle runner 机制自检（`--selfcheck`，强制）。
# 真实模型差分（外部推理运行时）缺失时显式 SKIPPED 并以退出码 78 单列，**不计入通过**。
#
# 用法：
#   bash tools/verify.sh                 # 五门禁 + 元契约；真实差分显式 SKIPPED
#   bash tools/verify.sh --no-native     # 跳过 native parity（无 native 工具链时）
#   POSE_ORACLE_MODEL=<仓库外模型路径> bash tools/verify.sh   # 附带真实 oracle 差分
#
# 退出码：0 全绿（含真实差分）；1 任一硬门禁失败；
#         78 = 除「真实模型差分」外全绿且该步已显式 SKIPPED（不计入通过）。

set -uo pipefail

SKIP_NATIVE=0
for arg in "$@"; do
  case "$arg" in
    --no-native) SKIP_NATIVE=1 ;;
    --help|-h)
      sed -n '2,15p' "$0"
      exit 0 ;;
    *)
      echo "FAIL: unknown argument '$arg'" >&2
      exit 1 ;;
  esac
done

FAILED=0
step() { echo; echo "======== $* ========"; }
ok()   { echo "  OK  : $*"; }
bad()  { echo "  FAIL: $*" >&2; FAILED=1; }
skip() { echo "  SKIP: $*"; }

# moon 定位：优先 PATH；否则回退标准安装目录（CI 安装到 $HOME/.moon/bin）。
if ! command -v moon >/dev/null 2>&1; then
  for d in "$HOME/.moon/bin" "${USERPROFILE:-}/.moon/bin"; do
    if [ -x "$d/moon" ]; then PATH="$d:$PATH"; export PATH; break; fi
  done
fi
if ! command -v moon >/dev/null 2>&1; then
  echo "FAIL: moon not found on PATH (install per README §5 / CI workflow)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. 五门禁（与 .github/workflows/ci.yml 完全同序）
# ---------------------------------------------------------------------------
step "Gate 1/5 · moon check --deny-warn"
if moon check --deny-warn; then ok "check"; else bad "moon check --deny-warn"; fi

step "Gate 2/5 · moon build"
if moon build; then ok "build"; else bad "moon build"; fi

step "Gate 3/5 · moon test (wasm；含截断/变异扫描)"
if moon test; then ok "test wasm"; else bad "moon test"; fi

step "Gate 4/5 · moon fmt --check"
if moon fmt --check; then ok "fmt"; else bad "moon fmt --check"; fi

step "Gate 5/5 · moon info + 快照 diff"
if moon info && git diff --exit-code -- pkg.generated.mbti cmd/main/pkg.generated.mbti; then
  ok "snapshot in sync"
else
  bad "snapshot out of sync (run 'moon info' and commit the .mbti)"
fi

# ---------------------------------------------------------------------------
# 2. 双目标等价（T-W2-4）：同一 builder/断言在 native 再跑一次，逐字节 diff=0
# ---------------------------------------------------------------------------
step "T-W2-4 · native parity (moon test --target native)"
if [ "$SKIP_NATIVE" -eq 1 ]; then
  skip "native parity (--no-native)"
elif moon test --target native; then
  ok "test native (same assertions ⇒ value diff = 0)"
else
  bad "native parity (moon test --target native)"
fi

# ---------------------------------------------------------------------------
# 3. 截断/变异自检（T-W2-3）：扫描用例必须在位，且变异规模 ≥1000
# ---------------------------------------------------------------------------
step "T-W2-3 · 截断/变异扫描自检"
SCAN_FILES="pose_wbtest.mbt"
missing=0
for pat in "截断扫描" "变异扫描" "scan_truncations" "scan_mutations"; do
  if ! grep -q "$pat" $SCAN_FILES 2>/dev/null; then
    bad "扫描用例缺失: $pat"
    missing=1
  fi
done
if [ "$missing" -eq 0 ]; then
  if grep -qE ', 1000\)' $SCAN_FILES; then
    ok "截断扫描 + 变异扫描（≥1000 体）在位"
  else
    bad "变异扫描规模未达 1000"
  fi
fi

# ---------------------------------------------------------------------------
# 4. 错误簿记 8/8（T-W2-6）+ 变体数冻结 = 8
# ---------------------------------------------------------------------------
step "T-W2-6 · 错误簿记 8/8"
VARIANTS=(BackendNotOpen BackendFailure InvalidConfig InvalidInput OutputDecode ShapeMismatch UnsupportedModel BudgetExceeded)
TESTFILES="pose_test.mbt pose_wbtest.mbt pose_golden_test.mbt pose_async_test.mbt"
book_bad=0
for v in "${VARIANTS[@]}"; do
  if ! grep -q "$v" $TESTFILES 2>/dev/null; then
    bad "错误变体未被任何测试断言: $v"
    book_bad=1
  fi
done
NVAR="$(awk '/pub\(all\) suberror PoseError \{/{f=1;next} f&&/^\}/{f=0} f&&/^  [A-Z][A-Za-z]+\(/{c++} END{print c+0}' pkg.generated.mbti)"
if [ "$NVAR" = "8" ]; then
  ok "8 个变体全部被测试断言；mbti 变体数 = 8（冻结）"
else
  bad "mbti 变体数 = $NVAR，期望 8（错误变体集合冻结）"
fi
if [ "$book_bad" -ne 0 ]; then bad "错误簿记不完整"; fi

# ---------------------------------------------------------------------------
# 5. 引用实存性（T-W1-1 延续）：代码/CI/README 引用的仓库内路径必须存在
#    （docs/*.md 自身不扫描：其「B18 实测不存在」属历史核验记录）
# ---------------------------------------------------------------------------
step "引用实存性 · 代码/CI/README 引用路径"
REF_FILES=""
for f in pose.mbt pose_async.mbt pose_test.mbt pose_wbtest.mbt pose_golden_test.mbt \
         pose_roi_test.mbt pose_async_test.mbt README.md .githooks/pre-commit \
         .github/workflows/ci.yml tools/verify.sh tools/numeric-oracle.sh \
         tests/golden/README.md; do
  [ -f "$f" ] && REF_FILES="$REF_FILES $f"
done
REFS="$(grep -ohE '(docs|tools|tests)/[A-Za-z0-9._/-]+' $REF_FILES 2>/dev/null | sort -u)"
ref_bad=0
while IFS= read -r r; do
  [ -z "$r" ] && continue
  # 只剥离尾部标点（不能从首个「.」截断，否则会吃掉扩展名）
  while [ "${r%[.,;:)]}" != "$r" ]; do r="${r%[.,;:)]}"; done
  case "$r" in
    */) r="${r%/}" ;;            # 目录引用去尾斜杠再判存在
  esac
  if [ ! -e "$r" ]; then
    bad "引用路径不存在: $r"
    ref_bad=1
  fi
done <<< "$REFS"
if [ "$ref_bad" -eq 0 ]; then ok "所有引用路径均实存"; fi

# ---------------------------------------------------------------------------
# 6. 外部 oracle（W5）
#    6a 机制自检（强制）：确定性自产探针走完整哈希门禁 → 比较 → 报告链路
#    6b 真实模型差分（可缺省）：缺失即显式 SKIPPED，不计入通过
# ---------------------------------------------------------------------------
step "W5-6a · oracle runner 机制自检（--selfcheck，强制）"
if bash tools/numeric-oracle.sh --selfcheck; then
  ok "runner 机制自检（哈希登记 → 门禁 → 比较 → 报告；非真实模型差分）"
else
  bad "oracle --selfcheck（runner 契约不可用）"
fi

step "W5-6b · 真实模型差分（可缺省）"
ORACLE_RC=0
if [ -n "${POSE_ORACLE_MODEL:-}" ]; then
  if bash tools/numeric-oracle.sh --model "$POSE_ORACLE_MODEL" --registry tools/numeric-oracle.sha256; then
    ok "oracle 哈希门禁通过（无比较命令时脚本自身 SKIPPED，见其输出）"
  else
    ORACLE_RC=$?
    if [ "$ORACLE_RC" -eq 78 ]; then
      skip "oracle SKIPPED (exit 78; not counted as passed)"
    else
      bad "oracle 硬失败 (exit $ORACLE_RC)"
    fi
  fi
else
  skip "无外部模型（POSE_ORACLE_MODEL 未设）；真实差分未运行，不计入通过"
  ORACLE_RC=78
fi

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
step "汇总"
if [ "$FAILED" -ne 0 ]; then
  echo "结果: FAIL（存在硬门禁失败）" >&2
  exit 1
fi
if [ "$ORACLE_RC" -eq 78 ]; then
  echo "结果: 五门禁 + 元契约全绿；外部 oracle SKIPPED（不计入通过）"
  exit 78
fi
echo "结果: 全绿（含 oracle）"
exit 0
