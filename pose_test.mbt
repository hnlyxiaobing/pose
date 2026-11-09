// Blackbox tests run against the package's public API. Use `@pose` to import.
// Prefer high-level behaviors over implementation details.
// Run `moon test` to execute and `moon test --update` to refresh snapshots.
//
// 本文件用 Mock 后端（测试替身，`PoseBackend` trait 实现）做纯 MoonBit 单测：
// letterbox 还原参数、输出解码形状（MoveNet [1,1,17,3] 类布局）、换后端不改
// 上层调用、错误路径（未 open / 配置非法 / 形状不匹配 / 预算超限等）。

///|
/// 把 Double 按小端 Float32 编码为 4 字节（构建测试用输出张量）。
fn f32_le(v : Double) -> Array[Byte] {
  let bits = Float::from_double(v).reinterpret_as_int()
  [
    (bits & 0xFF).to_byte(),
    ((bits >> 8) & 0xFF).to_byte(),
    ((bits >> 16) & 0xFF).to_byte(),
    ((bits >> 24) & 0xFF).to_byte(),
  ]
}

///|
/// 按 `(y, x, score)` 三元组平铺序列构建输出张量字节（MoveNet [1,1,N,3] 布局）。
fn raw_of(triplets : Array[Double]) -> Bytes {
  let arr : Array[Byte] = []
  for v in triplets {
    for b in f32_le(v) {
      arr.push(b)
    }
  }
  Bytes::from_array(arr)
}

///|
/// n 个相同的 `(y, x, score)` 三元组构成的输出张量。
fn raw_uniform(n : Int32, y : Double, x : Double, s : Double) -> Bytes {
  let arr : Array[Double] = []
  for _ in 0..<n {
    arr.push(y)
    arr.push(x)
    arr.push(s)
  }
  raw_of(arr)
}

///|
/// 模型规格构造器（配置化：尺寸 / dtype / 归一化 / 关键点数）。
fn spec_of(
  w : Int32,
  h : Int32,
  ch : Int32,
  dtype : @pose.TensorDtype,
  mean : Array[Double],
  std : Array[Double],
  n : Int32,
) -> @pose.ModelSpec {
  {
    input_width: w,
    input_height: h,
    input_channels: ch,
    input_dtype: dtype,
    mean,
    std,
    landmark_count: n,
    output_tensor_index: 0,
  }
}

///|
/// MoveNet.SinglePose 风格模型规格：192×192、Float32、17 点、(y,x,score)。
fn movenet_spec() -> @pose.ModelSpec {
  spec_of(
    192,
    192,
    3,
    @pose.TensorDtype::Float32,
    [0.0, 0.0, 0.0],
    [255.0, 255.0, 255.0],
    17,
  )
}

///|
/// 以 spec 为模型的默认合法配置。
fn config_of(spec : @pose.ModelSpec) -> @pose.PoseConfig {
  {
    model: spec,
    keep_aspect_ratio: true,
    pad_value: 0,
    score_threshold: 0.0,
    nms_threshold: 0.5,
    max_poses: 1,
    mirror_x: false,
  }
}

///|
/// 配置变体构造器（字段不可变，用复制式构造）。
fn config_with(
  base : @pose.PoseConfig,
  model : @pose.ModelSpec,
  keep_aspect_ratio : Bool,
  pad_value : Int32,
  score_threshold : Double,
  max_poses : Int32,
  mirror_x : Bool,
) -> @pose.PoseConfig {
  {
    model,
    keep_aspect_ratio,
    pad_value,
    score_threshold,
    nms_threshold: base.nms_threshold,
    max_poses,
    mirror_x,
  }
}

///|
/// 覆盖 nms_threshold / max_poses 的配置构造器（其余字段沿用 base）。
fn config_nms(
  base : @pose.PoseConfig,
  spec : @pose.ModelSpec,
  nms_threshold : Double,
  max_poses : Int32,
) -> @pose.PoseConfig {
  {
    model: spec,
    keep_aspect_ratio: base.keep_aspect_ratio,
    pad_value: base.pad_value,
    score_threshold: base.score_threshold,
    nms_threshold,
    max_poses,
    mirror_x: base.mirror_x,
  }
}

///|
/// 2 关键点姿态的模型规格（20×20），便于用归一化坐标构造精确 bbox（NMS 测试用）。
fn pair_spec() -> @pose.ModelSpec {
  spec_of(
    20,
    20,
    3,
    @pose.TensorDtype::Float32,
    [0.0, 0.0, 0.0],
    [1.0, 1.0, 1.0],
    2,
  )
}

///|
/// 全白 RGB 图像（内容不影响 Mock 固定输出）。
fn white_image(w : Int32, h : Int32) -> @pose.RgbImage {
  {
    width: w,
    height: h,
    layout: @pose.RgbLayout::Rgb,
    data: Bytes::make(w * h * 3, b'\xff'),
    timestamp_ns: 123456UL,
  }
}

///|
/// 测试替身：可脚本化 Mock 后端（纯 MoonBit，无 .so / 无设备）。
struct MockBackend {
  mut opened : Bool
  output : Bytes
  label : @pose.BackendKind
  fail_infer : Bool
  mut seen_input_len : Int32
}

///|
fn mock_of(output : Bytes, label : @pose.BackendKind) -> MockBackend {
  { opened: false, output, label, fail_infer: false, seen_input_len: -1, }
}

///|
/// 注入推理失败的 Mock。
fn failing_mock() -> MockBackend {
  {
    opened: true,
    output: Bytes::make(0, b'\x00'),
    label: @pose.BackendKind::Mock,
    fail_infer: true,
    seen_input_len: -1,
  }
}

///|
impl @pose.PoseBackend for MockBackend with fn open(self, _config) -> Unit raise @pose.PoseError {
  self.opened = true
}

///|
impl @pose.PoseBackend for MockBackend with fn infer(self, input) -> Bytes raise @pose.PoseError {
  if !self.opened {
    raise @pose.PoseError::BackendNotOpen("mock: infer before open")
  }
  if self.fail_infer {
    raise @pose.PoseError::BackendFailure("mock", "injected failure")
  }
  self.seen_input_len = input.length()
  self.output
}

///|
impl @pose.PoseBackend for MockBackend with fn close(self) -> Unit raise @pose.PoseError {
  self.opened = false
}

///|
impl @pose.PoseBackend for MockBackend with fn kind(self) -> @pose.BackendKind {
  self.label
}

///|
/// 第二个测试替身：验证「换后端不改上层调用」。
struct AltBackend {
  output : Bytes
}

///|
impl @pose.PoseBackend for AltBackend with fn open(_self, _config) -> Unit raise @pose.PoseError {
  ()
}

///|
impl @pose.PoseBackend for AltBackend with fn infer(self, _input) -> Bytes raise @pose.PoseError {
  self.output
}

///|
impl @pose.PoseBackend for AltBackend with fn close(_self) -> Unit raise @pose.PoseError {
  ()
}

///|
impl @pose.PoseBackend for AltBackend with fn kind(_self) -> @pose.BackendKind {
  @pose.BackendKind::Custom("alt-adapter")
}

///|
/// 捕获 raise PoseError 的调用结果。
fn[T] capture(f : () -> T raise @pose.PoseError) -> Result[T, @pose.PoseError] {
  Ok(f()) catch {
    e => Err(e)
  }
}

///|
/// 错误分类名（断言错误语义：配置/输入错误不重试，BackendFailure 可重试/降级，
/// BudgetExceeded 触发帧率降级）。
fn err_name(e : @pose.PoseError) -> String {
  match e {
    @pose.PoseError::BackendNotOpen(_) => "BackendNotOpen"
    @pose.PoseError::BackendFailure(_, _) => "BackendFailure"
    @pose.PoseError::InvalidConfig(_) => "InvalidConfig"
    @pose.PoseError::InvalidInput(_, _) => "InvalidInput"
    @pose.PoseError::OutputDecode(_) => "OutputDecode"
    @pose.PoseError::ShapeMismatch(_, _) => "ShapeMismatch"
    @pose.PoseError::UnsupportedModel(_) => "UnsupportedModel"
    @pose.PoseError::BudgetExceeded(_) => "BudgetExceeded"
  }
}

///|
/// 捕获结果的名称（"no error" 或错误分类名）。
fn[T] result_name(r : Result[T, @pose.PoseError]) -> String {
  match r {
    Ok(_) => "no error"
    Err(e) => err_name(e)
  }
}

///|
/// 后端标识名（用于断言结果标注）。
fn kind_name(k : @pose.BackendKind) -> String {
  match k {
    @pose.BackendKind::Tflite => "Tflite"
    @pose.BackendKind::MediaPipe => "MediaPipe"
    @pose.BackendKind::OnnxRuntime => "OnnxRuntime"
    @pose.BackendKind::Mock => "Mock"
    @pose.BackendKind::Custom(s) => "Custom:" + s
  }
}

///|
fn assert_close(actual : Double, expected : Double) -> Unit {
  if (actual - expected).abs() > 0.000001 {
    abort("expected \{expected}, got \{actual}")
  }
}

///|
test "detect: Mock 后端固定输出 → 解码 + letterbox 逆变换还原坐标" {
  let mock = mock_of(raw_uniform(17, 0.5, 0.5, 1.0), @pose.BackendKind::Mock)
  let spec = movenet_spec()
  let config = config_of(spec)
  let image = white_image(200, 100)
  // open/close 由组合根（实现方）负责，detect 不管理资源（DESIGN §5）
  @pose.PoseBackend::open(mock, config)
  let r = capture(() => @pose.detect(mock, image, config, 7UL))
  match r {
    Ok(res) => {
      assert_eq(res.landmarks.length(), 17)
      // 模型输入像素 (96, 96)；scale = 192/200，pad_y = (192 - 96)/2 = 48
      assert_close(res.landmarks[0].x, 100.0)
      assert_close(res.landmarks[0].y, 50.0)
      assert_close(res.landmarks[0].z, 0.0)
      assert_close(res.landmarks[0].visibility, 1.0)
      match res.landmarks[0].name {
        None => ()
        Some(_) => abort("landmark name must be None")
      }
      assert_close(res.score, 1.0)
      assert_eq(res.frame_id, 7UL)
      assert_eq(res.timestamp_ns, 123456UL)
      assert_eq(kind_name(res.backend), "Mock")
      // detect 把 letterbox 预处理字节交给后端（192*192*3*4 字节 Float32）
      assert_eq(mock.seen_input_len, 192 * 192 * 3 * 4)
    }
    Err(e) => abort("unexpected error: " + err_name(e))
  }
}

///|
test "detect: 换后端不改上层调用（同签名、同结果）" {
  let raw = raw_uniform(17, 0.5, 0.5, 1.0)
  let mock = mock_of(raw, @pose.BackendKind::Mock)
  let alt : AltBackend = { output: raw, }
  let spec = movenet_spec()
  let config = config_of(spec)
  let image = white_image(200, 100)
  @pose.PoseBackend::open(mock, config)
  @pose.PoseBackend::open(alt, config)
  let r1 = capture(() => @pose.detect(mock, image, config, 1UL))
  let r2 = capture(() => @pose.detect(alt, image, config, 1UL))
  match (r1, r2) {
    (Ok(a), Ok(b)) => {
      assert_eq(a.landmarks.length(), b.landmarks.length())
      assert_close(a.landmarks[0].x, b.landmarks[0].x)
      assert_close(a.landmarks[0].y, b.landmarks[0].y)
      assert_close(a.score, b.score)
      assert_eq(kind_name(a.backend), "Mock")
      assert_eq(kind_name(b.backend), "Custom:alt-adapter")
    }
    _ => abort("both backends must succeed")
  }
}

///|
test "detect: 未 open 的后端报 BackendNotOpen（不重试，先 open）" {
  let mock = mock_of(raw_uniform(17, 0.5, 0.5, 1.0), @pose.BackendKind::Mock)
  let r = capture(() => {
    @pose.detect(mock, white_image(200, 100), config_of(movenet_spec()), 1UL)
  })
  assert_eq(result_name(r), "BackendNotOpen")
}

///|
test "detect: 后端失败 BackendFailure 原样传播（可重试/降级语义）" {
  let mock = failing_mock()
  let r = capture(() => {
    @pose.detect(mock, white_image(200, 100), config_of(movenet_spec()), 1UL)
  })
  assert_eq(result_name(r), "BackendFailure")
  match r {
    Err(e) =>
      match e {
        @pose.PoseError::BackendFailure(kind, detail) => {
          assert_eq(kind, "mock")
          assert_eq(detail, "injected failure")
        }
        _ => abort("expected BackendFailure")
      }
    Ok(_) => abort("expected BackendFailure")
  }
}

///|
test "detect: 配置非法报 InvalidConfig（不触达后端）" {
  let mock = mock_of(raw_uniform(17, 0.5, 0.5, 1.0), @pose.BackendKind::Mock)
  let spec = movenet_spec()
  let base = config_of(spec)
  let zero_poses = config_with(base, spec, true, 0, 0.0, 0, false)
  // keep_aspect_ratio=false 现已支持（stretch）；这里改用越界的 score_threshold
  // 继续覆盖「配置非法不触达后端」路径，stretch 成功路径见 stretch 专项测试。
  let bad_threshold = config_with(base, spec, true, 0, 2.0, 1, false)
  let zero_std = config_with(
    base,
    spec_of(
      192,
      192,
      3,
      @pose.TensorDtype::Float32,
      [0.0, 0.0, 0.0],
      [0.0, 0.0, 0.0],
      17,
    ),
    true,
    0,
    0.0,
    1,
    false,
  )
  let r1 = capture(() => {
    @pose.detect(mock, white_image(200, 100), zero_poses, 1UL)
  })
  let r2 = capture(() => {
    @pose.detect(mock, white_image(200, 100), bad_threshold, 1UL)
  })
  let r3 = capture(() => {
    @pose.detect(mock, white_image(200, 100), zero_std, 1UL)
  })
  assert_eq(result_name(r1), "InvalidConfig")
  assert_eq(result_name(r2), "InvalidConfig")
  assert_eq(result_name(r3), "InvalidConfig")
  // 配置错误不重试：后端不应被触达
  assert_eq(mock.seen_input_len, -1)
}

///|
test "detect: 输入数据长度非法报 InvalidInput(w, h)" {
  let mock = mock_of(raw_uniform(17, 0.5, 0.5, 1.0), @pose.BackendKind::Mock)
  let bad : @pose.RgbImage = {
    width: 2,
    height: 2,
    layout: @pose.RgbLayout::Rgb,
    data: Bytes::make(3, b'\x00'),
    timestamp_ns: 0UL,
  }
  let r = capture(() => @pose.detect(mock, bad, config_of(movenet_spec()), 1UL))
  assert_eq(result_name(r), "InvalidInput")
  match r {
    Err(e) =>
      match e {
        @pose.PoseError::InvalidInput(w, h) => {
          assert_eq(w, 2)
          assert_eq(h, 2)
        }
        _ => abort("expected InvalidInput")
      }
    Ok(_) => abort("expected InvalidInput")
  }
}

///|
test "detect: 输出形状不符报 ShapeMismatch(expected, actual)" {
  // 契约：单姿态布局为 landmark_count * 3 个 Float32 = 204 字节
  let mock = mock_of(raw_uniform(10, 0.5, 0.5, 1.0), @pose.BackendKind::Mock)
  @pose.PoseBackend::open(mock, config_of(movenet_spec()))
  let r = capture(() => {
    @pose.detect(mock, white_image(200, 100), config_of(movenet_spec()), 1UL)
  })
  assert_eq(result_name(r), "ShapeMismatch")
  match r {
    Err(e) =>
      match e {
        @pose.PoseError::ShapeMismatch(expected, actual) => {
          assert_eq(expected, 204)
          assert_eq(actual, 120)
        }
        _ => abort("expected ShapeMismatch")
      }
    Ok(_) => abort("expected ShapeMismatch")
  }
}

///|
test "detect: 输出张量超过 max_poses 预算报 BudgetExceeded（帧率降级）" {
  // 34 个姿态块 > max_poses=1 预算
  let mock = mock_of(raw_uniform(34, 0.5, 0.5, 1.0), @pose.BackendKind::Mock)
  @pose.PoseBackend::open(mock, config_of(movenet_spec()))
  let r = capture(() => {
    @pose.detect(mock, white_image(200, 100), config_of(movenet_spec()), 1UL)
  })
  assert_eq(result_name(r), "BudgetExceeded")
}

///|
test "detect: 空输出张量报 OutputDecode" {
  let mock = mock_of(Bytes::make(0, b'\x00'), @pose.BackendKind::Mock)
  @pose.PoseBackend::open(mock, config_of(movenet_spec()))
  let r = capture(() => {
    @pose.detect(mock, white_image(200, 100), config_of(movenet_spec()), 1UL)
  })
  assert_eq(result_name(r), "OutputDecode")
}

///|
test "detect: 非有限输出值报 OutputDecode" {
  // 0x7FC00000 = Float32 NaN（小端 00 00 C0 7F），作为第 1 个三元组的 score
  let nan_score = Bytes::from_array([
    b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00',
    b'\x00', b'\xc0', b'\x7f',
  ])
  let raw = nan_score + raw_uniform(16, 0.5, 0.5, 1.0)
  let mock = mock_of(raw, @pose.BackendKind::Mock)
  @pose.PoseBackend::open(mock, config_of(movenet_spec()))
  let r = capture(() => {
    @pose.detect(mock, white_image(200, 100), config_of(movenet_spec()), 1UL)
  })
  assert_eq(result_name(r), "OutputDecode")
}

///|
test "detect: mirror_x 配置下坐标还原为镜像像素坐标" {
  let mock = mock_of(raw_uniform(17, 0.5, 0.5, 1.0), @pose.BackendKind::Mock)
  let spec = movenet_spec()
  let config = config_with(config_of(spec), spec, true, 0, 0.0, 1, true)
  @pose.PoseBackend::open(mock, config)
  let r = capture(() => @pose.detect(mock, white_image(200, 100), config, 1UL))
  match r {
    Ok(res) => {
      // x0 = 96 / (192/200) = 100，镜像还原 x = 200 - 1 - 100 = 99
      assert_close(res.landmarks[0].x, 99.0)
      assert_close(res.landmarks[0].y, 50.0)
    }
    Err(e) => abort("unexpected error: " + err_name(e))
  }
}

///|
test "decode_output: MoveNet [1,1,17,3] 布局解码为模型输入像素坐标" {
  let spec = movenet_spec()
  let triplets : Array[Double] = []
  for _ in 0..<17 {
    triplets.push(0.25)
    triplets.push(0.5)
    triplets.push(0.9)
  }
  let r = capture(() => {
    @pose.decode_output(raw_of(triplets), spec, config_of(spec))
  })
  match r {
    Ok(landmarks) => {
      assert_eq(landmarks.length(), 17)
      // x = 0.5 * 192 = 96，y = 0.25 * 192 = 48
      assert_close(landmarks[0].x, 96.0)
      assert_close(landmarks[0].y, 48.0)
      assert_close(landmarks[0].z, 0.0)
      assert_close(landmarks[0].visibility, 0.9)
    }
    Err(e) => abort("unexpected error: " + err_name(e))
  }
}

///|
test "decode_output: 33 点同构布局按 landmark_count 配置化解析" {
  let spec = spec_of(
    120,
    120,
    3,
    @pose.TensorDtype::Float32,
    [0.0, 0.0, 0.0],
    [255.0, 255.0, 255.0],
    33,
  )
  let triplets : Array[Double] = []
  for _ in 0..<33 {
    triplets.push(0.5)
    triplets.push(0.25)
    triplets.push(1.0)
  }
  let r = capture(() => {
    @pose.decode_output(raw_of(triplets), spec, config_of(spec))
  })
  match r {
    Ok(landmarks) => {
      assert_eq(landmarks.length(), 33)
      assert_close(landmarks[32].x, 30.0)
      assert_close(landmarks[32].y, 60.0)
      assert_close(landmarks[32].visibility, 1.0)
    }
    Err(e) => abort("unexpected error: " + err_name(e))
  }
}

///|
test "decode_output: score_threshold 阈值过滤（保序剔除低分点）" {
  let spec = spec_of(
    8,
    8,
    3,
    @pose.TensorDtype::Float32,
    [0.0, 0.0, 0.0],
    [255.0, 255.0, 255.0],
    3,
  )
  let config = config_with(config_of(spec), spec, true, 0, 0.5, 1, false)
  let raw = raw_of([0.5, 0.5, 0.9, 0.5, 0.5, 0.4, 0.5, 0.5, 0.6])
  let r = capture(() => @pose.decode_output(raw, spec, config))
  match r {
    Ok(landmarks) => {
      assert_eq(landmarks.length(), 2)
      assert_close(landmarks[0].visibility, 0.9)
      assert_close(landmarks[1].visibility, 0.6)
    }
    Err(e) => abort("unexpected error: " + err_name(e))
  }
}

///|
test "decode_output: 字节数不符报 ShapeMismatch(expected, actual)" {
  let spec = spec_of(
    8,
    8,
    3,
    @pose.TensorDtype::Float32,
    [0.0, 0.0, 0.0],
    [255.0, 255.0, 255.0],
    1,
  )
  let r = capture(() => {
    @pose.decode_output(raw_uniform(2, 0.5, 0.5, 1.0), spec, config_of(spec))
  })
  assert_eq(result_name(r), "ShapeMismatch")
  match r {
    Err(e) =>
      match e {
        @pose.PoseError::ShapeMismatch(expected, actual) => {
          assert_eq(expected, 12)
          assert_eq(actual, 24)
        }
        _ => abort("expected ShapeMismatch")
      }
    Ok(_) => abort("expected ShapeMismatch")
  }
}

///|
test "decode_output: 空张量与非有限值报 OutputDecode，规格非法报 InvalidConfig" {
  let spec = spec_of(
    8,
    8,
    3,
    @pose.TensorDtype::Float32,
    [0.0, 0.0, 0.0],
    [255.0, 255.0, 255.0],
    1,
  )
  let config = config_of(spec)
  let r1 = capture(() => {
    @pose.decode_output(Bytes::make(0, b'\x00'), spec, config)
  })
  // 0x7FC00000 = Float32 NaN（y 分量）
  let bad = Bytes::from_array([
    b'\x00', b'\x00', b'\xc0', b'\x7f', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00',
    b'\x00', b'\x80', b'\x3f',
  ])
  let r2 = capture(() => @pose.decode_output(bad, spec, config))
  let bad_config = config_with(config, spec, true, 0, 2.0, 1, false)
  let r3 = capture(() => {
    @pose.decode_output(raw_uniform(1, 0.5, 0.5, 1.0), spec, bad_config)
  })
  assert_eq(result_name(r1), "OutputDecode")
  assert_eq(result_name(r2), "OutputDecode")
  assert_eq(result_name(r3), "InvalidConfig")
}

///|
test "letterbox: 等比缩放、居中填充与 UInt8 透传字节" {
  // 源 4×2，模型输入 2×4：scale=0.5，scaled 2×1，pad_y=(4-1)/2=1
  let data = Bytes::from_array([
    b'\x0a', b'\x14', b'\x1e', b'\x00', b'\x00', b'\x00', b'\x64', b'\x6e', b'\x78',
    b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00',
    b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00',
  ])
  let image : @pose.RgbImage = {
    width: 4,
    height: 2,
    layout: @pose.RgbLayout::Rgb,
    data,
    timestamp_ns: 0UL,
  }
  let spec = spec_of(
    2,
    4,
    3,
    @pose.TensorDtype::UInt8,
    [0.0, 0.0, 0.0],
    [1.0, 1.0, 1.0],
    3,
  )
  let config = config_with(config_of(spec), spec, true, 7, 0.0, 1, false)
  let r = capture(() => @pose.letterbox(image, config))
  match r {
    Ok((bytes, t)) => {
      assert_eq(bytes.length(), 2 * 4 * 3)
      assert_close(t.scale, 0.5)
      assert_eq(t.pad_x, 0)
      assert_eq(t.pad_y, 1)
      assert_eq(t.source_width, 4)
      assert_eq(t.source_height, 2)
      assert_true(!t.mirrored)
      // 第 0 行为填充（pad_value=7）
      assert_eq(bytes[0].to_int(), 7)
      assert_eq(bytes[5].to_int(), 7)
      // 第 1 行为缩放区：采样源 (0,0)=(10,20,30) 与 (2,0)=(100,110,120)
      assert_eq(bytes[6].to_int(), 10)
      assert_eq(bytes[7].to_int(), 20)
      assert_eq(bytes[8].to_int(), 30)
      assert_eq(bytes[9].to_int(), 100)
      assert_eq(bytes[10].to_int(), 110)
      assert_eq(bytes[11].to_int(), 120)
      // 第 2、3 行为填充
      assert_eq(bytes[12].to_int(), 7)
      assert_eq(bytes[23].to_int(), 7)
    }
    Err(e) => abort("unexpected error: " + err_name(e))
  }
}

///|
test "letterbox: mirror_x 水平翻转采样并记录于 Transform" {
  let data = Bytes::from_array([
    b'\x0a', b'\x14', b'\x1e', b'\x28', b'\x32', b'\x3c',
  ])
  let image : @pose.RgbImage = {
    width: 2,
    height: 1,
    layout: @pose.RgbLayout::Rgb,
    data,
    timestamp_ns: 0UL,
  }
  let spec = spec_of(
    2,
    1,
    3,
    @pose.TensorDtype::UInt8,
    [0.0, 0.0, 0.0],
    [1.0, 1.0, 1.0],
    3,
  )
  let config = config_with(config_of(spec), spec, true, 0, 0.0, 1, true)
  let r = capture(() => @pose.letterbox(image, config))
  match r {
    Ok((bytes, t)) => {
      assert_true(t.mirrored)
      // 水平翻转：输出像素 0 = 源像素 (1,0) = (40,50,60)
      assert_eq(bytes[0].to_int(), 40)
      assert_eq(bytes[1].to_int(), 50)
      assert_eq(bytes[2].to_int(), 60)
      assert_eq(bytes[3].to_int(), 10)
      assert_eq(bytes[4].to_int(), 20)
      assert_eq(bytes[5].to_int(), 30)
    }
    Err(e) => abort("unexpected error: " + err_name(e))
  }
}

///|
test "letterbox: Float32 归一化编码 (pixel - mean) / std" {
  let data = Bytes::from_array([b'\xff', b'\xff', b'\xff'])
  let image : @pose.RgbImage = {
    width: 1,
    height: 1,
    layout: @pose.RgbLayout::Rgb,
    data,
    timestamp_ns: 0UL,
  }
  let spec = spec_of(
    1,
    1,
    3,
    @pose.TensorDtype::Float32,
    [0.0, 0.0, 0.0],
    [255.0, 255.0, 255.0],
    3,
  )
  // mean=0, std=255 → 255/255 = 1.0
  let r = capture(() => @pose.letterbox(image, config_of(spec)))
  match r {
    Ok((bytes, _t)) => {
      assert_eq(bytes.length(), 12)
      let expected = f32_le(1.0) // 0x3F800000
      for i in 0..<12 {
        assert_eq(bytes[i].to_int(), expected[i % 4].to_int())
      }
    }
    Err(e) => abort("unexpected error: " + err_name(e))
  }
}

///|
test "letterbox: 错误路径（数据长度 / stretch 由 letterbox_stretch 承担 / 非 3 通道）" {
  let spec = spec_of(
    2,
    2,
    3,
    @pose.TensorDtype::UInt8,
    [0.0, 0.0, 0.0],
    [1.0, 1.0, 1.0],
    3,
  )
  let bad : @pose.RgbImage = {
    width: 2,
    height: 2,
    layout: @pose.RgbLayout::Rgb,
    data: Bytes::make(3, b'\x00'),
    timestamp_ns: 0UL,
  }
  let good = white_image(2, 2)
  let r1 = capture(() => @pose.letterbox(bad, config_of(spec)))
  let stretch = config_with(config_of(spec), spec, false, 0, 0.0, 1, false)
  let r2 = capture(() => @pose.letterbox(good, stretch))
  let f16_spec = spec_of(
    2,
    2,
    3,
    @pose.TensorDtype::Float16,
    [0.0, 0.0, 0.0],
    [1.0, 1.0, 1.0],
    3,
  )
  let r3 = capture(() => @pose.letterbox(good, config_of(f16_spec)))
  let ch4_spec = spec_of(
    2,
    2,
    4,
    @pose.TensorDtype::UInt8,
    [0.0, 0.0, 0.0, 0.0],
    [1.0, 1.0, 1.0, 1.0],
    3,
  )
  let r4 = capture(() => @pose.letterbox(good, config_of(ch4_spec)))
  assert_eq(result_name(r1), "InvalidInput")
  // 旧的 letterbox 返回单 scale 的 Transform，无法表达非等比缩放；stretch 由
  // letterbox_stretch / detect 承担（见 stretch 专项测试）。
  assert_eq(result_name(r2), "InvalidConfig")
  // Float16 已被支持：255 → f16 0x5BF8，小端 F8 5B
  match r3 {
    Ok((bytes, t)) => {
      assert_eq(bytes.length(), 2 * 2 * 3 * 2)
      assert_eq(t.scale, 1.0)
      assert_eq(bytes[0].to_int(), 0xF8)
      assert_eq(bytes[1].to_int(), 0x5B)
    }
    Err(e) => abort("Float16 letterbox must succeed: " + err_name(e))
  }
  assert_eq(result_name(r4), "UnsupportedModel")
}

///|
test "letterbox: Float16 归一化编码（1.0 → 0x3C00，小端 00 3C）" {
  let image : @pose.RgbImage = {
    width: 1,
    height: 1,
    layout: @pose.RgbLayout::Rgb,
    data: Bytes::from_array([b'\xff', b'\xff', b'\xff']),
    timestamp_ns: 0UL,
  }
  let spec = spec_of(
    1,
    1,
    3,
    @pose.TensorDtype::Float16,
    [0.0, 0.0, 0.0],
    [255.0, 255.0, 255.0],
    3,
  )
  let r = capture(() => @pose.letterbox(image, config_of(spec)))
  match r {
    Ok((bytes, _t)) => {
      assert_eq(bytes.length(), 6)
      for c in 0..<3 {
        assert_eq(bytes[c * 2].to_int(), 0x00)
        assert_eq(bytes[c * 2 + 1].to_int(), 0x3C)
      }
    }
    Err(e) => abort("unexpected error: " + err_name(e))
  }
}

///|
test "restore: 像素坐标还原与镜像还原（不修改输入）" {
  let lm : @pose.Landmark = {
    x: 50.0,
    y: 50.0,
    z: 0.25,
    visibility: 0.8,
    name: None,
  }
  let res : @pose.PoseResult = {
    landmarks: [lm],
    score: 0.8,
    frame_id: 3UL,
    timestamp_ns: 9UL,
    backend: @pose.BackendKind::Mock,
  }
  let t : @pose.Transform = {
    scale: 0.5,
    pad_x: 0,
    pad_y: 25,
    source_width: 200,
    source_height: 100,
    mirrored: false,
  }
  let tm : @pose.Transform = {
    scale: 0.5,
    pad_x: 0,
    pad_y: 25,
    source_width: 200,
    source_height: 100,
    mirrored: true,
  }
  let r1 = capture(() => res.restore(t))
  let r2 = capture(() => res.restore(tm))
  match (r1, r2) {
    (Ok(a), Ok(b)) => {
      // x = (50 - 0) / 0.5 = 100；y = (50 - 25) / 0.5 = 50
      assert_close(a.landmarks[0].x, 100.0)
      assert_close(a.landmarks[0].y, 50.0)
      assert_close(a.landmarks[0].z, 0.25)
      assert_close(a.landmarks[0].visibility, 0.8)
      assert_eq(a.frame_id, 3UL)
      assert_eq(a.timestamp_ns, 9UL)
      // 镜像还原 x = 200 - 1 - 100 = 99
      assert_close(b.landmarks[0].x, 99.0)
      assert_close(b.landmarks[0].y, 50.0)
      // 纯函数：输入不变
      assert_close(res.landmarks[0].x, 50.0)
    }
    _ => abort("restore must succeed")
  }
}

///|
test "restore: Transform 非法报 InvalidConfig / InvalidInput" {
  let lm : @pose.Landmark = {
    x: 1.0,
    y: 1.0,
    z: 0.0,
    visibility: 1.0,
    name: None,
  }
  let res : @pose.PoseResult = {
    landmarks: [lm],
    score: 1.0,
    frame_id: 0UL,
    timestamp_ns: 0UL,
    backend: @pose.BackendKind::Mock,
  }
  let bad_scale : @pose.Transform = {
    scale: 0.0,
    pad_x: 0,
    pad_y: 0,
    source_width: 10,
    source_height: 10,
    mirrored: false,
  }
  let bad_size : @pose.Transform = {
    scale: 1.0,
    pad_x: 0,
    pad_y: 0,
    source_width: 0,
    source_height: 10,
    mirrored: false,
  }
  let r1 = capture(() => res.restore(bad_scale))
  let r2 = capture(() => res.restore(bad_size))
  assert_eq(result_name(r1), "InvalidConfig")
  assert_eq(result_name(r2), "InvalidInput")
}

///|
test "letterbox_stretch: 非等比拉伸无填充 + StretchTransform 比例" {
  // 源 4×2 → 模型 2×4：scale_x=0.5、scale_y=2.0，整幅输出无 pad
  let data = Bytes::from_array([
    b'\x0a', b'\x14', b'\x1e', b'\x28', b'\x32', b'\x3c', b'\x46', b'\x50', b'\x5a',
    b'\x64', b'\x6e', b'\x78', b'\x01', b'\x02', b'\x03', b'\x04', b'\x05', b'\x06',
    b'\x07', b'\x08', b'\x09', b'\x0a', b'\x0b', b'\x0c',
  ])
  let image : @pose.RgbImage = {
    width: 4,
    height: 2,
    layout: @pose.RgbLayout::Rgb,
    data,
    timestamp_ns: 0UL,
  }
  let spec = spec_of(
    2,
    4,
    3,
    @pose.TensorDtype::UInt8,
    [0.0, 0.0, 0.0],
    [1.0, 1.0, 1.0],
    3,
  )
  let config = config_with(config_of(spec), spec, false, 7, 0.0, 1, false)
  let r = capture(() => @pose.letterbox_stretch(image, config))
  match r {
    Ok((bytes, t)) => {
      assert_eq(bytes.length(), 2 * 4 * 3)
      assert_close(t.scale_x, 0.5)
      assert_close(t.scale_y, 2.0)
      assert_eq(t.source_width, 4)
      assert_eq(t.source_height, 2)
      assert_true(!t.mirrored)
      // 第 0 行：源 (0,0)=(10,20,30)、(2,0)=(70,80,90)
      assert_eq(bytes[0].to_int(), 10)
      assert_eq(bytes[5].to_int(), 90)
      // 第 1 行与第 0 行相同（sy = 1*2/4 = 0）
      assert_eq(bytes[6].to_int(), 10)
      assert_eq(bytes[11].to_int(), 90)
      // 第 2 行：源 (0,1)=(1,2,3)、(2,1)=(7,8,9)
      assert_eq(bytes[12].to_int(), 1)
      assert_eq(bytes[17].to_int(), 9)
      // 第 3 行与第 2 行相同
      assert_eq(bytes[18].to_int(), 1)
      // 无填充：pad_value=7 不应出现在首像素
      assert_eq(bytes[0].to_int() != 7, true)
    }
    Err(e) => abort("unexpected error: " + err_name(e))
  }
}

///|
test "letterbox_stretch: mirror_x 水平翻转采样" {
  let image : @pose.RgbImage = {
    width: 2,
    height: 1,
    layout: @pose.RgbLayout::Rgb,
    data: Bytes::from_array([
      b'\x0a', b'\x14', b'\x1e', b'\x28', b'\x32', b'\x3c',
    ]),
    timestamp_ns: 0UL,
  }
  let spec = spec_of(
    2,
    1,
    3,
    @pose.TensorDtype::UInt8,
    [0.0, 0.0, 0.0],
    [1.0, 1.0, 1.0],
    3,
  )
  let config = config_with(config_of(spec), spec, false, 0, 0.0, 1, true)
  let r = capture(() => @pose.letterbox_stretch(image, config))
  match r {
    Ok((bytes, t)) => {
      assert_true(t.mirrored)
      assert_eq(bytes[0].to_int(), 40)
      assert_eq(bytes[3].to_int(), 10)
    }
    Err(e) => abort("unexpected error: " + err_name(e))
  }
}

///|
test "detect: stretch 模式按 x/y 独立比例还原坐标" {
  let mock = mock_of(raw_uniform(17, 0.25, 0.25, 1.0), @pose.BackendKind::Mock)
  let spec = movenet_spec()
  let config = config_with(config_of(spec), spec, false, 0, 0.0, 1, false)
  @pose.PoseBackend::open(mock, config)
  let r = capture(() => @pose.detect(mock, white_image(200, 100), config, 3UL))
  match r {
    Ok(res) => {
      // 模型输入像素 (48, 48)；scale_x=192/200=0.96、scale_y=192/100=1.92
      assert_close(res.landmarks[0].x, 50.0)
      assert_close(res.landmarks[0].y, 25.0)
      assert_close(res.score, 1.0)
      assert_eq(res.frame_id, 3UL)
      assert_eq(kind_name(res.backend), "Mock")
      assert_eq(mock.seen_input_len, 192 * 192 * 3 * 4)
    }
    Err(e) => abort("unexpected error: " + err_name(e))
  }
}

///|
test "restore_stretch: 坐标还原 / 镜像 / 错误路径" {
  let lm : @pose.Landmark = {
    x: 50.0,
    y: 50.0,
    z: 0.25,
    visibility: 0.8,
    name: None,
  }
  let res : @pose.PoseResult = {
    landmarks: [lm],
    score: 0.8,
    frame_id: 3UL,
    timestamp_ns: 9UL,
    backend: @pose.BackendKind::Mock,
  }
  let t : @pose.StretchTransform = {
    scale_x: 0.5,
    scale_y: 0.25,
    source_width: 200,
    source_height: 100,
    mirrored: false,
  }
  let tm : @pose.StretchTransform = {
    scale_x: 0.5,
    scale_y: 0.25,
    source_width: 200,
    source_height: 100,
    mirrored: true,
  }
  let r1 = capture(() => res.restore_stretch(t))
  let r2 = capture(() => res.restore_stretch(tm))
  match (r1, r2) {
    (Ok(a), Ok(b)) => {
      // x = 50/0.5 = 100；y = 50/0.25 = 200
      assert_close(a.landmarks[0].x, 100.0)
      assert_close(a.landmarks[0].y, 200.0)
      assert_close(a.landmarks[0].z, 0.25)
      assert_close(a.landmarks[0].visibility, 0.8)
      // 镜像还原 x = 200 - 1 - 100 = 99
      assert_close(b.landmarks[0].x, 99.0)
      assert_close(b.landmarks[0].y, 200.0)
      // 纯函数：输入不变
      assert_close(res.landmarks[0].x, 50.0)
    }
    _ => abort("restore_stretch must succeed")
  }
  let bad_scale : @pose.StretchTransform = {
    scale_x: 0.0,
    scale_y: 1.0,
    source_width: 10,
    source_height: 10,
    mirrored: false,
  }
  let nan_scale : @pose.StretchTransform = {
    scale_x: 1.0,
    scale_y: Float::reinterpret_from_int(0x7FC00000).to_double(),
    source_width: 10,
    source_height: 10,
    mirrored: false,
  }
  let bad_size : @pose.StretchTransform = {
    scale_x: 1.0,
    scale_y: 1.0,
    source_width: 0,
    source_height: 10,
    mirrored: false,
  }
  assert_eq(
    result_name(capture(() => res.restore_stretch(bad_scale))),
    "InvalidConfig",
  )
  assert_eq(
    result_name(capture(() => res.restore_stretch(nan_scale))),
    "InvalidConfig",
  )
  assert_eq(
    result_name(capture(() => res.restore_stretch(bad_size))),
    "InvalidInput",
  )
}

///|
test "letterbox_stretch: 模式/输入/通道错误路径" {
  let spec = spec_of(
    2,
    2,
    3,
    @pose.TensorDtype::UInt8,
    [0.0, 0.0, 0.0],
    [1.0, 1.0, 1.0],
    3,
  )
  let good = white_image(2, 2)
  let aspect = config_with(config_of(spec), spec, true, 0, 0.0, 1, false)
  let r1 = capture(() => @pose.letterbox_stretch(good, aspect))
  let bad : @pose.RgbImage = {
    width: 2,
    height: 2,
    layout: @pose.RgbLayout::Rgb,
    data: Bytes::make(3, b'\x00'),
    timestamp_ns: 0UL,
  }
  let stretch = config_with(config_of(spec), spec, false, 0, 0.0, 1, false)
  let r2 = capture(() => @pose.letterbox_stretch(bad, stretch))
  let ch4_spec = spec_of(
    2,
    2,
    4,
    @pose.TensorDtype::UInt8,
    [0.0, 0.0, 0.0, 0.0],
    [1.0, 1.0, 1.0, 1.0],
    3,
  )
  let ch4 = config_with(config_of(ch4_spec), ch4_spec, false, 0, 0.0, 1, false)
  let r3 = capture(() => @pose.letterbox_stretch(good, ch4))
  assert_eq(result_name(r1), "InvalidConfig")
  assert_eq(result_name(r2), "InvalidInput")
  assert_eq(result_name(r3), "UnsupportedModel")
}

///|
test "detect_multi: 多姿态输出按块解码并按分数降序" {
  // Pose A: (0,0)-(10,10) score 1.0；Pose B: (10,10)-(20,20) score 0.9（bbox 相接 IoU=0）
  let raw = raw_of([0.0, 0.0, 1.0, 0.5, 0.5, 1.0, 0.5, 0.5, 0.9, 1.0, 1.0, 0.9])
  let spec = pair_spec()
  let config = config_nms(config_of(spec), spec, 0.5, 2)
  let mock = mock_of(raw, @pose.BackendKind::Mock)
  @pose.PoseBackend::open(mock, config)
  let r = capture(() => {
    @pose.detect_multi(mock, white_image(20, 20), config, 5UL)
  })
  match r {
    Ok(poses) => {
      assert_eq(poses.length(), 2)
      assert_close(poses[0].score, 1.0)
      assert_close(poses[1].score, 0.9)
      assert_close(poses[0].landmarks[0].x, 0.0)
      assert_close(poses[0].landmarks[1].x, 10.0)
      assert_close(poses[1].landmarks[0].x, 10.0)
      assert_eq(poses[0].frame_id, 5UL)
      assert_eq(kind_name(poses[0].backend), "Mock")
    }
    Err(e) => abort("unexpected error: " + err_name(e))
  }
  // 单姿态入口仍返回 NMS 后最高分姿态（签名不变）
  let r1 = capture(() => @pose.detect(mock, white_image(20, 20), config, 5UL))
  match r1 {
    Ok(p) => assert_close(p.score, 1.0)
    Err(e) => abort("unexpected error: " + err_name(e))
  }
}

///|
test "detect_multi: 全重叠姿态被 NMS 抑制（只保留最高分）" {
  let raw = raw_of([0.0, 0.0, 1.0, 0.5, 0.5, 1.0, 0.0, 0.0, 0.9, 0.5, 0.5, 0.9])
  let spec = pair_spec()
  let config = config_nms(config_of(spec), spec, 0.5, 2)
  let mock = mock_of(raw, @pose.BackendKind::Mock)
  @pose.PoseBackend::open(mock, config)
  let r = capture(() => {
    @pose.detect_multi(mock, white_image(20, 20), config, 1UL)
  })
  match r {
    Ok(poses) => {
      assert_eq(poses.length(), 1)
      assert_close(poses[0].score, 1.0)
    }
    Err(e) => abort("unexpected error: " + err_name(e))
  }
}

///|
test "detect_multi: IoU 恰等于阈值不抑制、略低于阈值才抑制" {
  // A bbox (0,0)-(10,10)，B bbox (0,0)-(10,5)：IoU = 50/100 = 0.5
  let raw = raw_of([0.0, 0.0, 1.0, 0.5, 0.5, 1.0, 0.0, 0.0, 0.9, 0.25, 0.5, 0.9])
  let spec = pair_spec()
  let keep_both = config_nms(config_of(spec), spec, 0.5, 2)
  let suppress = config_nms(config_of(spec), spec, 0.499, 2)
  let mock = mock_of(raw, @pose.BackendKind::Mock)
  @pose.PoseBackend::open(mock, keep_both)
  let r1 = capture(() => {
    @pose.detect_multi(mock, white_image(20, 20), keep_both, 1UL)
  })
  let r2 = capture(() => {
    @pose.detect_multi(mock, white_image(20, 20), suppress, 1UL)
  })
  match (r1, r2) {
    (Ok(a), Ok(b)) => {
      assert_eq(a.length(), 2)
      assert_eq(b.length(), 1)
      assert_close(b[0].score, 1.0)
    }
    _ => abort("both NMS threshold cases must succeed")
  }
}

///|
test "detect_multi: score_threshold 过滤掉全部关键点后姿态保留为空候选（score 0）" {
  let raw = raw_of([0.0, 0.0, 0.5, 0.5, 0.5, 0.5])
  let spec = pair_spec()
  let base = config_with(config_of(spec), spec, true, 0, 0.9, 1, false)
  let config = config_nms(base, spec, 0.5, 2)
  let mock = mock_of(raw, @pose.BackendKind::Mock)
  @pose.PoseBackend::open(mock, config)
  let r = capture(() => {
    @pose.detect_multi(mock, white_image(20, 20), config, 1UL)
  })
  match r {
    Ok(poses) => {
      assert_eq(poses.length(), 1)
      assert_eq(poses[0].landmarks.length(), 0)
      assert_close(poses[0].score, 0.0)
    }
    Err(e) => abort("unexpected error: " + err_name(e))
  }
}

///|
test "detect_multi: 预算超限 / 空输出 / 非整数块 / 非法 nms_threshold 错误路径" {
  let spec = pair_spec()
  let config = config_nms(config_of(spec), spec, 0.5, 2)
  // 3 个姿态块 = 72 字节 > max_poses=2 的 48 字节预算（pair_spec block=24）
  let over = mock_of(raw_uniform(6, 0.5, 0.5, 1.0), @pose.BackendKind::Mock)
  @pose.PoseBackend::open(over, config)
  let r1 = capture(() => {
    @pose.detect_multi(over, white_image(20, 20), config, 1UL)
  })
  // 空输出张量
  let empty = mock_of(Bytes::make(0, b'\x00'), @pose.BackendKind::Mock)
  @pose.PoseBackend::open(empty, config)
  let r2 = capture(() => {
    @pose.detect_multi(empty, white_image(20, 20), config, 1UL)
  })
  // 18 字节不是 24 字节姿态块的整数倍
  let partial = mock_of(Bytes::make(18, b'\x00'), @pose.BackendKind::Mock)
  @pose.PoseBackend::open(partial, config)
  let r3 = capture(() => {
    @pose.detect_multi(partial, white_image(20, 20), config, 1UL)
  })
  let bad_nms = config_nms(config_of(spec), spec, 1.5, 2)
  let ok = mock_of(raw_uniform(2, 0.5, 0.5, 1.0), @pose.BackendKind::Mock)
  @pose.PoseBackend::open(ok, bad_nms)
  let r4 = capture(() => {
    @pose.detect_multi(ok, white_image(20, 20), bad_nms, 1UL)
  })
  assert_eq(result_name(r1), "BudgetExceeded")
  assert_eq(result_name(r2), "OutputDecode")
  assert_eq(result_name(r3), "ShapeMismatch")
  match r3 {
    Err(@pose.PoseError::ShapeMismatch(expected, actual)) => {
      assert_eq(expected, 24)
      assert_eq(actual, 18)
    }
    _ => abort("expected ShapeMismatch")
  }
  assert_eq(result_name(r4), "InvalidConfig")
}

///|
/// 测试绑定共用的「可 raise」守卫：让声明了 error type 但不实际失败的辅助函数
/// 保留错误类型（避免 unused_error_type 警告），运行时恒不触发。
fn tflite_check(ok : Bool) -> Unit raise @pose.PoseError {
  if !ok {
    raise @pose.PoseError::BackendFailure("test", "injected")
  }
}

///|
/// 注入式 TFLite 绑定的 no-op open（不实际获取资源）。
fn tflite_open_ok(_config : @pose.PoseConfig) -> Unit raise @pose.PoseError {
  tflite_check(true)
}

///|
fn tflite_close_ok() -> Unit raise @pose.PoseError {
  tflite_check(true)
}

///|
/// 成功绑定：校验 detect 传入的预处理字节数，并返回 17 点固定输出。
fn tflite_infer_ok(input : Bytes) -> Bytes raise @pose.PoseError {
  if input.length() != 192 * 192 * 3 * 4 {
    raise @pose.PoseError::BackendFailure(
      "test-engine",
      "unexpected input length \{input.length()}",
    )
  }
  raw_uniform(17, 0.5, 0.5, 1.0)
}

///|
fn tflite_infer_fail(_input : Bytes) -> Bytes raise @pose.PoseError {
  raise @pose.PoseError::BackendFailure(
    "tflite-engine", "invoke failed: injected",
  )
}

///|
fn tflite_infer_short(_input : Bytes) -> Bytes raise @pose.PoseError {
  tflite_check(true)
  Bytes::make(7, b'\x00')
}

///|
fn tflite_binding_ok() -> @pose.TfliteBinding {
  {
    open_fn: tflite_open_ok,
    infer_fn: tflite_infer_ok,
    close_fn: tflite_close_ok,
  }
}

///|
fn tflite_binding_fail() -> @pose.TfliteBinding {
  {
    open_fn: tflite_open_ok,
    infer_fn: tflite_infer_fail,
    close_fn: tflite_close_ok,
  }
}

///|
fn tflite_binding_short() -> @pose.TfliteBinding {
  {
    open_fn: tflite_open_ok,
    infer_fn: tflite_infer_short,
    close_fn: tflite_close_ok,
  }
}

///|
test "TfliteAdapter: 注入 mock 绑定 → open/infer/detect 成功（kind=Tflite）" {
  let spec = movenet_spec()
  let config = config_of(spec)
  let adapter = @pose.TfliteAdapter::new(tflite_binding_ok(), spec)
  @pose.PoseBackend::open(adapter, config)
  assert_true(!adapter.used_fallback(), msg="primary binding must be used")
  let r = capture(() => {
    @pose.detect(adapter, white_image(200, 100), config, 4UL)
  })
  match r {
    Ok(res) => {
      assert_eq(res.landmarks.length(), 17)
      // letterbox: 模型输入 (96,96) → 源图 (100,50)
      assert_close(res.landmarks[0].x, 100.0)
      assert_close(res.landmarks[0].y, 50.0)
      assert_eq(res.frame_id, 4UL)
      assert_eq(kind_name(res.backend), "Tflite")
    }
    Err(e) => abort("unexpected error: " + err_name(e))
  }
  @pose.PoseBackend::close(adapter)
}

///|
test "TfliteAdapter: 输入字节数不匹配报 ShapeMismatch(expected, actual)" {
  let spec = movenet_spec()
  let adapter = @pose.TfliteAdapter::new(tflite_binding_ok(), spec)
  @pose.PoseBackend::open(adapter, config_of(spec))
  let r = capture(() => {
    @pose.PoseBackend::infer(adapter, Bytes::make(10, b'\x00'))
  })
  match r {
    Err(@pose.PoseError::ShapeMismatch(expected, actual)) => {
      assert_eq(expected, 192 * 192 * 3 * 4)
      assert_eq(actual, 10)
    }
    _ => abort("expected ShapeMismatch")
  }
}

///|
test "TfliteAdapter: 输出字节数不是姿态块整数倍报 ShapeMismatch(block, actual)" {
  let spec = movenet_spec()
  let adapter = @pose.TfliteAdapter::new(tflite_binding_short(), spec)
  @pose.PoseBackend::open(adapter, config_of(spec))
  let input = Bytes::make(192 * 192 * 3 * 4, b'\x00')
  let r = capture(() => @pose.PoseBackend::infer(adapter, input))
  match r {
    Err(@pose.PoseError::ShapeMismatch(expected, actual)) => {
      assert_eq(expected, 204)
      assert_eq(actual, 7)
    }
    _ => abort("expected ShapeMismatch")
  }
}

///|
test "TfliteAdapter: 绑定 invoke 失败原样传播 BackendFailure(kind, detail)" {
  let spec = movenet_spec()
  let config = config_of(spec)
  let adapter = @pose.TfliteAdapter::new(tflite_binding_fail(), spec)
  @pose.PoseBackend::open(adapter, config)
  let r = capture(() => {
    @pose.detect(adapter, white_image(200, 100), config, 1UL)
  })
  assert_eq(result_name(r), "BackendFailure")
  match r {
    Err(@pose.PoseError::BackendFailure(kind, detail)) => {
      assert_eq(kind, "tflite-engine")
      assert_eq(detail, "invoke failed: injected")
    }
    _ => abort("expected BackendFailure")
  }
}

///|
test "TfliteAdapter: 后端缺失回退（primary=None 用 fallback；两者皆缺报 BackendFailure）" {
  let spec = movenet_spec()
  let config = config_of(spec)
  let adapter = @pose.TfliteAdapter::with_fallback(
    None,
    Some(tflite_binding_ok()),
    spec,
  )
  @pose.PoseBackend::open(adapter, config)
  assert_true(adapter.used_fallback(), msg="fallback must be used")
  let r = capture(() => {
    @pose.detect(adapter, white_image(200, 100), config, 9UL)
  })
  match r {
    Ok(res) => {
      assert_eq(res.landmarks.length(), 17)
      assert_eq(kind_name(res.backend), "Tflite")
    }
    Err(e) => abort("unexpected error: " + err_name(e))
  }
  // 两者皆缺：open 报 BackendFailure（后端不可用，由上层决定降级）
  let missing = @pose.TfliteAdapter::unavailable(spec)
  let r2 = capture(() => @pose.PoseBackend::open(missing, config))
  assert_eq(result_name(r2), "BackendFailure")
  match r2 {
    Err(@pose.PoseError::BackendFailure(kind, _detail)) =>
      assert_eq(kind, "tflite")
    _ => abort("expected BackendFailure")
  }
}

///|
test "TfliteAdapter: 生命周期错误（未 open 调 infer / 重复 open / 重复 close）" {
  let spec = movenet_spec()
  let config = config_of(spec)
  let adapter = @pose.TfliteAdapter::new(tflite_binding_ok(), spec)
  let input = Bytes::make(192 * 192 * 3 * 4, b'\x00')
  let r1 = capture(() => @pose.PoseBackend::infer(adapter, input))
  @pose.PoseBackend::open(adapter, config)
  let r2 = capture(() => @pose.PoseBackend::open(adapter, config))
  @pose.PoseBackend::close(adapter)
  let r3 = capture(() => @pose.PoseBackend::close(adapter))
  let r4 = capture(() => @pose.PoseBackend::infer(adapter, input))
  assert_eq(result_name(r1), "BackendNotOpen")
  assert_eq(result_name(r2), "BackendFailure")
  assert_eq(result_name(r3), "BackendNotOpen")
  assert_eq(result_name(r4), "BackendNotOpen")
}

///|
test "TfliteAdapter: 畸形 ModelSpec 报 InvalidConfig（不 panic）" {
  let bad_spec = spec_of(
    192,
    192,
    3,
    @pose.TensorDtype::Float32,
    [0.0, 0.0, 0.0],
    [255.0, 255.0, 255.0],
    0,
  )
  let adapter = @pose.TfliteAdapter::new(tflite_binding_ok(), bad_spec)
  let r = capture(() => {
    @pose.PoseBackend::open(adapter, config_of(movenet_spec()))
  })
  assert_eq(result_name(r), "InvalidConfig")
}
