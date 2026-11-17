// W6-A 验收：异步后端门面与旧同步入口的防火墙一致性。

///|
priv struct AsyncMock {
  output : Bytes
  label : @pose.BackendKind
}

///|
impl @pose.AsyncPoseBackend for AsyncMock with fn open(_self, _config) {
  ()
}

///|
impl @pose.AsyncPoseBackend for AsyncMock with fn infer(self, _input) {
  self.output
}

///|
impl @pose.AsyncPoseBackend for AsyncMock with fn close(_self) {
  ()
}

///|
impl @pose.AsyncPoseBackend for AsyncMock with fn kind(self) {
  self.label
}

///|
async test "detect_async: 与 detect 同步入口逐字段等价（防火墙）" {
  let spec = movenet_spec()
  let config = config_of(spec)
  let image = white_image(8, 8)
  let raw = raw_uniform(17, 0.5, 0.5, 0.9)
  let sync_backend = mock_of(raw, @pose.BackendKind::Mock)
  @pose.PoseBackend::open(sync_backend, config)
  let sync = @pose.detect(sync_backend, image, config, 7UL)
  let backend = AsyncMock::{ output: raw, label: @pose.BackendKind::Mock, }
  @pose.AsyncPoseBackend::open(backend, config)
  let async_result = @pose.detect_async(backend, image, config, 7UL)
  assert_eq(async_result.landmarks.length(), sync.landmarks.length())
  assert_eq(async_result.score, sync.score)
  assert_eq(async_result.frame_id, sync.frame_id)
  assert_eq(async_result.timestamp_ns, sync.timestamp_ns)
}

///|
async test "detect_multi_async: 多姿态与空检测语义与同步入口一致" {
  let spec = movenet_spec()
  let config = config_nms(config_of(spec), spec, 0.5, 2)
  let image = white_image(8, 8)
  let multi = raw_uniform(34, 0.5, 0.5, 0.9)
  let sync_backend = mock_of(multi, @pose.BackendKind::Mock)
  @pose.PoseBackend::open(sync_backend, config)
  let sync_poses = @pose.detect_multi(sync_backend, image, config, 9UL)
  let backend = AsyncMock::{ output: multi, label: @pose.BackendKind::Mock, }
  @pose.AsyncPoseBackend::open(backend, config)
  let async_poses = @pose.detect_multi_async(backend, image, config, 9UL)
  assert_eq(async_poses.length(), sync_poses.length())
  for i in 0..<async_poses.length() {
    assert_eq(async_poses[i].score, sync_poses[i].score)
    assert_eq(
      async_poses[i].landmarks.length(),
      sync_poses[i].landmarks.length(),
    )
  }
  let empty_backend = AsyncMock::{
    output: b"",
    label: @pose.BackendKind::Mock,
  }
  assert_eq(
    @pose.detect_multi_async(empty_backend, image, config, 10UL).length(),
    0,
  )
}
