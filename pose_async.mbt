///|
/// 异步后端门面（W6-A，2026-11-17 裁决落地）：与冻结的 `PoseBackend` 完全并行的
/// 新 trait + 新入口，旧 trait 与旧 `detect`/`detect_multi` 一行未改。
///
/// 运行约束：异步执行依赖 `moonbitlang/core/async`（工具链自带核心实验包，
/// 非第三方依赖，版本随工具链锁定）；组合根负责提供 async 运行时与调度策略。
/// 本文件不引入任何推理引擎、模型路径或引擎句柄。
///
/// 语义防火墙：`detect_async` 的前处理/预算/解码/NMS/坐标还原与 `detect_multi`
/// 完全同构，只把 `infer` 换成 `infer_async`；两入口在等价后端下输出逐字节一致。

///|
/// 异步推理后端契约（新类型，与 `PoseBackend` 方法集冻结互不干扰）。
pub(open) trait AsyncPoseBackend {
  async fn open(Self, PoseConfig) -> Unit
  async fn infer(Self, Bytes) -> Bytes
  async fn close(Self) -> Unit
  async fn kind(Self) -> BackendKind
}

///|
/// 编排一帧的异步检测（单姿态入口）：前处理 → 异步推理 → 预算 → 解码 → NMS → 还原。
///
/// - 与 `detect` 相同的空检测语义：零输出或全部候选被阈值过滤时返回空结果。
/// - 错误分类、预算口径、坐标还原和 `backend` 标注与同步入口完全一致。
/// - 线程/调度策略由 `AsyncPoseBackend` 实现与组合根声明；本函数不获取/释放引擎资源。
pub async fn detect_async(
  backend : &AsyncPoseBackend,
  image : RgbImage,
  config : PoseConfig,
  frame_id : FrameId,
) -> PoseResult {
  let poses = detect_multi_async(backend, image, config, frame_id)
  if poses.length() == 0 {
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
/// 编排一帧的异步检测（多姿态入口）：语义与 `detect_multi` 同构。
pub async fn detect_multi_async(
  backend : &AsyncPoseBackend,
  image : RgbImage,
  config : PoseConfig,
  frame_id : FrameId,
) -> Array[PoseResult] {
  let (input, plan) = preprocess(image, config)
  let raw = backend.infer(input)
  let block = config.model.landmark_count * 3 * 4
  let budget = block * config.max_poses
  if raw.length() > budget {
    raise BudgetExceeded(
      "detect_async: output tensor \{raw.length()} bytes exceeds max_poses budget \{budget} bytes",
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
