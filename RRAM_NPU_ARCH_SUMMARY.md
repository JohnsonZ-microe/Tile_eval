# RRAM NPU 架构规格摘要（Tile_eval 工程参考）

> 来源：`D:\HKUST\AFD_Arch\rram_npu-main\rram_npu-main`（该工程是 Tile_eval 的上游架构 spec）。
> 本文档由以下文档整理而成，供 RTL 开发时快速查阅；数值以原文为准。
>
> | 文档 | 版本 | 日期 | 内容 |
> |---|---|---|---|
> | `docs/architecture.md` | v0.12 | 2026-10-07 | 系统总览、tile/条带化微架构（§4）、数值契约（§4.4）、SRAM 预算 |
> | `docs/data_bus.md` | v0.12 | 2026-10-07 | hub/树/tile 总线、flit 格式、流控、pass 调度、tile 内部（§9） |
> | `docs/chip_arch.md` | v0.9 | 2026-10-07 | PCIe/HDMA/RISC-V/AXI/APB/地址图/时钟复位/RRAM 编程 |
> | `docs/arith_cells.md` | v0.2 | 2026-10-07 | **tile 算术单元接口契约**（dec/dot32/sclap/act/quant/fcomb/bf16c） |
> | `docs/model_support.md` | v0.9 | 2026-10-07 | 通用模型支持（类格式、VSPLIT、预设模型表） |
> | `docs/firmware_arch.md` | v0.3 | 2026-10-07 | 固件/启动/MBOX 协议 |
> | `spec/regs/*.json` | — | — | 寄存器规格（tile/hub/node/hdma 等 26 个 block） |
>
> **与本工程的关系**：Tile_eval 实现的是规格 `RTL-TILE-PE-001`——即本架构中 tile 的
> **计算核心部分**（权重解码 + 精确 dot32 + scale + 80×4 FP32 RF 累加），不包括 SwiGLU/h 量化/
> 广播协议/RRAM 调度等。映射关系见 §12。

---

## 1. 系统定位与固定决策（architecture.md §1）

| 项 | 决策 |
|---|---|
| 功能 | **只做 FFN**：routed / shared / dense 三类层。无 attention、无 KV cache、无 LPDDR |
| Attention | 跑在带 HBM 的 GPU/NPU 上（attention–FFN 分离）；基线 RTX 5090，池 23–26 张 |
| 目标 | 每 chip 最大化 tokens/s，约束为每用户解码速度下限 **40–50 tok/s/user** |
| 工艺/芯片 | 22 nm，~200 mm² 逻辑 die，RRAM die 堆叠在上 |
| RRAM | **10 GB，64 个 area**，每 area 一个 1024-bit 读端口 + 一个 SPI 编程端口；写寿命低 → 视为可重编 ROM |
| 时钟 | 800 MHz–1 GHz → 聚合读带宽 **6.6–8.2 TB/s** |
| RRAM 读时序 | 同 SRAM：每 area 每周期 1 个随机 1024-bit 读；`RRAM_LAT` 参数（1..min(4,MAC_FILL)，默认 1）；本阶段不含 ECC |
| 目标模型 | DeepSeek-V4.1-Flash：40 MoE 层，hidden 5120，384 routed + 1 shared expert，top-6，expert 中间维 2304 |
| 权重格式 | 每类可配 FP4 / FP8 / FP8-FP32scale / FP8-BF16scale / INT4 / BF16；V4.1 用 routed FP4 E2M1+UE8M0/32 + shared FP8 E4M3+UE8M0/32 = **7.255941120 GB/层** |
| 映射 | V4.1 每芯一层、40 芯；通用模型 N 连续层/芯或 c 芯/超大层；每次 visit 是独立 step + GPU 往返 |
| 主机链路 | **PCIe Gen3 x4**：3.94 GB/s 原始，~3.15 GB/s 有效（单向） |
| 专家选择 | 假设均匀随机；不复制热专家 |
| 功耗 | 本阶段不约束 |

## 2. 系统架构与链路预算（architecture.md §2）

- **V4.1 层流水映射（选定）**：chip *i* 持有 layer *i*。每 token 每芯过链路一次：入 5.3 KB（FP8 x + scale + 路由头），出 10 KB（BF16 y）。最多 40 个微批并行；B = 20 工作点系统内约 80 个微批（~1600 请求）循环。
- **宽 EP（弃选）**：每层专家摊到 40 芯，每 token 需 ~5.6 芯 → 链路过载。
- B = 20 工作点：GPU 池 23–26 张 RTX 5090 / 40 RRAM 芯；服务器拓扑假设 4 server ×（8 GPU + 10 RRAM 卡）。
- 批 tok/s/chip（V4.1 预设）：~76,454（`model_support.md` §5.1）。

## 3. 芯片顶层（chip_arch.md）

- **单 `core_clk` 同步域**（D9）：hub + 树 + 64 tiles + rpgm 全部锁步；计算数据通路不碰 AXI。
- **时钟**（P4-1/2）：单 PLL；`sys_clk` = root/2（128-bit AXI/PCIe/CPU 域）；`CORE_DIV` 可被硬件 PVT trip 强制 2（整体降频保持锁步）。
- **互连**（D1/D2）：一条 128-bit AXI4 crossbar（`sys_clk`，6.4–8 GB/s）连 PCIe/DMA/CPU/hub 缓冲/PGM hub；4 段 APB，APB→CTRL 经树到达 tile 寄存器（每 tile 4 KiB 窗口，广播写在 tile 0x7F）。
- **RISC-V 管理子系统**：RV32IMAC + Zicsr/Zifencei，M/U，PMP，单发射顺序，`sys_clk`；无 MMU/cache，代码数据在 TCM（ITCM+DTCM+ROM = 272 KiB）。
- **PCIe endpoint**：Gen3 x4；MSI-X 5 向量；BAR0 控制/状态（含 MSI-X 表、MBOX BAR0+0x600_0000）、BAR2 ITCM/DTCM（host 加载固件）；出站 fence `POF` 处理 PERST#/DL_Down/FLR。
- **HDMA**（host DMA，唯一批量搬运）：ING（host→hub 入口 ring，双 bank）、EGR（hub 出口→host，分段 BF16/FP32 输出）、PGM（host→PGM 孔径，64 流表，≤8 chunk 在飞，2 KiB chunk）；ring：64 B 描述符 / 32 B 完成记录 + 尾部门铃（C3）。
- **启动**：QSPI（默认，BOOT_SRC strap）或 host 加载；单一 bootloader+firmware 镜像（无 A/B）；固件完成树自检、SRAM BIST、元数据恢复、SCAN 校验后进 RUN。
- **错误**：tile `ERR_STATUS`（19 位 W1C）+ ALARM 上行 flit；hub 入口准入检查（data_bus §8.1）；EGR 状态码 0x00–0x0D；PLIC 64 源；fatal 直接拉 MSI-X 向量 4。

## 4. 数据总线（data_bus.md §2、§5–§7）

### 4.1 拓扑：hub 居中的 4 叉树，64 tiles

| 链路 | 下行（广播） | 上行（汇聚） | 数量 | 长度 |
|---|---:|---:|---:|---:|
| hub ↔ L2（象限） | 512 b | 512 b | 4 | ~7 mm |
| L2 ↔ L1（2×2 组） | 512 b | 256 b | 16 | ~3.5 mm |
| L1 ↔ tile | 512 b | 128 b | 64 | ~1.8 mm |

- 下行：每节点寄存一拍并复制给 4 个孩子 → **所有 tile 同拍收到同一 flit**（等长路径），无路由无仲裁。
- 上行：整包轮转汇聚，包不变样；同源严格保序。
- 每 link 5 根 **SYNC** 线：`sync[0]`（x-credit 脉冲 AND 合并，每弹出一个 X/XS 条目一拍）、`sync[1]`（phase-done AND）、`err`（OR 粘滞）、`pgm_busy`、`pgm_unsafe`。
- 上行**credit 流控**（链路上有流水寄存器，不能用组合 ready）。

### 4.2 flit/包格式（§6，摘要）

- 下行 flit = 512 b 载荷 + 32 b 边带。类型：`X`（64 B 激活）、`XS`（64 个 1 B UE8M0 scale）、`H`（64 B = 32 × BF16 h 广播）、`CMD`（相位命令：pass id、phase GU/D、step begin/end、first、ybank、ntok、ctx 等）、`CTRL`（APB 寄存器读写，含树自检 NODE_ID）、`PGM`（编程数据）、STATUS（RRAM 返回/完成回报）。`CMD`/`H`/`CTRL`/`PGM` 不进 x FIFO。
- 上行包（phit = 128 b）：`H_UP`（tile 的 36 列 h 切片，BF16）、`Y_UP`（80 列完成 y 或 EP partial，BF16/FP32）、`ALARM`。
- tile 上行载荷槽有界：2×288 B 共享槽 + 1×288 B H 专用槽（M22）；H 优先，未启动的 Y 可让位 D commit；预约故障报 UP_SLOT 错而非暂停。
- tile 弹出 X/XS ≤1 条/拍入双缓冲操作数 staging；每物理条目一拍 `sync[0]`。

## 5. Pass 调度与相位（data_bus.md §3–§4）

- **条带化（architecture §4.1）**：每专家条带摊到 64 tiles，全部 tile 锁步跑同一专家 pass。总线仅三类任务，无 tile 间部分和：① 广播 x；② all-gather h（hub 收 64×36 切片→拼 2304 列→广播回）；③ 收集 y。选列切分（无部分和归约）比归约 y 少 284× 流量（0.018 MB/pass）。
- **GU 相**（每 tile 36 gate + 36 up 列 = 72 列，输入该 pass 的 R 个 token 全 x；K=5120）：RRAM k-major 读；V4.1 FP4 下 1440 数据字 + 90 scale 字 = **1530 周期/pass**；每 32 值 x 块供 9 拍 → x 需求 ~14 B/cycle（R=4）。
- **D 相**（80 输出列 × K=2304，输入全量 h FP8）：720+45 = **765 周期/pass**；h 从本地 h buffer 读，不占总线。
- **软件流水**：RRAM 每周期一字，同 pass 的 GU/D 不能重叠 → 发射顺序 GU(p) → D(p−1) → GU(p+1)；h(p) 的 all-gather 与 D(p−1) 重叠；GU 超前受 h bank 数限制（最多超前 D 一个 GU）。
- **双缓冲**：2 个 h bank（D(p) 读 h(p) 时 h(p+1) 到达）、2 个 y bank（step s 排放时 step s+1 累加）、入口双 bank（step 间流水不排空）。
- R = 4（每 pass 4 token/lane）；`B_MAX` ≤ 64（受入口/y bank 容量限制，model_support §5.8）。
- 相位局部 bias：D 前从 RRAM 读 BF16 bias 进 bias 上下文（M18）；相位流水开销假设 OVERHEAD 16 / STEP_EDGE 0（M17）。

## 6. Tile 微架构与算术契约（architecture §4 + data_bus §9 + arith_cells）★

### 6.1 数据通路总览

RRAM 1024b 字 → **dec**（解码 + scale 保持寄存器）→ **dot32**（8 列 × R lane = 32 单元/tile）→ **sclap** → **fcomb 7a**（最终 RF 累加，80 列 × R lane FP32 RF）→ GU 出口经 **act**（SwiGLU）+ bf16 cast → h 上行；h 到达时经 **quant**（FP8 块量化）存 h buffer；D 出口经 **fcomb 7b**（epi + yadd）入 y bank → Y_UP。

- MAC 阵列 `DOT_UNITS` = 8 列 × R=4 = 32 单元（FP4/INT4 字 8 列、FP8 字 4 列用 16 单元、BF16 字 2 列用 8 单元）。
- tag {phase, sweep, k-block, column, lane} 全程携带到 RF（data_bus §9.1 前递/HAZARD 依据）。

### 6.2 延迟预算（arith_cells §9，`pass_sched_sim.Pipeline`）

| 参数 | 值 | 组成（P5-1） |
|---|---:|---|
| `rram_lat` | 1 | RRAM 读口（范围 1..min(4,mac_fill)） |
| `mac_fill` | 4 | START→首个字消费（≥ RRAM_LAT） |
| `mac_drain` | 4 | = DEC_LAT 1 + DOT_LAT 2 + SCALE_LAT 1 + RFADD_LAT 1；末字消费→最终 RF 有效 = 1+mac_drain = 5 |
| `activation` | 4 | ACT_LAT（内部自由分拍） |
| `quantizer` | 4 | QUANT_LAT |
| `tile_y_lat` | 1 | y 读；BF16 cast 组合 |
| （未建模） | — | D commit = EPI_LAT 1 + YADD_LAT 1，与下相位重叠（P3-11） |

> **重分拍规则**：cell 实现可重分拍，但每个被建模的**和**必须不变；改变和值需重跑 `pass_sched_sim.py --check`。
> Tile_eval rev1 的 5 级（E0 采样→E4 提交，II=1）满足 mac_drain=4；rev2（21 级）/rev3（36 级）把 drain 加深到 20/35，属于改变和值，需按此规则重新对账。

### 6.3 算术单元契约（arith_cells §2–§8）

通用约定：FP32 = IEEE binary32，**每次运算单次 RNE，保留 subnormal（无 FTZ）**，溢出→±inf；不允许 FMA 替代两次舍入；元素打包小端（元素 i 宽 w 在 word bits [i·w,(i+1)·w)）；所有操作数解码后**精确**映射为 BF16 位型（无解码舍入）；全部单元在 `core_clk` 全流水，`in_valid/out_valid` **无反压**（锁步：任何 stall 都是全局的）。

| 单元 | 端口要点 | 参考语义 | 延迟 |
|---|---|---|---:|
| **dec** 解码 | in_word 1024b, in_kind(0 权重/1 scale/2 bias), wfmt → out_w 256×16 BF16 码（元素序 = col·32+k）, out_s（UE8M0 8b/BF16 16b/FP32 32b 条目）, out_ncols(8/4/2), err_nan | E2M1：e=0→m·0.5 否则 (1+m/2)·2^(e−1)；E4M3：e=0→m·2^-9 否则 (1+m/8)·2^(e−7)，e=15&m=7 为 NaN；INT4 补码 −8..7；BF16 位型不变；UE8M0 = 2^(code−127)，0xFF→按 127 处理 + NUMERIC。吞吐 1 字/拍（256 FP4 / 128 FP8 / 64 BF16 权重，或 128 UE8M0 / 64 BF16 / 32 FP32 scale） | 1 |
| **dot32** MAC lane | 每 (列,lane) 单元：w[32]×16b（解码后 BF16 码）、a[32]×8b（E4M3 码）、tag → out_p FP32 | **P5-2(b)**：`p = RNE_fp32(Σ w[k]·a[k])`——积精确、和精确、**仅一次 RNE**；精确 0→+0.0；tiny 保 subnormal；溢出→±inf；**顺序无关**（可用任意加法树）。定点化提示：FP4/FP8/INT4 × E4M3 的积是 2^-18 整数倍且 |积|<2^18 → 32 项和 <2^23，**42-bit 补码累加器精确**；BF16 权重需 285-bit 级更宽累加器。填充 k 用 a=0.0/scale=1.0。吞吐 1 部分和/单元/拍 | 2 |
| **sclap** scale 施加 | p + a_scale_e(UE8M0 指数) + sfmt + w_scale（保持寄存器；128-k scale 复用 4 个 k-block）→ out_q | UE8M0：纯指数缩放，等价 p·2^(a_e−127)·2^(w_e−127)（无舍入）；**BF16/FP32 权重 scale：两次舍入**——先 `RNE(p·2^a_scale)` 再 `RNE(·scale)`（保持 rev1 语义） | 1 |
| **fcomb 7a** RF 累加 | q + rf_rd（扫首 k-block 时 +0.0）→ rf_wr_en/rf_wr | `total[col] = fp32(total[col] + q)`，按 k-block 流序；前递解决同 entry 背靠背更新（data_bus §9.1，HAZARD 错误位） | 1 |
| **act** 激活（泛化 SwiGLU） | GU 和 s（FP32）→ h BF16 | V4.1 clamp 是特例。参考：`v = fp32(alpha·s)`；`g = s<0 ? fp32(exp2(g_lo·s+g_hi)) : 1`；softclip `sc(x) = fp32(beta·x + tanh(u_lo·x+u_hi)·u_off)`（beta=0 旁路）；`u = fp32(u_off + sc(s))`；`h = bf16(fp32(u·g·v))`。exp/tanh 允许 ±2 FP32 ULP（P5-3），h 在 BF16 cast 后比较、仅参考值距 BF16 舍入边界 ≤2 ULP 处允许 1 BF16 ULP 差 | 4 |
| **quant** h 量化 | 32 个 BF16 h/拍 → FP8 E4M3 + 每 32 块 UE8M0 scale | `amax = max(max_j|h[j]|, fp32(1e-4))`；`e = ceil(log2(amax/448))`，免除法：A=1.f·2^E 时 f≤0.75 → e=E−8 否则 E−7；`q[j] = E4M3(h[j]/2^e)`（最近偶 code，|x|>448→448，−0→0x80）；`se = e+127 ∈ [105,247]` 永不达 0xFF。非有限 h：块 scale 码 247、±inf→±448、NaN→0 + NUMERIC | 4 |
| **fcomb 7b** D 尾声 + y 写 | d[8 列] + b[8]（BF16 down bias，非 CMD first 强制 +0.0）+ w（BF16 lane 权重，无则 1.0）+ wplace_h/vacc/vsnap + y_old → y_new | h 放置（WPLACE=h）：`v = fp32(d + fp32(w·b)); t = vacc ? v : bf16(v)`；y 放置：`v = fp32(d + b); t = fp32(w·(vacc ? v : bf16(v)))`；`y_new = vsnap ? fp32(y_old + t) : fp32(+0.0 + t)`（−0 规整为 +0，P5-4）。吞吐 8 列/lane/拍 | EPI 1 + YADD 1 |
| **bf16c** BF16 cast | x FP32 → y 16b | `y = (x_bits + 0x7FFF + x_bits[16])[31:16]`（RNE）；±inf 保持；超 BF16 最大有限值→±inf；NaN 保持。用在 GU bias 边界、h 输出、VACC_FP32=0 的 D 尾声、BF16 Y_UP | 0（组合） |

### 6.4 数值契约要点（architecture §4.4 + arith_cells §9）

- dot32 部分和：精确积 + 精确和 + 单次 RNE（P5-2(b)，2026-10-07 用户决定）；求和顺序无关。
- sclap 的 BF16/FP32 权重 scale 是**两次舍入**（先移位 RNE 后乘 RNE）——不是单次；UE8M0 是纯指数运算无舍入。
- RF 累加是 FP32 逐 k-block 加（流序）；D 尾声按 fcomb 7b 的 cast 顺序。
- 越界码：E4M3 0x7F/0xFF→+0.0；UE8M0 0xFF→按 127（×1）；均置 `ERR_STATUS.NUMERIC`；FP32 溢出/inf/NaN 按 IEEE 传播、不钳位。
- 无 FTZ；−0 语义显式规定（P5-4：V_snap=0 写入存 `+0.0 + t`）。

### 6.5 tile 存储形态（data_bus §9.5 / chip_arch §9）

| 项 | 容量/规则 |
|---|---|
| x FIFO | 8,256 B（128 × 64 B 条目：64 k × 8 token FP8） |
| h buffer | 19,008 B = 2 bank × 2304 × R FP8 E4M3 + 2 × 2304×R/32 × UE8M0 scale（FP8 存储 vs BF16 省 1.09 MiB/chip） |
| y 累加器 | 40,960 B = 2 bank × 80 列 × R token × FP32 |
| 累加 RF | 1,280 B = 80 列 × 4 lane × FP32（**Tile_eval 的 RF**） |
| 操作数 staging | 1,024 B = 2×R×64 B X 寄存器 + 2×R×64 B scale 寄存器（双缓冲，scale 组边界零停顿） |
| rpgm | 2 × 2 KiB ping-pong |
| D-commit buffer | 80×R FP32 = 1,280 B **flop**（每拍排一行 8 字 y，P3-11） |
| 合计 | 74,624 B/tile × 64 |

tile 内控制：命令槽 2 个 + 1 pending（第三 CMD 拒绝→CMD_ILLEGAL）；X/XS 弹出 ≤1 条/拍、按强制的 pass/lane/idx 顺序（X_ORDER）；h bank/D bank 所有权与 pass 绑定（H_BANK/Y_BANK）；RRAM 返回 tag/phase 校验（RRAM_TAG）；scale 字保持寄存器支持 128-k scale 跨 4 个 k-block 复用与 D 扫描边界复用。

### 6.6 tile 寄存器窗口（spec/regs/tile.json；APB-BUS + t×4 KiB，tile 自身 0x0–0x3FF；广播写 = tile 0x7F；0x400–0xFFF 为 rpgm）

| 偏移 | 寄存器 | 要点 |
|---|---|---|
| 0x000 | TILE_ID | ID[5:0]（=上行边带 src）、RRAM_LAT[11:8]、INIT_DONE[31] |
| 0x004 | TILE_STATUS | PHASE_BUSY / PHASE（0 GU，1 D，2 SCAN）/ CMD_SLOTS / HBANK_BUSY / H_READY / YBANK_OWNED / UP_PENDING / XFIFO_LEVEL / CUR_PASS_ID |
| 0x008 | ERR_STATUS | 19 位 W1C：PROTO_TYPE, PROTO_CTRL, CMD_ILLEGAL, X_FIFO_OVF, X_ORDER, H_ORDER, H_BANK, Y_BANK, V0_DRAIN, DRAIN_ILLEGAL, UP_SLOT, UP_CREDIT, HAZARD, RRAM_TAG, BIAS, CTX_BUSY, REG_ADDR, RPGM, NUMERIC |
| 0x00C / 0x010 | ALARM_MASK / ERR_FIRST | ALARM/err 屏码；首错位快照 + PASS_ID |
| 0x03C–0x050 | CNT_* | RRAM 返回、UP_PKT、UP_CRD_STALL、Y_YIELD、SYNC1、CTRL 计数器 |
| 0x080–0x0A0 | DBG_CMD[2] / DBG_HBANK / DBG_YBANK_STEP[2] / DBG_V[4] | 命令槽、h bank 属主、y bank step_id、V[2][64] 位图快照 |
| 0x100 / 0x180 | CTX0/1_CLASS_RECORD[16] | 64 B 类记录镜像（与 hub_tables SLOT.CLS 布局一致；context loader 17 写中的前 16） |
| 0x140 / 0x1C0 | CTX0/1_VISIT_MODE | EP_PARTIAL[0]、PARTIAL_Y_FMT[1]（0 BF16 / 1 FP32 / 3 EP；2 非法）；RUN 期间拒绝 APB 写 |
| 0x200–0x300 | REMAP_FROM[32] / REMAP_TO[32] / REMAP_CTRL | 可选坏行重映射（firmware 拥有；EN=1 时 +1 读延迟） |

## 7. 权重格式与 RRAM 存储布局（chip_arch §5.6.1/§6.2a，arith_cells §2）

### 7.1 六种合法 (WFMT, SFMT) 组合

| WFMT | 权重 | SFMT / SBLK | 一个 scale 字后的权重字数 | scale 条目/字 | 每字列数 |
|---|---|---|---:|---:|---:|
| 0 fp4 | E2M1 | UE8M0 / 32 k | 16 | 128 | 8 |
| 1 fp8 | E4M3 | UE8M0 / 32 k | 32 | 128 | 4 |
| 2 fp8-f32 | E4M3 | FP32 / 128 k | 32 | 32 | 4 |
| 3 fp8-bf16 | E4M3 | BF16 / 128 k | 64 | 64 | 4 |
| 4 int4 | 有符号 INT4 | BF16 / 32 k | 8 | 64 | 8 |
| 5 bf16 | BF16 | 无 | — | — | 2 |

- WFMT 枚举顺序固定：fp4, fp8, fp8-f32, fp8-bf16, int4, bf16；SFMT：UE8M0/BF16/FP32/none；仅上表 6 个组合合法。**activation 恒为 FP8 E4M3 + 每 32 k 一个 UE8M0 scale**（x 的 XS flit，160 scale/token）。
- 32-k 格式：scale 条目按读序展平（k-block 先、列后，列最快）打包进 1024b scale 字，**先于**其覆盖的权重字发出；scale 字可跨连续 k 行。128-k 格式：每列组 scale 字属于唯一 128-k 块，首发于其权重前，保持供 4 个 32-k 行复用（scale 保持寄存器）。
- 字内 k 在列内递增、列随后；tile 列 j ↔ 逻辑列 t·C+j；h 索引 = t·C_I+j（与 H flit 顺序一致）。
- D 读：H_COLS ≤ 80 一次 k-major 扫描；>80（≤128）时 32-k 格式 80+余量、128-k 格式 64+余量两次扫描；边界 scale 字保持在寄存器跨扫描复用。
- 填充权重/scale 为 0；短组只含实际覆盖的权重字。
- **bias 在 scale 组之外**：BF16 gate bias、up bias、down bias 依 tile 列序；`bias_words = ceil(2×(2×ceil(I_V/64)+H_COLS)/128)`（BIAS_EN 时）；仅虚专家 0 有非零 down bias。

### 7.2 类区域（region）布局

- 每个使能类在 64 个 area 各占一个互不重叠 region；几何与填充字数跨 area 相同。
- 虚拟记录 = GU → D → bias 字；`BIAS_OFFSET = GU_words + D_words`；`EXPERT_STRIDE = BIAS_OFFSET + bias_words`；本地实专家 e 的虚块 v 起始 `RRAM_BASE + (e×VSPLIT + v)×EXPERT_STRIDE`（word = 128 B）。
- area 0 固定 65,536 B 元数据区：目录（177 × 32 B 记录）、激活 visit/class 记录、EP 配方（64 × 16 B）。
- 64 B 类记录字段：几何 8 B（H, H_KB=ceil(H/32), H_COLS=ceil(H/64), I_V 四个 u16）；格式 4 B（WFMT[2:0], SFMT[4:3], SBLK_128[5], BIAS_EN[6], WPLACE[7]=0 h/1 y, VACC_FP32[8]）；扩展 4 B（VSPLIT, N_LOCAL u16）；地址 16 B（RRAM_BASE, EXPERT_STRIDE, BIAS_OFFSET, CLASS_WORDS 四个 u32 字数/偏移）；激活参数 32 B（alpha, g_lo, g_hi, u_lo, u_hi, u_off, beta_g, beta_u 八个 FP32，beta=0 旁路 softclip）。

## 8. Hub（architecture §5 + chip_arch §5.6 + data_bus §8）

- 存储：入口缓冲（2 bank）、2 × 18,432 B BF16 h 装配、2 × 10 KiB 出口缓冲、work list；hub 合计 753,664 B。
- **visit 表**：128 硬件槽（激活深度 64/128 可选，复位 64），每槽 256 B 步长 = 32 B 头 + 2 × 64 B 类记录（第 3 类窗口保留）。头字段：LOGICAL_LAYER / VISIT_KIND / CLASS_MASK / GENERATION / TOPK / N_SHARED / SHARED_GATE_EN / HEADER_BYTES(32/64/96 B) / RECORD_BYTES / OUTPUT_TOKEN_BYTES / B_MAX / EP_MAP_ID / REGION_FIRST / EP_PARTIAL / PARTIAL_Y_FMT。RUN 期间不可重构（TABLE_VALID，stopped-PGM 才能写）。
- 微批入口：32 B 头（layer slot、step id、token 数、每 token 输出长、记录长、条目数、queue epoch 等）+ n_tokens × RECORD_BYTES 记录；记录 = 路由头 + FP8 x + UE8M0 scale（`RECORD_BYTES = H + ceil(H/32) + header`）。准入检查链（data_bus §8.1）→ 状态码 0x05–0x0B。
- HDMA↔hub：4 项 step tag 表（HD_TAG）；hub 不持 host 地址；单条有序 72 b `hub2hdma` FIFO（EGR_PIECE / STEP_DONE / STEP_REJECT）；hub 门铃页在 AXI 0x00_2018_0000。
- EP（宽专家并行）：每虚 pass 的部分 y 以 BF16/FP32 输出（PARTIAL_Y_FMT），GPU 归约 FP32；EP 配方 flop 保存于 hub（64 × 16 B，窗口 0x20000）。
- CTX：每 tile 2 个执行上下文（CTX0/1，CTRL flit 加载 17 写），支持 visit 重叠而无需 128 份完整 tile 表；复用需等所有 pending CMD 锁存。
- 大输出用分段 DMA（DRAIN 列扫 + egress 分段），SRAM 固定（M8）。

## 9. RRAM 编程路径（chip_arch §6，离线、无速度要求 D8）

- 流：HDMA PGM 队列（64 流表 {host_addr, bytes_left}，2 KiB chunk，≤8 在飞）→ **PGM hub**（AXI slave，64 个每 area 孔径 + 16 KB staging + credit 表）→ `PGM` flit 经广播树下发 → 每 tile 内 **rpgm**（2 × 2 KiB ping-pong + 简化 SPI master + 页序列器，紧邻该 area 的 SPI bond pad，走线 ~100 µm）→ 编程其 RRAM area。
- 校验：CRC32C `SCAN`（tile 经 1024b 读口回读 CRC），113 MB 层镜像 ~0.9 ms（SPI 回读 ~20 s）；每类 region 64 个 CRC。
- 停止/中止：PGM hub 拥有 stop/abort FSM（drain/freeze/fence）；`pgm_busy` / `pgm_unsafe`（MACRO_UNSAFE 粘滞）经 SYNC 上行；编程与读取绝不并发（RUN 冻结 PGM 队列）。
- 冷启动：校验元数据（area 0）→ 恢复 hub 表与 EP map → SCAN 全部类 region → RUN 需有效 CRC/几何/映射/region 互不重叠；溢出元数据镜像拒绝。

## 10. SRAM / 面积总账（chip_arch §9）

| 块 | 大小 |
|---|---:|
| Tiles：74,624 B × 64（x FIFO 8,256 + h buffer 19,008 + y acc 40,960 + RF 1,280 + rpgm 4,096 + staging 1,024） | 4,775,936 B (4.55 MiB) |
| Hub：入口 / h 装配 / 出口 / work list | 753,664 B (0.72 MiB) |
| Tiles：D-commit flop（80×R FP32/tile，P3-11） | 81,920 B (80 KiB) |
| PGM hub staging | 16 KiB |
| RISC-V ITCM + DTCM + ROM | 272 KiB |
| MBOX / HDMA 描述符 cache / PCIe 缓冲 | ~48 KiB |
| **芯片合计** | **~5,955,584 B (~5.68 MiB)** |

## 11. 通用模型支持（model_support.md）

- 三类层：routed / shared / dense；VSPLIT 虚拟专家展开（I > 2304 或 dense FFN）；每层每芯 N 连续层或 c 芯/超大层（EP）。
- ACT 泛化（八个 FP32 寄存器）覆盖 V4.1 SwiGLU clamp、gpt-oss softclip 等；专家 bias（gate/up/down BF16，仅虚专家 0 有 down bias）；路由权重/共享门/latent MoE/残差流各有规则。
- 预设表（§5.1）节选：deepseek-v4.1-flash（r=fp4, s=fp8，7.256 GB/层，40 芯，user 54.28 tok/s 上限，76,454 batch tok/s/chip）、kimi-k3（15.793 GB，185 芯）、gpt-oss-120b（1.825 GB，8 芯，106 tok/s）等 20+ 模型。

## 12. 与 Tile_eval RTL 的映射

**Tile_eval（规格 `RTL-TILE-PE-001`）实现的范围** = 本架构 tile 计算核的 MAC/RF 部分：

| 架构组件 | Tile_eval 对应 | 状态 |
|---|---|---|
| dec 单元（DEC_LAT=1） | `decode_weight`（pe*_pkg）+ 权重解包/activation 掩码（E1） | ✅ 已实现（位精确） |
| dot32（DOT_LAT=2，P5-2(b) 精确和 + 单 RNE，42/285-bit 定点） | `pe2/pe3_dot32`（CSA 树 + 定点累加 + 单次 pack_round，QUANTUM=-18/-142） | ✅ 已实现 |
| sclap（SCALE_LAT=1；UE8M0 指数缩放；BF16/FP32 两次舍入） | `pe2/pe3_scale`（shift + mul 级联，fmt0/1/5 bypass） | ✅ 已实现 |
| fcomb 7a RF 累加（RFADD_LAT=1，80×4 FP32 RF，首块 +0.0） | `tile_pe_v2/v3` 的 RF + `pe*_add` + occupied 冒险表 | ✅ 已实现（first_block≈首块 +0.0 旁路） |
| 顶层接口（1024b 权重字 / 32 FP8 激活 / scale / 掩码 / tag） | `tile_pe_v2/v3` 端口 | ✅（含 in_ready 反压） |
| act（SwiGLU）/ quant（h 量化） | — | ❌ 首阶段明确不做 |
| X FIFO / staging、h/y bank、CMD/CTRL/总线协议、RRAM 调度、rpgm、bias | — | ❌ 不做 |
| 错误模型（ERR_STATUS.NUMERIC 等） | errors[0]（数据错：权重码 127 / ascale 255 / activation 保留码）+ errors[1]（协议错：fmt>5 / 列越界 / mask=0），error_sticky | ✅ 简化子集 |

**流水级差异（重要）**：架构预算 mac_drain = 4（DEC 1 + DOT 2 + SCALE 1 + RFADD 1；末字→最终 RF 5 拍）；Tile_eval rev1 = 5 级（E0→E4，II=1）匹配；**rev2 = 21 级、rev3 = 36 级**改变了该和。arith_cells §9 要求重分拍保持被建模和值不变，否则需重跑 `pass_sched_sim.py --check` 更新性能模型。同地址再接受间隔 = 流水深度 + 1（rev2 E21 / rev3 E36），架构侧对应 data_bus §9.1 的最终 RF 前递/HAZARD 规则，在 Tile_eval 中以保守占用表实现（依赖吞吐换正确性；独立目的列仍可每拍 1 请求）。

**数值不变式（rev1/2/3 共同遵守，与本摘要 §6.3/§6.4 一一对应）**：六格式解码精确（无解码舍入）、FP8 E4M3 activation 固定、dot32 = 精确积 + 精确和 + 单 RNE（42-bit @2^-18 / 285-bit @2^-142 定点累加器，即 arith_cells §3 提示的实现）、UE8M0 纯指数缩放、BF16/FP32 权重 scale 两次舍入（先 shift 后乘）、FP32 逐次 RNE、subnormal 保留无 FTZ、±inf/NaN 按 IEEE 传播、−0 规则、越界码替换 + 错误标志。

---

*整理日期：2026-10-31；来源文档版本见文首表格。若上游 spec 更版（v0.12/v0.9/v0.2/v0.3/v0.9），以原文为准。*






