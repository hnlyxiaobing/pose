# hnlyxiaobing/pose

**姿态检测门面 —— 只定义 `PoseBackend` 接口与前后处理，推理后端可插拔。**

> 状态：**R4 增量实现（2026-11-09）**。`detect`/`detect_multi` 编排、letterbox/stretch 前处理、输出解码、**NMS 姿态去重**、**Float16 编码**、坐标还原与 **TfliteAdapter 注入式后端适配器**均已实现；`moon check --deny-warn` 0 error 0 warning、`moon test` 62/62 全过（基线 30）。`PoseBackend` 方法集与 `PoseError` 可见性保持冻结，R4 变更全部为加法性。

## 定位与为什么存在

选型复核（2026-11-06 检索 mooncakes.io）：`mediapipe` / `pose` / `landmark` 无可用 MoonBit 绑定（仅 `fiducial_marker@0.1.1` 标记检测），故门面**纯 MoonBit 自研**。各家模型前后处理差异大，若不抽门面，上层会被具体引擎绑死。

**两个关键修正**：

1. **提前到第一轮实现**（原计划把它排在相机之后的后置阶段）：原计划「取帧 → 姿态推理 → 电视渲染」的闭环验收清单里**没有 `pose`**，感知闭环逻辑上无法闭合。感知最小闭环（本地图片 → 姿态推理 → 关键点）必须有门面，但**不需要相机**——本地图片 + Mock 后端即可验证（详见 `docs/DECISIONS.md`「附：开发顺序结论」）。
2. **门面持有 trait，后端不依赖门面**：`pose` 定义 `PoseBackend` 并通过 `&PoseBackend` trait object 调用；`tflite_ffi` / MediaPipe / ONNX 都不知道 `pose` 存在，由组合根写适配器。这样消除「门面→后端、后端→门面」的潜在循环依赖，且换后端不改上层 API（决策详见 `docs/DECISIONS.md` 决策 1）。

## 能力范围 / 非目标

- **做**：`PoseBackend` trait（`open` / `infer` / `close` / `kind`）、中性 `RgbImage` / `Landmark` / `PoseResult` / `Transform` / `StretchTransform` / `BoundingBox` / `PoseCandidate`、`ModelSpec` / `PoseConfig` 配置化、`detect`/`detect_multi` 编排、letterbox 等比前处理、stretch 非等比前处理、Float16 编码、输出张量解码、**NMS 姿态去重**、关键点坐标还原、`TfliteAdapter` 注入式后端适配器骨架。
- **不做**：取帧、YUV 转换、渲染、**实现推理引擎**、模型文件下载、模型 zoo、量化决策、后端句柄管理。
- 后端二选一/多选：TFLite（首选，`TfliteBinding` 由组合根注入）、MediaPipe（后续增强后端，P2）、ONNX Runtime（备选，P2）、Mock（测试替身），选型理由见 `docs/DECISIONS.md` 决策 2。**本库不 import 任何一个**，也不持有任何引擎句柄。

## 公开接口（速览）

`detect(&PoseBackend, RgbImage, PoseConfig, FrameId) -> PoseResult`、`detect_multi(...) -> Array[PoseResult]`、`decode_output`、`decode_pose_batch`、`nms`、`letterbox`、`letterbox_stretch`、`PoseResult::restore` / `restore_stretch`、`TfliteAdapter`（`new` / `unavailable` / `with_fallback` / `used_fallback`）。完整签名见 `docs/API.md`。

`PoseBackend`（`pub(open)`）**方法集已冻结为 `open` / `infer` / `close` / `kind` 四个方法，冻结后增删方法即破坏性变更**；`close` 幂等语义：**不会二次释放，重复调用返回明确错误**（本库无 `detach` 方法）。`PoseError` 为 `pub(all) suberror`（包外适配器可构造）。

## 依赖

- **本轮零依赖**；独立 `moon.mod`，`moon check` 独立通过。
- 后续轮：后端适配器在**组合根**实现；`pose` 自身不引入 `tflite_ffi` / `moon-ort` / MediaPipe 依赖（零依赖与引入门槛见 `docs/DECISIONS.md` 决策 5）。

## 平台与许可风险

- 平台：全后端（`preferred_target = "wasm"`，未改动）；Mock 后端可在桌面纯 MoonBit 测试。
- 许可：本仓库 Apache-2.0；门面自身无外部二进制。模型许可（MoveNet Apache-2.0、BlazePose/MediaPipe Apache-2.0）与 `.so` 分发许可由后端承担，口径见 `docs/DECISIONS.md` 决策 2。
- 风险：前后处理与模型强绑定（`ModelSpec` 配置化缓解）；MediaPipe 输出 33 点而 MoveNet 17 点；2GB 电视 5–15 fps 的帧率预算；`infer(Bytes) -> Bytes` 是无类型字节契约，形状错误只能在运行时发现（用 `ShapeMismatch` 报出）。
- `[待验证假设]` 目标应用是否需要 33 关键点 / 3D world landmarks 尚待评审——评审需拍板；若需要，第一轮后端选型需复议（见 `docs/DECISIONS.md` 决策 4）。

## 测试与验收

- **测试策略**：Mock/Alt 后端与注入式 `TfliteBinding` mock 纯 MoonBit 单测（无需 `.so` / 设备）；letterbox/stretch 字节与还原参数断言；输出解码/多姿态 NMS 形状与排序测试；f16 逐值与集成；配置非法 / 后端未 open / 输出解码失败 / 预算超限 / 后端缺失回退的错误路径。test 包内 `MockBackend` / `AltBackend` 实现 `@pose.PoseBackend`，兼作「包外可实现」证据。
- **门禁（实跑，全部 exit 0）**：`moon clean` · `moon check --deny-warn` · `moon build` · `moon test`（62/62 全过）· `moon fmt --check` · `moon info` + 快照 diff。
- **验收标准**（实现轮）：换 TFLite / ONNX / Mock 后端不改上层调用；关键点坐标还原到输入图像坐标系正确；`moon check --deny-warn` 转绿（已达成）。与 Python `tflite-runtime` 的 <1e-4 数值对齐属 P2，**本轮未做**。

## 当前状态 / 本轮产物

| 项 | 状态 |
|---|---|
| `pose.mbt` 数据结构 + `PoseBackend` trait + 实现（detect/detect_multi / letterbox/letterbox_stretch / decode_output/decode_pose_batch / nms / restore/restore_stretch） | ✅ |
| `TfliteAdapter` + `TfliteBinding`（组合根注入、无 `tflite_ffi` import） | ✅ 骨架 + mock 注入测试；真实引擎绑定由组合根实现（未接入） |
| `pkg.generated.mbti` API 快照（R4 加法性新增已随源码提交） | ✅ |
| 编排 / letterbox / 解码 / 坐标还原 | ✅ 已实现，62 测试全过（基线 30 → 62） |
| NMS / Float16 / stretch | ✅ 已实现（真实模型上的 NMS 阈值标定属后续实测） |
| API 冻结（`PoseBackend` 四方法 / `PoseError` `pub(all)`） | ✅ 保持冻结（2026-11-07），R4 无破坏性变更 |
| 门禁 `moon clean` / `check --deny-warn` / `build` / `test` / `fmt --check` / 快照 diff | ✅ 全部 exit 0 |
| P2（MediaPipe/ONNX 第二后端、tflite-runtime 数值对齐） | ❌ 本轮未做（如实登记） |

## 文档索引

`docs/DESIGN.md`（设计契约）· `docs/API.md`（公开 API）· `docs/DECISIONS.md`（设计决策记录：门面持有 trait / 推理后端选型 / 零跨模块依赖与同构值类型 / 模型输出布局基准 / 依赖政策）
