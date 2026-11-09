# hnlyxiaobing/pose

> R4 增量（2026-11-09）。`PoseBackend`（`pub(open)`，方法集冻结为 `open` / `infer` / `close` / `kind`，**冻结后增删方法即破坏性变更**）、中性值类型、配置/结果/错误模型与 `detect`/`detect_multi` / `letterbox`/`letterbox_stretch` / `decode_output`/`decode_pose_batch` / `nms` / `restore`/`restore_stretch` / `TfliteAdapter` 实现均已完成；`PoseError` 为 `pub(all) suberror`。R4 新增（NMS 去重、Float16 编码、stretch 非等比缩放、TfliteAdapter 注入式适配器）全部为加法性。`close`：**不会二次释放，重复调用返回明确错误**（本库无 `detach`）。门禁：`moon check --deny-warn` 0 error 0 warning，`moon test` 62/62 全过（基线 30 → 62）。

姿态估计门面：持有 trait，后端由组合根注入；不链接 TFLite、不实现推理引擎（门面持有 trait、后端不依赖门面，避免与推理库形成循环依赖，见 `DECISIONS.md`）；letterbox/stretch、解码、NMS、还原等前后处理已在门面内实现。

完整文档见同目录 `README.md`、`DESIGN.md`、`API.md`、`DECISIONS.md`（设计决策记录）。

**当前状态：R4 增量实现完成，门禁全绿，62 测试；P2（MediaPipe/ONNX 第二后端、tflite-runtime 数值对齐）未做。**
