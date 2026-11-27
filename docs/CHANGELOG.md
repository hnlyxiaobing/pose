# pose 变更登记簿（CHANGELOG）

> 本文件登记每一次公开可见的变更：日期 / 工作包 / 新增 pub 声明 / 快照 diff 结论 / 测试增量。
> 仓库外申报口径（不在本仓库内的申报材料）一律不回写，仅以泛称描述差异。

## W1 · 漂移清理与自包含（2026-11-27）

- **工作包**：W1（P0/S，dev-plan §5 W1）。
- **新增 pub 声明**：无（仅注释 / 文档 / CI 文案 / 钩子）。
- **快照 diff**：空（`pkg.generated.mbti` 与 `cmd/main/pkg.generated.mbti` 均无变化）。
- **测试增量**：0（`moon test` 维持 64/64，零 `#skip`）。
- **要点**：修复 `docs/DECISIONS.md`、`docs/API.md` 等失效路径引用（改为指向 `docs/2026-11-17-*.md`）；去除 `pose.mbt` 注释中的外部模块/类型名（`yuv::`、`tflite_ffi`）；修正 `detect_multi` 空张量语义注释；README 补 `FrameId` 索引、改为唯一入口文档并加 docs 索引；`.githooks/pre-commit` 补齐五道门禁；新建本登记簿。
- **仓库外申报口径**：不回写；仅记录本仓库 git 实测。

---

<!-- 后续工作包在此追加登记。模板： -->
<!--
## W? · 标题（YYYY-MM-DD）
- 新增 pub 声明：...
- 快照 diff：...
- 测试增量：...
- 要点：...
-->
