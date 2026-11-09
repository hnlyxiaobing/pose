# pose · 公开 API（API.md）

> 与 `pkg.generated.mbti` 一致。R4 增量（2026-11-09）全部为**加法性**新增：无既有签名删除/改名/改参数/改返回类型。
> 全部函数**已实现**，`moon check --deny-warn` 0 error 0 warning，`moon test` 62/62。
> 错误传播统一 `raise PoseError`；门面无句柄；后端经 `&PoseBackend` 注入（`TfliteAdapter` 的引擎调用由组合根以 `TfliteBinding` 注入，本库不 import 后端）。

## 类型

| 类型 | 种类 | 说明 |
|---|---|---|
| `PoseBackend` | `pub(open) trait` | `open(Self, PoseConfig) -> Unit raise PoseError`；`infer(Self, Bytes) -> Bytes raise PoseError`；`close(Self) -> Unit raise PoseError`；`kind(Self) -> BackendKind`（不抛错）。**方法集已冻结为这四个方法，冻结后增删方法即破坏性变更。** |
| `RgbImage` | `pub(all) struct` | 门面侧中性图像（与 `yuv::RgbImage` 同构） |
| `RgbLayout` | `pub(all) enum` | Rgb / Bgr / Rgba / Bgra |
| `Landmark` | `pub(all) struct` | x / y / z / visibility / name |
| `PoseResult` | `pub(all) struct` | landmarks / score / frame_id / timestamp_ns / backend |
| `Transform` | `pub(all) struct` | letterbox 逆变换：scale / pad_x / pad_y / source 尺寸 / mirrored（字段未变） |
| `StretchTransform` | `pub(all) struct` | stretch 逆变换：scale_x / scale_y / source 尺寸 / mirrored |
| `BoundingBox` | `pub(all) struct` | NMS 用轴对齐 bbox：x1 / y1 / x2 / y2；附 `area` / `iou` |
| `PoseCandidate` | `pub(all) struct` | NMS 输入单元：landmarks / score / bbox；`PoseCandidate::new(landmarks)` 由关键点求均值与包围盒 |
| `ModelSpec` | `pub(all) struct` | 输入尺寸 / dtype / mean / std / landmark_count / output_tensor_index |
| `PoseConfig` | `pub(all) struct` | model / keep_aspect_ratio / pad_value / 阈值 / max_poses / mirror_x |
| `BackendKind` / `TensorDtype` | `pub(all) enum` | Tflite / MediaPipe / OnnxRuntime / Mock / Custom；Float32/Float16/UInt8/Int8/Int32 |
| `PoseError` | `pub(all) suberror` | 8 个分类错误；包外后端适配器可直接构造（包内仅此一个错误类型，未放宽其他类型） |
| `TfliteBinding` | `pub(all) struct` | 组合根注入的 TFLite 回调：`open_fn(PoseConfig)` / `infer_fn(Bytes)->Bytes` / `close_fn()`（均 `raise PoseError`） |
| `TfliteAdapter` | `pub struct`（不透明） | 注入式 TFLite 适配器：`new` / `unavailable` / `with_fallback` / `used_fallback`；`pub impl PoseBackend for TfliteAdapter` |
| `FrameId` | `pub type` | `UInt64` 别名 |

## 函数签名

| 签名 | 参数与所有权 | 返回 / 错误 | 资源与线程约束 | 实现状态 |
|---|---|---|---|---|
| `detect(backend : &PoseBackend, image : RgbImage, config : PoseConfig, frame_id : FrameId) -> PoseResult raise PoseError` | `backend` 由组合根注入（trait object）；`image`/`config` 只读 | `PoseResult`（多姿态输出时取 NMS 后最高分）/ `PoseError` | 门面无状态；并发约束由后端实现声明；不获取/释放资源 | ✅ 已实现：letterbox/stretch → infer → 预算 → 多姿态解码 → NMS → 坐标还原 |
| `detect_multi(...) -> Array[PoseResult] raise PoseError` | 同上 | 多姿态数组（按 score 降序） / `PoseError` | 同上 | ✅ 已实现：NMS（`nms_threshold` + `max_poses`）后逐姿态还原 |
| `decode_output(raw : Bytes, spec : ModelSpec, config : PoseConfig) -> Array[Landmark] raise PoseError` | `raw` 为单姿态输出块 | 关键点数组 / `OutputDecode` / `ShapeMismatch` | 纯函数 | ✅ 已实现：17/33 点布局、阈值过滤 |
| `decode_pose_batch(raw : Bytes, spec : ModelSpec, config : PoseConfig) -> Array[PoseCandidate] raise PoseError` | `raw` 为多姿态输出张量 | 候选数组 / `OutputDecode` / `ShapeMismatch` | 纯函数 | ✅ 已实现：按 `landmark_count*3*4` 切块解码 |
| `nms(candidates : Array[PoseCandidate], iou_threshold : Double, max_poses : Int32) -> Array[PoseCandidate] raise PoseError` | 只读输入（内部复制） | 保留候选 / `InvalidConfig` | 纯函数；稳定降序贪心 | ✅ 已实现：IoU 严格大于阈值才抑制，空输入返回空 |
| `letterbox(image : RgbImage, config : PoseConfig) -> (Bytes, Transform) raise PoseError` | `image` 只读 | 预处理字节 + 逆变换参数 / `InvalidInput` / `InvalidConfig` | 纯函数；返回新分配 `Bytes` | ✅ 已实现：等比缩放与填充、镜像采样、五种 dtype 编码；`keep_aspect_ratio=false` 时指向 `letterbox_stretch` |
| `letterbox_stretch(image : RgbImage, config : PoseConfig) -> (Bytes, StretchTransform) raise PoseError` | 同上 | 预处理字节 + stretch 逆变换 / `InvalidInput` / `InvalidConfig` | 纯函数 | ✅ 已实现：非等比拉伸、无填充、镜像采样 |
| `PoseResult::restore(self : PoseResult, t : Transform) -> PoseResult raise PoseError` | `self` 只读 | 坐标还原后的新结果 | 不修改输入 | ✅ 已实现：letterbox 逆变换 + 镜像还原 |
| `PoseResult::restore_stretch(self : PoseResult, t : StretchTransform) -> PoseResult raise PoseError` | 同上 | 坐标还原后的新结果 | 不修改输入 | ✅ 已实现：x / y 独立比例 + 镜像还原 |
| `BoundingBox::area(self) -> Double` / `BoundingBox::iou(self, other) -> Double` | 只读 | 面积 / 交并比 | 纯函数 | ✅ 已实现：退化盒/零并集返回 0 |
| `PoseCandidate::new(landmarks : Array[Landmark]) -> PoseCandidate` | 只读 | 候选（score 均值、bbox 包围） | 纯函数 | ✅ 已实现：空输入给零盒/score 0 |
| `TfliteAdapter::new(TfliteBinding, ModelSpec) -> TfliteAdapter` | 注入主绑定 | 适配器 | 不持有引擎句柄 | ✅ 已实现 |
| `TfliteAdapter::unavailable(ModelSpec) -> TfliteAdapter` | 无绑定 | 适配器（open 报 `BackendFailure`） | — | ✅ 已实现：后端缺失显式失败 |
| `TfliteAdapter::with_fallback(TfliteBinding?, TfliteBinding?, ModelSpec) -> TfliteAdapter` | 主/备绑定 | 适配器 | — | ✅ 已实现：主缺失时结构性回退 |
| `TfliteAdapter::used_fallback(Self) -> Bool` | 只读 | 是否用过回退 | — | ✅ 已实现 |

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
| TFLite（注入式骨架） | 组合根用 `tflite_ffi::Interpreter` 实现 `TfliteBinding` 的 `open_fn` / `infer_fn` / `close_fn`，注入 `TfliteAdapter`；适配器负责输入/输出尺寸校验、生命周期与缺失回退 | ✅ `TfliteAdapter` + `TfliteBinding` 已实现并有 mock 注入测试；**真实 `tflite_ffi` 绑定未接入**（组合根职责，pose 不 import） |
| MediaPipe JNI | 版本同锁 + ABI diff 快照 | 后续增强（P2，选型理由见 `DECISIONS.md` 决策 2） |
| `moon-ort` / ONNX | 第二后端 | 备选（P2，本轮不引入） |

## 非目标

取帧、YUV 转换、渲染、实现推理引擎、模型下载、模型 zoo、量化决策。

## 状态

门禁（实跑，全部 exit 0）：`moon clean` · `moon check --deny-warn`（0 error 0 warning）· `moon build` · `moon test`（62/62 全过）· `moon fmt --check` · `moon info` + `git diff --exit-code -- pkg.generated.mbti cmd/main/pkg.generated.mbti`。
API 快照：`pkg.generated.mbti`（R4 变更全部为加法性新增并已随源码提交）。
实现：✅ `detect` / `detect_multi` / `letterbox` / `letterbox_stretch` / `decode_output` / `decode_pose_batch` / `nms` / `restore` / `restore_stretch` / `TfliteAdapter`。
冻结项：`PoseBackend` 方法集（`open` / `infer` / `close` / `kind` 四方法）与 `PoseError` 可见性（`pub(all) suberror`）——冻结后增删方法或改动可见性即破坏性变更。
