// Whitebox tests run within the package scope.
// Use them to validate internal helpers or invariants.
// Keep them focused; public behavior belongs in `_test.mbt`.
//
// 本文件覆盖内部辅助逻辑：letterbox 缩放/填充参数、Float32 小端读写、量化编码。

///|
test "letterbox_plan: 宽度受限等比缩放与上下填充" {
  // 400×200 → 192×192：scale=192/400，scaled 192×96，pad_y=(192-96)/2=48
  let (scale, sw, sh, px, py) = letterbox_plan(400, 200, 192, 192)
  assert_true((scale - 192.0 / 400.0).abs() < 0.000000000001)
  assert_eq(sw, 192)
  assert_eq(sh, 96)
  assert_eq(px, 0)
  assert_eq(py, 48)
}

///|
test "letterbox_plan: 高度受限等比缩放与左右填充" {
  // 100×400 → 192×192：scaled 48×192，pad_x=(192-48)/2=72
  let (scale, sw, sh, px, py) = letterbox_plan(100, 400, 192, 192)
  assert_true((scale - 192.0 / 400.0).abs() < 0.000000000001)
  assert_eq(sw, 48)
  assert_eq(sh, 192)
  assert_eq(px, 72)
  assert_eq(py, 0)
}

///|
test "letterbox_plan: 正好放满时无填充" {
  let (scale, sw, sh, px, py) = letterbox_plan(64, 64, 32, 32)
  assert_true((scale - 0.5).abs() < 0.000000000001)
  assert_eq(sw, 32)
  assert_eq(sh, 32)
  assert_eq(px, 0)
  assert_eq(py, 0)
}

///|
test "f32 小端读写往返与位模式" {
  let buf = FixedArray::make(4, b'\x00')
  for v in [0.0, 1.0, -1.0, 0.5, -2.25, 255.0, 0.1] {
    write_f32_le(buf, 0, v)
    assert_true((read_f32_le(Bytes::from_array(buf), 0) - v).abs() < 0.000001)
  }
  write_f32_le(buf, 0, 0.5)
  // 0.5f32 = 0x3F000000，小端存储 00 00 00 3F
  assert_eq(buf[0].to_int(), 0x00)
  assert_eq(buf[1].to_int(), 0x00)
  assert_eq(buf[2].to_int(), 0x00)
  assert_eq(buf[3].to_int(), 0x3F)
}

///|
test "f32 小端已知位模式（0.0 / 1.0 / 255.0）" {
  let buf = FixedArray::make(4, b'\x00')
  write_f32_le(buf, 0, 0.0)
  assert_eq(read_f32_le(Bytes::from_array(buf), 0), 0.0)
  write_f32_le(buf, 0, 1.0)
  assert_eq(buf[2].to_int(), 0x80)
  assert_eq(buf[3].to_int(), 0x3F)
  write_f32_le(buf, 0, 255.0)
  assert_eq(buf[2].to_int(), 0x7F)
  assert_eq(buf[3].to_int(), 0x43)
}

///|
test "clamp_round_int: 四舍五入与夹取" {
  assert_eq(clamp_round_int(2.4, 0, 255), 2)
  assert_eq(clamp_round_int(2.6, 0, 255), 3)
  assert_eq(clamp_round_int(300.0, 0, 255), 255)
  assert_eq(clamp_round_int(-300.0, 0, 255), 0)
  assert_eq(clamp_round_int(-1.0, -128, 127), -1)
  assert_eq(clamp_round_int(1.0, -128, 127), 1)
}

///|
test "encode_value: UInt8 夹取 / Int8 补码 / Int32 小端 / Float16 小端编码" {
  let buf = FixedArray::make(8, b'\x00')
  encode_value(buf, 0, 300.0, UInt8)
  assert_eq(buf[0].to_int(), 255)
  encode_value(buf, 0, -5.0, UInt8)
  assert_eq(buf[0].to_int(), 0)
  encode_value(buf, 0, -1.0, Int8)
  assert_eq(buf[0].to_int(), 0xFF)
  encode_value(buf, 0, 1.0, Int32)
  assert_eq(buf[0].to_int(), 1)
  assert_eq(buf[1].to_int(), 0)
  assert_eq(buf[2].to_int(), 0)
  assert_eq(buf[3].to_int(), 0)
  // Float16 1.0 = 0x3C00，小端 00 3C
  encode_value(buf, 0, 1.0, Float16)
  assert_eq(buf[0].to_int(), 0x00)
  assert_eq(buf[1].to_int(), 0x3C)
}

///|
test "validate_spec_and_config: std 为 0 / 阈值越界 / pad_value 越界报 InvalidConfig" {
  fn make_config(
    std : Array[Double],
    pad_value : Int32,
    nms_threshold : Double,
  ) -> PoseConfig {
    let spec : ModelSpec = {
      input_width: 8,
      input_height: 8,
      input_channels: 3,
      input_dtype: Float32,
      mean: [0.0, 0.0, 0.0],
      std,
      landmark_count: 3,
      output_tensor_index: 0,
    }
    {
      model: spec,
      keep_aspect_ratio: true,
      pad_value,
      score_threshold: 0.5,
      nms_threshold,
      max_poses: 1,
      mirror_x: false,
    }
  }
  let config1 = make_config([0.0, 1.0, 1.0], 0, 0.5)
  let r1 = try {
    validate_spec_and_config(config1.model, config1)
    false
  } catch {
    InvalidConfig(_) => true
    _ => false
  }
  assert_true(r1, msg="zero std must raise InvalidConfig")
  let config2 = make_config([1.0, 1.0, 1.0], 300, 0.5)
  let r2 = try {
    validate_spec_and_config(config2.model, config2)
    false
  } catch {
    InvalidConfig(_) => true
    _ => false
  }
  assert_true(r2, msg="pad_value out of range must raise InvalidConfig")
  let config3 = make_config([1.0, 1.0, 1.0], 0, -0.1)
  let r3 = try {
    validate_spec_and_config(config3.model, config3)
    false
  } catch {
    InvalidConfig(_) => true
    _ => false
  }
  assert_true(r3, msg="nms_threshold out of range must raise InvalidConfig")
}

///|
/// f32 → f16 位模式助手（白盒：直接测内部转换函数）。
fn f16_bits_of(v : Double) -> Int32 {
  f32_to_f16_bits(Float::from_double(v))
}

///|
test "f32→f16: 正规数已知位模式（±0 / ±1 / 0.5 / 2 / 1024 / 65504）" {
  assert_eq(f16_bits_of(0.0), 0x0000)
  assert_eq(f16_bits_of(-0.0), 0x8000)
  assert_eq(f16_bits_of(1.0), 0x3C00)
  assert_eq(f16_bits_of(-1.0), 0xBC00)
  assert_eq(f16_bits_of(0.5), 0x3800)
  assert_eq(f16_bits_of(2.0), 0x4000)
  assert_eq(f16_bits_of(1024.0), 0x6400)
  assert_eq(f16_bits_of(65504.0), 0x7BFF)
  assert_eq(f16_bits_of(0.0999755859375), 0x2E66)
  assert_eq(f16_bits_of(1.0 / 3.0), 0x3555)
}

///|
test "f32→f16: NaN 折叠为 0x7E00、±Inf 保号、溢出饱和" {
  let nan = Float::reinterpret_from_int(0x7FC00000).to_double()
  let neg_nan = Float::reinterpret_from_int(0xFFC00000).to_double()
  let inf = Float::reinterpret_from_int(0x7F800000).to_double()
  let neg_inf = Float::reinterpret_from_int(0xFF800000).to_double()
  assert_eq(f16_bits_of(nan), 0x7E00)
  assert_eq(f16_bits_of(neg_nan), 0x7E00)
  assert_eq(f16_bits_of(inf), 0x7C00)
  assert_eq(f16_bits_of(neg_inf), 0xFC00)
  assert_eq(f16_bits_of(70000.0), 0x7C00)
  assert_eq(f16_bits_of(-70000.0), 0xFC00)
  assert_eq(f16_bits_of(1.0e9), 0x7C00)
  // 65520 恰在 65504 与 2^16 之间：尾数全 1 为奇数 → RNE 进位到 Inf
  assert_eq(f16_bits_of(65520.0), 0x7C00)
}

///|
test "f32→f16: 次正规数边界（2^-24 / 2^-23 / 2^-15 / 2^-14）" {
  assert_eq(f16_bits_of(0.00000005960464477539063), 0x0001) // 2^-24
  assert_eq(f16_bits_of(0.00000011920928955078125), 0x0002) // 2^-23
  assert_eq(f16_bits_of(-0.00000005960464477539063), 0x8001) // -2^-24
  assert_eq(f16_bits_of(0.000030517578125), 0x0200) // 2^-15
  assert_eq(f16_bits_of(0.00006103515625), 0x0400) // 2^-14 → 最小正规数
}

///|
test "f32→f16: 下溢为带符号零（2^-25 平局取偶）" {
  // 2^-25 是最小次正规数的一半：平局取偶 → +0 / -0
  assert_eq(f16_bits_of(0.000000029802322387695313), 0x0000)
  assert_eq(f16_bits_of(-0.000000029802322387695313), 0x8000)
  // 略大于 2^-25 → 最小次正规数
  assert_eq(f16_bits_of(0.00000003), 0x0001)
  // 3×2^-25 = 1.5 个次正规 ulp：平局取偶 → 0x0002
  assert_eq(f16_bits_of(0.00000008940696716308594), 0x0002)
  // 远小于半 ulp 与 f32 次正规数 → 0
  assert_eq(f16_bits_of(1.0e-8), 0x0000)
  assert_eq(f16_bits_of(Float::reinterpret_from_int(1).to_double()), 0x0000)
}

///|
test "f32→f16: round-to-nearest-ties-to-even 边界" {
  // 1 + 2^-10 精确可表示
  assert_eq(f16_bits_of(1.0009765625), 0x3C01)
  // 1 + 2^-11 恰为 0x3C00 与 0x3C01 的中点：取偶 → 0x3C00
  assert_eq(f16_bits_of(1.00048828125), 0x3C00)
  // 1 + 3×2^-11 恰为 0x3C01 与 0x3C02 的中点：取偶 → 0x3C02
  assert_eq(f16_bits_of(1.00146484375), 0x3C02)
  // 1 + 5×2^-11 恰为 0x3C02 与 0x3C03 的中点：取偶 → 0x3C02
  assert_eq(f16_bits_of(1.00244140625), 0x3C02)
}

///|
/// 浮点近似断言（白盒测试包内本地定义；黑盒包的同名助手不可见）。
fn assert_close(actual : Double, expected : Double) -> Unit {
  if (actual - expected).abs() > 0.000001 {
    abort("expected \{expected}, got \{actual}")
  }
}

///|
/// 用两点构造覆盖指定 bbox 的候选（两点 visibility 相同 ⇒ score 即该值）。
fn nms_candidate(
  score : Double,
  x1 : Double,
  y1 : Double,
  x2 : Double,
  y2 : Double,
) -> PoseCandidate {
  let a : Landmark = { x: x1, y: y1, z: 0.0, visibility: score, name: None, }
  let b : Landmark = { x: x2, y: y2, z: 0.0, visibility: score, name: None, }
  PoseCandidate::new([a, b])
}

///|
/// nms 是否以 InvalidConfig 拒绝该参数组合。
fn nms_rejects(
  candidates : Array[PoseCandidate],
  iou_threshold : Double,
  max_poses : Int32,
) -> Bool {
  try {
    let _ = nms(candidates, iou_threshold, max_poses)
    false
  } catch {
    InvalidConfig(_) => true
    _ => false
  }
}

///|
test "BoundingBox: area / IoU（相离 / 相接 / 嵌套 / 相同 / 退化）" {
  let a : BoundingBox = { x1: 0.0, y1: 0.0, x2: 10.0, y2: 10.0, }
  let b : BoundingBox = { x1: 0.0, y1: 0.0, x2: 10.0, y2: 5.0, }
  let c : BoundingBox = { x1: 20.0, y1: 20.0, x2: 30.0, y2: 30.0, }
  let touch : BoundingBox = { x1: 10.0, y1: 0.0, x2: 20.0, y2: 10.0, }
  let nested : BoundingBox = { x1: 0.0, y1: 0.0, x2: 5.0, y2: 5.0, }
  let degenerate : BoundingBox = { x1: 1.0, y1: 1.0, x2: 1.0, y2: 1.0, }
  assert_eq(a.area(), 100.0)
  assert_eq(b.area(), 50.0)
  assert_eq(degenerate.area(), 0.0)
  // 交集 50、并集 100 ⇒ 0.5
  assert_eq(a.iou(b), 0.5)
  // 相离 / 仅边界相接（交集面积为 0）⇒ 0
  assert_eq(a.iou(c), 0.0)
  assert_eq(a.iou(touch), 0.0)
  // 嵌套：25 / 100 = 0.25；自身 = 1.0
  assert_eq(a.iou(nested), 0.25)
  assert_eq(a.iou(a), 1.0)
  // 退化盒：面积为 0，IoU 记为 0（避免除零）
  assert_eq(a.iou(degenerate), 0.0)
  assert_eq(degenerate.iou(degenerate), 0.0)
}

///|
test "PoseCandidate::new: score 均值 / bbox 包围 / 空输入零盒" {
  let empty : Array[Landmark] = []
  let e = PoseCandidate::new(empty)
  assert_eq(e.score, 0.0)
  assert_eq(e.landmarks.length(), 0)
  assert_eq(e.bbox.x1, 0.0)
  assert_eq(e.bbox.y1, 0.0)
  assert_eq(e.bbox.x2, 0.0)
  assert_eq(e.bbox.y2, 0.0)
  let l1 : Landmark = { x: 2.0, y: 3.0, z: 0.0, visibility: 0.2, name: None, }
  let l2 : Landmark = { x: 8.0, y: 9.0, z: 0.0, visibility: 0.6, name: None, }
  let c = PoseCandidate::new([l1, l2])
  assert_close(c.score, 0.4)
  assert_eq(c.bbox.x1, 2.0)
  assert_eq(c.bbox.y1, 3.0)
  assert_eq(c.bbox.x2, 8.0)
  assert_eq(c.bbox.y2, 9.0)
  assert_eq(c.landmarks.length(), 2)
}

///|
test "nms: 空输入返回空数组（不报错）" {
  let empty : Array[PoseCandidate] = []
  let kept = nms(empty, 0.5, 2)
  assert_eq(kept.length(), 0)
}

///|
test "nms: 全重叠只保留最高分（贪心排序）" {
  let cands = [
    nms_candidate(0.7, 20.0, 20.0, 30.0, 30.0),
    nms_candidate(0.8, 0.0, 0.0, 10.0, 10.0),
    nms_candidate(0.9, 0.0, 0.0, 10.0, 10.0),
  ]
  let kept = nms(cands, 0.5, 5)
  assert_eq(kept.length(), 2)
  assert_close(kept[0].score, 0.9)
  assert_close(kept[1].score, 0.7)
  // 纯函数：输入数组顺序未被修改
  assert_close(cands[0].score, 0.7)
  assert_close(cands[1].score, 0.8)
}

///|
test "nms: 阈值边界 IoU == threshold 不抑制（严格大于才抑制）" {
  // a bbox 100，b bbox 50，IoU = 0.5
  let cands = [
    nms_candidate(0.9, 0.0, 0.0, 10.0, 10.0),
    nms_candidate(0.8, 0.0, 0.0, 10.0, 5.0),
  ]
  assert_eq(nms(cands, 0.5, 2).length(), 2)
  assert_eq(nms(cands, 0.499, 2).length(), 1)
  assert_eq(nms(cands, 0.0, 2).length(), 1)
  assert_close(nms(cands, 0.499, 2)[0].score, 0.9)
}

///|
test "nms: threshold=1.0 不抑制任何候选（IoU 上界为 1.0）" {
  let cands = [
    nms_candidate(0.9, 0.0, 0.0, 10.0, 10.0),
    nms_candidate(0.8, 0.0, 0.0, 10.0, 5.0),
    nms_candidate(0.7, 0.0, 0.0, 10.0, 10.0),
  ]
  let kept = nms(cands, 1.0, 5)
  assert_eq(kept.length(), 3)
}

///|
test "nms: max_poses 截断与同分稳定顺序" {
  let cands = [
    nms_candidate(0.5, 0.0, 0.0, 5.0, 5.0),
    nms_candidate(0.5, 10.0, 10.0, 15.0, 15.0),
    nms_candidate(0.5, 20.0, 20.0, 25.0, 25.0),
  ]
  let all = nms(cands, 0.5, 5)
  assert_eq(all.length(), 3)
  // 同分保持输入顺序
  assert_eq(all[0].bbox.x1, 0.0)
  assert_eq(all[1].bbox.x1, 10.0)
  assert_eq(all[2].bbox.x1, 20.0)
  let capped = nms(cands, 0.5, 2)
  assert_eq(capped.length(), 2)
  assert_eq(capped[0].bbox.x1, 0.0)
  assert_eq(capped[1].bbox.x1, 10.0)
  // 退化 bbox（两点重合）IoU 为 0，不应误抑制
  let deg = [
    nms_candidate(0.6, 1.0, 1.0, 1.0, 1.0),
    nms_candidate(0.5, 1.0, 1.0, 1.0, 1.0),
  ]
  assert_eq(nms(deg, 0.0, 5).length(), 2)
}

///|
test "nms: 非法阈值 / 非法 max_poses 报 InvalidConfig" {
  let cands = [nms_candidate(0.9, 0.0, 0.0, 10.0, 10.0)]
  let nan = Float::reinterpret_from_int(0x7FC00000).to_double()
  let inf = Float::reinterpret_from_int(0x7F800000).to_double()
  assert_true(nms_rejects(cands, nan, 2), msg="NaN threshold must be rejected")
  assert_true(
    nms_rejects(cands, -0.1, 2),
    msg="negative threshold must be rejected",
  )
  assert_true(nms_rejects(cands, 1.1, 2), msg="threshold > 1 must be rejected")
  assert_true(
    nms_rejects(cands, inf, 2),
    msg="infinite threshold must be rejected",
  )
  assert_true(nms_rejects(cands, 0.5, 0), msg="max_poses=0 must be rejected")
  assert_true(
    nms_rejects(cands, 0.5, -1),
    msg="negative max_poses must be rejected",
  )
}
