# pose · 设计决策记录（DECISIONS.md）

> 本文记录本库的架构设计决策，内容已全部自足收录，读者无需访问仓库外任何文件。
> 每条按「背景 → 决策 → 理由 → 后果」组织；`../README.md` / `DESIGN.md` / `API.md` 中的
> 「见 `DECISIONS.md`」均指向本文对应小节。

---

## 决策 1：门面持有 `PoseBackend` trait，后端不依赖门面，组合根写适配器

**背景（潜在循环依赖问题）**。最初的实现思路是「`pose` 直接调用推理后端」+「后端实现
`pose::PoseBackend`」，这会形成经典插件架构的**潜在循环依赖**：

```
pose ──(调用后端)──► tflite_ffi ──(实现 trait)──► pose
```

在「零跨模块 import」约束（见决策 3）下，这个环会直接表现为不可编译的双向依赖。
另有两个可替换性要求：换推理后端不换上层 API；不向上层泄漏后端实现细节
（引擎句柄、模型路径、量化格式）。

**决策**。

1. `pose` **拥有** `pub(open) trait PoseBackend { open / infer / close / kind }` 与全部
   中性值类型（`RgbImage` / `Landmark` / `PoseResult` / `ModelSpec` / `PoseConfig` / `Transform`）。
2. `pose::detect(backend : &PoseBackend, image, config, frame_id)` 通过 **trait object**
   调用后端，不 import 任何后端模块。
3. **后端库不知道门面存在**：`tflite_ffi` 只暴露 `Interpreter`（持 `#external` 句柄 +
   `TensorDesc`），不 import `pose`；MediaPipe / ONNX 后端同理。
4. **组合根**（未来 App 工程里的适配代码，不是新库）写薄适配器：
   `struct TfliteAdapter { interp : Interpreter }` + `impl PoseBackend for TfliteAdapter`，
   把 `infer(Bytes) -> Bytes` 映射到 `set_input / invoke / output_raw`。
5. 后端句柄、模型路径、量化格式、引擎版本**全部留在各自模块**，不进入 `PoseResult`
   之外的任何上层类型。

**理由**。门面持有 trait、后端不依赖门面，从结构上消除「门面→后端、后端→门面」的
潜在循环依赖；`pose` 可以用 Mock 后端做纯 MoonBit 单测（无需 `.so`、无需设备）；
换 ONNX / MediaPipe 只需在组合根新增一个适配器，上层 API 完全稳定。`&PoseBackend`
trait object 语法已实测可用。

**后果**。

- 正面：彻底消除循环依赖；Mock 后端纯 MoonBit 单测；换后端 = 换适配器；上层 API 稳定。
- 负面：组合根多一个适配器文件；trait object 调用有一次间接跳转（对 5–15 fps 的
  帧率预算可忽略）。`&PoseBackend` 的并发约束由实现方声明并写进后端模块自身文档，
  `pose` 自身无状态。
- 被替代方案：① `pose` 直接 import `tflite_ffi`（否决：循环依赖 + 引擎绑死）；
  ② 把 trait 抽到单独的 `inference-core` 模块（否决：为 4 个方法新建一个模块，成本高
  且改变目录结构，后续可复议）；③ 用配置字符串在 `pose` 内部 if/else 分发后端
  （否决：违反开闭原则且泄漏实现细节）。
- 风险：`infer(Bytes) -> Bytes` 是无类型字节契约，形状错误只能在运行时发现。缓解：
  `ModelSpec` / `TensorDesc` 提供形状元数据，组合根适配器负责校验并以
  `PoseError::ShapeMismatch` 报出。若 MediaPipe 后端需要回调式异步推理，当前同步 trait
  不够用（属待验证项）；新增 `infer_async` 属破坏性变更（`PoseBackend` 方法集已冻结）。

---

## 决策 2：推理后端选型——TFLite 首选、MediaPipe 降级、ONNX 备选

**背景（调研事实）**。

- MediaPipe **有** `tasks/c/vision/pose_landmarker/pose_landmarker.h`（`extern "C"`、
  `MP_EXPORT`、`MpPoseLandmarkerCreate/DetectImage/Close`，Apache-2.0），但上游提交自称
  "Breaking API change to internal C API"（2026-11-03），头文件含 `<cstdint>` 与
  `int num_poses = 1;` 等 **C++ 语法**，官方 API 参考不列 C，Python ctypes 文档明确要求
  "Pin your mediapipe version"。结论应表述为「有 C ABI、无官方稳定/公开 ABI 承诺」。
- TFLite `c_api.h` 自述 "useful for shared libraries where having a **stable ABI boundary**
  is important"，受 TFLite 版本号覆盖；`c_api_opaque.h` / `common.h` / `builtin_op_data.h` /
  `builtin_ops.h` 属 **Extension APIs**，独立版本号、保留不兼容变更权利；
  `c_api_experimental.h` 与 C++ API 不受保证。`TfLiteInterpreter` **未弃用**，是稳定核心
  C API（真实弃用是 `TfLiteRegistrationExternal`→`TfLiteOperator`）。
- ONNX Runtime 遵循 SemVer 2.0，C API 只导出 `GetOrtApiBase`→append-only `OrtApi`
  函数指针表，**ABI 纪律最强**；`moon-ort@0.1.1`(MIT) 已存在但仅 native CPU、
  dlopen ORT 1.30.0、不支持 Windows/GPU。
- 模型事实：MoveNet.SinglePose 为 Apache-2.0，Lightning `192×192×3`、输出 `[1,1,17,3]`
  （f16/int8 变体可用）；BlazePose/MediaPipe 输出 33 点。两家模型前后处理差异大。

**决策**。

1. **第一轮唯一推理后端 = LiteRT/TFLite `c_api.h`**。后端 FFI 层只声明 `c_api.h` 覆盖的
   能力（model / options / interpreter / tensor / invoke），**不声明
   Extension/opaque/delegate/experimental 符号**，避免踩无 ABI 保证的区域。
2. **MediaPipe 不进第一轮**，降级为后续增强后端，且必须满足：与 mediapipe 版本同锁、
   做 ABI 结构布局 diff 快照、C++ 胶水层隔离其非 C99 头。若只需 17 关键点，优先用
   MoveNet + TFLite C API（体积与合规成本更低）。
3. **ONNX Runtime 登记为第二可替换后端**（组合根适配器），本轮**不引入 `moon-ort`
   依赖**；其价值是 ABI 纪律强、模型来源不同，可在 TFLite 模型许可/精度不合适时切换。
4. **模型与 `.so` 许可单独审计**：框架 Apache-2.0 ≠ 模型可商用、≠ 预编译 `.so` 可随包
   分发。MoveNet / BlazePose 托管许可标为 Apache-2.0；MoveNet 模型卡含「监控类用途超出
   适用范围」类声明（其法律约束力待法务确认）。
5. `pose::ModelSpec` 用配置化（输入尺寸 / dtype / 均值方差 / 关键点数 / 输出张量索引）
   缓解「前后处理与模型强绑定」，换模型尽量只改配置。

**理由**。把外部 ABI 依赖收敛到唯一有官方稳定承诺的 C API；MediaPipe 的 breaking-change
风险被隔离在后续阶段；换后端不改 `pose` 上层 API；模型的 17 点 vs 33 点差异用配置吸收。

**后果**。

- 正面：唯一稳定 ABI 面；MediaPipe 风险隔离；上层 API 稳定；17/33 点差异配置化。
- 负面：第一轮只有 17 关键点（MoveNet 系），若目标应用依赖 33 点/3D world landmarks
  则不够（见决策 4 的待评审前提）；预编译 `.so` 需随包分发 armv7/arm64 两份（约 3–5 MB）。
- 被替代方案：① 直接绑 MediaPipe `tasks/c`（否决：internal C ABI、C++ 头、无稳定承诺）；
  ② 用仅 js 目标的 LiteRT 解析执行方案移植到 native（否决：可移植性未证实）；
  ③ 用 `moon-ort` 作首选（否决：不支持 Windows/GPU、需 dlopen ORT 1.30.0、与目标
  Android 平台不匹配）。
- 风险：TFLite C API 不覆盖全部 delegate/GPU 算子（第一轮只用 CPU，需在设备上验证
  5–15 fps 帧率预算）；量化模型（f16/int8）输出精度差异需数值对齐测试（后端侧 <1e-4）；
  模型商用条款在最终 App 分发前必须补法务结论。

---

## 决策 3：零跨模块 import；跨模块只走纯值契约，同构值类型各自定义

**背景**。各项目（`pose` / `yuv` / `tflite_ffi` / …）是**独立 MoonBit 模块**，各自持有
`../moon.mod`，不是同一模块内的多个包；任何跨模块 `import` 都会让 `moon check` 因找不到
依赖而失败。同时 MoonBit 是**名义类型系统**：两个模块里结构完全相同的 `struct` 也不是
同一类型。若按「相机 → YUV 转换 → 姿态门面 → 推理后端」的字面顺序实现编译期依赖，
会出现多处循环风险——包括「门面想复用转换库的 `RgbImage` 类型」造成的
`yuv ↔ pose` 类型环，以及决策 1 描述的 `pose ↔ tflite_ffi` 环。

**决策**。

1. **零跨模块 import**：全部模块可独立 `moon check`；不新增跨模块依赖。
2. 定义**跨模块纯值契约（Wire Contract）**：Frame / Rgb / Blob / Tensor / Handle 五类，
   全部是 `{ width, height, format, Bytes, timestamp }` 一类的纯值。各模块**自带同构值
   类型**、不共享类型定义——例如 `pose::RgbImage` / `RgbLayout` 与 `yuv::RgbImage` /
   `RgbLayout` 结构一致（同构），由组合根做值到值的适配。
3. 引入**组合根**概念：它不是新库，而是未来 App 工程里的一段适配代码，负责 ① 用纯值
   在模块间构造目标类型；② 注入后端实现；③ 编排生命周期；④ 把下层错误映射为上层诊断。
4. `#external` 句柄、JNIEnv、FuncRef **永不跨模块传递**，只留在声明它的模块内部。
5. 抽象（trait）放在消费方（门面/组合根），实现方不反向依赖。

**理由**。各模块可完全并行开发/评审；API 边界被迫写成中性值类型，天然满足「后端可替换、
实现细节不泄漏」；`moon check` 无外部依赖风险；从结构上避免全部潜在循环依赖（含
`yuv ↔ pose` 的类型复用环）。

**后果**。

- 正面：并行开发、边界中性、可独立检查、无循环依赖。
- 负面：组合根需要写少量显式适配代码（几个值类型 + 后端适配器）；`YuvFrame` /
  `RgbImage` 在两个模块里各定义一次，存在**结构漂移风险**——靠跨模块契约表 +
  `moon info` API 快照（`../pkg.generated.mbti`）+ 组合根测试守住。
- 被替代方案：① 抽出一个公共 `media-frame` 模块统一值类型（可逆决策：适配代码膨胀时
  再抽，当前收益不抵成本）；② 合并成一个多包模块（破坏既有骨架，禁止）；③ 发布到
  mooncakes.io 后用真实 import（引入版本耦合，不采用）。

---

## 决策 4：模型输出布局以 MoveNet 17 点与 MediaPipe 33 点为事实基准

**背景（模型事实）**。MoveNet.SinglePose（Apache-2.0）Lightning 输入 `192×192×3`、
输出 `[1,1,17,3]`——17 个关键点，每点 `(y, x, score)` 三元组、坐标为相对模型输入尺寸的
归一化值（f16/int8 变体可用）；BlazePose/MediaPipe 输出 **33** 点（另有 3D world
landmarks）。两家模型的前后处理差异大，输出布局不一致。

**决策**。

1. `decode_output` 按 `[landmark_count, 3]` 的 Float32（小端）`(y, x, score)` 布局解析，
   `landmark_count` 配置化——MoveNet 的 17 点布局与 MediaPipe 的 33 点同构布局均适用。
2. 第一轮按 **17 点**设计（`ModelSpec.landmark_count = 17`、`PoseConfig.model` 默认
   MoveNet 风格），33 点通过配置支持。
3. 坐标换算约定：`x = x_norm * input_width`、`y = y_norm * input_height`（模型输入像素系），
   `z = 0`（2D 模型无深度），`visibility = score`；再经 `Transform` 还原到输入图像像素系。

**理由与后果**。布局事实基准让解码实现与测试有确定依据（17 点/33 点均可由配置覆盖）；
但**目标应用是否需要 33 关键点 / 3D world landmarks 尚待评审**——若需要，第一轮后端
选型（决策 2）需复议，因为 MoveNet 系只有 17 点、无 3D world landmarks。

---

## 决策 5：依赖政策——本库零依赖，引入第三方包须过五条门槛

**背景**。用户约束「不引入无依据的大型依赖」；且任何 `moon add` 都会引入网络/版本耦合、
破坏模块可独立 `moon check` 的性质、与决策 3 的零 import 冲突。

**决策**。`pose` 本轮**零依赖**（独立 `../moon.mod`，`moon check` 独立通过）；后续轮的后端
适配器在组合根实现，`pose` 自身不引入 `tflite_ffi` / `moon-ort` / MediaPipe 依赖。
后续新增任何第三方依赖必须**同时**满足五条门槛并在文档留痕：① 用途（明确解决哪层能力，
且无更小代价替代）；② 许可（SPDX 已核验、与 Apache-2.0 兼容、再分发义务列明）；
③ 维护（版本/owner/最后更新/是否 legacy）；④ 平台（目标后端一致，不破坏独立
`moon check`）；⑤ 风险（登记待验证项，给出替代方案与移除成本）。

**理由与后果**。保持「clone 即可 `moon check` / `moon test`」的自足性；代价是后端接入
工作量被后移到组合根，但未消失。

---

## 决策 6：R4 增量在 API 冻结语义下的落地方式（NMS / Float16 / stretch / TfliteAdapter）

**背景**。R4 需新增 NMS 姿态去重、Float16 输入编码、stretch 非等比缩放与 TFLite 适配器，但
`PoseBackend` 方法集、`PoseError` 可见性与既有公开类型（含 `Transform` 的六字段构造式）已冻结；
本仓库 API 冻结约定只允许**加法性**新增公开 API：既有签名变更即破坏性变更；新增须同步 `pkg.generated.mbti` 快照、在 `docs/API.md` 登记并经 CI 快照门禁校验。

**决策**。

1. **全部为加法性新增**：`BoundingBox` / `PoseCandidate` / `nms` / `decode_pose_batch` /
   `detect_multi`；`StretchTransform` / `letterbox_stretch` / `PoseResult::restore_stretch`；
   `TfliteBinding` / `TfliteAdapter`。既有签名零改动，`detect` / `letterbox` / `decode_output` /
   `restore` / `Transform` / `PoseConfig` 字段均保持原样。
2. **stretch 用并行类型而非给 `Transform` 加字段**：单 `scale` 无法表达 x/y 独立比例；给
   `pub(all) struct Transform` 加字段会破坏包外六字段构造式（测试中也大量使用）。故新增
   `StretchTransform`，由 `detect` 内部的 `preprocess` 按 `keep_aspect_ratio` 成对分派
   「前处理 ↔ 还原」。`letterbox` 对 stretch 配置显式报 `InvalidConfig` 并指向新 API。
3. **NMS 会话/中间值**：`decode_pose_batch` 按 `landmark_count * 3 * 4` 字节切块，`PoseCandidate`
   携带过滤后关键点、均值 score 与 bbox；`nms` 按 score 降序**稳定**排序后贪心，IoU **严格大于**
   阈值才抑制，空输入返回空。`detect` 委托 `detect_multi` 并返回最高分姿态，保持单结果签名与
   `score` 既有语义（保留关键点 visibility 均值）。
4. **TfliteAdapter 不违反门面持有 trait 决策**：pose 仍**不 import `tflite_ffi`**、不持有引擎句柄/路径。
   「组合根写适配器」收敛为「组合根注入 `TfliteBinding` 三个字节级回调」，门面提供
   可复用的尺寸校验（`ShapeMismatch`）、生命周期错误与「绑定缺失 → 回退绑定」骨架；真实
   interpreter 的创建/调用仍在组合根与后端模块内。
5. **Float16**：`f32_to_f16_bits` 按 round-to-nearest-ties-to-even 转换，NaN 折叠为 `0x7E00`、
   ±Inf 保号、溢出饱和、`2^-25` 下溢为带符号零、f16 次正规区间正常编码；`letterbox` 对
   `Float16` 不再拒绝（原 `UnsupportedModel` 行为按新特性移除，属行为变更、非签名变更）。

**后果**。正面：冻结语义与「零跨模块 import」同时保持；新增能力可独立测试（合成张量 + mock
注入，无 `.so`/模型）。负面：本决策增加了并行类型与函数，API 面变大；`letterbox` 与
`letterbox_stretch` 需调用方按 `keep_aspect_ratio` 选择。风险：NMS 阈值/bbox 仅在合成张量上
验证，真实 MoveNet 输出上的阈值标定 `[仍需实测]`；真实 `tflite_ffi` 绑定未接入。

---

## 附：开发顺序结论（背景补充）

早期路线图把姿态门面排在相机之后的第二阶段，且「取帧 → 姿态推理 → 电视渲染」的闭环
验收清单里没有 `pose`——感知闭环逻辑上无法闭合。第一性原理分析给出的**感知最小闭环**
（一个本地 RGB 样本 → 姿态门面 + Mock/TFLite 后端 → 关键点坐标）必须有门面，但
**不需要相机**（相机是可替换帧源，不在最小闭环的关键路径上）。因此 `pose`（API +
trait + Mock 后端）**提前到第一轮实现**，`camera2` 后移为可替换帧源；验证方式为纯
MoonBit 单测 + 与 Python `tflite-runtime` 数值对齐（后端侧 <1e-4）。
