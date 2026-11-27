// W4 验收：ROI 前处理与新布局防火墙（T-W4-1..5）。
//
// ROI 为纯加法新入口（`RoiRect`/`RoiTransform`/`letterbox_roi`/`detect_roi`/
// `PoseResult::restore_roi`）；旧 `detect`/`letterbox` 语义不变（防火墙）。

///|
/// w×h RGB 灰度图：像素 (x,y) 三通道均取 `10*y + x`（便于精确断言采样位置）。
fn roi_gray_image(w : Int32, h : Int32) -> @pose.RgbImage {
  let arr : Array[Byte] = []
  for y in 0..<h {
    for x in 0..<w {
      let v = (10 * y + x).to_byte()
      arr.push(v)
      arr.push(v)
      arr.push(v)
    }
  }
  {
    width: w,
    height: h,
    layout: @pose.RgbLayout::Rgb,
    data: Bytes::from_array(arr),
    timestamp_ns: 777UL,
  }
}

///|
/// 断言两个 PoseResult 除 backend 外逐字段相等（ROI 与全图对比用）。
fn roi_assert_pose_same(
  label : String,
  a : @pose.PoseResult,
  b : @pose.PoseResult,
) -> Unit {
  if a.landmarks.length() != b.landmarks.length() {
    abort(label + ": landmark 数不一致")
  }
  for i in 0..<a.landmarks.length() {
    if a.landmarks[i].x != b.landmarks[i].x ||
      a.landmarks[i].y != b.landmarks[i].y ||
      a.landmarks[i].visibility != b.landmarks[i].visibility {
      abort(label + ": landmark " + i.to_string() + " 不一致")
    }
  }
  if a.score != b.score {
    abort(label + ": score 不一致")
  }
  if a.frame_id != b.frame_id {
    abort(label + ": frame_id 不一致")
  }
  if a.timestamp_ns != b.timestamp_ns {
    abort(label + ": timestamp_ns 不一致")
  }
}

///|
/// T-W4-1：ROI 边界（零尺寸 / 负原点 / 越界）均 `InvalidInput`，不 panic。
test "ROI: 边界非法报 InvalidInput(x, y)（T-W4-1）" {
  let image = roi_gray_image(4, 4)
  let spec = spec_of(
    4,
    4,
    3,
    @pose.TensorDtype::UInt8,
    [0.0, 0.0, 0.0],
    [1.0, 1.0, 1.0],
    3,
  )
  let config = config_of(spec)
  let bad_rois : Array[@pose.RoiRect] = [
    { x: 0, y: 0, width: 0, height: 2, },
    { x: 0, y: 0, width: 2, height: 0, },
    { x: -1, y: 0, width: 2, height: 2, },
    { x: 0, y: -1, width: 2, height: 2, },
    { x: 3, y: 0, width: 2, height: 2, },
    { x: 0, y: 3, width: 2, height: 2, },
    { x: 5, y: 5, width: 1, height: 1, },
  ]
  for roi in bad_rois {
    let r = capture(() => @pose.letterbox_roi(image, config, roi))
    assert_true(
      result_name(r) == "InvalidInput",
      msg="ROI 非法必须 InvalidInput",
    )
  }
}

///|
/// T-W4-1 补：ROI 贴边（恰好在边界内）合法，可正常前处理。
test "ROI: 贴边合法（右下角恰为边界）可前处理（T-W4-1）" {
  let image = roi_gray_image(4, 4)
  let spec = spec_of(
    2,
    2,
    3,
    @pose.TensorDtype::UInt8,
    [0.0, 0.0, 0.0],
    [1.0, 1.0, 1.0],
    3,
  )
  let config = config_of(spec)
  let r = capture(() => {
    @pose.letterbox_roi(image, config, { x: 2, y: 2, width: 2, height: 2, })
  })
  match r {
    Ok((bytes, t)) => {
      assert_eq(bytes.length(), 2 * 2 * 3)
      assert_eq(t.roi_x, 2)
      assert_eq(t.roi_y, 2)
      assert_eq(t.roi_width, 2)
      assert_eq(t.roi_height, 2)
      assert_eq(t.source_width, 4)
      assert_eq(t.source_height, 4)
      // 裁出 (2,2)/(3,2)/(2,3)/(3,3) = 22/23/32/33；2×2 目标 scale=1 → 逐像素对应
      assert_eq(bytes[0].to_int(), 22)
      assert_eq(bytes[3].to_int(), 23)
      assert_eq(bytes[6].to_int(), 32)
      assert_eq(bytes[9].to_int(), 33)
    }
    Err(e) => abort("unexpected error: " + err_name(e))
  }
}

///|
/// letterbox_roi 黄金：4×4 源图 ROI=(1,1,2,2) → 2×2 裁剪 → 4×4 模型（scale=2），
/// 断言采样字节与 RoiTransform 全字段。
test "ROI: letterbox_roi 裁剪 + 缩放字节与 RoiTransform 全字段（W4）" {
  let image = roi_gray_image(4, 4)
  let spec = spec_of(
    4,
    4,
    3,
    @pose.TensorDtype::UInt8,
    [0.0, 0.0, 0.0],
    [1.0, 1.0, 1.0],
    3,
  )
  let config = config_of(spec)
  let roi : @pose.RoiRect = { x: 1, y: 1, width: 2, height: 2, }
  let r = capture(() => @pose.letterbox_roi(image, config, roi))
  match r {
    Ok((bytes, t)) => {
      assert_eq(bytes.length(), 4 * 4 * 3)
      // RoiTransform 全字段
      assert_close(t.scale_x, 2.0)
      assert_close(t.scale_y, 2.0)
      assert_eq(t.offset_x, 0)
      assert_eq(t.offset_y, 0)
      assert_eq(t.roi_x, 1)
      assert_eq(t.roi_y, 1)
      assert_eq(t.roi_width, 2)
      assert_eq(t.roi_height, 2)
      assert_eq(t.source_width, 4)
      assert_eq(t.source_height, 4)
      assert_true(!t.mirrored)
      // 裁剪后为 src(1,1)=11, src(2,1)=12, src(1,2)=21, src(2,2)=22
      // 4×4 输出采样 (ty/2, tx/2)：rows0,1 = [11,11,12,12]，rows2,3 = [21,21,22,22]
      assert_eq(bytes[0].to_int(), 11)
      assert_eq(bytes[9].to_int(), 12)
      assert_eq(bytes[24].to_int(), 21)
      assert_eq(bytes[33].to_int(), 22)
    }
    Err(e) => abort("unexpected error: " + err_name(e))
  }
}

///|
/// T-W4-2 变形律：ROI = 整图时 `detect_roi ≡ detect`（等比模式），逐字段相等。
test "ROI: ROI=整图 ≡ detect（等比模式，T-W4-2）" {
  let spec = movenet_spec()
  let config = config_of(spec)
  let image = white_image(8, 8)
  let raw = raw_uniform(17, 0.5, 0.5, 0.9)
  let full : @pose.RoiRect = { x: 0, y: 0, width: 8, height: 8, }
  let b1 = mock_of(raw, @pose.BackendKind::Mock)
  let b2 = mock_of(raw, @pose.BackendKind::Mock)
  @pose.PoseBackend::open(b1, config)
  @pose.PoseBackend::open(b2, config)
  let d = @pose.detect(b1, image, config, 11UL)
  let dr = @pose.detect_roi(b2, image, config, full, 11UL)
  roi_assert_pose_same("ROI=整图", dr, d)
}

///|
/// T-W4-2 变形律（stretch 模式）：ROI = 整图时 `detect_roi ≡ detect`。
test "ROI: ROI=整图 ≡ detect（stretch 模式，T-W4-2）" {
  let spec = movenet_spec()
  let config = config_with(config_of(spec), spec, false, 0, 0.0, 1, false)
  let image = white_image(8, 6)
  let raw = raw_uniform(17, 0.5, 0.5, 0.8)
  let full : @pose.RoiRect = { x: 0, y: 0, width: 8, height: 6, }
  let b1 = mock_of(raw, @pose.BackendKind::Mock)
  let b2 = mock_of(raw, @pose.BackendKind::Mock)
  @pose.PoseBackend::open(b1, config)
  @pose.PoseBackend::open(b2, config)
  let d = @pose.detect(b1, image, config, 12UL)
  let dr = @pose.detect_roi(b2, image, config, full, 12UL)
  roi_assert_pose_same("ROI=整图 stretch", dr, d)
}

///|
/// T-W4-5：镜像 + ROI 组合坐标还原。ROI 内镜像以 ROI 宽为基准，最后平移到整图坐标。
/// 4×1 源图 ROI=(1,0,2,1)、mirror_x=true、模型输入 2×1：模型 x=0 应对应源 x=2。
test "ROI: 镜像 + 子 ROI 组合还原坐标（T-W4-5）" {
  let image = roi_gray_image(4, 1)
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
  let roi : @pose.RoiRect = { x: 1, y: 0, width: 2, height: 1, }
  let r = capture(() => @pose.letterbox_roi(image, config, roi))
  match r {
    Ok((bytes, t)) => {
      assert_true(t.mirrored)
      assert_eq(t.roi_x, 1)
      assert_eq(t.roi_width, 2)
      // 裁剪 = src(1,0)=1, src(2,0)=2；镜像后 tx=0 取裁剪列 1 = 2，tx=1 取裁剪列 0 = 1
      assert_eq(bytes[0].to_int(), 2)
      assert_eq(bytes[3].to_int(), 1)
      // restore_roi：模型 x=0 → roi_x + (roi_w-1-0) = 1+1 = 2（即 src(2,0)）
      let landmark : @pose.Landmark = {
        x: 0.0,
        y: 0.0,
        z: 0.0,
        visibility: 1.0,
        name: None,
      }
      let pose : @pose.PoseResult = {
        landmarks: [landmark],
        score: 1.0,
        frame_id: 0UL,
        timestamp_ns: 0UL,
        backend: @pose.BackendKind::Mock,
      }
      let restored = @pose.PoseResult::restore_roi(pose, t)
      assert_close(restored.landmarks[0].x, 2.0)
      assert_close(restored.landmarks[0].y, 0.0)
    }
    Err(e) => abort("unexpected error: " + err_name(e))
  }
}

///|
/// T-W4-5 补：detect_roi 与 restore_roi 在同一 ROI/镜像设置下坐标一致
/// （两条路径代数一致性：detect 内还原 + 平移 == letterbox_roi + restore_roi）。
test "ROI: detect_roi 与 manual letterbox_roi+restore_roi 坐标一致（T-W4-5）" {
  let image = roi_gray_image(8, 8)
  let spec = spec_of(
    4,
    4,
    3,
    @pose.TensorDtype::Float32,
    [0.0, 0.0, 0.0],
    [255.0, 255.0, 255.0],
    17,
  )
  let config = config_with(config_of(spec), spec, true, 0, 0.0, 1, true)
  let roi : @pose.RoiRect = { x: 2, y: 2, width: 4, height: 4, }
  // 模型坐标 (x=2,y=2) 表示模型帧内该点；raw 用 y=0.5,x=0.5 ⇒ 模型帧 (2,2)
  let raw = raw_uniform(17, 0.5, 0.5, 1.0)
  let backend = mock_of(raw, @pose.BackendKind::Mock)
  @pose.PoseBackend::open(backend, config)
  let via_detect = @pose.detect_roi(backend, image, config, roi, 3UL)
  // 手工路径：letterbox_roi + 未还原的 PoseResult + restore_roi
  let (_, t) = @pose.letterbox_roi(image, config, roi)
  let model_pose : @pose.PoseResult = {
    landmarks: [{ x: 2.0, y: 2.0, z: 0.0, visibility: 1.0, name: None, }],
    score: 1.0,
    frame_id: 3UL,
    timestamp_ns: 0UL,
    backend: @pose.BackendKind::Mock,
  }
  let via_manual = @pose.PoseResult::restore_roi(model_pose, t)
  assert_close(via_detect.landmarks[0].x, via_manual.landmarks[0].x)
  assert_close(via_detect.landmarks[0].y, via_manual.landmarks[0].y)
}

///|
/// T-W4-4：错误变体集合不变（仍 8 个）——ROI 非法复用 `InvalidInput`，不新增变体。
/// `err_name` 的穷尽匹配在编译期即锁定 8 变体；此处再断言 ROI 错误只落在既有变体上。
test "ROI: 错误变体仍为既有 8 个（T-W4-4）" {
  let image = roi_gray_image(4, 4)
  // 非 3 通道模型 → UnsupportedModel（既有变体）
  let spec2 = spec_of(2, 2, 1, @pose.TensorDtype::UInt8, [0.0], [1.0], 3)
  let config2 = config_of(spec2)
  let r = capture(() => {
    @pose.letterbox_roi(image, config2, { x: 0, y: 0, width: 2, height: 2, })
  })
  assert_true(
    result_name(r) == "UnsupportedModel",
    msg="1 通道应 UnsupportedModel",
  )
  // 非等比配置下 letterbox_roi → InvalidConfig（既有变体）
  let spec3 = spec_of(
    2,
    2,
    3,
    @pose.TensorDtype::UInt8,
    [0.0, 0.0, 0.0],
    [1.0, 1.0, 1.0],
    3,
  )
  let config3 = config_with(config_of(spec3), spec3, false, 0, 0.0, 1, false)
  let r2 = capture(() => {
    @pose.letterbox_roi(image, config3, { x: 0, y: 0, width: 2, height: 2, })
  })
  assert_true(
    result_name(r2) == "InvalidConfig",
    msg="非等比 ROI 应 InvalidConfig",
  )
}

///|
/// T-W4-3 防火墙：旧 `detect` 在既有语料上输出与 W4 前一致（同输入逐字节稳定）。
/// 断言「ROI 合入不改旧路径」——用既有 8×8 语料重复调用并校验关键字段。
test "ROI: 旧 detect 输出不变（防火墙，T-W4-3）" {
  let spec = movenet_spec()
  let config = config_of(spec)
  let image = white_image(8, 8)
  let raw = raw_uniform(17, 0.5, 0.5, 0.9)
  let backend = mock_of(raw, @pose.BackendKind::Mock)
  @pose.PoseBackend::open(backend, config)
  let r = @pose.detect(backend, image, config, 42UL)
  // 模型 (96,96) 经 letterbox scale=24 无填充 → 原图 (4,4)
  assert_eq(r.landmarks.length(), 17)
  for l in r.landmarks {
    assert_close(l.x, 4.0)
    assert_close(l.y, 4.0)
    assert_close(l.visibility, 0.9)
  }
  assert_close(r.score, 0.9)
  assert_eq(r.frame_id, 42UL)
  assert_eq(r.timestamp_ns, 123456UL)
}
