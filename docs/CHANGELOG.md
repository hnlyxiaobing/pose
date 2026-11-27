# pose 变更登记簿（CHANGELOG）

> 本文件登记每一次公开可见的变更：日期 / 工作包 / 新增 pub 声明 / 快照 diff 结论 / 测试增量。
> 仓库外申报口径（不在本仓库内的申报材料）一律不回写，仅以泛称描述差异。

## W1 · 漂移清理与自包含（2026-11-27）

- **工作包**：W1（P0/S，dev-plan §5 W1）。
- **新增 pub 声明**：无（仅注释 / 文档 / CI 文案 / 钩子）。
- **快照 diff**：空（`pkg.generated.mbti` 与 `cmd/main/pkg.generated.mbti` 均无变化）。
- **测试增量**：0（`moon test` 维持 64/64，零 `#skip`）。
- **要点**：修复 `docs/DECISIONS.md`、`docs/API.md` 等失效路径引用（改为指向 `docs/2026-11-17-*.md`）；去除 `pose.mbt` 注释中的外部模块/类型名（`yuv::`、`tflite_ffi`）；修正 `detect_multi` 空张量语义注释；README 补 `FrameId` 索引、改为唯一入口文档并加 docs 索引；`.githooks/pre-commit` 补齐五道门禁；新建本登记簿。
- **仓库外申报口径**：不回写；仅记录本仓库 git 实测。

---

## W3 · fail-closed 输入加固（2026-11-27）

- **工作包**：W3（P1/S，dev-plan §5 W3）。
- **新增 pub 声明**：无（`pkg.generated.mbti` 快照 diff 为空）。
- **快照 diff**：空（`pkg.generated.mbti` 与 `cmd/main/pkg.generated.mbti` 均无变化）。
- **测试增量**：+3（`moon test` 64/64 → 67/67，零 `#skip`）。
- **要点**（三项 fail-closed 修复，如 dev-plan §5 W3 所述）：
  - `nms` 入口逐候选校验 `score` 与 `bbox` 四坐标 `is_finite()`，非有限即 `InvalidConfig`（关闭 B22 非有限候选导致 fail-open 的静默放行）。
  - `letterbox`/`letterbox_stretch` 数据长度改用 `to_int64()` 中间量校验，`letterbox_plan` 与 `resize_encode` 的缩放/采样算术改为 Int64 中间量（关闭 B23 `w*h*src_ch` 与采样偏移的 Int32 乘法回绕）。
  - `detect_multi` 预算改为 `block.to_int64() * max_poses.to_int64()`，并在 `validate_spec_and_config` 与 `nms` 增加 `max_poses` 上界（`max_poses_upper_bound = 65536`）拒绝极端值（关闭预算回绕成负值）。
  - 仅非有限候选 / 极端尺寸 / 极端 `max_poses` 样本改变行为；原 62 用例零改动全绿（防火墙）。
- **仓库外申报口径**：不回写；仅记录本仓库 git 实测。

---

<!-- 后续工作包在此追加登记。模板： -->
<!--
## W? · 标题（YYYY-MM-DD）
- 新增 pub 声明：...
- 快照 diff：...
- 测试增量：...
- 要点：...
-->

---

## W2 · 门面契约 golden 与双目标等价固化（2026-11-27）

- **工作包**：W2（P1/M，dev-plan §5 W2）。
- **新增 pub 声明**：无（`pkg.generated.mbti` 快照 diff 为空；只加测试与脚本）。
- **快照 diff**：空（`pkg.generated.mbti` 与 `cmd/main/pkg.generated.mbti` 均无变化）。
- **测试增量**：+11（`moon test` 67/67 → 78/78，零 `#skip`；wasm/native 双目标各 78/78）。
- **要点**：
  - **L2 受控 golden（`pose_golden_test.mbt`）**：letterbox 2×2→4×4 五种 dtype（Float32/Float16/UInt8/Int8/Int32）输入字节 + `Transform` 全字段；2×2→4×6 填充带与采样区；`mirror_x` 采样翻转；`decode_output` 17 点 @192²、33 点 @256² 逐字段；`detect` 端到端逐字段（`frame_id`/`timestamp_ns`/`backend` 标注）；P1 幂等律（同输入双次调用逐字节相等）；P4 后端注入律（Mock vs Alt 仅 `backend` 不同）。
  - **L2 语料登记（`tests/golden/README.md`）**：确定性字节 builder 逐条登记（非文件 fixture、非第三方模型，延续 B7 零死资产），每条 golden 均由测试真实断言（T-W2-1）。
  - **L1 截断/变异扫描（`pose_wbtest.mbt`）**：`scan_truncations` 遍历 17 点 204 字节张量全前缀 + 每 12 字节结构边界；`scan_mutations` 固定种子 `0x9E3779B97F4A7C15`（xorshift64）生成 1000 个替换/插入/删除变异体；`nms` 变异注入 NaN/Inf score/bbox（固定种子 `0xD1B54A32D192ED03`，100 体）必须 `InvalidConfig`。只允许 `OutputDecode`/`ShapeMismatch`/`InvalidConfig`/`BudgetExceeded`，无 panic/挂起（T-W2-3）。
  - **双目标等价（T-W2-4）**：同一 builder/断言在 wasm 与 native 各跑一次，均 78/78 通过 ⇒ 值输出逐字节 diff = 0；无浮点容差放宽。
  - **脚本层（`tools/verify.sh`，仓库自包含）**：串起五门禁 + native parity + 截断/变异自检 + 错误簿记 8/8（8 变体全被测试断言且 mbti 变体数冻结=8）+ 引用实存性；外部 oracle 缺失显式 SKIPPED（退出码 78 单列），不计入通过（T-W2-6）。
  - 防火墙：原 67 用例零改动全绿（T-W2-5）。
- **仓库外申报口径**：不回写；仅记录本仓库 git 实测。
