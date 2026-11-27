# Golden 语料登记（W2 / L2）

本目录是 W2 交付的**受控黄金差分（L2）语料登记表**。语料形态为**确定性字节 builder**
（测试代码内构造，非第三方模型、非文件 fixture），延续 B7「零死资产」口径；每一条
golden 都必须在 `pose_golden_test.mbt` / `pose_wbtest.mbt` 中被**真实断言**（`T-W2-1`：
入库且被测试真实读取，非死资产）。新增/修改任一 golden 须同步更新本表。

> 校验方式：`moon test`（wasm）+ `moon test --target native` 各跑一次，断言对两目标
> 一致即证明值输出逐字节 diff = 0（`T-W2-4`）。断言入口见 `tools/verify.sh`。

## 1. 基础 fixture builder

| builder | 形态 | 内容 |
|---|---|---|
| `golden_src_2x2` / `golden_image_2x2` | 2×2 RGB，12 字节 | 行主序像素 R/G/B：`(10,11,12) (20,21,22) (30,31,32) (40,41,42)`；`timestamp_ns=123456` |
| `raw_of` / `raw_uniform` / `spec_of` / `config_of` | `pose_test.mbt` 既有 builder | 输出张量 `(y,x,score)` 小端 Float32 平铺 |

## 2. Golden 行（逐条登记）

| # | golden 行 | 断言位置 | 精确记录 |
|---|---|---|---|
| G1 | letterbox 2×2→4×4，5 dtype | `pose_golden_test.mbt` `golden: letterbox 4×4 五 dtype` | `scale=2.0`、`pad=(0,0)`、`source=(2,2)`、`mirrored=false`；总字节 `4*4*3*elem`；左上像素 R=10 编码：Float32 `00 00 20 41`、Float16 `00 49`、UInt8 `0A`、Int8 `0A`、Int32 `0A 00 00 00` |
| G2 | letterbox 2×2→4×6（填充） | `golden: letterbox 4×6 填充带与采样区字节` | `scale=2.0`、`pad=(0,1)`；第 0/5 行全 `7`；第 1 行 tx0,1→`(10,11,12)`、tx2,3→`(20,21,22)`；第 3 行 tx0→`(30,31,32)` |
| G3 | letterbox mirror_x 2×2→4×4 | `golden: letterbox mirror_x 采样翻转字节` | `mirrored=true`；tx=0 取源列 1→`(20,21,22)`；tx=2 取源列 0→`(10,11,12)` |
| G4 | decode_output 17 点 @192² | `golden: decode_output 17 点边界逐字段` | `x_norm=0.5,y_norm=0.25,score=0.9` → 每点 `x=96,y=48,vis=0.9,z=0,name=None`，共 17 点 |
| G5 | decode_output 33 点 @256² | `golden: decode_output 33 点边界逐字段` | `x_norm=0.25,y_norm=0.5,score=0.75` → 每点 `x=64,y=128,vis=0.75`，共 33 点 |
| G6 | detect 端到端 @8×8→192² | `golden: detect 端到端逐字段` | 模型坐标 (96,96) 经 `scale=24` 无填充逆变换 → 原图 `(4,4)`；`score=0.9`、`frame_id=7`、`timestamp_ns=123456`、`backend=Mock` |
| G7 | P1 幂等律 | `golden: P1 幂等律` | `letterbox`/`nms`/`detect` 双次调用输出逐字节相等 |
| G8 | P4 后端注入律 | `golden: P4 后端注入等价` | Mock 与 Alt 同 raw → landmarks/score/frame_id/timestamp_ns 全等；仅 `backend` 标注不同（`Mock` vs `Custom("alt-adapter")`） |

## 2b. W4 ROI golden（`pose_roi_test.mbt`）

| # | golden 行 | 断言位置 | 精确记录 |
|---|---|---|---|
| G9 | ROI 边界拒绝 | `ROI: 边界非法报 InvalidInput` | 零宽/零高/负原点/右上越界/右下越界 → `InvalidInput(x,y)` |
| G10 | ROI 贴边合法 | `ROI: 贴边合法...` | 4×4 源图 ROI=(2,2,2,2) → 2×2 模型 scale=1，逐像素 `22/23/32/33` |
| G11 | letterbox_roi 裁剪+缩放 | `ROI: letterbox_roi 裁剪 + 缩放字节...` | ROI=(1,1,2,2) → 裁剪 `11/12/21/22` → 4×4 scale=2 采样 `11,11,12,12 / 21,21,22,22`；`RoiTransform` 11 字段全断言 |
| G12 | ROI=整图 ≡ detect | `ROI: ROI=整图 ≡ detect`（等比/stretch） | 两模式逐字段相等 |
| G13 | 镜像 + 子 ROI | `ROI: 镜像 + 子 ROI 组合还原坐标` | 4×1 源、ROI=(1,0,2,1)、mirror：模型 x=0→源 x=2；`restore_roi` 一致 |
| G14 | 两路径代数一致 | `ROI: detect_roi 与 manual letterbox_roi+restore_roi 坐标一致` | 同 ROI/镜像下两条还原路径坐标相等 |
| G15 | 错误变体仍 8 个 | `ROI: 错误变体仍为既有 8 个` | 1 通道→`UnsupportedModel`；非等比 `letterbox_roi`→`InvalidConfig` |
| G16 | 旧 detect 防火墙 | `ROI: 旧 detect 输出不变` | 8×8 语料 → (4,4)、score 0.9、ts 123456 |

## 3. 截断 / 变异扫描语料（L1）

| 扫描 | 种子/规模 | 断言位置 | 允许错误集合 |
|---|---|---|---|
| 截断扫描 | 17 点 204 字节张量：全前缀 `0..=204` + 每 12 字节结构边界（`b`、`b+1`） | `pose_wbtest.mbt` `截断扫描：17 点 golden...` | `OutputDecode` / `ShapeMismatch` / `InvalidConfig` / `BudgetExceeded`（无 panic/挂起） |
| 变异扫描 | 固定种子 `0x9E3779B97F4A7C15`（xorshift64），1000 体，替换/插入/删除 | `pose_wbtest.mbt` `变异扫描：固定种子 ≥1000...` | 同上 |
| nms 变异扫描 | 固定种子 `0xD1B54A32D192ED03`，100 体注入 NaN/Inf score/bbox | `pose_wbtest.mbt` `变异扫描：nms 候选注入非有限值...` | 必须 `InvalidConfig` |

## 4. 计数口径

`moon test` = **88** 条（W2 前 67 → W2 后 78 → W4 后 87 → 收口后 88；W2 新增 11：截断 1 + 变异 2 + golden 8；
W4 新增 9 条 ROI 用例；收口新增 1 条扫描器负对照），零 `#skip`；wasm / native 双目标各 88/88。计数以 `moon test` 实测为准，易漂移。

## 5. 扫描器负对照（防断言空转）

`pose_wbtest.mbt` 的「扫描器负对照：允许集合外变体必须判 false」断言 `decode_capture_allowed`
的判定不是恒真：允许集合内 4 变体（`OutputDecode`/`ShapeMismatch`/`InvalidConfig`/`BudgetExceeded`）
判 true，集合外 4 变体（`BackendNotOpen`/`InvalidInput`/`UnsupportedModel`/`BackendFailure`）
必须判 false，成功路径判 true。这样「截断/变异扫描全绿」才有意义。
