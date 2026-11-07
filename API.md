# pose · 公开 API（API.md）

> 与 `pkg.generated.mbti` 一致（与 R1 快照 `pkg.generated.mbti.r1` 逐字节相同，冻结前零签名变化）。
> 全部函数**已实现**，`moon check --deny-warn` 0 error 0 warning（原 4 条 `0068` 随实现落地而消失）。
> 错误传播统一 `raise PoseError`；门面无句柄；后端经 `&PoseBackend` 注入。

## 类型

| 类型 | 种类 | 说明 |
|---|---|---|
| `PoseBackend` | `pub(open) trait` | `open(Self, PoseConfig) -> Unit raise PoseError`；`infer(Self, Bytes) -> Bytes raise PoseError`；`close(Self) -> Unit raise PoseError`；`kind(Self) -> BackendKind`（不抛错）。**方法集已冻结为这四个方法，冻结后增删方法即破坏性变更。** |
| `RgbImage` | `pub(all) struct` | 门面侧中性图像（与 `yuv::RgbImage` 同构） |
| `RgbLayout` | `pub(all) enum` | Rgb / Bgr / Rgba / Bgra |
| `Landmark` | `pub(all) struct` | x / y / z / visibility / name |
| `PoseResult` | `pub(all) struct` | landmarks / score / frame_id / timestamp_ns / backend |
| `Transform` | `pub(all) struct` | scale / pad_x / pad_y / source 尺寸 / mirrored |
| `ModelSpec` | `pub(all) struct` | 输入尺寸 / dtype / mean / std / landmark_count / output_tensor_index |
| `PoseConfig` | `pub(all) struct` | model / keep_aspect_ratio / pad_value / 阈值 / max_poses / mirror_x |
| `BackendKind` / `TensorDtype` | `pub(all) enum` | Tflite / MediaPipe / OnnxRuntime / Mock / Custom；Float32/Float16/UInt8/Int8/Int32 |
| `PoseError` | `pub(all) suberror` | 8 个分类错误；包外后端适配器可直接构造（包内仅此一个错误类型，未放宽其他类型） |
| `FrameId` | `pub type` | `UInt64` 别名 |

## 函数签名

| 签名 | 参数与所有权 | 返回 / 错误 | 资源与线程约束 | 实现状态 |
|---|---|---|---|---|
| `detect(backend : &PoseBackend, image : RgbImage, config : PoseConfig, frame_id : FrameId) -> PoseResult raise PoseError` | `backend` 由组合根注入（trait object）；`image`/`config` 只读 | `PoseResult` 纯值 / `PoseError` | 门面无状态；并发约束由后端实现声明；不获取/释放资源 | ✅ 已实现：letterbox → infer → 预算控制 → 解码 → 坐标还原；NMS 未实现（`nms_threshold` 仅校验） |
| `decode_output(raw : Bytes, spec : ModelSpec, config : PoseConfig) -> Array[Landmark] raise PoseError` | `raw` 为后端输出张量原始字节 | 关键点数组 / `OutputDecode` / `ShapeMismatch` | 纯函数 | ✅ 已实现：17 点 / 33 点布局解析、阈值过滤 |
| `letterbox(image : RgbImage, config : PoseConfig) -> (Bytes, Transform) raise PoseError` | `image` 只读 | 预处理字节 + 逆变换参数 / `InvalidInput` | 纯函数；返回新分配 `Bytes` | ✅ 已实现：等比缩放与填充、镜像采样、dtype 量化编码 |
| `PoseResult::restore(self : PoseResult, t : Transform) -> PoseResult raise PoseError` | `self` 只读 | 坐标还原后的新结果 | 不修改输入 | ✅ 已实现：归一化→像素坐标、镜像还原 |

## `PoseBackend` 方法语义（方法集已冻结）

| 方法 | 签名 | 语义 |
|---|---|---|
| `open` | `open(Self, PoseConfig) -> Unit raise PoseError` | 获取后端自有资源；错误以 `PoseError` 传播 |
| `infer` | `infer(Self, Bytes) -> Bytes raise PoseError` | 纯调用，不持有相机、不持有渲染状态 |
| `close` | `close(Self) -> Unit raise PoseError` | 释放后端自有资源：**不会二次释放，重复调用返回明确错误** |
| `kind` | `kind(Self) -> BackendKind` | 诊断标注，不抛错 |

> **方法集已冻结，冻结后增删方法即破坏性变更。** 冻结集为 `open / infer / close / kind` 四个方法；
> 本库无 `detach` 方法（`close` 即唯一资源释放入口）。包外实现证据见 `pose_test.mbt`
> （test 包内 `MockBackend` / `AltBackend` 实现 `@pose.PoseBackend`，保留为「包外可实现」指针级证据）。

## 错误构造速查

`BackendNotOpen` · `BackendFailure(kind, detail)`（可重试/降级）· `InvalidConfig` · `InvalidInput(w,h)` · `OutputDecode` · `ShapeMismatch(expected, actual)` · `UnsupportedModel` · `BudgetExceeded`

## 后端契约（由组合根实现，本库不 import）

| 后端 | 适配器职责 | 状态 |
|---|---|---|
| Mock | 固定输出，纯 MoonBit 测试替身 | ✅ 已实现于 `pose_test.mbt`（test 包内 `MockBackend` / `AltBackend`，包外实现证据） |
| `tflite_ffi` | `infer(Bytes)` → `set_input` / `invoke` / `output_raw` | W1 |
| MediaPipe JNI | 版本同锁 + ABI diff 快照 | R4（ADR-0008） |
| `moon-ort` / ONNX | 第二后端 | R4，本轮不引入 |

## 非目标

取帧、YUV 转换、渲染、实现推理引擎、模型下载、模型 zoo、量化决策。

## 状态

门禁（R2 实跑，全部 exit 0）：`moon clean` · `moon check --deny-warn`（0 error 0 warning）· `moon build` · `moon test`（30/30 全过）· `moon fmt --check`。
API 快照：`pkg.generated.mbti`（与 `pkg.generated.mbti.r1` 逐字节相同，零签名变化）。实现：✅ `detect` / `letterbox` / `decode_output` / `PoseResult::restore`。
冻结项：`PoseBackend` 方法集（`open` / `infer` / `close` / `kind` 四方法）与 `PoseError` 可见性（`pub(all) suberror`）——冻结后增删方法或改动可见性即破坏性变更。
