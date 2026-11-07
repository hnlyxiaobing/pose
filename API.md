# pose · 公开 API（API.md）

> 与 `pkg.generated.mbti` 一致。全部函数为 `declare`（**无实现**，预期 `0068` 告警）。
> 错误传播统一 `raise PoseError`；门面无句柄；后端经 `&PoseBackend` 注入。

## 类型

| 类型 | 种类 | 说明 |
|---|---|---|
| `PoseBackend` | `pub trait` | `open(Self, PoseConfig) -> Unit raise PoseError`；`infer(Self, Bytes) -> Bytes raise PoseError`；`close(Self) -> Unit raise PoseError`；`kind(Self) -> BackendKind` |
| `RgbImage` | `pub(all) struct` | 门面侧中性图像（与 `yuv::RgbImage` 同构） |
| `RgbLayout` | `pub(all) enum` | Rgb / Bgr / Rgba / Bgra |
| `Landmark` | `pub(all) struct` | x / y / z / visibility / name |
| `PoseResult` | `pub(all) struct` | landmarks / score / frame_id / timestamp_ns / backend |
| `Transform` | `pub(all) struct` | scale / pad_x / pad_y / source 尺寸 / mirrored |
| `ModelSpec` | `pub(all) struct` | 输入尺寸 / dtype / mean / std / landmark_count / output_tensor_index |
| `PoseConfig` | `pub(all) struct` | model / keep_aspect_ratio / pad_value / 阈值 / max_poses / mirror_x |
| `BackendKind` / `TensorDtype` | `pub(all) enum` | Tflite / MediaPipe / OnnxRuntime / Mock / Custom；Float32/Float16/UInt8/Int8/Int32 |
| `PoseError` | `pub suberror` | 8 个分类错误 |
| `FrameId` | `pub type` | `UInt64` 别名 |

## 函数签名

| 签名 | 参数与所有权 | 返回 / 错误 | 资源与线程约束 | TODO |
|---|---|---|---|---|
| `detect(backend : &PoseBackend, image : RgbImage, config : PoseConfig, frame_id : FrameId) -> PoseResult raise PoseError` | `backend` 由组合根注入（trait object）；`image`/`config` 只读 | `PoseResult` 纯值 / `PoseError` | 门面无状态；并发约束由后端实现声明；不获取/释放资源 | letterbox、NMS、坐标还原、预算控制 |
| `decode_output(raw : Bytes, spec : ModelSpec, config : PoseConfig) -> Array[Landmark] raise PoseError` | `raw` 为后端输出张量原始字节 | 关键点数组 / `OutputDecode` / `ShapeMismatch` | 纯函数 | 17 点 / 33 点输出布局解析 |
| `letterbox(image : RgbImage, config : PoseConfig) -> (Bytes, Transform) raise PoseError` | `image` 只读 | 预处理字节 + 逆变换参数 / `InvalidInput` | 纯函数；返回新分配 `Bytes` | 等比缩放与填充 |
| `PoseResult::restore(self : PoseResult, t : Transform) -> PoseResult raise PoseError` | `self` 只读 | 坐标还原后的新结果 | 不修改输入 | 归一化→像素坐标、镜像还原 |

## 错误构造速查

`BackendNotOpen` · `BackendFailure(kind, detail)`（可重试/降级）· `InvalidConfig` · `InvalidInput(w,h)` · `OutputDecode` · `ShapeMismatch(expected, actual)` · `UnsupportedModel` · `BudgetExceeded`

## 后端契约（由组合根实现，本库不 import）

| 后端 | 适配器职责 | 状态 |
|---|---|---|
| Mock | 固定输出，纯 MoonBit 测试替身 | W0 |
| `tflite_ffi` | `infer(Bytes)` → `set_input` / `invoke` / `output_raw` | W1 |
| MediaPipe JNI | 版本同锁 + ABI diff 快照 | R4（ADR-0008） |
| `moon-ort` / ONNX | 第二后端 | R4，本轮不引入 |

## 非目标

取帧、YUV 转换、渲染、实现推理引擎、模型下载、模型 zoo、量化决策。

## 状态

`moon check`：✅ 0 error，4 × `0068`。API 快照：`pkg.generated.mbti`。实现：❌ 后续轮。
