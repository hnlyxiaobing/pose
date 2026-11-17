# pose 后端中立姿态门面开发文档

> 建立：2026-11-17 ｜ 状态：待开发 ｜ 适用仓库：本仓库（独立自包含）
> 配套文档：[2026-11-17-test-system-design.md](2026-11-17-test-system-design.md)（验收测试 ID `T-W*-*` 出自该文档）
> 本文所有「现状」结论均为 2026-11-17 对本仓库源码的实测核对，非转述历史文档。
> 五门禁 2026-11-17 实跑（开发前基线）：`moon check --deny-warn` 退出 0；`moon build` 退出 0；`moon test` **62/62 通过、0 条 #skip**；`moon fmt --check` 退出 0；`moon info` 后 `git diff --exit-code -- pkg.generated.mbti cmd/main/pkg.generated.mbti` 退出 0（双快照 SHA-256 前后不变）。工具链 moon 0.1.20261104 / moonc v0.10.20+65efd5b93，与 CI 版本锁一致。附加复验：`moon test --target native` 显示 62/62、退出 0（工具回报另附沙箱策略提示，本轮未复跑，逐字节双目标差分仍列缺口 B24）。
>
> 说明：本轮 P1 线索中包含仓库外的申报材料；其计数与「后续」口径一律按 P4 实测重核，本文只以「仓库外申报口径」泛称记录差异，不假定该材料在本仓库可访问、不回写。
>
> **裁决落地记录（2026-11-17，用户采纳推荐 A）**：W5-A 已新增 `tools/numeric-oracle.sh` + 空哈希登记（默认无条目，缺库/缺比较命令显式 SKIPPED/78，哈希未登记硬失败，真实结论不进通过计数）；W6-A 已新增 `AsyncPoseBackend` trait 与 `detect_async`/`detect_multi_async`（纯加法 +7 行快照、零新错误变体，旧同步入口逐字节不变），并新增 2 条异步防火墙测试（`moon test` **64/64**）。快照 diff 为纯加法，须与源码同提交。

## 0. 现状基线（实测核对，开发前必读）

能力点清单（P1 基准，仓库自足文档 + 公开 API 面核对后确立）：

- F1 `PoseBackend` 四方法契约（`open/infer/close/kind`）与包外可实现性（Mock / Alt 双测试替身）
- F2 `detect` / `detect_multi` 编排（前处理 → 后端推理 → 预算 → 解码 → NMS → 坐标还原）
- F3 letterbox 等比前处理 / stretch 非等比前处理、镜像采样、mean/std 归一化、五种 dtype 小端编码（含 Float16 RNE）
- F4 `decode_output` / `decode_pose_batch`（17 点与 33 点同构布局、阈值过滤）、`nms`（IoU 严格大于阈值、稳定降序、`max_poses` 截断）
- F5 `PoseResult::restore` / `restore_stretch`（模型输入像素系 → 原图系，镜像翻转）
- F6 `TfliteAdapter` 注入式适配器（三回调、生命周期状态机、输入/输出形状校验、后端缺失回退与 `used_fallback` 观测）
- F7 `PoseError` 错误模型（8 分类）与错误传播语义（配置错误不重试 / 后端错误可降级 / 预算超限触发帧率降级）
- F8 配置域校验（`validate_spec` / `validate_spec_and_config`）与 Int32 溢出上界、输出字节预算检查
- F9 零推理引擎依赖：不 import 任何后端、不持有模型/句柄、不实现推理
- F10 「后续」能力（ROI crop、与外部推理运行时的数值对齐、第二后端、真实绑定接线）的交付状态

非目标清单：不取帧、不做 YUV 转换、不渲染、不实现推理引擎、不管理模型文件下载；不把真实引擎句柄/模型路径引入本包；不封装任何外部任务式视觉 API；不把下游语义（动作识别、姿态评分、骨架绘制）带入结果类型；对 trait 的破坏性扩展（`infer_async` 等）冻结。

### B# 基线事实表

| # | 事实（已实现/缺口/漂移，含细节） | 证据位置（文件+函数/行段） |
|---|---|---|
| B1 | 已实现：公开面 = 7 个顶层 `pub fn`、`PoseError` 8 变体（含 `to_repr`）、13 个 `pub(all)` 值类型、1 个私有字段 `pub struct`、1 个 `pub(open) trait`、1 个类型别名；`TfliteAdapter` 8 个方法与 `PoseBackend` impl 均在快照中 | `pkg.generated.mbti` L9–169；`cmd/main/pkg.generated.mbti` |
| B2 | 漂移（API 索引）：README §3 自称自动抽取全部 `pub` 声明行，但遗漏 `pub type FrameId = UInt64`（其余逐条一致） | README.md L30–68 ↔ `pkg.generated.mbti` L161 |
| B3 | 已实现：8 个错误变体逐个数清且测试显式簿记 **8/8**（每变体均有直接变体名断言用例）；无死变体 | `pose.mbt` L268–277；`pkg.generated.mbti` L25–34；`pose_test.mbt` / `pose_wbtest.mbt` 变体名 Grep |
| B4 | 已实测：测试 **62/62**（黑盒 40 + 白盒 22）；`#skip` 全仓 0 条；native 目标 62/62、退出 0（附沙箱提示，未复跑） | `moon test` / `moon test --target native` 2026-11-17 实跑；`grep -c '^test "'` = 40 + 22 |
| B5 | 已实测：五门禁全绿；双快照 `moon info` 前后 SHA-256 分别为 `3bc2a78d…cad`/`6d7651f9…fcc`，diff 退出 0；工具链版本与 CI 锁定一致 | 2026-11-17 五门禁实跑记录；`moon version --all`；`.github/workflows/ci.yml` L42–46 |
| B6 | 漂移（计数）：`git rev-list --count HEAD` = **17**，仓库外申报口径写 16；本模块 README 未记提交数，差异仅登记不回写 | 2026-11-17 `git rev-list --count HEAD`；仓库外申报口径仅作线索 |
| B7 | 已实现：零第三方依赖、零模型/`.so` 入库、零 `tests/fixtures` 资产（全部测试为程序化字节构造）；`cmd/main` 为模板（仅 `println("Hello")`），无 CLI 契约 | `moon.mod` 无 import 块；目录实测；`cmd/main/main.mbt` L1–7；LICENSE = Apache-2.0 |
| B8 | 已实现（F1）：`pub(open) trait PoseBackend` 四方法冻结；包外 Mock/Alt 两替身与包内 `TfliteAdapter` 三实现证明可替换；`detect` 对三后端调用签名不变 | `pose.mbt` L100–105；`pose_test.mbt` L165–241、L328–350、L1411–1432 |
| B9 | 已实现（F2）：`detect` 委托 `detect_multi`，返回 NMS 后首姿态；空输出/全阈值过滤返回零检测空结果（score 0、`backend=kind()`），非报错；多姿态按 score 降序返回 | `pose.mbt` L1108–1127、L1141–1177；`pose_test.mbt` L482–496、L1201–1230、L1277–1295 |
| B10 | 已实现（F3）：letterbox 整数缩放计划 + 居中填充；stretch 非等比无填充；镜像采样 `x'=w-1-x`；均值/方差归一化；5 dtype 小端编码；Float16 RNE 含 NaN→`0x7E00`、±Inf、次正规与下溢边界 | `pose.mbt` L488–505、L691–732、L585–663、L748–844；`pose_wbtest.mbt` L160–223 |
| B11 | 已实现（F4）：`decode_output` 恰好一块、空张量返回空数组、非有限值 `OutputDecode`；`decode_pose_batch` 按块整数倍切分；`nms` 稳定插入排序 + IoU 严格 `>` 阈值 + 截断；bbox 退化 IoU=0 | `pose.mbt` L902–948、L961–999、L297–327；`pose_wbtest.mbt` L264–400 |
| B12 | 已实现（F5）：两种逆变换均纯函数、不夹取坐标、不修改输入；镜像还原 `x=source_width-1-x0`；非法 scale（含 NaN）与非法源尺寸分别报错 | `pose.mbt` L1008–1065；`pose_test.mbt` L884–972、L1080–1159 |
| B13 | 已实现（F6）：`TfliteAdapter` 三构造入口、主/回退绑定选择、未 open / 重复 open / 重复 close 错误、输入字节数 `ShapeMismatch(expected,actual)`、输出块整数倍校验、绑定失败原样传播；`kind()` 恒为 Tflite | `pose.mbt` L136–262；`pose_test.mbt` L1411–1534 |
| B14 | 已实现（F8）：`validate_spec` 正数域 + mean/std 长度/有限/非零 + landmark≤1e6 + 输入张量≤256 MiB（Int64 中间量避免溢出）；`validate_spec_and_config` 校验 pad∈[0,255]、阈值∈[0,1]、`max_poses>0`；`detect_multi` 预算 `block*max_poses` 超限即 `BudgetExceeded` | `pose.mbt` L409–471、L1147–1156；`pose_wbtest.mbt` L403–440；`pose_test.mbt` L471–479 |
| B15 | 已实现（F9）：仓库内无任何后端 import；`TfliteBinding` 由三个 `(PoseConfig)->Unit`、`(Bytes)->Bytes`、`()->Unit` 回调组成，真实解释器由组合根持有 | `pose.mbt` L4–8、L116–120；`moon.pkg`；目录实测 |
| B16 | 缺口（F10 「后续」逐项核对）：ROI crop 接口未交付（README §6 自述）；与外部运行时逐元素 <1e-4 对齐未做；第二后端与真实引擎接线均属组合根职责、不在本仓库；申报口径中的 NMS 阈值标定属目标应用配置，不是库能力 | README.md L82–83；`pkg.generated.mbti` 无 crop/layout 相关声明；目录实测无模型/依赖 |
| B17 | 漂移（自包含）：`pose.mbt` 注释引用兄弟模块的类型名与具体推理库模块/类型名（L5、L31、L41、L110、L145）；本仓库无对应 import，假定外部代码可访问，违反模块自包含约束（仅注释层，API 与行为不受影响） | `pose.mbt` L4–5、L31、L41、L110、L145 |
| B18 | 漂移（引用实存性）：源码/测试/CI 共 5 处引用本仓库内不存在的设计文档路径或节号（源码注释 2、测试注释 1、CI 注释 1、CI 失败消息 1）；实测四个疑似文档路径均不存在 | `pose.mbt` L4/L99；`pose_test.mbt` L301；`.github/workflows/ci.yml` L23/L119；目录实测 |
| B19 | 漂移（注释 vs 代码）：`detect_multi` 文档注释仍称「空输出张量 `OutputDecode`」，实测代码与既有测试均为零检测空数组；与仓库外申报口径记载的后续修正一致 | `pose.mbt` L1139 ↔ L1157 + `decode_pose_batch` L935–937；`pose_test.mbt` L1298–1326 |
| B20 | 口径待调整：README L4 称「本文件是本仓库唯一说明文档」；本轮两份带日期文档落 `docs/` 后须改为「唯一入口文档」并加 docs 索引（不改 API） | README.md L4；本轮交付物 |
| B21 | 门覆盖缺口：`.githooks/pre-commit` 仅执行 `moon check`，未覆盖其余四门禁；CI 五门禁完整，本地钩子与 CI 不一致 | `.githooks/pre-commit` L1–2 ↔ `.github/workflows/ci.yml` L96–122 |
| B22 | 健壮性缺口（nms fail-open）：`PoseCandidate` 为 `pub(all)`，包外可构造 `score=NaN` 或 bbox 含 NaN/Inf 的候选；`nms` 未校验数值有限性，NaN 比较使排序非全序、`iou` 返回 NaN 时 `NaN > threshold` 为假 ⇒ 异常候选永不被抑制 | `pose.mbt` L337–341、L961–999、L309–327（无 `is_finite` 校验） |
| B23 | 健壮性缺口（整数溢出面）：`letterbox` / `letterbox_stretch` 用 `w*h*src_ch` 的 Int32 乘法判数据长度，`detect_multi` 用 `block*max_poses` 做预算；合法 spec 有上界但源图尺寸与 `max_poses` 无上界，极端值可能回绕后误判长度或预算 | `pose.mbt` L768、L823、L1150–1152；对照 L425–431 的 Int64 防护仅覆盖 spec |
| B24 | 平台等价现状：wasm 62/62；native 62/62、退出 0；但无「同 fixture 双目标逐字节差分」golden，浮点边界（Float16/归一化）尚无跨目标一致性断言 | 2026-11-17 `moon test` + `moon test --target native`；测试文件无目标分支断言 |
| B25 | 许可与对标线索：仓库外申报口径称 17/33 点布局语义参考公开模型卡（Apache-2.0）且未移植代码；本仓库零第三方代码、零二进制资产，口径仅作线索，不据此声称任何外部文件可访问 | 仓库外申报口径（仅作线索）；`moon.mod`；目录实测 |

F# → B# 覆盖：F1→B8；F2→B9；F3→B10；F4→B11；F5→B12；F6→B13；F7→B3；F8→B14；F9→B15；F10→B16。

**对历史口径的修正**（以 2026-11-17 实测为准）：

1. 提交数：仓库外申报口径 16 → 实测 **17**（B6；申报材料在仓库外，不回写）。
2. README API 索引并非完整 pub 面：漏 `FrameId` 类型别名（B2）。
3. README「唯一说明文档」在 docs/ 交付后失效（B20）。
4. `detect_multi` 空张量语义：源码注释仍写 `OutputDecode`，代码与测试已是零检测空结果（B19）。
5. 62/62 测试、8 变体、零依赖、零 #skip、双快照无漂移均实测成立（B3/B4/B5/B7）；「后续」项逐项核对后 ROI crop 与数值对齐确认未实现（B16）。
6. 自包含漂移不止在文档：源码注释存在外部模块/类型引用（B17），CI 文案存在失效路径引用（B18）。

## 1. 硬约束（每个工作包都必须满足）

1. API 冻结：`pkg.generated.mbti`（含 `cmd/main` 快照）是冻结基线，只允许纯加法；禁止给 13 个 `pub(all)` 值类型加字段；禁止新增错误变体（`PoseError` 8 变体冻结，破坏性需求走 ADR+用户裁决+CHANGELOG+主版本四件例外）；校验失败用既有 `InvalidConfig`/`ShapeMismatch`/`BudgetExceeded` 等变体表达，不新增变体；语义变更走新函数新类型防火墙（W4/W6），旧 API 语义永不改变。
2. 加法三件套：快照随源码同提交且 diff 纯加法 + `docs/CHANGELOG.md` 登记 + CI 快照门禁绿。
3. 依赖不动：本模块零第三方依赖；工具链钉死 moon 0.1.20261104 / moonc v0.10.20+65efd5b93 / core 0.10.20+65efd5b93（CI 版本断言强制）；`TfliteBinding` 的三回调形态即依赖接口约束——本库只见字节与 `PoseError`，不得引入具体引擎类型或换用流式接口。
4. 许可红线：真实模型、`.so`、第三方二进制与许可不明样本永不入库；真实运行时差分只允许「仓库外本地路径 + SHA-256 登记 + 显式 SKIPPED」（W5）；入库测试资产一律确定性程序化构造（现状 B7 延续）。
5. 五门禁全绿才可合入；`#skip`/SKIPPED/退出码 78 不得写成通过。fail-closed 修复（W3：以前静默放行的非有限候选/越界乘法组合现在拒绝）属行为增强而非契约破坏（错误变体集合与 API 签名不变），但须 CHANGELOG 显式登记 + 回归确认仅受影响样本变化。
6. 边界不变量：不取帧、不做色彩转换、不渲染、不实现推理、不管理模型文件、不产出下游语义；`PoseBackend` 方法集冻结；firewall 条款——新函数合入后旧 `detect`/`detect_multi`/`letterbox`/`nms` 在全部既有语料上输出逐字节不变、旧用例零改动全绿。
7. 文档自包含：本文、配套文档、代码注释、帮助文本、CI/脚本不得引用或假定可访问本仓库之外的目录、路径或兄弟模块符号（B17/B18 为现存违例，W1 清理）；仓库外申报口径只以泛称描述，不写路径、不回写。

## 2. 业界对标摘要（P2 结论，证据三级标注）

**渠道与限定**：2026-11-17 经公开 web 渠道（官方 API 文档、搜索引擎、公开生态文章）调研；mooncakes 站内搜索此前实测为 422/SPA 无法穷举，本轮直接走公开渠道，不冒充已穷举。「未见同类」限定为：**MoonBit 语言 + 「后端可注入的前后处理门面（不持有推理引擎）+ 稳定值类型/错误契约」组合语义 + 2026-11-17 时点 + 上述公开渠道**。

| 能力（F#） | 本模块（B# 实测） | MediaPipe Tasks Vision PoseLandmarker | TensorFlow Lite Task Library 姿态估计器 | JS `@tensorflow-models/pose-detection` | Ultralytics YOLO-pose（Python） | OpenCV DNN + 自写后处理 |
|---|---|---|---|---|---|---|
| F1 可替换后端契约 | ✓ `pub(open)` trait + 三回调注入（B8/B13/B15） | ✗ 固定 MediaPipe 任务运行时，仅可换模型资产/委托 | ✗ 固定 Task Library 运行时 | ◐ 可切 TFJS 后端但非用户 trait | ✗ 固定 PyTorch/导出链 | ◐ 可换 DNN 后端但无统一门面 |
| F2 单帧/多姿态编排 | ✓ `detect`/`detect_multi` + 空检测语义（B9） | ✓ IMAGE/VIDEO/LIVE_STREAM + `numPoses` | ✓ 同步检测 API | ✓ `estimatePoses` | ✓ `model.track` | ✗ 需自行拼装 |
| F3 可配置前处理与 dtype | ✓ letterbox/stretch/镜像 + 5 dtype 小端（B10） | ◐ 内置 resize/归一化/色彩转换，但策略不可注入 | ◐ 由任务内 metadata 决定 | ◐ 由模型配置决定 | ◐ 框架内部决定 | ✓ 完全自控但需自写 |
| F4 关键点布局/解码/NMS | ✓ 17/33 同构布局、阈值过滤、姿态级 NMS（B11） | ✓ 33 点 + world landmarks + 分割掩码 | ✓ 关键点 + 置信度 | ✓ MoveNet 17 点等 | ✓ 17 点 + 跟踪 | ✗ 全自写 |
| F5 坐标还原 | ✓ 两种逆变换 + 镜像（B12） | ◐ 输出归一化坐标，像素换算由调用方做 | ◐ 同左 | ◐ 同左 | ◐ 输出图像系框/点 | ✗ 全自写 |
| F6 生命周期/形状校验 | ✓ 显式状态机 + `ShapeMismatch`/回退观测（B13） | ◐ `close()` + 任务初始化 | ◐ 解释器生命周期 | ◐ 模型释放 | ◐ 资源由框架管理 | ✗ 全自写 |
| F7 错误模型 | ✓ 8 分类冻结 + 显式簿记 8/8（B3） | ◐ 平台异常/任务异常 | ◐ Java/平台异常 | ◐ Promise reject | ◐ Python 异常 | ✗ 无 |
| F8 预算/配置域校验 | ✓ 上界与预算检查（B14） | ◐ `numPoses`/置信度阈值 | ◐ 置信度阈值 | ◐ `maxPoses` | ◐ conf/iou 参数 | ✗ 无 |
| F9 零引擎依赖 | ✓ 本包零 import（B15） | ✗ | ✗ | ✗ | ✗ | ◐ 仅依赖 DNN 模块 |
| F10 数值对齐/第二后端 | ✗ 未做（B16） | —（自身即参考实现之一） | — | — | — | — |

- 证据等级：MediaPipe 官方 API 页（输入 `MPImage`/`mp.Image`、输出归一化关键点、可选 world landmarks/分割掩码、`numPoses` 与三类置信度阈值、IMAGE/VIDEO/LIVE_STREAM 运行模式）与本轮搜索结果交叉印证 [已知常识]；其版本/维护状态 [需联网核实]。TFLite Task Library 与 JS 姿态检测库的职责划分 [已知常识]，具体参数/最新版本 [需联网核实]。Ultralytics 17 点输出与其 AGPL-3.0 许可提示 [需联网核实]（仅作许可红线对照，本模块不引入）。OpenCV DNN 为低层图像/推理模块而非姿态门面 [已知常识]。本模块全部列来自 2026-11-17 源码实测 [仅据本项目文档]。
- 最接近 1–3 名与重叠度：**MediaPipe Tasks Vision PoseLandmarker**（重叠最高：多姿态、置信度、运行模式与坐标输出；但它自带推理闭环，前处理策略与后端不可注入）；**TFLite Task Library 姿态估计器**（同属推理任务层，契约强但门面语义封闭）；**JS `@tensorflow-models/pose-detection`**（多模型统一入口最接近「换模型不改调用」，但仍绑定 TFJS 生态）。
- 差异化判断：本模块不是推理库，而是「**字节进出、后端可替换**」的中立层：把前处理、解码、NMS、逆变换规范成纯值契约，配合 8 分类错误与预算控制。组合语义（MoonBit + trait 注入 + 冻结值类型 + wasm 优先）在调研渠道内未见同类；换引擎不改上层调用是本模块而非对标库的卖点。
- 缺失能力清单：已声明非目标 = 推理引擎/取帧/渲染/模型管理/下游语义；真缺口 = ROI crop（B16）、数值对齐（B16/B24）、非有限候选 fail-open（B22）、整数溢出面（B23）、README 索引与注释漂移（B2/B17/B18/B19/B20）。

## 3. 边界裁决（P3 结论）

**本质职责（一句话）**：给定一帧 RGB 与一份模型规格，把后端黑盒返回的字节张量**忠实还原为输入图像像素系中可计数、可预算的关键点值**——只回答「张量是什么、坐标在哪、结果可信吗」，永不回答「用哪个引擎算、怎么取帧、怎么画」。

**边界判据**：是否停留在「纯值前处理 / 字节契约 / 解码与逆变换 / 错误分类」层面且不持有引擎句柄、模型文件或上层语义。满足者界内；需要真实解释器、相机/渲染、动作判定者界外（属组合根或应用层）。

| 灰区 | 判据结论 | 裁决 | 落点（W#） |
|---|---|---|---|
| G1 名称含引擎名的 `TfliteAdapter` | 界内：仅三回调编排、零 import、无引擎类型（B13/B15） | 冻结现有签名与语义；归属声明「真实解释器由组合根持有」；外部一致性锁：三回调字节契约进 golden；注释去掉外部模块引用 | W1、W2 |
| G2 姿态级 NMS 与通用目标检测 NMS | 界内：以关键点 bbox 去重是解码后处理；类别/anchor NMS 界外 | 冻结现有 `nms`签名；通用化走新函数新类型，旧函数输出不变 | W4（若扩展）、W2（恒等式） |
| G3 Float16 编码 vs 通用数值转换库 | 界内：作为模型输入编码的一环；独立 f16 工具库界外 | 冻结 `f32_to_f16_bits` 现有 NaN 折叠/下溢语义；新精度策略走新函数防火墙 | W2（性质固化） |
| G4 ROI crop（申报「后续」/ README 风险） | 界外于现有 API：改变前处理语义，不能改 `letterbox`/`detect` | 冻结 + 新函数新类型防火墙（`RoiRect`/`detect_roi`），旧入口零改动 | W4 |
| G5 与外部运行时的 <1e-4 数值对齐 | 界外于库 API：需外部模型/依赖，属验证层 | 冻结边界；脚本层 runner + 本地路径 + SHA-256 + 显式 SKIPPED，不进通过计数 | W5（裁决 A 已落地） |
| G6 异步推理（`infer_async` 等） | 界外于现有 trait：改方法集属破坏性变更 | 冻结 `PoseBackend`；如做，另立新 trait 防火墙；三选项交用户裁决 | W6（裁决 A 已落地） |
| G7 注释/CI 引用外部模块与失效文档 | 界内（自包含违约，非能力） | 纯文档修复，不动逻辑；仓库外申报口径只保留泛称 | W1 |

## 4. 工作包总览

| 包 | 名称 | 优先级 | 规模(S/M/L/XL) | API 影响 | 对应缺口(B#) |
|---|---|---|---|---|---|
| W1 | 漂移清理与自包含 | P0 | S | 无（仅文档/注释/CI/钩子） | B2、B6、B17–B21、B25 |
| W2 | 门面契约 golden 与双目标等价固化 | P1 | M | 无（脚本层 + 测试层） | B4、B24、G1/G2/G3 |
| W3 | fail-closed 输入加固 | P1 | S | 无（复用既有错误变体，签名不变） | B22、B23 |
| W4 | ROI 与新布局防火墙扩展 | P2 | M | 加法：`RoiRect` / `RoiTransform` / `letterbox_roi` / `detect_roi` | B16、G4 |
| W5 | 外部运行时数值 oracle runner（A 已落地） | P2 | L | 无（脚本层） | B16、B24、G5 |
| W6 | 异步后端门面（A 已落地） | P2 | M | 加法：新 trait + 2 个新入口（快照 +7 行） | G6、README §2 冻结声明 |

## 5. 工作包详细设计

### W1 漂移清理与自包含（P0/S）

**目标**：消除 B2/B17/B18/B19/B20/B21 六类已登记漂移，使文档、注释、CI 文案与代码现状一致且仓库自包含；B6 的提交数差异属仓库外申报口径，仅在此登记、不回写。
**非目标**：不改任何 `.mbt` 逻辑；不恢复仓库内不存在的历史设计文档；不删除任何既有 pub 声明或错误变体。
**新增 API**：无。
**实现要点**：
- `pose.mbt` L4/L5/L31/L41/L110/L145 注释：删除兄弟模块类型名与外部推理模块/类型名，改为自足表述（「由组合根适配等价的中性图像值」「由注入绑定承载具体引擎」）；`pose.mbt` L99、`pose_test.mbt` L301、CI 注释与 Gate5 失败消息中的失效文档路径/节号改为「README.md §1/§2/§3」或本仓库 docs 索引；改后对所有 `.mbt/.md/.yml/.ps1` 做引用实存性扫描。
- `pose.mbt` L1139 注释：空张量语义改为「零检测：返回空结果」，与 L1157 及既有测试一致。
- README §3 索引补 `pub type FrameId = UInt64`；L4「唯一说明文档」改为「唯一入口文档；带日期的开发/测试文档见 `docs/`」并加索引；抽取口径改为「全部 pub 声明（含类型别名/方法/trait/impl）」。
- `.githooks/pre-commit` 补齐五门禁（与 CI 同序），保留可跳过钩子的人手路径说明；不改变 CI 既有门禁顺序。
- 新建 `docs/CHANGELOG.md`，登记 W1（日期/工作包/新增 pub=无/快照 diff=空/测试增量=0），并注明仓库外申报口径不回写。
**验收**：T-W1-1 引用实存性扫描零失效；T-W1-2 README 索引 ↔ mbti 逐条一致（含类型别名）；T-W1-3 五门禁绿 + 双快照 diff 空；T-W1-4 CHANGELOG 建立并登记；T-W1-5 钩子序列与 CI 一致。

### W2 门面契约 golden 与双目标等价固化（P1/M）

**目标**：把现有 62 条点状断言升级为可回归的契约资产：绿包 golden、五种 dtype 与 Float16 边界扫描、截断/变异无 panic、wasm/native 逐字节差分、错误簿记门禁化（B4/B24）。
**非目标**：不改任何 pub API；不把真实运行时引入测试；不新增第三方依赖；不把 #skip 计入通过。
**新增 API**：无。
**实现要点**：
- 建 `tests/golden/` 确定性自产样例（测试代码字节 builder，非第三方模型）：letterbox 与 stretch 在 2 组尺寸 × 5 dtype × mirror 开关下的输入字节 + `Transform`/`StretchTransform` 全字段；decode `block` 与 `decode_pose_batch` 的 17/33 点边界；`detect` 端到端结果逐字段 golden（含 frame_id/timestamp/backend 标注）。
- 性质：同输入双次调用逐字节相等；`PoseResult::restore` 与 `restore_stretch` 在 `mirror_x=false` 时对同一模型坐标应满足各自逆变换恒等式；`nms` 输入数组不变、同分稳定、阈值边界（= 不抑制、> 抑制）；Float16 全 f32 位模式按指数/尾数分段扫描（重点次正规/下溢/RNE 中点），与既有 22 条白盒断言对齐。
- 截断扫描：每个 golden 输出张量的全前缀 + 每 12 字节结构边界；只允许 `OutputDecode`/`ShapeMismatch`/`InvalidConfig`/`BudgetExceeded`，无 panic/挂起；固定种子变异 ≥1000 体（替换/插入/删除）。
- 双目标：同一 builder 在 wasm/native 各跑一次，值输出逐字节 diff=0；浮点差异先定位再定 golden 容差，容差策略写进测试文档 §5（不得默默放宽）。
- 脚本层 `tools/verify.sh`（仓库自包含）：串起五门禁 + native parity + 变异 + 错误簿记 8/8 + 引用实存性；oracle 缺失显式 SKIPPED。
**验收**：T-W2-1 golden 集入库且由测试真实读取（非死资产）；T-W2-2 dtype/Float16 边界性质全绿；T-W2-3 截断+≥1000 变异无 panic；T-W2-4 wasm/native 值输出 diff=0；T-W2-5 旧 62 用例零改动全绿（防火墙）；T-W2-6 错误簿记 8/8 门禁化。

### W3 fail-closed 输入加固（P1/S）

**目标**：关闭 B22（非有限候选导致 NMS fail-open）与 B23（Int32 乘法回绕）两处静默放行。
**非目标**：不新增错误变体；不改任何合法输入的现有输出；不自动修复/夹取异常候选；不改 `BoundingBox::area/iou` 的纯数学签名（外部直接调用保持原语义）。
**新增 API**：无（mbti diff 为空）。
**实现要点**：
- `nms` 入口逐个候选校验 `score` 与 `bbox` 四坐标 `is_finite()`，非有限即 `InvalidConfig("nms: non-finite candidate ...")`；复用既有变体，消息为新增文本（属加法）；排序与 IoU 主体不变。
- `letterbox`/`letterbox_stretch`：源图尺寸上限与 `w*h*src_ch` 用 Int64 中间量计算并与 `Bytes.length()` 比较，越界或不符 `InvalidInput(w,h)`；采样偏移 `(tx-pad)*w/scaled_w` 随之上界受控。
- `detect_multi` 预算：`block.to_int64()*max_poses.to_int64()` 与 `raw.length()` 比较，`max_poses` 上界并入 `validate_spec_and_config`（超大值 `InvalidConfig`），避免回绕成负预算；错误变体仍为 `BudgetExceeded`/`InvalidConfig`。
- 三项按 fail-closed 修复例外登记 CHANGELOG；回归语料确认只有非有限候选/极端尺寸/极端 max_poses 样本改变行为，原 62 用例零改动全绿。
**验收**：T-W3-1 NaN/Inf score 与 bbox → `InvalidConfig`（包外构造候选亦成立）；T-W3-2 极端尺寸图像 → `InvalidInput`，无越界读；T-W3-3 极端 `max_poses` → `InvalidConfig` 且预算不回绕；T-W3-4 防火墙旧 62 用例零改动全绿；T-W3-5 截断/变异扫描无 panic。

### W4 ROI 与新布局防火墙扩展（P2/M）

**目标**：落地 README §6 自述未交付的 ROI crop（B16），并把「换关键点布局」限制在新函数新类型内。
**非目标**：不改 `detect`/`detect_multi`/`letterbox`/`letterbox_stretch` 一行语义；不在本包做图像解码/裁剪分配器以外的语义；不引入第二推理引擎。
**新增 API（mbti 草案，纯加法）**：

```text
pub(all) struct RoiRect {
  x : Int32
  y : Int32
  width : Int32
  height : Int32
}
pub(all) struct RoiTransform {
  scale_x : Double
  scale_y : Double
  offset_x : Int32
  offset_y : Int32
  source_width : Int32
  source_height : Int32
  mirrored : Bool
}
pub fn letterbox_roi(RgbImage, PoseConfig, RoiRect) -> (Bytes, RoiTransform) raise PoseError
pub fn detect_roi(&PoseBackend, RgbImage, PoseConfig, RoiRect, FrameId) -> PoseResult raise PoseError
```

**实现要点**：`RoiRect` 越界/非正尺寸 → `InvalidInput(x,y)`（复用既有变体，不新增）；`letterbox_roi` 复用 `resize_encode` 与 W3 的 Int64 长度检查，ROI 坐标进入 `RoiTransform` 由 `restore` 新函数（同包内新入口、不改旧 `restore`）还原；`detect_roi` 复用 `detect_multi` 的预算/NMS 流程，但分派 ROI 前处理；`RoiRect` 为全新 struct，不给 `Transform`/`PoseConfig` 加字段；快照 diff 必须纯加法并登记 CHANGELOG。
**验收**：T-W4-1 ROI 边界（贴边/越界/零尺寸）断言；T-W4-2 ROI 与全图在 ROI=全图时数值等价（新律）；T-W4-3 旧 `detect` 在既有 62 语料上逐字节不变；T-W4-4 快照 diff 纯加法 + 错误变体仍 8 个；T-W4-5 镜像 + ROI 组合坐标还原断言。

### W5 外部运行时数值 oracle runner（裁决 A 已落地，P2/L）

**目标**：在许可与模块边界内回答「前处理字节与解码值是否与外部推理运行时一致（<1e-4）」（B16/B24、G5）。
**非目标**：不把模型、第三方运行时或许可不明二进制入库；不把真实差分写入 CI 通过计数；不改任何 API。
**须裁决选项**：
- **A（推荐，2026-11-17 采纳并落地）**：建仓库自包含脚本 `tools/numeric-oracle.sh`，输入为仓库外本地模型路径 + SHA-256 登记文件；哈希不符拒绝执行；用确定性自产图像跑外部运行时与本库 `letterbox`/`decode_output`，只比双方共同声明的浮点值字段，容差 1e-4；无模型/依赖时输出显式 SKIPPED（退出码 78 口径），不计通过。需用户确认外部模型可合法用于本地差分并提供路径。
- **B（零成本降级）**：不建 runner；README §6 与测试文档 L3/R 维持「未实现/需本地配置」声明，仅把本轮实测的 62/62 与双目标结论作为内部一致性证据。
- **C（不推荐）**：把模型与运行时依赖引入仓库或 CI 镜像——触碰许可红线与零依赖约束，除非用户另行裁决四件例外，否则不执行。
**实现要点（A）**：脚本不引用工作区路径或兄弟模块；样本路径由参数注入；报告登记哈希/日期/工具链版本/容差与失败样本；入库占位用例以 `#skip` 单列且永不冒充通过。
**验收**：T-W5-1 有模型→差分报告与哈希登记；T-W5-2 无模型→显式 SKIPPED；T-W5-3 哈希不符拒绝执行；T-W5-4 SKIPPED 不进通过计数。

### W6 异步后端门面（裁决 A 已落地，P2/M）

**目标**：回应 README §2「`infer_async` 属破坏性变更须裁决」的冻结灰区（G6）。
**非目标**：不改 `PoseBackend` 方法集；不引入 async 运行时依赖；不在未裁决前写任何"已实现"。
**须裁决选项**：
- **A（推荐，2026-11-17 采纳并落地）**：新增独立 trait（如 `AsyncPoseBackend`）与 `detect_async` 新入口，完全走新类型/新函数防火墙；旧 trait 与旧 `detect` 零改动，快照纯加法。
- **B（零成本降级）**：维持现状，README 明确「异步后端属非目标，由组合根在包外编排」，测试文档该行保持「未实现」。
- **C（不推荐）**：给 `PoseBackend` 增加 `infer_async` 方法——破坏性变更，须 ADR + 用户裁决 + CHANGELOG + 主版本四件例外齐备方可启动。
**实现要点（A）**：异步 trait 仅定义字节进出的 async 契约，不引入引擎类型；所有既有同步路径逐字节不变；新增 L0/L1 断言与快照纯加法登记。
**验收**：T-W6-1（裁决 A 时）新 trait/入口全绿且旧 62 用例零改动；T-W6-2（裁决 A 时）快照 diff 纯加法、错误变体仍 8 个；T-W6-3（裁决 B 时）README 非目标声明落盘、测试文档保持未实现。

## 6. 里程碑与合入顺序

```text
M0（第1日）   W1 漂移清理与自包含（零风险文档/注释/CI/钩子）
M1            W3 fail-closed 输入加固（安全缺口，行为增强例外流程）
M2            W2 契约 golden + 双目标等价（高价值低成本）与 W4 ROI 防火墙（新能力）
M3（已落地）  W5 外部 oracle runner（A：哈希登记 + SKIPPED 纪律）
M4（已落地）  W6 异步后端门面（A：新 trait + 新入口，纯加法）
```

排序判据：先零风险文档、再安全缺口、再高价值低成本、最后安全敏感/大工程与须裁决项；每包独立提交、独立过五门禁；W5/W6 已于 2026-11-17 由用户裁决采纳 A 并落地，不再列为待裁决项。

## 7. 簿记与变更管理

- `docs/CHANGELOG.md`：每包登记「日期/工作包/新增 pub 声明/快照 diff 结论/测试增量」；W1 首条记「无新增、diff 空、增量 0」。
- README §3 API 索引随 `moon info` 快照同步（含类型别名/方法/trait），禁手编 mbti；索引抽取口径随 W1 修正。
- 提交数等易漂移计数以本仓库 git 实测为准；仓库外申报口径与本仓库文档不一致时不反向回写。
- 破坏性需求一律走 ADR + 用户裁决 + CHANGELOG + 主版本四件例外；本轮所有 W# 均满足零新错误变体。
- fail-closed 修复（W3）在 CHANGELOG 显式登记「以前静默放行的输入现在拒绝」，并附仅受影响样本的回归对照。

## 8. 完成定义（DoD，逐包勾选）

- [ ] 新增 API 与 mbti 草案一致（偏差回写本文）；零新增错误变体
- [ ] 快照 diff 纯加法（或空），CHANGELOG 已登记
- [ ] `T-W*-*` 验收全绿；`#skip` 显式标注原因、不计通过
- [ ] 五门禁全绿；无 CLI 契约意外引入（现状为模板 main）
- [ ] 防火墙回归：新函数/新包合入后旧 API 在既有语料上输出逐字节不变、旧用例零改动全绿（W1/W5 纯文档脚本包以「旧用例零改动全绿」为准）
- [ ] 畸形输入（非有限候选、极端尺寸、截断/变异张量）无 panic、无越界
- [ ] 零新第三方依赖；零许可不明二进制入库
- [ ] README 能力/非目标/API 索引同步；本文状态行更新「已交付+日期」
- [ ] 自包含扫描：docs + 代码注释 + 帮助文本 + CI/脚本无工作区路径与兄弟模块符号引用

## 9. 风险登记

| 风险 | 等级 | 缓解 |
|---|---|---|
| 浮点跨目标差异使 wasm/native 逐字节 golden 无法统一 | 中 | W2 先定位差异来源再定容差；容差口径写入测试文档 §5，不静默放宽 |
| `pub(all) PoseCandidate` 允许外部构造非有限值，加固后可能改变下游行为 | 中 | W3 按 fail-closed 例外流程：CHANGELOG 显式登记 + 回归只影响异常样本；合法输入输出不变 |
| ROI 扩展被误做成对旧 `detect` 的语义修改 | 高 | W4 强制新类型新函数防火墙 + T-W4-3 逐字节回归 + 快照纯加法门禁 |
| 真实模型/外部运行时差分触碰许可与零依赖红线 | 高 | W5 仅脚本层 + 本地路径 + 哈希 + 显式 SKIPPED；未裁决前不启动 |
| 仓库外申报口径继续被当作事实引用 | 中 | 本文 §0 集中登记修正；产出文档只用泛称，不写路径、不回写 |
| 异步后端诉求通过改 trait 落地造成破坏性变更 | 中 | W6 三选项冻结；未裁决前 `PoseBackend` 方法集零改动 |
