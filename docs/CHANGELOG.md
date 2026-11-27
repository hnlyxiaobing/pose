# pose 变更登记簿（CHANGELOG）

> 本文件登记每一次公开可见的变更：日期 / 工作包 / 新增 pub 声明 / 快照 diff 结论 / 测试增量。
> 仓库外申报口径（不在本仓库内的申报材料）一律不回写，仅以泛称描述差异。

## 历史补登 · CHANGELOG 建立前的已落地工作包（2026-11-17）

> 本登记簿于 W1 建立（2026-11-27）。W5-A、W6-A 在此前已由用户裁决落地，特此补登以保持
> 「每包有记录」的完整性；事实口径以本仓库 git 实测与 `pkg.generated.mbti` 为准。

### W5-A · 外部运行时数值 oracle runner（2026-11-17）

- **工作包**：W5-A（P2/L，dev-plan §5 W5，裁决 A）。
- **新增 pub 声明**：无（仅脚本层）。
- **快照 diff**：空。
- **测试增量**：0（脚本层 SKIPPED 不计入 `moon test` 通过数）。
- **要点**：新建 `tools/numeric-oracle.sh` + `tools/numeric-oracle.sha256`（默认仅注释、零条目）。只接受仓库外本地模型路径 + SHA-256 登记；哈希不符拒绝执行；缺模型/缺比较命令显式 SKIPPED（退出码 78）；真实结论永不进入通过计数。
- **仓库外申报口径**：不回写。

### W6-A · 异步后端门面（2026-11-17）

- **工作包**：W6-A（P2/M，dev-plan §5 W6，裁决 A）。
- **新增 pub 声明**：`pub(open) trait AsyncPoseBackend`、`pub async fn detect_async(...)`、`pub async fn detect_multi_async(...)`（纯加法）。
- **快照 diff**：纯加法（+7 行）。
- **测试增量**：+2（`moon test` 62/62 → 64/64；异步防火墙：与同步入口逐字段等价）。
- **要点**：旧 `PoseBackend` 方法集与 `detect`/`detect_multi` 零改动、逐字节不变；零新错误变体（仍 8 个）；未引入 async 运行时依赖。
- **仓库外申报口径**：不回写。

---

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

---

## W4 · ROI 与新布局防火墙扩展（2026-11-27）

- **工作包**：W4（P2/M，dev-plan §5 W4）。
- **新增 pub 声明（纯加法，无删除/无改签名）**：
  - `pub(all) struct RoiRect { x, y, width, height : Int32 }`
  - `pub(all) struct RoiTransform { scale_x, scale_y : Double; offset_x, offset_y : Int32; roi_x, roi_y, roi_width, roi_height, source_width, source_height : Int32; mirrored : Bool }`
  - `pub fn letterbox_roi(RgbImage, PoseConfig, RoiRect) -> (Bytes, RoiTransform) raise PoseError`
  - `pub fn detect_roi(&PoseBackend, RgbImage, PoseConfig, RoiRect, FrameId) -> PoseResult raise PoseError`
  - `pub fn PoseResult::restore_roi(Self, RoiTransform) -> Self raise PoseError`
- **快照 diff**：纯加法（`pkg.generated.mbti` 中仅新增上述 5 项；`cmd/main` 快照无变化；错误变体仍 8 个）。
- **测试增量**：+9（`moon test` 78/78 → 87/87，零 `#skip`；wasm/native 双目标各 87/87）。
- **要点**：
  - `RoiRect` 越界 / 非正尺寸 / 负原点 / 数据长度不符 → `InvalidInput(x, y)`（复用既有变体，不新增错误变体）。
  - `letterbox_roi` 复用 `crop_roi` + `letterbox` 的整数缩放计划与采样编码（含 Float16/RNE、归一化、镜像）；非等比配置报 `InvalidConfig`（与 `letterbox` 一致）。
  - `detect_roi` 复用 `detect`（含 letterbox/stretch 分派、预算、NMS、ROI 内坐标还原）后把关键点平移到整图坐标；ROI=整图时与 `detect` 逐字段相等（T-W4-2，两种模式均断言）。
  - `PoseResult::restore_roi` 为 `letterbox_roi` 的对偶还原：`x = roi_x + (mirrored ? roi_width-1-sx : sx)`，`sx = (x-offset_x)/scale_x`；与 `detect_roi` 路径代数一致。
  - 防火墙：旧 `detect`/`detect_multi`/`letterbox`/`letterbox_stretch`/`restore`/`restore_stretch` 零改动，原 78 用例零改动全绿（T-W4-3）。
- **已登记限制**：`letterbox_roi` 仅承载等比模式（非等比 ROI 请用 `detect_roi`，它按 `keep_aspect_ratio` 分派两种模式）。
- **仓库外申报口径**：不回写；仅记录本仓库 git 实测。

---

## W5 收口 · oracle runner 机制自检与元契约自动化（2026-11-27）

- **工作包**：W5（T-W5-1 收口）+ W2 元契约补强 + CI 接线。
- **新增 pub 声明**：无（`pkg.generated.mbti` 与 `cmd/main` 快照 diff 均为空）。
- **快照 diff**：空。
- **测试增量**：+1（`moon test` 87/87 → 88/88，零 `#skip`；wasm/native 双目标各 88/88）。
- **要点**：
  - **`tools/numeric-oracle.sh --selfcheck`（T-W5-1 机制收口）**：用**确定性自产探针**（临时目录内固定 ASCII 字节，非第三方模型、入库零资产）走完整链路——SHA-256 计算 → 登记表 `grep` 门禁 → 比较命令执行 → 报告，证明 runner **契约**可跑通。八条路径已实测：selfcheck PASS(0)、无参数 SKIPPED(78)、模型不存在 SKIPPED(78)、哈希未登记 FAIL(1)、登记表缺失 FAIL(1)、比较失败 FAIL(1)、比较通过 PASS(0)、哈希门禁过但无 `--compare` SKIPPED(78)。
    - **边界声明（不自欺）**：selfcheck **不**证明与任何推理运行时的数值一致；与外部运行时的 <1e-4 真实差分仍需用户提供仓库外合法模型，属许可红线内的用户侧可选步骤，默认显式 SKIPPED。
  - **`tools/verify.sh` 接入 selfcheck（强制步骤）**：元契约新增 `W5-6a`，runner 机制不可用即红；`W5-6b` 保留真实差分为可缺省步骤。整体退出码语义不变（0=全绿含真实差分；78=除真实差分外全绿且已显式 SKIPPED；1=失败）。
  - **扫描器负对照测试（+1）**：`decode_capture_allowed` 的允许集合判定加负对照——集合内 4 变体判 true，集合外 4 变体（`BackendNotOpen`/`InvalidInput`/`UnsupportedModel`/`BackendFailure`）必须判 false，成功路径判 true。证明「截断/变异扫描全绿」不是断言空转。
  - **CI 新增 `meta-contract` job**：`bash tools/verify.sh --no-native`，退出码 0/78 均按成功（78 = 真实差分显式 SKIPPED），其余按失败。与既有 `five-gates` job 互不替代。native 双目标等价因依赖 runner 主机 C 工具链、尚未在 GitHub Actions 实跑验证，故 CI 用 `--no-native` 跳过（本机等价实跑已通过）。
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
