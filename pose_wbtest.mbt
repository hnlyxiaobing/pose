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
test "encode_value: UInt8 夹取 / Int8 补码 / Int32 小端 / Float16 显式拒绝" {
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
  let r = try {
    encode_value(buf, 0, 0.5, Float16)
    false
  } catch {
    UnsupportedModel(_) => true
    _ => false
  }
  assert_true(r, msg="Float16 must raise UnsupportedModel")
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
