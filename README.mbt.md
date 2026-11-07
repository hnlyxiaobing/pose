# hnlyxiaobing/pose

> Round-1 · 架构与声明可评审（2026-11-06）。本包只有 `PoseBackend` trait、中性值类型、配置/结果/错误模型与 `declare` 函数签名，**无推理逻辑**。`moon check`：0 error，4 × `[0068]`（预期）。

姿态估计门面：持有 trait，后端由组合根注入；不链接 TFLite、不写像素循环（ADR-0004）。

完整文档见同目录 `README.md`、`DESIGN.md`、`API.md`；总体架构与决策见 `../docs/architecture.md`、`../docs/adr/`。

**当前状态：等待评审，不进入实现。**
