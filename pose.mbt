///|
/// 姿态检测门面（facade）：类型、`PoseBackend` trait 与编排/前后处理实现。
///
/// 契约决策（见 docs/DECISIONS.md）：门面拥有 `PoseBackend` trait 与中性值类型，
/// 后端（tflite_ffi / MediaPipe / ONNX）**不依赖本库**，由组合根提供适配器实现 trait。
/// 由此消除「门面→后端、后端→门面」的潜在循环依赖，换后端不换上层 API。
/// 本文件实现 detect 编排、letterbox 前处理、decode_output 后处理与坐标还原；
/// **不实现推理引擎**，不 import 任何后端模块。

///|
/// 单个关键点。坐标统一为「输入图像像素坐标系」，`z` 为模型相对深度（无深度时为 0）。
pub(all) struct Landmark {
  x : Double
  y : Double
  z : Double
  visibility : Double
  name : String?
}

///|
/// 一帧的检测结果。
pub(all) struct PoseResult {
  landmarks : Array[Landmark]
  score : Double
  frame_id : UInt64
  timestamp_ns : UInt64
  backend : BackendKind
}

///|
/// 门面侧的中性 RGB 图像（与 `yuv::RgbImage` 结构一致，由组合根适配）。
pub(all) struct RgbImage {
  width : Int32
  height : Int32
  layout : RgbLayout
  data : Bytes
  timestamp_ns : UInt64
}

///|
/// 门面侧的通道顺序枚举（与 `yuv::RgbLayout` 同构）。
pub(all) enum RgbLayout {
  Rgb
  Bgr
  Rgba
  Bgra
}

///|
/// 后端种类标识。仅用于诊断与结果标注，不参与调度。
pub(all) enum BackendKind {
  Tflite
  MediaPipe
  OnnxRuntime
  Mock
  Custom(String)
}

///|
/// 模型输入规格：张量形状、数据类型、归一化参数、关键点数量。
pub(all) struct ModelSpec {
  input_width : Int32
  input_height : Int32
  input_channels : Int32
  input_dtype : TensorDtype
  mean : Array[Double]
  std : Array[Double]
  landmark_count : Int32
  output_tensor_index : Int32
}

///|
/// 张量数据类型。
pub(all) enum TensorDtype {
  Float32
  Float16
  UInt8
  Int8
  Int32
}

///|
/// 前后处理配置：letterbox 填充、置信度阈值、坐标缩放策略均显式化。
pub(all) struct PoseConfig {
  model : ModelSpec
  keep_aspect_ratio : Bool
  pad_value : Int32
  score_threshold : Double
  nms_threshold : Double
  max_poses : Int32
  mirror_x : Bool
}

///|
/// 推理后端契约。实现必须满足：
/// - `infer` 是纯调用，不持有相机、不持有渲染状态；
/// - 后端自有资源的获取/释放在 `open` / `close` 中完成，错误以 `PoseError` 传播；
/// - 实现不得向上层暴露具体引擎类型（TFLite / MediaPipe 句柄等）。
/// 可见性：`pub(open)`，组合根（包外）可实现本 trait 注入后端（见 docs/DECISIONS.md）。
pub(open) trait PoseBackend {
  fn open(Self, PoseConfig) -> Unit raise PoseError
  fn infer(Self, Bytes) -> Bytes raise PoseError
  fn close(Self) -> Unit raise PoseError
  fn kind(Self) -> BackendKind
}

///|
/// 组合根注入的 TFLite 引擎绑定：把门面的无类型字节契约映射到具体引擎调用。
///
/// **本库不 import `tflite_ffi`**：组合根持有 `tflite_ffi::Interpreter`，
/// 用三个闭包/函数实现本绑定后注入 `TfliteAdapter`：
/// - `open(config)` → 加载模型、创建 interpreter（资源由组合根/后端持有）；
/// - `infer(input)` → `set_input` + `invoke` + `output_raw`，返回输出张量字节；
/// - `close()` → 释放 interpreter。
/// 绑定函数抛出的 `PoseError` 会由适配器原样向上传播（如 `BackendFailure`）。
pub(all) struct TfliteBinding {
  open_fn : (PoseConfig) -> Unit raise PoseError
  infer_fn : (Bytes) -> Bytes raise PoseError
  close_fn : () -> Unit raise PoseError
}

///|
/// TFLite 后端适配器骨架（组合根注入绑定，pose 内不出现任何引擎句柄/路径）。
///
/// 职责（本仓库风险缓解：「组合根适配器负责校验并以 `ShapeMismatch` 报错」）：
/// - 生命周期：`open` 校验 `ModelSpec` 并转发给绑定；未 open 调 `infer` 报
///   `BackendNotOpen`；重复 open / 重复 close 报明确错误（不会二次释放）；
/// - 输入校验：输入字节数必须等于 `input_width * input_height * input_channels *
///   dtype_size`，否则 `ShapeMismatch(expected, actual)`；
/// - 输出校验：输出字节数必须是非零的 `landmark_count * 3 * 4` 整数倍，否则
///   `ShapeMismatch(block, actual)`；
/// - **后端缺失回退**：主绑定为 `None` 时使用注入的 fallback 绑定（`used_fallback`
///   可观测）；两者皆缺则 `BackendFailure("tflite", "backend unavailable...")`。
///   回退只针对「绑定缺失」（结构性不可用），不掩盖主绑定的运行时调用失败。
/// - `kind()` 恒为 `BackendKind::Tflite`（诊断标注，不参与调度）。
pub struct TfliteAdapter {
  priv primary : TfliteBinding?
  priv fallback : TfliteBinding?
  priv spec : ModelSpec
  priv mut opened : Bool
  priv mut fallback_used : Bool
}

///|
/// 用主绑定构造适配器（正常路径：组合根已拿到真实 `tflite_ffi` 引擎）。
pub fn TfliteAdapter::new(
  binding : TfliteBinding,
  spec : ModelSpec,
) -> TfliteAdapter {
  {
    primary: Some(binding),
    fallback: None,
    spec,
    opened: false,
    fallback_used: false,
  }
}

///|
/// 无任何绑定（真实库/模型缺失）的适配器：`open` 会报 `BackendFailure`，
/// 供上层在「后端不可用」时走显式降级（例如换 Mock 或另一后端）。
pub fn TfliteAdapter::unavailable(spec : ModelSpec) -> TfliteAdapter {
  { primary: None, fallback: None, spec, opened: false, fallback_used: false, }
}

///|
/// 带回退绑定构造适配器：`primary` 为 `None` 时使用 `fallback`（组合根可注入
/// 「desktop 无 .so 时的 Mock / 另一引擎」），`used_fallback` 记录是否实际用到。
pub fn TfliteAdapter::with_fallback(
  primary : TfliteBinding?,
  fallback : TfliteBinding?,
  spec : ModelSpec,
) -> TfliteAdapter {
  { primary, fallback, spec, opened: false, fallback_used: false, }
}

///|
/// 本实例是否使用过回退绑定（诊断/测试用；一旦回退即为 true）。
pub fn TfliteAdapter::used_fallback(self : TfliteAdapter) -> Bool {
  self.fallback_used
}

///|
/// 选择本次调用使用的绑定：主绑定优先；缺失则回退；两者皆缺报 `BackendFailure`。
fn TfliteAdapter::select_binding(
  self : TfliteAdapter,
) -> TfliteBinding raise PoseError {
  match self.primary {
    Some(binding) => binding
    None =>
      match self.fallback {
        Some(binding) => {
          self.fallback_used = true
          binding
        }
        None =>
          raise BackendFailure(
            "tflite", "backend unavailable: no engine binding injected (composition root must inject TfliteBinding or a fallback)",
          )
      }
  }
}

///|
/// 模型输入字节数（`input_width * input_height * input_channels * dtype_size`）。
fn input_byte_len(spec : ModelSpec) -> Int32 {
  spec.input_width *
  spec.input_height *
  spec.input_channels *
  dtype_size(spec.input_dtype)
}

///|
pub impl PoseBackend for TfliteAdapter with fn open(self, config) -> Unit raise PoseError {
  validate_spec(self.spec)
  if self.opened {
    raise BackendFailure("tflite", "backend already open")
  }
  let binding = self.select_binding()
  (binding.open_fn)(config)
  self.opened = true
}

///|
pub impl PoseBackend for TfliteAdapter with fn infer(self, input) -> Bytes raise PoseError {
  if !self.opened {
    raise BackendNotOpen("tflite: infer before open")
  }
  validate_spec(self.spec)
  let want = input_byte_len(self.spec)
  if input.length() != want {
    raise ShapeMismatch(want, input.length())
  }
  let binding = self.select_binding()
  let output = (binding.infer_fn)(input)
  let block = self.spec.landmark_count * 3 * 4
  if output.length() == 0 || output.length() % block != 0 {
    raise ShapeMismatch(block, output.length())
  }
  output
}

///|
pub impl PoseBackend for TfliteAdapter with fn close(self) -> Unit raise PoseError {
  if !self.opened {
    raise BackendNotOpen("tflite: close called when not open")
  }
  let binding = self.select_binding()
  (binding.close_fn)()
  self.opened = false
}

///|
pub impl PoseBackend for TfliteAdapter with fn kind(_self) -> BackendKind {
  Tflite
}

///|
/// 显式声明把 `PoseBackend` 的方法提升为 `TfliteAdapter` 的常规方法
/// （MoonBit 对 `pub impl` 的隐式提升已弃用；本声明消除该告警，
/// 同时让调用方既可写 `adapter.infer(input)`，也可写 `PoseBackend::infer`）。
pub extend TfliteAdapter with PoseBackend::{open, infer, close, kind}

///|
/// 姿态错误模型。区分「配置错误 / 后端错误 / 解码错误」，便于上层决定重试还是降级。
/// 可见性：`pub(all)`，后端适配器（包外）需构造这些错误值向上传播。
#derive(Debug)
pub(all) suberror PoseError {
  BackendNotOpen(String)
  BackendFailure(String, String)
  InvalidConfig(String)
  InvalidInput(Int32, Int32)
  OutputDecode(String)
  ShapeMismatch(Int32, Int32)
  UnsupportedModel(String)
  BudgetExceeded(String)
}

///|
pub extend PoseError with Debug::{to_repr}

///|
/// 帧序号。
pub type FrameId = UInt64

///|
/// 轴对齐包围盒（模型输入像素坐标系），由姿态关键点导出，仅用于 NMS 去重。
pub(all) struct BoundingBox {
  x1 : Double
  y1 : Double
  x2 : Double
  y2 : Double
}

///|
/// 包围盒面积；退化盒（`x2 <= x1` 或 `y2 <= y1`）面积为 0。
pub fn BoundingBox::area(self : BoundingBox) -> Double {
  let w = self.x2 - self.x1
  let h = self.y2 - self.y1
  if w <= 0.0 || h <= 0.0 {
    0.0
  } else {
    w * h
  }
}

///|
/// 两个包围盒的 IoU（交并比，范围 `[0, 1]`；并集面积为 0 时返回 0）。
pub fn BoundingBox::iou(self : BoundingBox, other : BoundingBox) -> Double {
  let ix1 = if self.x1 > other.x1 { self.x1 } else { other.x1 }
  let iy1 = if self.y1 > other.y1 { self.y1 } else { other.y1 }
  let ix2 = if self.x2 < other.x2 { self.x2 } else { other.x2 }
  let iy2 = if self.y2 < other.y2 { self.y2 } else { other.y2 }
  let iw = ix2 - ix1
  let ih = iy2 - iy1
  if iw <= 0.0 || ih <= 0.0 {
    0.0
  } else {
    let inter = iw * ih
    let union = self.area() + other.area() - inter
    if union <= 0.0 {
      0.0
    } else {
      inter / union
    }
  }
}

///|
/// 单姿态候选：关键点（已按 `score_threshold` 过滤）、置信度与包围盒。
///
/// - `score` = `landmarks` 的 `visibility` 均值（空数组为 0），用于 NMS 排序；
/// - `bbox` = `landmarks` 的轴对齐包围盒（空数组为零盒），仅用于 IoU 去重，
///   不进入 `PoseResult`；
/// - 该类型是 `decode_pose_batch` 与 `nms` 之间的中性中间值，包外也可直接构造
///   以复用 NMS（例如自定义后处理）。
pub(all) struct PoseCandidate {
  landmarks : Array[Landmark]
  score : Double
  bbox : BoundingBox
}

///|
/// 由关键点构造候选：`score` 取 visibility 均值，`bbox` 取关键点轴对齐包围盒。
pub fn PoseCandidate::new(landmarks : Array[Landmark]) -> PoseCandidate {
  let n = landmarks.length()
  if n == 0 {
    PoseCandidate::{
      landmarks,
      score: 0.0,
      bbox: { x1: 0.0, y1: 0.0, x2: 0.0, y2: 0.0, },
    }
  } else {
    let mut x1 = landmarks[0].x
    let mut y1 = landmarks[0].y
    let mut x2 = landmarks[0].x
    let mut y2 = landmarks[0].y
    let mut total = 0.0
    for l in landmarks {
      if l.x < x1 {
        x1 = l.x
      }
      if l.y < y1 {
        y1 = l.y
      }
      if l.x > x2 {
        x2 = l.x
      }
      if l.y > y2 {
        y2 = l.y
      }
      total = total + l.visibility
    }
    PoseCandidate::{
      landmarks,
      score: total / n.to_double(),
      bbox: { x1, y1, x2, y2, },
    }
  }
}

///|
/// letterbox 的逆变换参数，用于把归一化坐标还原到输入图像坐标系。
pub(all) struct Transform {
  scale : Double
  pad_x : Int32
  pad_y : Int32
  source_width : Int32
  source_height : Int32
  mirrored : Bool
}

///|
/// stretch（非等比缩放）的逆变换参数：x / y 各自比例、无填充。
///
/// 与 `Transform` 并存而不改其字段，是为了满足 API 冻结语义中的「只允许加法性
/// 新增」：`Transform` 的构造式（六个字段）保持不变，旧调用方无需改动。
pub(all) struct StretchTransform {
  scale_x : Double
  scale_y : Double
  source_width : Int32
  source_height : Int32
  mirrored : Bool
}

///|
/// 校验 ModelSpec 的参数域（纯函数）。后端适配器在 open/infer 前复用本校验，
/// 保证畸形规格以 `InvalidConfig` 报出而不是在整数除法处 panic。
fn validate_spec(spec : ModelSpec) -> Unit raise PoseError {
  if spec.input_width <= 0 || spec.input_height <= 0 {
    raise InvalidConfig("ModelSpec input size must be positive")
  }
  if spec.landmark_count <= 0 {
    raise InvalidConfig("ModelSpec.landmark_count must be positive")
  }
  if spec.input_channels <= 0 {
    raise InvalidConfig("ModelSpec.input_channels must be positive")
  }
  // 上界校验：防止畸形 spec 在 `input_width * input_height * channels * dtype_size`
  // 或 `landmark_count * 3 * 4` 处发生 Int32 溢出（可能得到 0 / 负数，进而在
  // 整数除法或缓冲区分配处 panic）。真实姿态模型的输入远小于这些上界。
  if spec.landmark_count > 1000000 {
    raise InvalidConfig("ModelSpec.landmark_count is too large (max 1000000)")
  }
  let input_bytes = spec.input_width.to_int64() *
    spec.input_height.to_int64() *
    spec.input_channels.to_int64() *
    dtype_size(spec.input_dtype).to_int64()
  if input_bytes > 268435456L {
    raise InvalidConfig("ModelSpec input tensor exceeds 256 MiB")
  }
  if spec.mean.length() != spec.input_channels ||
    spec.std.length() != spec.input_channels {
    raise InvalidConfig("ModelSpec mean/std must have input_channels entries")
  }
  for i in 0..<spec.input_channels {
    if !spec.mean[i].is_finite() {
      raise InvalidConfig("ModelSpec mean must be finite")
    }
    if !spec.std[i].is_finite() || spec.std[i] == 0.0 {
      raise InvalidConfig("ModelSpec std must be finite and non-zero")
    }
  }
}

///|
/// 校验 ModelSpec 与 PoseConfig 的参数域（纯函数）。
/// 配置类错误一律 `InvalidConfig`；均值/方差必须显式给出（长度等于
/// `input_channels`，`std` 非零且有限），拒绝任何静默默认值。
fn validate_spec_and_config(
  spec : ModelSpec,
  config : PoseConfig,
) -> Unit raise PoseError {
  validate_spec(spec)
  if config.pad_value < 0 || config.pad_value > 255 {
    raise InvalidConfig("PoseConfig.pad_value must be in 0..=255")
  }
  if !config.score_threshold.is_finite() ||
    config.score_threshold < 0.0 ||
    config.score_threshold > 1.0 {
    raise InvalidConfig("PoseConfig.score_threshold must be in [0, 1]")
  }
  if !config.nms_threshold.is_finite() ||
    config.nms_threshold < 0.0 ||
    config.nms_threshold > 1.0 {
    raise InvalidConfig("PoseConfig.nms_threshold must be in [0, 1]")
  }
  if config.max_poses <= 0 {
    raise InvalidConfig("PoseConfig.max_poses must be positive")
  }
}

///|
/// 像素布局的通道数（Rgb/Bgr 为 3，Rgba/Bgra 为 4）。
fn layout_channels(layout : RgbLayout) -> Int32 {
  match layout {
    Rgb => 3
    Bgr => 3
    Rgba => 4
    Bgra => 4
  }
}

///|
/// letterbox 缩放计划：整数运算求等比缩放尺寸与四周填充，避免浮点漂移。
/// 返回 (scale, scaled_width, scaled_height, pad_x, pad_y)；
/// `scale` 取被夹住的那一维（宽或高）的精确比例，pad 为左/上填充像素数。
fn letterbox_plan(
  w : Int32,
  h : Int32,
  tw : Int32,
  th : Int32,
) -> (Double, Int32, Int32, Int32, Int32) {
  if tw * h <= th * w {
    // 宽度受限：缩放到 tw
    let scaled_w = tw
    let scaled_h = h * tw / w
    (tw.to_double() / w.to_double(), scaled_w, scaled_h, 0, (th - scaled_h) / 2)
  } else {
    // 高度受限：缩放到 th
    let scaled_h = th
    let scaled_w = w * th / h
    (th.to_double() / h.to_double(), scaled_w, scaled_h, (tw - scaled_w) / 2, 0)
  }
}

///|
/// 取源图像 (x, y) 处像素并统一为 RGB 顺序（丢弃 alpha 通道）。
fn read_rgb(image : RgbImage, x : Int32, y : Int32) -> (Int32, Int32, Int32) {
  let ch = layout_channels(image.layout)
  let off = (y * image.width + x) * ch
  let d = image.data
  match image.layout {
    Rgb => (d[off].to_int(), d[off + 1].to_int(), d[off + 2].to_int())
    Bgr => (d[off + 2].to_int(), d[off + 1].to_int(), d[off].to_int())
    Rgba => (d[off].to_int(), d[off + 1].to_int(), d[off + 2].to_int())
    Bgra => (d[off + 2].to_int(), d[off + 1].to_int(), d[off].to_int())
  }
}

///|
/// 把 Double 值四舍五入并夹取到 [lo, hi]，返回整数。
fn clamp_round_int(v : Double, lo : Int32, hi : Int32) -> Int32 {
  let r = v.round().to_int()
  if r < lo {
    lo
  } else if r > hi {
    hi
  } else {
    r
  }
}

///|
/// 小端写入 IEEE 754 Float32。
fn write_f32_le(out : FixedArray[Byte], off : Int32, v : Double) -> Unit {
  let bits = Float::from_double(v).reinterpret_as_int()
  out[off] = (bits & 0xFF).to_byte()
  out[off + 1] = ((bits >> 8) & 0xFF).to_byte()
  out[off + 2] = ((bits >> 16) & 0xFF).to_byte()
  out[off + 3] = ((bits >> 24) & 0xFF).to_byte()
}

///|
/// 小端写入 Int32（补码）。
fn write_i32_le(out : FixedArray[Byte], off : Int32, v : Int32) -> Unit {
  out[off] = (v & 0xFF).to_byte()
  out[off + 1] = ((v >> 8) & 0xFF).to_byte()
  out[off + 2] = ((v >> 16) & 0xFF).to_byte()
  out[off + 3] = ((v >> 24) & 0xFF).to_byte()
}

///|
/// 小端读取 IEEE 754 Float32 并转为 Double。
fn read_f32_le(b : Bytes, off : Int32) -> Double {
  let bits = b[off].to_int() |
    (b[off + 1].to_int() << 8) |
    (b[off + 2].to_int() << 16) |
    (b[off + 3].to_int() << 24)
  Float::reinterpret_from_int(bits).to_double()
}

///|
/// 把 IEEE 754 binary32 舍入为 binary16 的位模式（不含字节序，返回 16 位值）。
///
/// - 舍入：round-to-nearest-ties-to-even（就近舍入、平局取偶）。
/// - NaN：一律折叠为规范 quiet NaN `0x7E00`（不保留符号/负载）。
/// - Infinity：`0x7C00` / `0xFC00`（带符号）。
/// - 溢出（|v| 超过 f16 最大值 65504 且舍入到 2^16）：饱和为带符号 Infinity。
/// - 次正规：f16 次正规区间 `[2^-24, 2^-14)` 正常编码；`2^-25` 恰好是
///   「最小次正规的一半」，按平局取偶舍入为 0；小于 `2^-25` 的 f32 值
///   （含全部 f32 次正规数与 ±0）一律为带符号零。
fn f32_to_f16_bits(f : Float) -> Int32 {
  let bits = f.reinterpret_as_int()
  let sign = (bits >> 16) & 0x8000
  let exp = (bits >> 23) & 0xFF
  let mant = bits & 0x7FFFFF
  if exp == 0xFF {
    // NaN / Infinity
    if mant != 0 {
      0x7E00
    } else {
      sign | 0x7C00
    }
  } else if exp == 0 {
    // f32 ±0 与 f32 次正规数均远小于 f16 最小次正规数的一半
    sign
  } else {
    let e = exp - 127
    if e > 15 {
      // 超出 f16 最大指数：饱和为 Infinity
      sign | 0x7C00
    } else if e >= -14 {
      // f16 正规数：保留 10 位尾数，按 RNE 舍入
      let m10 = mant >> 13
      let rem = mant & 0x1FFF
      let mut m = m10
      if rem > 0x1000 || (rem == 0x1000 && (m10 & 1) == 1) {
        m = m + 1
      }
      // m 进位到 1024 时会自然加进指数域；指数域满 31 即溢出为 Infinity
      let h = ((e + 15) << 10) + m
      if h >= 0x7C00 {
        sign | 0x7C00
      } else {
        sign | h
      }
    } else if e >= -25 {
      // f16 次正规数（含 e = -25 这个「最小次正规的一半」边界）：
      // 24 位有效数右移后在 2^-24 网格上按 RNE 舍入（进位到 0x0400 即最小正规数）
      let n = 0x800000 + mant
      let shift = -e - 1
      let m = n >> shift
      let half = 1 << (shift - 1)
      let rem = n & ((1 << shift) - 1)
      let mut h = m
      if rem > half || (rem == half && (m & 1) == 1) {
        h = h + 1
      }
      sign | h
    } else {
      // 小于 2^-25：舍入为带符号零
      sign
    }
  }
}

///|
/// 小端写入 IEEE 754 Float16（由 Double 先转 f32，再按 RNE 舍入到 f16）。
fn write_f16_le(out : FixedArray[Byte], off : Int32, v : Double) -> Unit {
  let bits = f32_to_f16_bits(Float::from_double(v))
  out[off] = (bits & 0xFF).to_byte()
  out[off + 1] = ((bits >> 8) & 0xFF).to_byte()
}

///|
/// 把归一化值按 dtype 量化并写入输出缓冲（小端）。
fn encode_value(
  out : FixedArray[Byte],
  off : Int32,
  v : Double,
  dtype : TensorDtype,
) -> Unit {
  match dtype {
    Float32 => write_f32_le(out, off, v)
    Float16 => write_f16_le(out, off, v)
    UInt8 => out[off] = clamp_round_int(v, 0, 255).to_byte()
    Int8 => out[off] = (clamp_round_int(v, -128, 127) & 0xFF).to_byte()
    Int32 => write_i32_le(out, off, clamp_round_int(v, -2147483648, 2147483647))
  }
}

///|
/// 每个输入元素的字节数（`Float32`/`Int32` 为 4，`Float16` 为 2，8 位类型为 1）。
fn dtype_size(dtype : TensorDtype) -> Int32 {
  match dtype {
    Float32 => 4
    Float16 => 2
    UInt8 => 1
    Int8 => 1
    Int32 => 4
  }
}

///|
/// 缩放计划：采样所需的缩放区尺寸与填充。x / y 比例由缩放区尺寸隐式决定
/// （`scale_x = scaled_w / w`、`scale_y = scaled_h / h`），此处不重复存储。
priv struct ResizePlan {
  scaled_w : Int32
  scaled_h : Int32
  pad_x : Int32
  pad_y : Int32
}

///|
/// 按缩放计划采样 + 归一化 + 按 dtype 编码，返回模型输入字节。
/// 采样约定与既有 letterbox 一致：`sx = (tx - pad_x) * w / scaled_w`（整数下取整），
/// `mirror_x` 时 `sx' = w - 1 - sx`；填充区写入 `pad_value` 并经同一归一化。
fn resize_encode(
  image : RgbImage,
  config : PoseConfig,
  plan : ResizePlan,
) -> Bytes {
  let spec = config.model
  let tw = spec.input_width
  let th = spec.input_height
  let w = image.width
  let h = image.height
  let elem = dtype_size(spec.input_dtype)
  let out = FixedArray::make(tw * th * 3 * elem, b'\x00')
  for ty in 0..<th {
    for tx in 0..<tw {
      let pixel = if tx >= plan.pad_x &&
        tx < plan.pad_x + plan.scaled_w &&
        ty >= plan.pad_y &&
        ty < plan.pad_y + plan.scaled_h {
        let sx0 = (tx - plan.pad_x) * w / plan.scaled_w
        let sy = (ty - plan.pad_y) * h / plan.scaled_h
        let sx = if config.mirror_x { w - 1 - sx0 } else { sx0 }
        read_rgb(image, sx, sy)
      } else {
        (config.pad_value, config.pad_value, config.pad_value)
      }
      let (r, g, b) = pixel
      let values = [r.to_double(), g.to_double(), b.to_double()]
      for c in 0..<3 {
        let v = (values[c] - spec.mean[c]) / spec.std[c]
        encode_value(
          out,
          (ty * tw + tx) * 3 * elem + c * elem,
          v,
          spec.input_dtype,
        )
      }
    }
  }
  Bytes::from_array(out)
}

///|
/// 前处理：按比例缩放并填充到模型输入尺寸，返回预处理字节与还原参数。
///
/// - 等比缩放：`scale = min(tw/w, th/h)`，缩放区居中，四周填 `pad_value`（像素值，
///   与像素同样经过 `(pixel - mean) / std` 归一化后按 `input_dtype` 编码，小端）。
/// - `mirror_x` 为真时水平翻转采样（`x' = width - 1 - x`），并记录到
///   `Transform.mirrored`，由 `PoseResult::restore` 还原。
/// - 本函数只承载等比（letterbox）模式；`keep_aspect_ratio = false` 时返回的
///   单 `scale` `Transform` 无法表达非等比逆变换，故报 `InvalidConfig`，
///   请改用 `letterbox_stretch`（或直接 `detect`，由它按配置分派）。
/// - 错误：配置/规格非法 `InvalidConfig`；尺寸与数据长度不符 `InvalidInput(w, h)`；
///   仅支持 3 通道模型输入，其余 `UnsupportedModel`。
/// - dtype：Float32 / Float16 / UInt8 / Int8 / Int32 全部支持（Float16 按
///   round-to-nearest-even 编码，NaN → 0x7E00、溢出 → ±Inf，见 `f32_to_f16_bits`）。
pub fn letterbox(
  image : RgbImage,
  config : PoseConfig,
) -> (Bytes, Transform) raise PoseError {
  let spec = config.model
  validate_spec_and_config(spec, config)
  if !config.keep_aspect_ratio {
    raise InvalidConfig(
      "letterbox: keep_aspect_ratio=false is not representable by Transform; use letterbox_stretch",
    )
  }
  if spec.input_channels != 3 {
    raise UnsupportedModel("letterbox: only 3-channel model input is supported")
  }
  let w = image.width
  let h = image.height
  if w <= 0 || h <= 0 {
    raise InvalidInput(w, h)
  }
  let src_ch = layout_channels(image.layout)
  if image.data.length() != w * h * src_ch {
    raise InvalidInput(w, h)
  }
  let tw = spec.input_width
  let th = spec.input_height
  let (scale, scaled_w, scaled_h, pad_x, pad_y) = letterbox_plan(w, h, tw, th)
  let bytes = resize_encode(image, config, ResizePlan::{
    scaled_w,
    scaled_h,
    pad_x,
    pad_y,
  })
  let t = Transform::{
    scale,
    pad_x,
    pad_y,
    source_width: w,
    source_height: h,
    mirrored: config.mirror_x,
  }
  (bytes, t)
}

///|
/// 前处理（stretch 模式）：把整幅源图非等比拉伸到模型输入尺寸，无填充。
///
/// - `scale_x = tw / w`、`scale_y = th / h`，采样 `sx = tx * w / tw`、
///   `sy = ty * h / th`（整数下取整），整幅输出都是图像内容，`pad_value` 不参与。
/// - `mirror_x` 语义与 `letterbox` 一致；逆变换由 `PoseResult::restore_stretch` 完成。
/// - 适用场景：模型训练时即非等比拉伸（MoveNet 等多数模型推荐 letterbox，但
///   部分自定义模型/数据管线使用直接 resize），需要与训练侧前处理严格一致时。
/// - 错误：`keep_aspect_ratio = true` 时 `InvalidConfig`（应改用 `letterbox`）；
///   其余同 `letterbox`（`InvalidInput` / `UnsupportedModel`）。
pub fn letterbox_stretch(
  image : RgbImage,
  config : PoseConfig,
) -> (Bytes, StretchTransform) raise PoseError {
  let spec = config.model
  validate_spec_and_config(spec, config)
  if config.keep_aspect_ratio {
    raise InvalidConfig(
      "letterbox_stretch: keep_aspect_ratio must be false (use letterbox for aspect-preserving resize)",
    )
  }
  if spec.input_channels != 3 {
    raise UnsupportedModel(
      "letterbox_stretch: only 3-channel model input is supported",
    )
  }
  let w = image.width
  let h = image.height
  if w <= 0 || h <= 0 {
    raise InvalidInput(w, h)
  }
  let src_ch = layout_channels(image.layout)
  if image.data.length() != w * h * src_ch {
    raise InvalidInput(w, h)
  }
  let tw = spec.input_width
  let th = spec.input_height
  let scale_x = tw.to_double() / w.to_double()
  let scale_y = th.to_double() / h.to_double()
  let bytes = resize_encode(image, config, ResizePlan::{
    scaled_w: tw,
    scaled_h: th,
    pad_x: 0,
    pad_y: 0,
  })
  let t = StretchTransform::{
    scale_x,
    scale_y,
    source_width: w,
    source_height: h,
    mirrored: config.mirror_x,
  }
  (bytes, t)
}

///|
/// 解码一个姿态块（`landmark_count` 个 `(y, x, score)` Float32 三元组），
/// 不做阈值过滤；`base` 为该块在输出张量中的起始字节偏移。
fn decode_block(
  raw : Bytes,
  base : Int32,
  spec : ModelSpec,
) -> Array[Landmark] raise PoseError {
  let out : Array[Landmark] = []
  for i in 0..<spec.landmark_count {
    let off = base + i * 12
    let y_norm = read_f32_le(raw, off)
    let x_norm = read_f32_le(raw, off + 4)
    let score = read_f32_le(raw, off + 8)
    if !(y_norm.is_finite() && x_norm.is_finite() && score.is_finite()) {
      raise OutputDecode("decode: non-finite value in output tensor")
    }
    out.push(Landmark::{
      x: x_norm * spec.input_width.to_double(),
      y: y_norm * spec.input_height.to_double(),
      z: 0.0,
      visibility: score,
      name: None,
    })
  }
  out
}

///|
/// 按 `score_threshold` 保序过滤关键点（`score < threshold` 剔除），返回新数组。
fn filter_landmarks(
  landmarks : Array[Landmark],
  threshold : Double,
) -> Array[Landmark] {
  let out : Array[Landmark] = []
  for l in landmarks {
    if l.visibility >= threshold {
      out.push(l)
    }
  }
  out
}

///|
/// 后处理：把后端原始输出张量字节解码为关键点数组（单姿态）。
///
/// - 布局：`[landmark_count, 3]` 的 Float32（小端）三元组 `(y, x, score)`，
///   坐标为相对模型输入尺寸的归一化值（MoveNet `输出 [1,1,17,3]` 的 17 点布局；
///   33 点同构布局同样适用，`landmark_count` 配置化）。
/// - `x = x_norm * input_width`、`y = y_norm * input_height`（模型输入像素系），
///   `z = 0`（2D 模型无深度），`visibility = score`，`name = None`（张量无名称）。
/// - 阈值过滤：`score < config.score_threshold` 的关键点被剔除。
/// - 多姿态输出请用 `decode_pose_batch`（本函数要求恰好一个姿态块的字节数）。
/// - 错误：规格/配置非法 `InvalidConfig`；非有限数值 `OutputDecode`；
///   字节数与 `landmark_count * 3 * 4` 不符 `ShapeMismatch(expected, actual)`。
/// - 空张量（0 字节）视为零检测：返回空数组，不报错。
pub fn decode_output(
  raw : Bytes,
  spec : ModelSpec,
  config : PoseConfig,
) -> Array[Landmark] raise PoseError {
  validate_spec_and_config(spec, config)
  let block = spec.landmark_count * 3 * 4
  if raw.length() == 0 {
    return []
  }
  if raw.length() != block {
    raise ShapeMismatch(block, raw.length())
  }
  filter_landmarks(decode_block(raw, 0, spec), config.score_threshold)
}

///|
/// 后处理（多姿态）：把输出张量按 `landmark_count * 3 * 4` 字节切分为姿态块，
/// 逐块解码、阈值过滤后构造 `PoseCandidate` 数组。
///
/// - 每个候选的 `score` 与 `bbox` 均基于**过滤后**保留的关键点计算，与
///   `PoseResult.score` 的既有语义（保留关键点 visibility 均值）一致。
/// - 错误：规格/配置非法 `InvalidConfig`；非有限数值 `OutputDecode`；
///   字节数不是姿态块整数倍 `ShapeMismatch(block, raw.length())`。
/// - 空张量（0 字节）视为零检测：返回空数组，不报错。
/// - 预算（`max_poses`）由编排层 `detect_multi` 在调用本函数前检查。
pub fn decode_pose_batch(
  raw : Bytes,
  spec : ModelSpec,
  config : PoseConfig,
) -> Array[PoseCandidate] raise PoseError {
  validate_spec_and_config(spec, config)
  let block = spec.landmark_count * 3 * 4
  if raw.length() == 0 {
    return []
  }
  if raw.length() % block != 0 {
    raise ShapeMismatch(block, raw.length())
  }
  let count = raw.length() / block
  let out : Array[PoseCandidate] = []
  for b in 0..<count {
    let all = decode_block(raw, b * block, spec)
    out.push(PoseCandidate::new(filter_landmarks(all, config.score_threshold)))
  }
  out
}

///|
/// 姿态级非极大值抑制（NMS）：按 `score` 降序贪心保留，若候选与任一已保留候选的
/// bbox IoU **严格大于** `iou_threshold` 则抑制；最多保留 `max_poses` 个。
///
/// - 空输入返回空数组（不报错）；同分候选保持输入顺序（稳定插入排序）；
/// - 阈值边界：`IoU == threshold` **不**抑制（只有 `>` 抑制）；`threshold = 1.0`
///   不抑制任何候选（IoU 上界为 1.0）；`threshold = 0.0` 抑制所有正重叠候选；
/// - 全重叠（相同 bbox）只保留最高分的一个；坐标相同的退化 bbox IoU 为 0，不会被
///   误抑制；
/// - 纯函数：不修改输入数组（内部先复制再排序）；
/// - 错误：`iou_threshold` 非有限或不在 `[0, 1]`、`max_poses <= 0` → `InvalidConfig`。
pub fn nms(
  candidates : Array[PoseCandidate],
  iou_threshold : Double,
  max_poses : Int32,
) -> Array[PoseCandidate] raise PoseError {
  if !iou_threshold.is_finite() || iou_threshold < 0.0 || iou_threshold > 1.0 {
    raise InvalidConfig("nms: iou_threshold must be in [0, 1]")
  }
  if max_poses <= 0 {
    raise InvalidConfig("nms: max_poses must be positive")
  }
  let sorted = candidates.copy()
  let n = sorted.length()
  // 稳定插入排序：score 降序，同分保持输入顺序（n 为姿态数，规模很小）
  for i in 1..<n {
    let mut j = i
    while j > 0 && sorted[j - 1].score < sorted[j].score {
      sorted.swap(j - 1, j)
      j = j - 1
    }
  }
  let kept : Array[PoseCandidate] = []
  for cand in sorted {
    if kept.length() >= max_poses {
      break
    }
    let mut suppressed = false
    for k in kept {
      if k.bbox.iou(cand.bbox) > iou_threshold {
        suppressed = true
        break
      }
    }
    if !suppressed {
      kept.push(cand)
    }
  }
  kept
}

///|
/// 把关键点从模型输入坐标系还原到原始图像坐标系。
///
/// - `x = (x - pad_x) / scale`、`y = (y - pad_y) / scale`；
///   `t.mirrored` 为真时再做水平翻转 `x = source_width - 1 - x`（像素索引约定）。
/// - 纯函数：不修改输入，返回新结果；不夹取坐标（越界值如实暴露给上层）。
/// - 错误：`scale` 非正（含 NaN）`InvalidConfig`；source 尺寸非法 `InvalidInput`。
pub fn PoseResult::restore(
  self : PoseResult,
  t : Transform,
) -> PoseResult raise PoseError {
  if !(t.scale > 0.0) {
    raise InvalidConfig("Transform.scale must be positive")
  }
  if t.source_width <= 0 || t.source_height <= 0 {
    raise InvalidInput(t.source_width, t.source_height)
  }
  let w = t.source_width.to_double()
  let landmarks = self.landmarks.map(fn(l) {
    let x0 = (l.x - t.pad_x.to_double()) / t.scale
    let y0 = (l.y - t.pad_y.to_double()) / t.scale
    let x = if t.mirrored { w - 1.0 - x0 } else { x0 }
    Landmark::{ x, y: y0, z: l.z, visibility: l.visibility, name: l.name, }
  })
  PoseResult::{
    landmarks,
    score: self.score,
    frame_id: self.frame_id,
    timestamp_ns: self.timestamp_ns,
    backend: self.backend,
  }
}

///|
/// 把关键点从模型输入坐标系还原到原始图像坐标系（stretch 模式）。
///
/// - `x = x / scale_x`、`y = y / scale_y`（stretch 无填充）；
///   `t.mirrored` 为真时再做水平翻转 `x = source_width - 1 - x`（像素索引约定）。
/// - 纯函数：不修改输入，返回新结果；不夹取坐标。
/// - 错误：`scale_x`/`scale_y` 非正（含 NaN）`InvalidConfig`；source 尺寸非法 `InvalidInput`。
pub fn PoseResult::restore_stretch(
  self : PoseResult,
  t : StretchTransform,
) -> PoseResult raise PoseError {
  if !(t.scale_x > 0.0) || !(t.scale_y > 0.0) {
    raise InvalidConfig("StretchTransform scale_x/scale_y must be positive")
  }
  if t.source_width <= 0 || t.source_height <= 0 {
    raise InvalidInput(t.source_width, t.source_height)
  }
  let w = t.source_width.to_double()
  let landmarks = self.landmarks.map(fn(l) {
    let x0 = l.x / t.scale_x
    let y0 = l.y / t.scale_y
    let x = if t.mirrored { w - 1.0 - x0 } else { x0 }
    Landmark::{ x, y: y0, z: l.z, visibility: l.visibility, name: l.name, }
  })
  PoseResult::{
    landmarks,
    score: self.score,
    frame_id: self.frame_id,
    timestamp_ns: self.timestamp_ns,
    backend: self.backend,
  }
}

///|
/// 前处理结果携带的逆变换参数（按 `keep_aspect_ratio` 分派两种模式）。
priv enum ResizeTransform {
  Aspect(Transform)
  Stretch(StretchTransform)
}

///|
/// 前处理分派：等比 → `letterbox` + `Transform`；非等比 → `letterbox_stretch`
/// + `StretchTransform`。`detect` 用同一分派保证「前处理 ↔ 坐标还原」成对一致。
fn preprocess(
  image : RgbImage,
  config : PoseConfig,
) -> (Bytes, ResizeTransform) raise PoseError {
  if config.keep_aspect_ratio {
    let (bytes, t) = letterbox(image, config)
    (bytes, Aspect(t))
  } else {
    let (bytes, t) = letterbox_stretch(image, config)
    (bytes, Stretch(t))
  }
}

///|
/// 编排一帧的检测（单姿态入口）：输入 RGB → letterbox/stretch 缩放与归一化 →
/// 后端推理 → 多姿态解码 → NMS 去重 → 最高分姿态的坐标还原。
///
/// - 参数：`backend` 为 trait object，由组合根注入；`image`/`config` 只读纯值。
/// - 缩放：`keep_aspect_ratio = true` 走等比 letterbox（`Transform` 还原）；为
///   false 走 stretch 非等比拉伸（`StretchTransform` 还原），两者坐标反变换均正确。
/// - 返回：`PoseResult` 纯值（坐标已还原到输入图像像素系）；多姿态输出时返回
///   **NMS 后分数最高**的姿态；`score` 为保留关键点 `visibility` 的均值（无保留
///   关键点时为 0）；`timestamp_ns` 取自图像；`backend` 为 `backend.kind()` 标注。
/// - 错误：配置/输入错误不重试（`InvalidConfig` / `InvalidInput`）；后端错误原样
///   传播（`BackendNotOpen` / `BackendFailure`，可重试或降级由上层决定）；输出张量
///   超过 `max_poses` 姿态块预算 `BudgetExceeded`（触发帧率降级）；解码错误
///   `OutputDecode` / `ShapeMismatch`。
/// - 资源：`detect` 不获取/释放资源，只调用 `infer`；门面无可变状态，
///   并发约束由 `PoseBackend` 实现声明（见各后端自身文档）。
/// - 多姿态请用 `detect_multi`；本函数保持既有的单结果签名（API 冻结语义）。
/// - 非目标：不取帧、不做 YUV 转换、不渲染、不实现推理引擎、不管理模型文件下载。
pub fn detect(
  backend : &PoseBackend,
  image : RgbImage,
  config : PoseConfig,
  frame_id : FrameId,
) -> PoseResult raise PoseError {
  let poses = detect_multi(backend, image, config, frame_id)
  if poses.length() == 0 {
    // 零检测（空输出张量或全部候选被阈值过滤）：返回空结果。
    PoseResult::{
      landmarks: [],
      score: 0.0,
      frame_id,
      timestamp_ns: image.timestamp_ns,
      backend: backend.kind(),
    }
  } else {
    poses[0]
  }
}

///|
/// 编排一帧的检测（多姿态入口）：输入 RGB → letterbox/stretch 缩放与归一化 →
/// 后端推理 → 多姿态解码 → NMS 去重 → 逐姿态坐标还原。
///
/// - 输出张量按 `landmark_count * 3 * 4` 字节切块，每块为一个姿态；
/// - NMS 使用 `config.nms_threshold`（bbox IoU 严格大于阈值才抑制）与
///   `config.max_poses`（保留上限），按候选 `score` 降序贪心；
/// - 返回数组按 `score` 降序（NMS 保留顺序）；每个 `PoseResult` 的 `score` 为
///   该姿态保留关键点 visibility 均值，`frame_id`/`timestamp_ns`/`backend` 同
///   单姿态入口；
/// - 错误语义同 `detect`；空输出张量 `OutputDecode`，字节数非姿态块整数倍
///   `ShapeMismatch`，超过 `max_poses` 预算 `BudgetExceeded`。
pub fn detect_multi(
  backend : &PoseBackend,
  image : RgbImage,
  config : PoseConfig,
  frame_id : FrameId,
) -> Array[PoseResult] raise PoseError {
  let (input, plan) = preprocess(image, config)
  let raw = backend.infer(input)
  // 预算控制：输出张量携带的姿态块数不得超过 max_poses（单姿态布局为 1 块）。
  let block = config.model.landmark_count * 3 * 4
  let budget = block * config.max_poses
  if raw.length() > budget {
    raise BudgetExceeded(
      "detect: output tensor \{raw.length()} bytes exceeds max_poses budget \{budget} bytes",
    )
  }
  let candidates = decode_pose_batch(raw, config.model, config)
  let kept = nms(candidates, config.nms_threshold, config.max_poses)
  let backend_kind = backend.kind()
  let poses : Array[PoseResult] = []
  for c in kept {
    let result = PoseResult::{
      landmarks: c.landmarks,
      score: c.score,
      frame_id,
      timestamp_ns: image.timestamp_ns,
      backend: backend_kind,
    }
    poses.push(
      match plan {
        Aspect(t) => result.restore(t)
        Stretch(t) => result.restore_stretch(t)
      },
    )
  }
  poses
}
