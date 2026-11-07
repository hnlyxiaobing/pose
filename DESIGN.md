# pose · 设计契约（DESIGN.md）

> Round-1 / 2026-11-06 ｜ 状态：架构与声明可评审，无业务逻辑

## 1. 分层位置与职责

L3 感知绑定层的**门面（facade）**。职责：定义稳定的姿态检测 API、中性值类型与可插拔后端契约；编排「图像 → 前处理 → 推理 → 解码 → 关键点」。**不实现推理引擎**（架构原则 P4 / ADR-0004）。

## 2. 模块边界 / 依赖方向 / 数据流

```
yuv::RgbImage ──(组合根 Wire 适配)──► pose::RgbImage
                                        │ detect(&PoseBackend, ...)
                                        ▼
                            PoseBackend::infer(Bytes) -> Bytes
                                        ▲
                        组合根适配器（TfliteAdapter / OnnxAdapter / Mock）
                                        │
                            tflite_ffi::Interpreter 等（不知道 pose 存在）
```

**关键**：箭头只从组合根指向后端；`pose` 与后端之间**没有编译期依赖**，因此不存在 `pose ↔ tflite_ffi` 环。`pose` 用 `&PoseBackend` trait object（本机探针已验证该语法可用）。

## 3. 核心数据结构

| 类型 | 作用 |
|---|---|
| `PoseBackend` | trait：`open(PoseConfig)` / `infer(Bytes)->Bytes` / `close()` / `kind()`，全部 `raise PoseError` |
| `RgbImage` / `RgbLayout` | 门面侧中性图像值类型（与 `yuv` 同构） |
| `Landmark { x, y, z, visibility, name }` | 单点；坐标统一为输入图像像素系 |
| `PoseResult { landmarks, score, frame_id, timestamp_ns, backend }` | 一帧结果 |
| `ModelSpec` | 输入尺寸 / dtype / mean / std / 关键点数 / 输出张量索引（配置化缓解模型绑定） |
| `PoseConfig` | letterbox / 阈值 / NMS / max_poses / mirror_x |
| `Transform` | letterbox 逆变换参数 |
| `BackendKind` / `TensorDtype` | 诊断标识与张量类型 |
| `PoseError` | 区分配置 / 后端 / 解码 / 预算错误 |
| `FrameId` | `UInt64` 别名 |

## 4. 错误模型

`PoseError`：`BackendNotOpen`、`BackendFailure(kind, detail)`、`InvalidConfig`、`InvalidInput(w,h)`、`OutputDecode`、`ShapeMismatch(expected, actual)`、`UnsupportedModel`、`BudgetExceeded`。

分类意义：配置/输入错误不重试；`BackendFailure` 可重试或降级到另一后端；`BudgetExceeded` 触发帧率降级。错误由组合根映射，不泄漏后端错误类型。

## 5. 资源生命周期

门面侧全部纯值，无句柄。`PoseBackend::open` / `close` 由**实现方**负责后端资源；`detect` 不获取/释放资源，只调用 `infer`。`PoseResult` 只读、可跨线程共享。

## 6. 线程 / 并发边界

门面无可变状态、`detect` 可并发（前提是注入的后端实现允许）；**并发约束由 `&PoseBackend` 实现声明**并写进其 `DESIGN.md`。例如 `tflite_ffi` 规定同一 Interpreter 禁止并发 invoke。

## 7. 平台约束与外部依赖

- `preferred_target = "wasm"`（未改动），全后端；Mock 后端可在桌面跑。
- 外部依赖：无。后端由组合根注入；本库不 import `tflite_ffi` / `moon-ort` / MediaPipe。
- 模型事实：MoveNet.SinglePose Apache-2.0，Lightning `192×192×3`、输出 `[1,1,17,3]`；BlazePose/MediaPipe 33 点。第一轮按 17 点设计（Q8 待评审确认）。

## 8. 输入输出类型与错误传播（纯 MoonBit 库）

| 输入 | 输出 | 错误传播 |
|---|---|---|
| `&PoseBackend + RgbImage + PoseConfig + FrameId` | `PoseResult` | `PoseError` |
| `Bytes + ModelSpec + PoseConfig` | `Array[Landmark]` | `OutputDecode` / `ShapeMismatch` |
| `RgbImage + PoseConfig` | `(Bytes, Transform)` | `InvalidInput` |
| `PoseResult + Transform` | `PoseResult`（坐标还原） | `PoseError` |

`infer(Bytes) -> Bytes` 是 Tensor Wire；`ModelSpec` / `TensorDesc` 提供形状元数据，适配器负责校验。

## 9. 可替换性与实现细节不泄漏

上层只看到 `PoseBackend` / `PoseResult`；后端句柄、模型路径、量化格式、引擎版本**全部留在后端模块**。换后端 = 组合根换一个适配器，`detect` 签名不变。MediaPipe 若需异步回调式推理，可在 R4 增加 `infer_async` 而不改 `detect`。

## 10. 测试策略

| 层次 | 内容 |
|---|---|
| 黑盒 | Mock 后端：固定输入 → 固定关键点；换 Mock 实现不改调用 |
| 白盒 | letterbox 缩放/填充参数、还原变换、输出解码形状、阈值过滤、NMS |
| 错误路径 | 未 open、配置非法、输入尺寸错、输出形状不符、预算超限 |
| 门禁 | `moon fmt --check` / `moon check` / `moon test --enable-coverage` / `moon info` |

## 11. 验收标准（实现轮）

1. 换 TFLite / ONNX / Mock 后端不改上层 API；2. 关键点坐标还原正确；3. 与 Python `tflite-runtime` 数值对齐（后端侧 <1e-4）；4. R4 `--deny-warn` 转绿。

## 12. 未解决问题 / 待验证假设

- Q8：目标游戏是否需要 33 点 / 3D world landmarks（影响第一轮后端选型）。
- 异步推理后端（MediaPipe LIVE_STREAM）与当前同步 trait 的兼容性未验证。
- 模型商用条款（Q4）与设备帧率预算未实测。

## 13. 当前状态与 TODO

`pose.mbt` 已写入全部类型、`PoseBackend` trait 与 4 个 `declare` 函数，公开 API 有 `///` 文档注释与 `TODO(实现轮)`。**未实现任何编排/前后处理逻辑**。

## References

`../docs/dependency-graph.md` §1.1（MVL-S）· `../docs/adr/ADR-0002`、`ADR-0004`、`ADR-0005`、`ADR-0008` · `https://storage.googleapis.com/movenet/MoveNet.SinglePose%20Model%20Card.pdf`
