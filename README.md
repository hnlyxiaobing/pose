# pose · 姿态估计门面

> 独立发布单元 ｜ L3 感知绑定 ｜ `preferred_target = wasm` ｜ Apache-2.0
> 状态：`moon test` **64/64** 通过（2026-11-17 本机实测，含 2 条异步门面用例）；带日期的开发/测试文档见 `docs/`，本文件是唯一入口文档。
> 公开 API 以 `pkg.generated.mbti` 为准（由 `moon info` 生成，禁手工编辑）；加法性变更须登记 `docs/CHANGELOG.md` + 快照审阅 + 快照门禁。

## 1. 定位与边界

用中立的值类型与 `PoseBackend` trait 把「张量输出」解码成关键点，隔离上层与具体推理后端。

**能力**

- `PoseBackend` 四方法契约与 `detect(&PoseBackend, …)`
- `decode_output` 支持 MoveNet 17 点与 MediaPipe/BlazePose 33 点同构布局（由 `ModelSpec.landmark_count` 配置）
- NMS（稳定降序、IoU 严格大于阈值）、stretch/ROI 缩放、Float16（RNE、NaN `0x7E00`）
- `TfliteAdapter` / `TfliteBinding` 注入式适配器（三回调），`MockBackend` / `AltBackend` 演示包外可实现

**非目标**

- 不 import 任何推理后端；不封装 MediaPipe Tasks C API
- 不做模型加载、张量分配与锚点解码的两阶段编排（属组合根）

## 2. 关键设计决策（本仓库自足记录）

- 门面持有 trait，后端不知道门面存在，消除 `pose ↔ tflite_ffi` 循环。
- R4 把 `TfliteAdapter` 实现收进本包（`pub impl PoseBackend for TfliteAdapter`），`TfliteBinding` 以回调注入；`pose` 不 import 后端的红线仍守住。
- Q8 已收官：目标 App 实测为 **33 点 BlazePose**，由配置层吸收而非换后端；ADR-0008 的「第一轮 17 点」前提已修订。
- `PoseBackend` 方法集冻结；异步后端经 2026-11-17 裁决 A 另立 `AsyncPoseBackend` trait 与 `detect_async`/`detect_multi_async` 新入口（纯加法），旧同步 trait 与方法零改动；异步执行依赖工具链自带核心实验包（非第三方依赖）。

## 3. 公开 API 索引（自动抽取 `pkg.generated.mbti` 的全部 `pub` 声明行，含类型别名 / 方法 / trait / impl；完整字段见快照）

```text
pub async fn detect_async(&AsyncPoseBackend, RgbImage, PoseConfig, UInt64) -> PoseResult
pub async fn detect_multi_async(&AsyncPoseBackend, RgbImage, PoseConfig, UInt64) -> Array[PoseResult]
pub fn decode_output(Bytes, ModelSpec, PoseConfig) -> Array[Landmark] raise PoseError
pub fn decode_pose_batch(Bytes, ModelSpec, PoseConfig) -> Array[PoseCandidate] raise PoseError
pub fn detect(&PoseBackend, RgbImage, PoseConfig, UInt64) -> PoseResult raise PoseError
pub fn detect_multi(&PoseBackend, RgbImage, PoseConfig, UInt64) -> Array[PoseResult] raise PoseError
pub fn letterbox(RgbImage, PoseConfig) -> (Bytes, Transform) raise PoseError
pub fn letterbox_stretch(RgbImage, PoseConfig) -> (Bytes, StretchTransform) raise PoseError
pub fn nms(Array[PoseCandidate], Double, Int32) -> Array[PoseCandidate] raise PoseError
pub(all) suberror PoseError {
pub fn PoseError::to_repr(Self) -> @debug.Repr
pub(all) enum BackendKind {
pub(all) struct BoundingBox {
pub fn BoundingBox::area(Self) -> Double
pub fn BoundingBox::iou(Self, Self) -> Double
pub(all) struct Landmark {
pub(all) struct ModelSpec {
pub(all) struct PoseCandidate {
pub fn PoseCandidate::new(Array[Landmark]) -> Self
pub(all) struct PoseConfig {
pub(all) struct PoseResult {
pub fn PoseResult::restore(Self, Transform) -> Self raise PoseError
pub fn PoseResult::restore_stretch(Self, StretchTransform) -> Self raise PoseError
pub(all) struct RgbImage {
pub(all) enum RgbLayout {
pub(all) struct StretchTransform {
pub(all) enum TensorDtype {
pub struct TfliteAdapter {
pub fn TfliteAdapter::close(Self) -> Unit raise PoseError
pub fn TfliteAdapter::infer(Self, Bytes) -> Bytes raise PoseError
pub fn TfliteAdapter::kind(Self) -> BackendKind
pub fn TfliteAdapter::new(TfliteBinding, ModelSpec) -> Self
pub fn TfliteAdapter::open(Self, PoseConfig) -> Unit raise PoseError
pub fn TfliteAdapter::unavailable(ModelSpec) -> Self
pub fn TfliteAdapter::used_fallback(Self) -> Bool
pub fn TfliteAdapter::with_fallback(TfliteBinding?, TfliteBinding?, ModelSpec) -> Self
pub impl PoseBackend for TfliteAdapter
pub(all) struct TfliteBinding {
pub(all) struct Transform {
pub type FrameId = UInt64
pub(open) trait PoseBackend {
pub(open) trait AsyncPoseBackend {
```

## 4. 依赖、平台与许可

零第三方依赖；`preferred_target = wasm`；Apache-2.0。

## 5. 命令行与验证

- 本库无 CLI；`cmd/main` 为模板。
- 复验：`moon clean` → `moon check --deny-warn` → `moon build` → `moon test` → `moon fmt --check` → `moon info` 后检查 `pkg.generated.mbti` 无意外 diff。
- 单一入口（推荐）：`bash tools/verify.sh` —— 仓库自包含地串起五门禁 + `moon test --target native` 双目标等价 + 截断/变异自检 + 错误簿记 8/8 + 引用实存性；外部推理运行时 oracle 缺失时显式 SKIPPED（整体退出码 78 = 除 oracle 外全绿，不计入通过），`--no-native` 可跳过双目标步。
- 本仓库为独立 Git 仓库，文档与 CI 均自包含，不依赖工作区其他目录。

## 6. 风险与未决

- P1-b 第二步的 ROI crop 接口尚未交付（计划于 W4）。
- 与外部推理运行时的 <1e-4 逐元素数值对齐：runner 已建（`tools/numeric-oracle.sh`，仓库外模型路径 + SHA-256 门禁），但本机无外部模型/运行时，真实差分未跑（缺失时显式 SKIPPED，不计入通过）。

## 7. 文档索引（`docs/`）

- `docs/2026-11-17-backend-neutral-facade-dev-plan.md` —— 后端中立门面开发计划（能力点 F1–F10、硬约束、边界裁决、工作包 W1–W6、里程碑与 DoD）。
- `docs/2026-11-17-test-system-design.md` —— 测试系统设计（分层 L0–L5、断言 A1–A8、fixture 体系、覆盖矩阵、错误簿记、验收 ID `T-W*-*`）。
- `docs/CHANGELOG.md` —— 加法性变更登记簿（每工作包：日期 / 新增 pub / 快照 diff / 测试增量）。
- `tests/golden/README.md` —— L2 golden 语料登记表（builder / 种子 / 精确记录 / 断言位置）。

