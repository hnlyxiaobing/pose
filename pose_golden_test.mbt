// W2 / L2 受控黄金差分（golden corpus）。
//
// 全部语料由确定性字节 builder 自产（非第三方模型、零文件 fixture，延续 B7），
// 由 `tests/golden/README.md` 登记；本文件逐条断言这些 golden 值，因此 golden 是
// 「被测试真实读取」的资产而非死资产（T-W2-1）。
//
// 双目标：同一 builder 在 wasm / native 各跑一次（由 `tools/verify.sh` 串起），
// 值输出逐字节 diff = 0（T-W2-4）；本文件的断言对两目标一致。

///|
/// 2×2 RGB 源图（12 字节），逐通道可区分：R 按行主序 10/20/30/40 递增，G=+1，B=+2。
fn golden_src_2x2() -> Bytes {
  Bytes::from_array([
    b'\x0a', b'\x0b', b'\x0c', b'\x14', b'\x15', b'\x16', b'\x1e', b'\x1f', b'\x20',
    b'\x28', b'\x29', b'\x2a',
  ])
}

///|
/// 2×2 RGB 源图对应的 RgbImage（timestamp 固定值，便于 detect golden）。
fn golden_image_2x2() -> @pose.RgbImage {
  {
    width: 2,
    height: 2,
    layout: @pose.RgbLayout::Rgb,
    data: golden_src_2x2(),
    timestamp_ns: 123456UL,
  }
}

///|
/// 逐字节相等（Bytes 无内建 `==`）。
fn golden_bytes_equal(a : Bytes, b : Bytes) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i in 0..<a.length() {
    if a[i].to_int() != b[i].to_int() {
      return false
    }
  }
  true
}

///|
/// 2×2 → 4×4 letterbox（scale=2，无填充）在 5 种 dtype 下的输入字节与 Transform
/// 全字段 golden。断言各 dtype 元素大小、总字节数与左上像素 R 通道编码。
test "golden: letterbox 4×4 五 dtype 输入字节 + Transform 全字段（L2）" {
  let cases : Array[(@pose.TensorDtype, Int32, Int32, Array[Int32])] = [
    (@pose.TensorDtype::Float32, 4, 0x20, [0x00, 0x00, 0x20, 0x41]),
    (@pose.TensorDtype::Float16, 2, 0x49, [0x00, 0x49]),
    (@pose.TensorDtype::UInt8, 1, 0x0A, [0x0A]),
    (@pose.TensorDtype::Int8, 1, 0x0A, [0x0A]),
    (@pose.TensorDtype::Int32, 4, 0x00, [0x0A, 0x00, 0x00, 0x00]),
  ]
  for c in cases {
    let dtype = c.0
    let elem = c.1
    let expect = c.3
    let spec = spec_of(4, 4, 3, dtype, [0.0, 0.0, 0.0], [1.0, 1.0, 1.0], 17)
    let config = config_with(config_of(spec), spec, true, 0, 0.0, 1, false)
    let r = capture(() => @pose.letterbox(golden_image_2x2(), config))
    match r {
      Ok((bytes, t)) => {
        // 总字节数 = tw*th*3*elem
        assert_eq(bytes.length(), 4 * 4 * 3 * elem)
        // Transform 全字段
        assert_close(t.scale, 2.0)
        assert_eq(t.pad_x, 0)
        assert_eq(t.pad_y, 0)
        assert_eq(t.source_width, 2)
        assert_eq(t.source_height, 2)
        assert_true(!t.mirrored)
        // 左上像素 R 通道（源 (0,0).R = 10）按 dtype 精确编码
        for k in 0..<expect.length() {
          assert_eq(bytes[k].to_int(), expect[k])
        }
      }
      Err(e) => abort("unexpected error: " + err_name(e))
    }
  }
}

///|
/// 2×2 → 4×6 letterbox（scale=2，pad_y=1，pad_value=7）的填充区与采样区 golden。
/// 覆盖「第二组尺寸」与填充/贴边像素。
test "golden: letterbox 4×6 填充带与采样区字节（L2）" {
  let spec = spec_of(
    4,
    6,
    3,
    @pose.TensorDtype::UInt8,
    [0.0, 0.0, 0.0],
    [1.0, 1.0, 1.0],
    17,
  )
  let config = config_with(config_of(spec), spec, true, 7, 0.0, 1, false)
  let r = capture(() => @pose.letterbox(golden_image_2x2(), config))
  match r {
    Ok((bytes, t)) => {
      assert_eq(bytes.length(), 4 * 6 * 3)
      assert_close(t.scale, 2.0)
      assert_eq(t.pad_x, 0)
      assert_eq(t.pad_y, 1)
      assert_eq(t.source_width, 2)
      assert_eq(t.source_height, 2)
      assert_true(!t.mirrored)
      // 第 0 行为填充（4 像素 × 3 通道 = 12 字节，全 7）
      for i in 0..<12 {
        assert_eq(bytes[i].to_int(), 7)
      }
      // 第 1 行（偏移 12） = 源第 0 行：tx 0,1 取源列 0（10,11,12），tx 2,3 取源列 1（20,21,22）
      let o = 12
      assert_eq(bytes[o + 0].to_int(), 10)
      assert_eq(bytes[o + 1].to_int(), 11)
      assert_eq(bytes[o + 2].to_int(), 12)
      assert_eq(bytes[o + 9].to_int(), 20)
      assert_eq(bytes[o + 10].to_int(), 21)
      assert_eq(bytes[o + 11].to_int(), 22)
      // 第 3 行（偏移 36） = 源第 1 行：tx 0 取源列 0（30,31,32）
      let o3 = 36
      assert_eq(bytes[o3 + 0].to_int(), 30)
      assert_eq(bytes[o3 + 1].to_int(), 31)
      assert_eq(bytes[o3 + 2].to_int(), 32)
      // 第 5 行为填充（偏移 60）：首字节 7
      assert_eq(bytes[60].to_int(), 7)
    }
    Err(e) => abort("unexpected error: " + err_name(e))
  }
}

///|
/// mirror_x 水平翻转 golden：2×2 → 4×4 采样列翻转（x'=w-1-x），Transform.mirrored=true。
test "golden: letterbox mirror_x 采样翻转字节（L2）" {
  let spec = spec_of(
    4,
    4,
    3,
    @pose.TensorDtype::UInt8,
    [0.0, 0.0, 0.0],
    [1.0, 1.0, 1.0],
    17,
  )
  let config = config_with(config_of(spec), spec, true, 0, 0.0, 1, true)
  let r = capture(() => @pose.letterbox(golden_image_2x2(), config))
  match r {
    Ok((bytes, t)) => {
      assert_eq(bytes.length(), 4 * 4 * 3)
      assert_close(t.scale, 2.0)
      assert_true(t.mirrored)
      // 未镜像时 tx=0 取源列 0（10,11,12）；镜像后 tx=0 取源列 1（20,21,22）
      assert_eq(bytes[0].to_int(), 20)
      assert_eq(bytes[1].to_int(), 21)
      assert_eq(bytes[2].to_int(), 22)
      // tx=2 未镜像取源列 1；镜像后取源列 0（10,11,12）
      let o = 2 * 3
      assert_eq(bytes[o + 0].to_int(), 10)
      assert_eq(bytes[o + 1].to_int(), 11)
      assert_eq(bytes[o + 2].to_int(), 12)
    }
    Err(e) => abort("unexpected error: " + err_name(e))
  }
}

///|
/// decode_output 17 点边界 golden：x_norm=0.5、y_norm=0.25、score=0.9 于 192×192 模型，
/// 解出 x=96、y=48、visibility=0.9、z=0、name=None。
test "golden: decode_output 17 点边界逐字段（L2）" {
  let spec = spec_of(
    192,
    192,
    3,
    @pose.TensorDtype::Float32,
    [0.0, 0.0, 0.0],
    [255.0, 255.0, 255.0],
    17,
  )
  let config = config_of(spec)
  let raw = raw_uniform(17, 0.25, 0.5, 0.9)
  let r = capture(() => @pose.decode_output(raw, spec, config))
  match r {
    Ok(landmarks) => {
      assert_eq(landmarks.length(), 17)
      for l in landmarks {
        assert_close(l.x, 96.0)
        assert_close(l.y, 48.0)
        assert_close(l.visibility, 0.9)
        assert_eq(l.z, 0.0)
        assert_true(l.name is None)
      }
    }
    Err(e) => abort("unexpected error: " + err_name(e))
  }
}

///|
/// decode_output 33 点边界 golden：x_norm=0.25、y_norm=0.5、score=0.75 于 256×256 模型，
/// 解出 x=64、y=128、visibility=0.75；验证 33 点布局由 landmark_count 配置化解析。
test "golden: decode_output 33 点边界逐字段（L2）" {
  let spec = spec_of(
    256,
    256,
    3,
    @pose.TensorDtype::Float32,
    [0.0, 0.0, 0.0],
    [255.0, 255.0, 255.0],
    33,
  )
  let config = config_of(spec)
  let raw = raw_uniform(33, 0.5, 0.25, 0.75)
  let r = capture(() => @pose.decode_output(raw, spec, config))
  match r {
    Ok(landmarks) => {
      assert_eq(landmarks.length(), 33)
      for l in landmarks {
        assert_close(l.x, 64.0)
        assert_close(l.y, 128.0)
        assert_close(l.visibility, 0.75)
      }
    }
    Err(e) => abort("unexpected error: " + err_name(e))
  }
}

///|
/// detect 端到端逐字段 golden：8×8 图像 → 192×192 模型，模型坐标 (96,96) 经 letterbox
/// 逆变换（scale=24、无填充）还原为原图 (4,4)；frame_id/timestamp/backend 标注精确。
test "golden: detect 端到端逐字段（frame_id/timestamp/backend）（L2）" {
  let spec = movenet_spec()
  let config = config_of(spec)
  let image = white_image(8, 8)
  let raw = raw_uniform(17, 0.5, 0.5, 0.9)
  let backend = mock_of(raw, @pose.BackendKind::Mock)
  @pose.PoseBackend::open(backend, config)
  let r = capture(() => @pose.detect(backend, image, config, 7UL))
  match r {
    Ok(result) => {
      assert_eq(result.landmarks.length(), 17)
      for l in result.landmarks {
        assert_close(l.x, 4.0)
        assert_close(l.y, 4.0)
        assert_close(l.visibility, 0.9)
      }
      assert_close(result.score, 0.9)
      assert_eq(result.frame_id, 7UL)
      assert_eq(result.timestamp_ns, 123456UL)
      assert_true(result.backend is @pose.BackendKind::Mock)
    }
    Err(e) => abort("unexpected error: " + err_name(e))
  }
}

///|
/// P1 幂等律 golden：同一输入两次调用 letterbox / nms / detect，输出逐字节相等。
test "golden: P1 幂等律（双次调用逐字节相等）（L2）" {
  let spec = movenet_spec()
  let config = config_of(spec)
  let image = white_image(8, 8)
  // letterbox 双次
  let (b1, t1) = @pose.letterbox(image, config)
  let (b2, t2) = @pose.letterbox(image, config)
  assert_true(golden_bytes_equal(b1, b2))
  assert_close(t1.scale, t2.scale)
  assert_eq(t1.pad_x, t2.pad_x)
  // nms 双次
  let cands : Array[@pose.PoseCandidate] = []
  for i in 0..<3 {
    let lm : @pose.Landmark = {
      x: i.to_double(),
      y: i.to_double(),
      z: 0.0,
      visibility: 0.5,
      name: None,
    }
    cands.push(@pose.PoseCandidate::new([lm, lm]))
  }
  let n1 = @pose.nms(cands, 0.5, 3)
  let n2 = @pose.nms(cands, 0.5, 3)
  assert_eq(n1.length(), n2.length())
  for i in 0..<n1.length() {
    assert_eq(n1[i].score, n2[i].score)
    assert_eq(n1[i].bbox.x1, n2[i].bbox.x1)
  }
  // detect 双次
  let raw = raw_uniform(17, 0.5, 0.5, 0.9)
  let backend = mock_of(raw, @pose.BackendKind::Mock)
  @pose.PoseBackend::open(backend, config)
  let d1 = @pose.detect(backend, image, config, 1UL)
  let d2 = @pose.detect(backend, image, config, 1UL)
  assert_eq(d1.landmarks.length(), d2.landmarks.length())
  for i in 0..<d1.landmarks.length() {
    assert_eq(d1.landmarks[i].x, d2.landmarks[i].x)
    assert_eq(d1.landmarks[i].y, d2.landmarks[i].y)
    assert_eq(d1.landmarks[i].visibility, d2.landmarks[i].visibility)
  }
  assert_eq(d1.score, d2.score)
}

///|
/// P4 后端注入律 golden：Mock 与 Alt 后端输出同一 raw 时，除 `backend` 标注外
/// `PoseResult` 逐字段相等。
test "golden: P4 后端注入等价（Mock vs Alt 仅 backend 不同）（L2）" {
  let spec = movenet_spec()
  let config = config_of(spec)
  let image = white_image(8, 8)
  let raw = raw_uniform(17, 0.5, 0.5, 0.9)
  let mock = mock_of(raw, @pose.BackendKind::Mock)
  let alt : AltBackend = { output: raw, }
  @pose.PoseBackend::open(mock, config)
  @pose.PoseBackend::open(alt, config)
  let rm = @pose.detect(mock, image, config, 3UL)
  let ra = @pose.detect(alt, image, config, 3UL)
  assert_eq(rm.landmarks.length(), ra.landmarks.length())
  for i in 0..<rm.landmarks.length() {
    assert_eq(rm.landmarks[i].x, ra.landmarks[i].x)
    assert_eq(rm.landmarks[i].y, ra.landmarks[i].y)
    assert_eq(rm.landmarks[i].visibility, ra.landmarks[i].visibility)
  }
  assert_eq(rm.score, ra.score)
  assert_eq(rm.frame_id, ra.frame_id)
  assert_eq(rm.timestamp_ns, ra.timestamp_ns)
  // 仅 backend 标注不同
  assert_true(rm.backend is @pose.BackendKind::Mock)
  assert_true(ra.backend is @pose.BackendKind::Custom("alt-adapter"))
}
