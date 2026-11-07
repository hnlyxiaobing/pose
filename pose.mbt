///|
/// 姿态检测门面（facade）：类型、`PoseBackend` trait 与编排/前后处理实现。
///
/// 契约决策（见 docs/adr/ADR-0004）：门面拥有 `PoseBackend` trait 与中性值类型，
/// 后端（tflite_ffi / MediaPipe / ONNX）**不依赖本库**，由组合根提供适配器实现 trait。
/// 由此消除「门面→后端、后端→门面」的循环，换后端不换上层 API。
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
/// 可见性：`pub(open)`，组合根（包外）可实现本 trait 注入后端（ADR-0004）。
pub(open) trait PoseBackend {
  fn open(Self, PoseConfig) -> Unit raise PoseError
  fn infer(Self, Bytes) -> Bytes raise PoseError
  fn close(Self) -> Unit raise PoseError
  fn kind(Self) -> BackendKind
}

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
/// 校验 ModelSpec 与 PoseConfig 的参数域（纯函数）。
/// 配置类错误一律 `InvalidConfig`；均值/方差必须显式给出（长度等于
/// `input_channels`，`std` 非零且有限），拒绝任何静默默认值。
fn validate_spec_and_config(
  spec : ModelSpec,
  config : PoseConfig,
) -> Unit raise PoseError {
  if spec.input_width <= 0 || spec.input_height <= 0 {
    raise InvalidConfig("ModelSpec input size must be positive")
  }
  if spec.landmark_count <= 0 {
    raise InvalidConfig("ModelSpec.landmark_count must be positive")
  }
  if spec.input_channels <= 0 {
    raise InvalidConfig("ModelSpec.input_channels must be positive")
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
  if !config.keep_aspect_ratio {
    raise InvalidConfig(
      "PoseConfig.keep_aspect_ratio must be true: stretch resize is not representable by Transform",
    )
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
/// 把归一化值按 dtype 量化并写入输出缓冲（小端）。
/// Float16 编码不在本轮范围，以 `UnsupportedModel` 显式拒绝。
fn encode_value(
  out : FixedArray[Byte],
  off : Int32,
  v : Double,
  dtype : TensorDtype,
) -> Unit raise PoseError {
  match dtype {
    Float32 => write_f32_le(out, off, v)
    UInt8 => out[off] = clamp_round_int(v, 0, 255).to_byte()
    Int8 => out[off] = (clamp_round_int(v, -128, 127) & 0xFF).to_byte()
    Int32 => write_i32_le(out, off, clamp_round_int(v, -2147483648, 2147483647))
    Float16 =>
      raise UnsupportedModel("letterbox: Float16 input dtype is not supported")
  }
}

///|
/// 前处理：按比例缩放并填充到模型输入尺寸，返回预处理字节与还原参数。
///
/// - 等比缩放：`scale = min(tw/w, th/h)`，缩放区居中，四周填 `pad_value`（像素值，
///   与像素同样经过 `(pixel - mean) / std` 归一化后按 `input_dtype` 编码，小端）。
/// - `mirror_x` 为真时水平翻转采样（`x' = width - 1 - x`），并记录到
///   `Transform.mirrored`，由 `PoseResult::restore` 还原。
/// - 错误：配置/规格非法 `InvalidConfig`；尺寸与数据长度不符 `InvalidInput(w, h)`；
///   仅支持 3 通道模型输入与 Float32/UInt8/Int8/Int32，其余 `UnsupportedModel`。
pub fn letterbox(
  image : RgbImage,
  config : PoseConfig,
) -> (Bytes, Transform) raise PoseError {
  let spec = config.model
  validate_spec_and_config(spec, config)
  if spec.input_channels != 3 {
    raise UnsupportedModel("letterbox: only 3-channel model input is supported")
  }
  match spec.input_dtype {
    Float16 =>
      raise UnsupportedModel("letterbox: Float16 input dtype is not supported")
    _ => ()
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
  let elem = match spec.input_dtype {
    Float32 => 4
    Float16 => 2
    UInt8 => 1
    Int8 => 1
    Int32 => 4
  }
  let out = FixedArray::make(tw * th * 3 * elem, b'\x00')
  for ty in 0..<th {
    for tx in 0..<tw {
      let pixel = if tx >= pad_x &&
        tx < pad_x + scaled_w &&
        ty >= pad_y &&
        ty < pad_y + scaled_h {
        let sx0 = (tx - pad_x) * w / scaled_w
        let sy = (ty - pad_y) * h / scaled_h
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
  let t = Transform::{
    scale,
    pad_x,
    pad_y,
    source_width: w,
    source_height: h,
    mirrored: config.mirror_x,
  }
  (Bytes::from_array(out), t)
}

///|
/// 后处理：把后端原始输出张量字节解码为关键点数组。
///
/// - 布局：`[landmark_count, 3]` 的 Float32（小端）三元组 `(y, x, score)`，
///   坐标为相对模型输入尺寸的归一化值（MoveNet `输出 [1,1,17,3]` 的 17 点布局；
///   33 点同构布局同样适用，`landmark_count` 配置化）。
/// - `x = x_norm * input_width`、`y = y_norm * input_height`（模型输入像素系），
///   `z = 0`（2D 模型无深度），`visibility = score`，`name = None`（张量无名称）。
/// - 阈值过滤：`score < config.score_threshold` 的关键点被剔除。
/// - 错误：规格/配置非法 `InvalidConfig`；空张量或非有限数值 `OutputDecode`；
///   字节数与 `landmark_count * 3 * 4` 不符 `ShapeMismatch(expected, actual)`。
pub fn decode_output(
  raw : Bytes,
  spec : ModelSpec,
  config : PoseConfig,
) -> Array[Landmark] raise PoseError {
  validate_spec_and_config(spec, config)
  let block = spec.landmark_count * 3 * 4
  if raw.length() == 0 {
    raise OutputDecode("decode_output: empty output tensor")
  }
  if raw.length() != block {
    raise ShapeMismatch(block, raw.length())
  }
  let out : Array[Landmark] = []
  for i in 0..<spec.landmark_count {
    let base = i * 12
    let y_norm = read_f32_le(raw, base)
    let x_norm = read_f32_le(raw, base + 4)
    let score = read_f32_le(raw, base + 8)
    if !(y_norm.is_finite() && x_norm.is_finite() && score.is_finite()) {
      raise OutputDecode("decode_output: non-finite value in output tensor")
    }
    if score >= config.score_threshold {
      out.push(Landmark::{
        x: x_norm * spec.input_width.to_double(),
        y: y_norm * spec.input_height.to_double(),
        z: 0.0,
        visibility: score,
        name: None,
      })
    }
  }
  out
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
/// 编排一帧的检测：输入 RGB → letterbox/归一化 → 后端推理 → 关键点解码 → 坐标还原。
///
/// - 参数：`backend` 为 trait object，由组合根注入；`image`/`config` 只读纯值。
/// - 返回：`PoseResult` 纯值（坐标已还原到输入图像像素系）；`score` 为保留关键点
///   `visibility` 的均值（无保留关键点时为 0）；`timestamp_ns` 取自图像；
///   `backend` 为 `backend.kind()` 标注。
/// - 错误：配置/输入错误不重试（`InvalidConfig` / `InvalidInput`）；后端错误原样
///   传播（`BackendNotOpen` / `BackendFailure`，可重试或降级由上层决定）；输出张量
///   超过 `max_poses` 姿态块预算 `BudgetExceeded`（触发帧率降级）；解码错误
///   `OutputDecode` / `ShapeMismatch`。
/// - 资源：`detect` 不获取/释放资源，只调用 `infer`；门面无可变状态，
///   并发约束由 `PoseBackend` 实现声明（见各后端 DESIGN.md）。
/// - 非目标：不取帧、不做 YUV 转换、不渲染、不实现推理引擎、不管理模型文件下载。
pub fn detect(
  backend : &PoseBackend,
  image : RgbImage,
  config : PoseConfig,
  frame_id : FrameId,
) -> PoseResult raise PoseError {
  let (input, t) = letterbox(image, config)
  let raw = backend.infer(input)
  // 预算控制：输出张量携带的姿态块数不得超过 max_poses（单姿态布局为 1 块）。
  let block = config.model.landmark_count * 3 * 4
  let budget = block * config.max_poses
  if raw.length() > budget {
    raise BudgetExceeded(
      "detect: output tensor \{raw.length()} bytes exceeds max_poses budget \{budget} bytes",
    )
  }
  let landmarks = decode_output(raw, config.model, config)
  let n = landmarks.length()
  let score = if n == 0 {
    0.0
  } else {
    let mut total = 0.0
    for l in landmarks {
      total = total + l.visibility
    }
    total / n.to_double()
  }
  let result = PoseResult::{
    landmarks,
    score,
    frame_id,
    timestamp_ns: image.timestamp_ns,
    backend: backend.kind(),
  }
  result.restore(t)
}
