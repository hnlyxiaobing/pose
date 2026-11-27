# pose 测试系统设计（第一性原理）

> 建立：2026-11-17 ｜ 状态：设计生效，随开发文档逐包落地 ｜ 适用仓库：本仓库（独立自包含）
> 配套文档：[2026-11-17-backend-neutral-facade-dev-plan.md](2026-11-17-backend-neutral-facade-dev-plan.md)（`T-W*-*` 验收 ID 一一对应；B# 证据行见该文档 §0）

## 1. 第一性原理：本库的正确性是什么

本库的数学形态：

```text
(RgbImage, PoseConfig, PoseBackend, FrameId)
  → (Bytes 前处理张量 → 后端 Bytes → 姿态块解码 → NMS → 坐标逆变换)
  → Array[PoseResult] | PoseError
```

正确性不可约简为以下断言，每条必须有测试层承载：

| # | 断言 | 含义 | 反例（测试必须抓住） |
|---|---|---|---|
| A1 | 坐标寻址忠实 | `(y,x,score)` 三元组按小端 Float32 解码；17/33 点由 `landmark_count` 配置化；模型输入像素系经 letterbox/stretch 逆变换（含镜像）回到原图系 | `x_norm=0.5`、输入宽 192 时解出 48 而非 96；镜像还原该翻转未翻转 |
| A2 | 完整性 fail-closed | 非有限输出 → `OutputDecode`；形状/字节数不符 → `ShapeMismatch`；超预算 → `BudgetExceeded`；非有限候选 → `InvalidConfig`（W3）；未校验 ≠ 通过 | NaN score 的候选参与 NMS 排序后永不被抑制；空张量被误报为 `OutputDecode` |
| A3 | 边界纯净 | 只输出 `Landmark`/`PoseResult` 等中立值；`z=0`、`name=None`；不产出动作/渲染/骨架语义；不暴露引擎句柄 | 结果类型被塞入具体引擎对象；后端种类影响调度而非仅标注 |
| A4 | 输入安全 | 任意畸形 spec/图像/输出字节不 panic、不越界、内存有界；Int32 乘法不回绕（W3） | 巨大 `width*height*channels` 回绕成小值后通过长度检查，采样越界 |
| A5 | 契约稳定 | 公开签名/错误 8 变体/空检测语义与快照一致；变更只加法；旧语料逐字节不变 | README 索引漏 `FrameId`；新函数合入后旧 `detect` 输出变化 |
| A6 | 平台等价 | wasm 与 native 同输入同值输出（浮点边界按 §5 容差口径） | Float16 下溢与 RNE 中点两目标舍入不同而无断言 |
| A7 | 后端注入等价（FFI 类附加） | Mock / Alt / 三回调适配器在相同字节输出下上层值一致（仅 `backend` 标注、生命周期错误不同） | 换后端导致解码/NMS/坐标还原结果漂移 |
| A8 | 适配器生命周期 | `TfliteAdapter` 未 open 拒绝、重复 open/close 拒绝、回退标志单调（一旦 true 恒 true）、失败原样传播 | 主绑定缺失时回退未被记录；重复 close 二次释放 |

设计推论：A1/A2 → 性质测试 + 结构化 golden + 截断/变异扫描；A2 → 错误变体簿记 + 恒等式；A4 → 边界值与极端乘法构造；A5/A6 → 五门禁 + 双目标差分 + 防火墙回归；真实运行时符合性 → 外部 oracle 层（许可约束下本地可选，显式 SKIPPED）。

## 2. 测试分层

```text
L0 单元与程序化 fixture（每个 pub fn 行为样例；W4 收口后 59 黑盒 + 29 白盒 = 88）
L1 性质与变异（变形律 / Float16 位模式扫描 / 截断扫描 / 固定种子变异 ≥1000 体；W2 已落地）
L2 受控黄金差分（tests/golden/ 自产字节 + 逐字段黄金记录；W2 已落地 ✓）
L3 外部 oracle 差分（外部推理运行时，仓库外本地路径 + 哈希 + 显式 SKIPPED；W5 已落地 A）
L4 CLI 场景 E2E（本库无 CLI：退化为库级编排场景 detect/detect_multi/detect_roi 的预期/拒绝矩阵）
L5 元契约门禁（快照 / 错误簿记 8/8 / 双目标等价 / 变异自检 / 引用实存性 / 钩子一致性；W2 已落地 `tools/verify.sh`）
R  真实样本本地 runner（仓库外路径 + SHA-256 门禁 + 显式 SKIPPED，永不进通过计数）
```

断言×层承载表：

| 断言 | 主承载层 | 辅助层 |
|---|---|---|
| A1 坐标寻址忠实 | L0 + L2 | L1（逆变换恒等式） |
| A2 完整性 fail-closed | L0 + L5（簿记） | L1（截断/变异）、L4（错误路径） |
| A3 边界纯净 | L0 | L2（结果逐字段 golden） |
| A4 输入安全 | L1 | L0（极端构造）、L4 |
| A5 契约稳定 | L5 | L2（防火墙逐字节） |
| A6 平台等价 | L5（双目标差分） | L2（同一 builder） |
| A7 后端注入等价 | L0 + L2 | L4（多后端同帧） |
| A8 生命周期 | L0 | L1（状态序列性质） |

## 3. fixture 体系

| 类 | 形态 | 入库 | 许可 | 现状 |
|---|---|---|---|---|
| F-A 程序化构造 | 测试代码字节 builder（`raw_of`/`raw_uniform`/`spec_of`/`white_image`） | 是 | 随仓库 | 已实现（B7）；测试内 builder 真实消费 |
| F-B 受控文件 fixture | `tests/fixtures/*` | 是 | 哈希登记（当前无登记文件） | 当前无目录、无死资产（B7）；W2 仍走 F-C 程序化自产，故未建文件 fixture |
| F-C 生成器资产 | 确定性 builder（golden builder / 变异种子） | 是 | 自产 | W2 已落地：`pose_golden_test.mbt` + `tests/golden/README.md` 登记 + `scan_mutations` 固定种子 |
| F-D 真实第三方样本/模型 | 仓库外本地路径 | 否（红线） | 许可不明 | W5 已裁决 A 并落地 runner；仅 R runner + 显式 SKIPPED |

红线：F-D 永不入库；golden 字节变更须同步登记 + 黄金记录（防样本漂移假绿）；外部申报材料不进入本仓库测试路径或文档引用。
builder 能力清单：`spec_of(w,h,ch,dtype,mean,std,landmark_count)` 覆盖尺寸/通道/5 dtype/均值方差/关键点数；`config_with`/`config_nms` 覆盖 keep_aspect_ratio/pad/score/nms/max_poses/mirror；输出张量 builder 覆盖 0 块、1 块、多块、非整数块、NaN/Inf 分量、极值归一化坐标；图像 builder 覆盖 RGB/BGR/RGBA/BGRA、尺寸与数据长度不符、极端尺寸（W3）。

## 4. L1 性质与变异

- 变形律 P1 幂等律：同一输入两次 `detect`/`letterbox`/`nms` 输出逐字节相等。
- 变形律 P2 前处理↔还原恒等式：`mirror_x=false` 时 `PoseResult::restore(letterbox(bytes,t))` 对自身模型坐标满足 `x = (x_model - pad_x)/scale`、`y = (y_model - pad_y)/scale`；stretch 同理除以 `scale_x/scale_y`。
- 变形律 P3 全图 ROI 等价律（W4 已落地）：`RoiRect` 恰为全图时 `detect_roi ≡ detect`（等比 + stretch 两种模式均断言，T-W4-2）；另有 `detect_roi` ≡ `letterbox_roi` + `restore_roi` 的代数一致性断言（T-W4-5 补）。
- 变形律 P4 后端注入律：`MockBackend` 与 `AltBackend` 输出同一 raw 时，除 `backend` 标注外 `PoseResult` 逐字段相等（已有 L0 用例，W2 入 golden）。
- 变形律 P5 **防火墙律**：任一 W# 合入后，旧 `detect`/`detect_multi`/`letterbox`/`letterbox_stretch`/`decode_output`/`decode_pose_batch`/`nms`/`restore`/`restore_stretch` 在既有 62 语料上输出逐字节不变、旧用例零改动全绿。
- Float16 位模式扫描：按指数段（正规/次正规/下溢/溢出/NaN/Inf）分段穷举代表值 + RNE 中点（1±k·2^-11、2^-25、3×2^-25、65520），与 `f32_to_f16_bits` 既有 22 条白盒断言对齐；当前 NaN 折叠为 `0x7E00`、下溢取偶的语义冻结，不得在扫描中「顺手修正」。
- 位翻转：输出张量关键 `(y,x,score)` 单 bit 翻转 → `OutputDecode`（非有限）或解码值改变；**格式依赖口径**：本格式有 Float32 数值域但无 checksum，翻转后可能仍是合法有限值，因此断言为「要么报声明错误类型，要么输出与翻转前不同」，不得断言全部必错。
- 边界值矩阵：空输入 0 字节、恰一块、非整数块、极值归一化坐标（±1e9）、`landmark_count` = 1/17/33/上界±1、输入张量 256 MiB 上界±1、`max_poses` 上界±1（W3）、镜像与贴边像素。
- 截断扫描（W2 已落地）：驱动 `scan_truncations(raw, spec, config)`（`pose_wbtest.mbt`）对每个 golden 输出张量遍历全前缀（小样本 17 点 204 字节全扫）+ 每 12 字节结构边界抽样；只允许声明的错误类型，不允许 panic/挂起。注册的分发入口：`decode_output`、`decode_pose_batch`（新增解析路径须登记进同一驱动）。
- 变异语料（W2 已落地）：驱动 `scan_mutations(raw, spec, config, count)`，固定种子 xorshift64 随机替换/插入/删除，**1000 变异体**；`nms` 额外注入非有限 score/bbox（W3 后必须 `InvalidConfig`，由 `变异扫描：nms 候选注入非有限值` 用例覆盖）。

## 5. L3 oracle 矩阵 + R runner

| oracle | 差分对象 | 规范化口径 |
|---|---|---|
| 外部推理运行时（W5 已裁决 A；具体模型/运行时由用户侧合法提供） | 本库 `letterbox` 输出字节与 `decode_output` 关键点值；只比双方共同声明的浮点字段，不比引擎内部中间张量/下游语义 | 逐元素绝对误差 <1e-4；输入图像、模型规格、dtype、归一化参数登记在报告中 |
| 第二后端（第二引擎/第二实现，属组合根） | 同一 raw 下 `detect` 的 `PoseResult` 值字段，忽略 `backend` 标注 | 逐字段相等（容差按 A6 口径）；缺失→SKIPPED |

纪律：oracle 缺失 → 显式 SKIPPED + 原因（退出码 78 口径），不得写成通过；oracle 版本/模型 SHA-256 随结果登记。R runner：样本路径 + 登记哈希 → 哈希不符拒绝执行 → 规范化差分 → 报告「本地已差分 + 哈希 + 日期」；入库占位用例保留不删，真实结论永不进入通过计数。

**runner 机制自检（2026-11-27）**：`bash tools/numeric-oracle.sh --selfcheck` 用确定性自产探针（临时目录固定 ASCII 字节；非第三方模型、零入库资产）走完整链路（SHA-256 计算 → 登记表 grep 门禁 → 比较命令执行 → 报告），实测覆盖 8 条路径。它只证明 runner **契约**可跑通，**不**产生任何数值一致性结论；真实 <1e-4 差分仍需用户提供仓库外合法模型并以显式 SKIPPED 之外的方式登记。

**双目标容差策略（A6/T-W2-4）**：wasm 与 native 同一 builder/断言各跑一次，**要求逐字节 diff = 0，不放宽任何容差**；若出现差异先定位根因（通常是未显式指定宽度的整数/浮点语义），修正代码或改为显式位级构造，**不得以容差掩盖**。外部 oracle（L3）的 <1e-4 容差仅适用于跨实现差分，与本库双目标等价无关。

## 6. 覆盖矩阵与错误簿记

### 6.1 能力×场景×安全 覆盖矩阵

现状列初测自 2026-11-17 P4 实测，已于 2026-11-27 W1–W6 落地后刷新（B# 见开发文档 §0）；✓=已有用例，◐=点状/间接覆盖，✗=待建。

| ID | 能力/场景 | L0 | L1 | L2 | L3 | L4 | 现状(P4) | 缺口→W# |
|---|---|---|---|---|---|---|---|---|
| F1 | 后端 trait + 包外可实现 | ✓ | ✗ | ✓ | ✗ | ✓ | Mock/Alt/TfliteAdapter 三实现（B8/B13） | 后端注入 golden→W2（已落地 ✓）；异步→W6（已落地 ✓） |
| F2 | detect/detect_multi 编排 | ✓ | ◐ | ✓ | ✗ | ✓ | 空检测/多姿态/NMS/预算路径（B9） | 端到端 golden→W2（已落地 ✓） |
| F3 | letterbox/stretch + 5 dtype | ✓ | ✓ | ✓ | ✗ | ✓ | 整数计划 + RNE 边界白盒 + 5 dtype golden（B10） | golden + dtype 扫描→W2（已落地 ✓）；整数溢出→W3（已落地 ✓） |
| F4 | decode 17/33 + batch + nms | ✓ | ✓ | ✓ | ✗ | ✓ | 布局/阈值/IoU 边界 + 截断/变异（B11/B22） | 截断变异→W2（已落地 ✓）；非有限候选→W3（已落地 ✓） |
| F5 | restore/restore_stretch 镜像 | ✓ | ◐ | ✓ | ✗ | ✓ | 纯函数 + 非法变换 + 双目标 golden（B12） | 双目标 golden→W2（已落地 ✓） |
| F6 | TfliteAdapter 生命周期/回退 | ✓ | ✗ | ✗ | ✗ | ✓ | 重复 open/close、形状、回退（B13） | 状态序列性质未纳入 W2（残余，非 T-W2 验收项） |
| F7 | 错误模型 8 变体 | ✓ | ✗ | ✓ | ✗ | ✓ | 显式簿记 8/8（B3） | 门禁化→W2（已落地 ✓，`tools/verify.sh`） |
| F8 | 配置域/预算校验 | ✓ | ◐ | ✗ | ✗ | ✓ | 256 MiB / landmark 上限 / 预算 + max_poses 上界（B14） | 极端乘法→W3（已落地 ✓） |
| F9 | 零引擎依赖/自包含 | ✓ | ✗ | ✗ | ✗ | ✗ | 零 import + 注释/CI 自包含（B15/B17 已修复） | 注释/CI 清理→W1（已落地 ✓） |
| F10 | ROI crop / 数值对齐 | ✓ | ◐ | ✗ | ◐ | ✗ | ROI 已交付（B16 部分补齐）；oracle runner 已建 | ROI→W4（已落地 ✓）；oracle→W5（已落地 A） |
| S1 | 预期场景端到端（单帧体感、换后端、17→33 配置迁移） | ✓ | | ✓ | | ✓ | 现有 88 条覆盖三场景 | 脚本化 golden→W2（已落地 ✓） |
| S2 | 安全拒绝场景（配置非法不触达后端、超预算、非有限输出写盘前拒绝） | ✓ | ◐ | | | ✓ | `seen_input_len=-1` 断言（B14/B9） | 非有限候选→W3（已落地 ✓） |
| C1 | 输入安全（畸形不 panic、内存有界、Int32 不回绕） | ✓ | ✓ | | | | 上界校验 + 系统截断/变异扫描（B14/B22/B23） | 截断+变异→W2（已落地 ✓）；极端乘法→W3（已落地 ✓） |
| C2 | 防火墙（新函数不改旧语义） | ✓ | ✓ | ✓ | | ◐ | 固化 golden + 双目标等价（B24 已修复） | P5/T-W2-5/T-W3-4→W2/W3（已落地 ✓）；T-W4-3→W4（已落地 ✓） |
| C3 | 许可红线（F-D 零入库） | ✓ | | | | | 零模型/二进制（B7/B25） | R runner 哈希门禁→W5（已落地 A） |
| C4 | 契约稳定（快照/README 索引/引用实存性） | ✓ | | | | | 双快照无漂移；README 索引一致、引用全实存（B2/B5/B18 已修复） | 清理→W1（已落地 ✓）；门禁→W2（已落地 ✓） |

C 行已含防火墙（C2）与许可红线（C3）两行。

### 6.2 错误变体触发簿记（8/8 强制）

| 变体 | 触发 fixture（初测 2026-11-17） | W3/W4 新增触发（均已落地） |
|---|---|---|
| `BackendNotOpen` | ✓ 未 open 调 `infer` / `close` / `detect`；Mock 与适配器双通道 | 无 |
| `BackendFailure` | ✓ 注入 invoke 失败、主/回退皆缺、重复 open、显式 `(kind, detail)` 断言 | 无 |
| `InvalidConfig` | ✓ 零 std / 越界阈值 / pad 越界 / 非法 Transform / 超大 spec / 非法 nms 阈值 | ✓ 非有限候选、极端 `max_poses`（W3 已落地） |
| `InvalidInput` | ✓ 图像尺寸与数据长度不符、非法 Transform 源尺寸、显式 `(w,h)` 断言 | ✓ 极端尺寸 Int64 判定（W3）；ROI 越界/零尺寸/负原点（W4 已落地） |
| `OutputDecode` | ✓ NaN y / NaN score 输出张量，白盒 + 黑盒双通道 | 位翻转语料（W2 已落地：变异扫描） |
| `ShapeMismatch` | ✓ 单块/批处理字节数不符、适配器输入/输出长度不符，显式 `(expected,actual)` 断言 | 截断扫描（W2 已落地） |
| `UnsupportedModel` | ✓ 非 3 通道模型输入（letterbox 与 stretch 两路径 + `letterbox_roi`） | 无 |
| `BudgetExceeded` | ✓ 34 块 > `max_poses=1`、3 块 > `max_poses=2` | ✓ 极端预算回绕回归（W3 已落地） |

显式簿记 **8/8**（2026-11-27 复核，每变体均有直接变体名断言，无死变体；`tools/verify.sh` 将此门禁化）；W3/W4 只增加触发语料，不新增变体（仍 8 个）。

### 6.3 恒等式断言（语义契约，全路径成立）

- 错误分类恒等式：配置错误不触达后端（`seen_input_len=-1`）；后端错误原样传播（`(kind,detail)` 逐字一致）；空输出张量 = 零检测（空 landmarks、score 0）而非 `OutputDecode`。
- `decode_output(raw)` 在 `raw.length()==landmark_count*3*4` 时保留顺序；`decode_pose_batch` 候选数 = `raw.length()/(landmark_count*3*4)`；两函数对长度为 0 的输入均返回空。
- `PoseCandidate.score` = 保留关键点 visibility 均值（空为 0）；`bbox` = 保留关键点轴对齐包围盒（空为零盒）；`name` 恒 `None`、`z` 恒 0（模型张量无名称/深度）。
- `BoundingBox::area` 对退化盒恒 0；`iou` 对相离/相接/退化盒恒 0、自身恒 1；`nms` 中 IoU **恰等于**阈值不抑制、严格大于才抑制；同分保持输入序；输入数组不被修改；`max_poses` 截断后按 score 降序。
- `TfliteAdapter.kind()` 恒为同一诊断标签、不参与调度；`used_fallback()` 一旦为 true 恒 true；`close` 后 `infer` 必为 `BackendNotOpen`。
- dtype 恒等式：Float16 NaN 恒折叠为 `0x7E00`；±0 保号；下溢 2^-25 平局取偶为带符号零；5 dtype 每元素字节数 4/2/1/1/4。
- **防火墙恒等式：任一 W# 合入后，旧 API 在全部既有语料上输出逐字节不变、旧用例零改动全绿**（纯文档/脚本包 W1/W5 以旧用例零改动全绿为准）。

### 6.4 #skip 清单（显式单列，永不计入通过）

| 用例 | 位置 | 原因 |
|---|---|---|
| （无） | — | 当前基线零 `#skip`（2026-11-27 实测：`moon test` **88/88**，含 W6-A 异步 2 条、W3 fail-closed 3 条、W2 golden 8 条 + 截断/变异扫描 3 条、W4 ROI 9 条、扫描器负对照 1 条；脚本层 SKIPPED 见下） |

计数口径：88 条声明（黑盒 59 + 白盒 29）− 0 条 `#skip` = 88 执行（2026-11-27，wasm；native 同为 88/88）；W5-A 的 `tools/numeric-oracle.sh` 在缺模型/缺比较命令时以退出码 78 SKIPPED，属脚本层独立口径，永不进入 `moon test` 通过计数；`--selfcheck` 仅在脚本层运行，不产生 `moon test` 用例。

### 6.5 验收 ID 双向追溯表

| `T-W*-*` | W#（开发文档） | 矩阵缺口行 | 断言/层 |
|---|---|---|---|
| T-W1-1 引用实存性扫描零失效 | W1（已落地 ✓） | C4、F9 | A5/L5 |
| T-W1-2 README 索引 ↔ mbti 逐条一致（含类型别名） | W1（已落地 ✓） | C4 | A5/L5 |
| T-W1-3 五门禁绿 + 双快照 diff 空 | W1（已落地 ✓） | C4 | A5/L5 |
| T-W1-4 CHANGELOG 建立并登记 | W1（已落地 ✓） | C4 | A5/L5 |
| T-W1-5 本地钩子序列与 CI 一致 | W1（已落地 ✓） | C4 | A5/L5 |
| T-W2-1 golden 集入库且被测试真实读取 | W2（已落地 ✓，8 条 golden） | F1–F5、S1 | A1/L2 |
| T-W2-2 dtype/Float16 边界性质全绿 | W2（已落地 ✓，5 dtype golden） | F3 | A1/A6/L1 |
| T-W2-3 截断 + ≥1000 变异无 panic | W2（已落地 ✓，1000 变异体） | C1、F4 | A4/L1 |
| T-W2-4 wasm/native 值输出 diff=0 | W2（已落地 ✓，W2 时点双目标 78/78；现 88/88） | F5、C2 | A6/L5 |
| T-W2-5 旧 62 用例零改动全绿（防火墙） | W2（已落地 ✓，67 用例零改动） | C2 | A5/L5 |
| T-W2-6 错误簿记 8/8 门禁化 | W2（已落地 ✓，`tools/verify.sh`） | F7 | A2/L5 |
| T-W3-1 NaN/Inf score 与 bbox → `InvalidConfig` | W3（已落地 ✓） | F4、S2 | A2/L0 |
| T-W3-2 极端尺寸图像 → `InvalidInput`，无越界读 | W3（已落地 ✓） | C1、F3 | A4/L0+L1 |
| T-W3-3 极端 `max_poses` → `InvalidConfig` 且预算不回绕 | W3（已落地 ✓） | F8 | A4/L0 |
| T-W3-4 防火墙：旧 62 用例零改动全绿 | W3（已落地 ✓，64/64） | C2 | A5/L5 |
| T-W3-5 截断/变异扫描无 panic | W3（扫描驱动 W2 已落地 ✓，覆盖 decode 路径） | C1 | A4/L1 |
| T-W4-1 ROI 边界（贴边/越界/零尺寸）断言 | W4（已落地 ✓） | F10 | A4/L0 |
| T-W4-2 ROI=全图时数值等价 | W4（已落地 ✓，等比 + stretch） | F10、C2 | A1/L1 |
| T-W4-3 旧 `detect` 在既有语料上逐字节不变 | W4（已落地 ✓，78 用例零改动） | C2 | A5/L5 |
| T-W4-4 快照 diff 纯加法、错误变体仍 8 个 | W4（已落地 ✓，5 项新增 pub） | C4、F7 | A5/L5 |
| T-W4-5 镜像 + ROI 组合坐标还原 | W4（已落地 ✓） | F10、F5 | A1/L0 |
| T-W5-1 有模型→差分报告与哈希登记 | W5（机制已闭环 ✓：`--selfcheck` 端到端验证 runner 契约 8 条路径；真实模型差分需用户侧提供仓库外合法模型） | F10、L3/R | A1/L3 |
| T-W5-2 无模型→显式 SKIPPED | W5（A 已落地 ✓，实测退出 78） | C3 | A2/L3 |
| T-W5-3 哈希不符拒绝执行 | W5（A 已落地 ✓，实测退出 1） | C3 | A4/R |
| T-W5-4 SKIPPED 不进通过计数 | W5（A 已落地 ✓） | C3 | A5/L5 |
| T-W6-1 裁决 A：新 trait/入口全绿且旧 62 用例零改动 | W6（A 已落地 ✓，64/64） | F1、C2 | A5/L0+L5 |
| T-W6-2 裁决 A：快照纯加法（+7 行）、错误变体仍 8 个 | W6（A 已落地 ✓） | C4、F7 | A5/L5 |
| T-W6-3 裁决 B 存档（未采纳） | W6（B 未采纳） | F1 | A5/L5 |

W5/W6 均已裁决并采纳 A；未采纳的 B 选项仅作历史存档，不表示当前仍待裁决。

## 7. L4 CLI 场景 E2E

本库无 CLI（`cmd/main` 为打印模板，B7）；L4 退化为库级编排 E2E，禁止把模板输出写成契约。

| 场景 | 调用序列 | 断言要点（错误分类 + 结果字段） |
|---|---|---|
| 单帧体感（letterbox） | `open` → `detect(mock, 200×100, keep_aspect=true, frame=7)` → `close` | `Ok`、17 点、首点 (100,50)、score/frame/timestamp/backend 标注、后端收到 192×192×3×4 字节 |
| 换后端不改上层 | 同帧分别 `detect(Mock)` 与 `detect(Alt)` | 位置/score 相等，`backend` 标注不同 |
| 配置迁移 17→33 | 仅改 `ModelSpec.landmark_count` 后 `decode_output` | 33 点、末点坐标与 visibility 正确 |
|  stretch 帧 | `keep_aspect=false` → `detect` | x/y 各按 `scale_x/scale_y` 还原、无填充参与 |
| 安全拒绝（配置非法） | `score_threshold=2.0` / `std=0` / `max_poses=0` → `detect` | `InvalidConfig`，`seen_input_len=-1`（未触达后端） |
| 安全拒绝（超预算） | 34 姿态块、`max_poses=1` → `detect` | `BudgetExceeded` |
| 安全拒绝（形状/非有限） | 10 点 raw / NaN 分量 → `detect` | `ShapeMismatch(204,120)` / `OutputDecode` |
| 零检测 | 空 raw → `detect` / `detect_multi` | `Ok`、空 landmarks、score 0（非错误） |

记录行/JSON 契约冻结口径：本库stdout/文件输出面为空（模板 main 不参与库契约）；未来若引入 CLI 即属新增契约，须单独快照与退出码矩阵。退出码矩阵 0/1/2 当前不适用（无 CLI），脚本层 runner 的 78（SKIPPED）按独立口径登记。

## 8. L5 元契约门禁

1. 快照门禁：`moon info` + `git diff --exit-code -- pkg.generated.mbti cmd/main/pkg.generated.mbti`（纯加法，快照随源码同提交）。
2. 双目标等价：同一程序化 builder 在 wasm/native 跑同输入，值输出逐字节 diff=0（浮点容差按 §5 登记）。
3. 错误簿记门禁：§6.2 的 8 变体 ↔ 测试代码显式变体名断言双向核对，缺一即红；新增触发语料不新增变体。
4. 变异自检（区分三类证据，不称全自动）：(a) **文本扫描门禁已自动化**——`tools/verify.sh` 对错误变体名、引用实存性等做静态核对；(a2) **机制自检已自动化**——`tools/numeric-oracle.sh --selfcheck` 用确定性自产探针验证 oracle runner 契约，扫描器负对照另由 `decode_capture_allowed` 测试证明断言非空转；(b) **人工缺陷注入尚未自动化**——改动 NMS 抑制 / 镜像位翻转 / Float16 RNE 对应逻辑时，临时注入 3 类缺陷（NMS 跳过抑制 / 镜像漏做 / RNE 改向零截断），确认套件变红后还原复绿；该项属发布前人工复核项。
5. 计数纪律：`#skip` 不计通过；过滤串以 `*` 结尾防空转假绿；SKIPPED 与退出码 78 单列报告。
6. 引用实存性扫描：`.mbt/.md/.yml/.sh/.ps1` 注释与文案引用的仓库内路径全部实存；README API 索引与快照逐条一致（含类型别名/方法/trait）；无工作区路径与兄弟模块符号。
7. 本地钩子一致性：`.githooks/pre-commit` 与 CI 五门禁同序（W1 后）。
8. oracle runner 机制门禁（2026-11-27）：`bash tools/numeric-oracle.sh --selfcheck` 用确定性自产探针走完整链路（哈希计算 → 登记表门禁 → 比较 → 报告），证明 runner 契约可用；它**不**替代真实模型差分，也**不**产生任何数值一致性结论。

## 9. CI 集成与执行入口

五门禁不变（`five-gates` job 已固化）；L0/L1/L2 挂 `moon test`；L3/L4/R/parity/mutation 为脚本层。
**单一仓库自包含入口（W2 已落地，2026-11-27 补 selfcheck）**：`bash tools/verify.sh` 串起五门禁 + native parity + 截断/变异自检 + 错误簿记 8/8 + 引用实存性 + **oracle runner 机制自检（强制）**；真实模型差分缺失时该步显式 SKIPPED（脚本整体退出码 78，表示「除真实差分外全绿」），`--no-native` 可跳过双目标步。
**CI 接线（2026-11-27）**：新增独立 `meta-contract` job 运行 `bash tools/verify.sh --no-native`，退出码 0/78 均按成功（78 = 真实差分显式 SKIPPED，不计入通过），其余按失败；与 `five-gates` job 互不替代。native 双目标等价因依赖 runner 主机 C 工具链、尚未在 GitHub Actions 实跑验证，故 CI 用 `--no-native`（本机等价实跑已通过），需要时显式去掉。
复验命令（本仓库根目录自包含）：

```bash
moon check --deny-warn
moon build
moon test
moon test --target native
moon fmt --check
moon info; git diff --exit-code -- pkg.generated.mbti cmd/main/pkg.generated.mbti
```

Windows 下 moon 把进度写 stderr，以退出码与 `Total tests: N, passed: N` 判定；语句分隔用 `;` 而非 `&&`。

## 10. 维护规则与验收清单

1. 新增 pub API ⇒ 同提交附 L0 样例 + L1 性质 + 矩阵/簿记更新；无测试不合入。
2. 新增解析/解码路径（含 ROI）⇒ 进截断扫描 fixture 集；非有限输入必走 §6.2 既有变体。
3. golden/登记哈希变更 ⇒ 黄金记录同提交更新，并附「仅受影响样本变化」对照。
4. 每包合入 ⇒ 开发文档 DoD 勾选 + 矩阵现状刷新 + CHANGELOG 测试增量。
5. 「通过」须可复验：命令 + 日期 + 计数；SKIPPED 永远单列。

落地验收：L0 ✓（88 条实跑）、L1 ✓（截断扫描 + 固定种子 1000 变异体 + 扫描器负对照）、L2 ✓（8 条 golden + `tests/golden/README.md` 登记）、L3 ◐（W5 已裁决 A，runner 机制已由 `--selfcheck` 端到端验证；真实模型差分需用户侧提供仓库外合法模型，缺省显式 SKIPPED）、L4 ✓（库级 E2E，无 CLI）、L5 ✓（快照/错误簿记 8/8/双目标等价/引用实存性/oracle 机制自检由 `tools/verify.sh` 门禁化；人工缺陷注入仍为人工复核，不得称全自动）、R ✗（零入库样本；W5-A 本地可选）；W1–W6 全部落地（W5/W6 已裁决并采纳 A）。
