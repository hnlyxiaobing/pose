# hnlyxiaobing/pose

> API 冻结轮（2026-11-07）。`PoseBackend`（`pub(open)`，方法集冻结为 `open` / `infer` / `close` / `kind`，**冻结后增删方法即破坏性变更**）、中性值类型、配置/结果/错误模型与 `detect` / `letterbox` / `decode_output` / `restore` 实现均已完成；`PoseError` 为 `pub(all) suberror`。`close`：**不会二次释放，重复调用返回明确错误**（本库无 `detach`）。门禁：`moon check --deny-warn` 0 error 0 warning，`moon test` 30/30 全过。

姿态估计门面：持有 trait，后端由组合根注入；不链接 TFLite、不实现推理引擎（门面持有 trait、后端不依赖门面，避免与推理库形成循环依赖，见 `DECISIONS.md`）；letterbox/解码/还原等前后处理已在门面内实现。

完整文档见同目录 `README.md`、`DESIGN.md`、`API.md`、`DECISIONS.md`（设计决策记录）。

**当前状态：API 冻结待评审（实现完成，门禁全绿，30 测试）。**
