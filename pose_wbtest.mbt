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
