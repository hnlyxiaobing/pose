# hnlyxiaobing/pose

**姿态检测门面 —— 只定义 `PoseBackend` 接口与前后处理，推理后端可插拔。**

> 状态：**Round-1 架构与声明可评审**。已写入数据结构、`PoseBackend` trait 与 `declare` 签名，`moon check` 0 error（4 条预期 `0068` 告警）。**无业务逻辑**。

## 定位与为什么存在

路线图「拼图三」复核（2026-11-06）：`mediapipe` 命中全为无关包，`pose` / `landmark` 无任何可用绑定（仅 `fiducial_marker@0.1.1` 标记检测）。各家模型前后处理差异大，若不抽门面，上层会被具体引擎绑死。判定为**纯 MoonBit 自研门面**（`docs/capability-matrix.md` #09）。

**两个关键修正**：

1. **从 M2 提前到 W0**：原报告 M1 的退出标准是「取帧 → 姿态推理 → 电视渲染」，但 M1 交付清单里**没有 `pose`**（POS-01 在 M2），感知闭环逻辑上无法闭合（冲突 C2）。第一性原理给出的 MVL-S 必须有门面，但**不需要相机**——本地图片 + Mock 后端即可验证。
2. **门面持有 trait，后端不依赖门面**（ADR-0004）：`pose` 定义 `PoseBackend` 并通过 `&PoseBackend` trait object 调用；`tflite_ffi` / MediaPipe / ONNX 都不知道 `pose` 存在，由组合根写适配器。这样消除 K1 循环，且换后端不改上层 API。

## 能力范围 / 非目标

- **做**：`PoseBackend` trait（`open` / `infer` / `close` / `kind`）、中性 `RgbImage` / `Landmark` / `PoseResult` / `Transform`、`ModelSpec` / `PoseConfig` 配置化、`detect` 编排、letterbox 前处理、输出张量解码、关键点坐标还原。
- **不做**：取帧、YUV 转换、渲染、**实现推理引擎**、模型文件下载、模型 zoo、量化决策、后端句柄管理。
- 后端二选一/多选：TFLite（首选，ADR-0008）、MediaPipe（R4 增强）、ONNX Runtime（备选）、Mock（测试替身）。**本库不 import 任何一个**。

## 公开接口（速览）

`detect(&PoseBackend, RgbImage, PoseConfig, FrameId) -> PoseResult raise PoseError`、`decode_output`、`letterbox`、`PoseResult::restore`。完整签名见 `API.md`。

## 依赖

- **本轮零依赖**；独立 `moon.mod`，`moon check` 独立通过。
- 后续轮：后端适配器在**组合根**实现；`pose` 自身不引入 `tflite_ffi` / `moon-ort` / MediaPipe 依赖（ADR-0004、ADR-0010）。

## 平台与许可风险

- 平台：全后端（`preferred_target = "wasm"`，未改动）；Mock 后端可在桌面纯 MoonBit 测试。
- 许可：本仓库 Apache-2.0；门面自身无外部二进制。模型许可（MoveNet Apache-2.0、BlazePose/MediaPipe Apache-2.0）与 `.so` 分发许可由后端承担，见 ADR-0008。
- 风险：前后处理与模型强绑定（`ModelSpec` 配置化缓解）；MediaPipe 输出 33 点而 MoveNet 17 点；2GB 电视 5–15 fps 的帧率预算；`infer(Bytes) -> Bytes` 是无类型字节契约，形状错误只能在运行时发现（用 `ShapeMismatch` 报出）。
- `[待验证假设]` 目标游戏是否需要 33 关键点 / 3D world landmarks（`docs/open-questions.md` Q8）——评审需拍板。

## 测试与验收

- **测试策略**：Mock 后端纯 MoonBit 单测（无需 `.so` / 设备）；letterbox 还原参数断言；输出解码形状测试；配置非法 / 后端未 open / 输出解码失败的错误路径；`moon test --enable-coverage`。
- **验收标准**（实现轮）：换 TFLite / ONNX / Mock 后端不改上层调用；关键点坐标还原到输入图像坐标系正确；R4 `--deny-warn` 转绿。

## 当前状态 / 本轮产物

| 项 | 状态 |
|---|---|
| `pose.mbt` 数据结构 + `PoseBackend` trait + `declare` 签名 | ✅ |
| `pkg.generated.mbti` API 快照 | ✅ |
| 编排 / letterbox / 解码 / NMS / 后端适配器 | ❌ 后续轮，`TODO(实现轮)` |
| `moon check` | ✅ 0 error（4 × `0068`，预期） |

## 文档索引

`DESIGN.md` · `API.md` · `../docs/architecture.md` §4/§7 · `../docs/adr/ADR-0002`、`ADR-0004`、`ADR-0005`、`ADR-0008`
