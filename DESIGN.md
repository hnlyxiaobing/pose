# pose · 设计契约（DESIGN.md）

> API 冻结轮 / 2026-11-07 ｜ 状态：实现完成、门禁全绿；`PoseBackend` 方法集与 `PoseError` 可见性已冻结

## 1. 分层位置与职责

L3 感知绑定层的**门面（facade）**。职责：定义稳定的姿态检测 API、中性值类型与可插拔后端契约；编排「图像 → 前处理 → 推理 → 解码 → 关键点」。**不实现推理引擎**（门面拥有 trait、后端不依赖门面，见 `DECISIONS.md` 决策 1）。

## 2. 模块边界 / 依赖方向 / 数据流

```
yuv::RgbImage ──(组合根纯值适配)──► pose::RgbImage
                                        │ detect(&PoseBackend, ...)
                                        ▼
                            PoseBackend::infer(Bytes) -> Bytes
                                        ▲
                        组合根适配器（TfliteAdapter / OnnxAdapter / Mock）
                                        │
                            tflite_ffi::Interpreter 等（不知道 pose 存在）
```

**关键**：箭头只从组合根指向后端；`pose` 与后端之间**没有编译期依赖**，因此不存在 `pose ↔ tflite_ffi` 的潜在循环依赖。`pose` 用 `&PoseBackend` trait object（MoonBit 的 `&Trait` 语法已实测可用）。

## 3. 核心数据结构

| 类型 | 作用 |
|---|---|
| `PoseBackend` | `pub(open)` trait：`open(PoseConfig)` / `infer(Bytes)->Bytes` / `close()` 均 `raise PoseError`，`kind()` 返回 `BackendKind` 不抛错；**方法集已冻结为这四个方法，冻结后增删方法即破坏性变更** |
| `RgbImage` / `RgbLayout` | 门面侧中性图像值类型（与 `yuv` 同构） |
| `Landmark { x, y, z, visibility, name }` | 单点；坐标统一为输入图像像素系 |
| `PoseResult { landmarks, score, frame_id, timestamp_ns, backend }` | 一帧结果 |
| `ModelSpec` | 输入尺寸 / dtype / mean / std / 关键点数 / 输出张量索引（配置化缓解模型绑定） |
| `PoseConfig` | letterbox / 阈值 / NMS / max_poses / mirror_x |
| `Transform` | letterbox 逆变换参数 |
| `BackendKind` / `TensorDtype` | 诊断标识与张量类型 |
| `PoseError` | `pub(all) suberror`（包外适配器可构造）：区分配置 / 后端 / 解码 / 预算错误 |
| `FrameId` | `UInt64` 别名 |

## 4. 错误模型

`PoseError`：`BackendNotOpen`、`BackendFailure(kind, detail)`、`InvalidConfig`、`InvalidInput(w,h)`、`OutputDecode`、`ShapeMismatch(expected, actual)`、`UnsupportedModel`、`BudgetExceeded`。

分类意义：配置/输入错误不重试；`BackendFailure` 可重试或降级到另一后端；`BudgetExceeded` 触发帧率降级。错误由组合根映射，不泄漏后端错误类型。

可见性（决策 4 追认）：`PoseError` 为 `pub(all) suberror`，包外后端适配器可直接构造这些错误值向上传播；`pose` 包内仅此一个错误类型，未放宽任何其他错误类型。

## 5. 资源生命周期

门面侧全部纯值，无句柄。`PoseBackend::open` / `close` 由**实现方**负责后端资源；`detect` 不获取/释放资源，只调用 `infer`。`close` 的幂等语义（统一措辞）：**不会二次释放，重复调用返回明确错误**。本门面无 `detach` 方法（`close` 是唯一资源释放入口）。`PoseResult` 只读、可跨线程共享。

## 6. 线程 / 并发边界

门面无可变状态、`detect` 可并发（前提是注入的后端实现允许）；**并发约束由 `&PoseBackend` 实现声明**并写进后端模块自身文档。例如基于 TFLite 的后端可规定同一 Interpreter 禁止并发 invoke。

## 7. 平台约束与外部依赖

- `preferred_target = "wasm"`（未改动），全后端；Mock 后端可在桌面跑。
- 外部依赖：无。后端由组合根注入；本库不 import `tflite_ffi` / `moon-ort` / MediaPipe。
- 模型事实：MoveNet.SinglePose Apache-2.0，Lightning `192×192×3`、输出 `[1,1,17,3]`；BlazePose/MediaPipe 33 点。第一轮按 17 点设计（是否需要 33 点 / 3D world landmarks 待评审确认，见 `DECISIONS.md` 决策 4）。

## 8. 输入输出类型与错误传播（纯 MoonBit 库）

| 输入 | 输出 | 错误传播 |
|---|---|---|
| `&PoseBackend + RgbImage + PoseConfig + FrameId` | `PoseResult` | `PoseError` |
| `Bytes + ModelSpec + PoseConfig` | `Array[Landmark]` | `OutputDecode` / `ShapeMismatch` |
| `RgbImage + PoseConfig` | `(Bytes, Transform)` | `InvalidInput` |
| `PoseResult + Transform` | `PoseResult`（坐标还原） | `PoseError` |

`infer(Bytes) -> Bytes` 是跨模块张量纯值（Tensor Wire）；`ModelSpec` / `TensorDesc` 提供形状元数据，适配器负责校验。

## 9. 可替换性与实现细节不泄漏

上层只看到 `PoseBackend` / `PoseResult`；后端句柄、模型路径、量化格式、引擎版本**全部留在后端模块**。换后端 = 组合根换一个适配器，`detect` 签名不变。MediaPipe 若需异步回调式推理而新增 `infer_async`：`PoseBackend` 方法集已冻结为四方法，该新增属**破坏性变更**，须先经评审裁决走破坏性变更流程（`detect` 签名可不变，但会破坏包外既有 trait 实现）。

## 10. 测试策略

| 层次 | 内容 |
|---|---|
| 黑盒 | Mock 后端：固定输入 → 固定关键点；换 Mock 实现不改调用 |
| 白盒 | 内部辅助：`letterbox_plan` 缩放/填充参数、f32 小端读写、量化编码、配置校验（NMS 未实现，无覆盖） |
| 错误路径 | 未 open、配置非法、输入尺寸错、输出形状不符、预算超限 |
| 门禁 | `moon clean` / `moon check --deny-warn` / `moon build` / `moon test` / `moon fmt --check`（`pkg.generated.mbti` 为冻结快照，本轮不运行 `moon info`） |

## 11. 验收标准（实现轮）

1. 换 TFLite / ONNX / Mock 后端不改上层 API；2. 关键点坐标还原正确；3. 与 Python `tflite-runtime` 数值对齐（后端侧 <1e-4）；4. `moon check --deny-warn` 转绿（已达成，0 error 0 warning）。

## 12. 未解决问题 / 待验证假设

- `[待验证假设]` 目标应用是否需要 33 关键点 / 3D world landmarks 尚待评审（影响第一轮后端选型，见 `DECISIONS.md` 决策 4）。
- 异步推理后端（MediaPipe LIVE_STREAM 式回调推理）与当前同步 trait 的兼容性未验证。
- 模型商用条款：MoveNet / BlazePose 托管许可标为 Apache-2.0，MoveNet 模型卡含「监控类用途超出适用范围」类声明（其法律约束力待法务确认），预编译 `.so` 随包分发的许可须单独审计；设备帧率预算未实测。

## 13. 当前状态与 TODO

实现完成：`detect` 编排、`letterbox` 前处理、`decode_output` 后处理、`PoseResult::restore` 坐标还原均已实现，30 个测试全过（黑盒 22 + 白盒 8，与首轮基线一致）。test 包内 `MockBackend` / `AltBackend` 实现 `@pose.PoseBackend`，是「包外可实现」的指针级证据，保留不删。

未实现（留待后续轮 / 组合根职责）：NMS（`nms_threshold` 仅做取值校验，无 NMS 算法）、后端适配器（TFLite / MediaPipe / ONNX，由组合根提供）。

API 冻结（2026-11-07）：`PoseBackend` 方法集冻结为 `open` / `infer` / `close` / `kind` 四方法；`PoseError` 追认 `pub(all) suberror`。冻结后增删方法或改动可见性即破坏性变更。

门禁（实跑，全部 exit 0）：`moon clean` · `moon check --deny-warn` · `moon build` · `moon test`（30/30）· `moon fmt --check`。

## References

设计决策（门面持有 trait、推理后端选型、零跨模块依赖与同构值类型、模型输出布局基准、依赖政策）见 `DECISIONS.md`；模型卡参考 `https://storage.googleapis.com/movenet/MoveNet.SinglePose%20Model%20Card.pdf`。
