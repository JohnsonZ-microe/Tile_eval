# Rev4 Tile 审计报告

审计快照：20261031T104748Z（2026-10-31，Asia/Shanghai）

## 结论

19项Python测试通过，但存在golden遗漏矩阵计算、RTL编译阻塞及协议/流水问题；不能标记Rev4已验证。

本次审阅所有29个实现/验证/脚本文件及5个配套文档（ROM按内容校验）。未改变RTL、testbench、模型或原运行脚本。所有静态发现不冒充HDL编译/仿真证据。未声称穷尽所有bug。

## 已执行证据

- `python_tests.log`：现有19项Python单元测试，exit 0。
- `checks.json`：只读探针、工具可用性、冻结依赖和历史manifest哈希比对。
- `source_hashes.json`：29个被审计实现文件的当前SHA-256；检查前后不变。
- `verify.py`：可复运行审计探针；仅将新日志写入本目录。哈希匹配只是版本证据，不是功能正确证明。
- 全1 FP4×FP8 dot32：期望0x42000000，golden返回0。
- sigmoid(-101)：当前0，独立host-double→FP32为0x0000000a；需后续高精度最终确认。
- `fp32_to_bf16(0x7f800001)`当前得到infinity 0x7f80，NaN类别丢失。
- 本地未发现VCS/DC/Verilator/Icarus；无HDL执行，无远端任务。当前历史local manifest所有29项哈希匹配。

## 时序统一口径

以请求在E0上升沿接受为起点：staging在E1沿后输出，scheduler最早E2采样；RRAM在E2沿后输出，scheduler最早E3采样。LAT=2/3的命名包含采样口径，不能仅凭常量差认定多一拍。
PE边界合同为E0接受、E35沿后提交、同元素最早E36重接收。后处理和队列等待不属于固定PE延迟。

## 问题清单

### R4-001 · P0 · Tile golden 没有执行矩阵累加

分类：已确认不一致；模块：model

触发/证据：TileRef.run_phase 组装 activations/scale 后直接结束循环，未调用 ArrayReference 更新 RF。

影响：GU/D 期望结果不依赖真实矩阵乘积；现有 12 场景生成成功不能证明计算正确。

建议：补齐 oracle 调用后重新生成所有向量；本次不修改。

验收：全 1 dot32 应得到 FP32 32（0x42000000），目前探针得到 0；更换权重必须改变输出。

验证状态：静态源码审计；除明确列出的 Python 探针外，尚无 HDL 编译或 VCS 动态复现。

- `Tile_eval/rev4/model/tile_reference.py:393` · SHA-256 `e409d758170993977703c15ce22e24536941453adb64d5eec5a97853144e6c9f`
- `Tile_eval/rev4/model/test_tile_reference.py:84` · SHA-256 `329f968d76c970463977fb4ba3155c0b28b65703845214342b1a764a9a63fc2a`

### R4-002 · P0 · 计算模块引用未定义符号

分类：已确认不一致；模块：scheduler, act

触发/证据：filelist 中找不到 K_GU、K_D 和 fp32_clamp 的定义。

影响：当前源码存在编译阻塞；需要 VCS 给出正式诊断，不能宣称 RTL 已通过。

建议：明确常量和 clamp 函数来源，修复后编译全部 tops。

验收：所有 filelist 模块及两个 testbench 编译成功，无未解析标识符。

验证状态：静态源码审计；除明确列出的 Python 探针外，尚无 HDL 编译或 VCS 动态复现。

- `Tile_eval/rev4/rtl/pe4_sched.sv:187` · SHA-256 `c0bfa68a93b1e4a919aeffd94776eecc6d10a210640859cebf2ac18747db37bc`
- `Tile_eval/rev4/rtl/pe4_act.sv:108` · SHA-256 `ea32b209cade9453ac97e3f552c9714383cc60a00ce9d41aa502895e10f12601`

### R4-003 · P0 · ACT 的 vpipe 类型与赋值不兼容；Tile bench 嵌套 always

分类：已确认不一致；模块：act, tb

触发/证据：vpipe 声明为 16 个 16-bit unpacked 元素却按 packed shift 使用；tb_tile 的 initial 内出现 always。

影响：类型/语法层面阻断编译，不能将 Python 测试代替 elaboration。

建议：修正 valid 数据类型和 testbench 进程层级。

验收：VCS 编译及 valid 移位定向测试通过。

验证状态：静态源码审计；除明确列出的 Python 探针外，尚无 HDL 编译或 VCS 动态复现。

- `Tile_eval/rev4/rtl/pe4_act.sv:66` · SHA-256 `ea32b209cade9453ac97e3f552c9714383cc60a00ce9d41aa502895e10f12601`
- `Tile_eval/rev4/tb/tb_tile_v4.sv:131` · SHA-256 `8ccc0a6f4f56b405d9d0f44d0762e7e50e36f7917179dad325b49a91a5f10fcd`

### R4-004 · P0 · 8 列计数被 3-bit 截断为零

分类：已确认不一致；模块：scheduler

触发/证据：classp_t 和 rq_t 的 ncols 为 [2:0]，r.ncols=3'(8)。

影响：FP4/INT4 列基址、列掩码和 D ngroups 除法失效。

建议：列数表示范围须容纳 8，并检查所有派生位宽。

验收：六格式列数为 8/4/4/4/8/2；无除零或零列事务。

验证状态：静态源码审计；除明确列出的 Python 探针外，尚无 HDL 编译或 VCS 动态复现。

- `Tile_eval/rev4/rtl/pe4_sched.sv:148` · SHA-256 `c0bfa68a93b1e4a919aeffd94776eecc6d10a210640859cebf2ac18747db37bc`
- `Tile_eval/rev4/rtl/pe4_sched.sv:166` · SHA-256 `c0bfa68a93b1e4a919aeffd94776eecc6d10a210640859cebf2ac18747db37bc`

### R4-005 · P0 · X FIFO 拼接宽度 534 bit，存储及解包按 533 bit

分类：已确认不一致；模块：bus

触发/证据：8+3+10+1+512=534；pass/lane/index 切片与拼接不一致。

影响：合法 X/XS 元数据在入队后变化，可能触发 X_ORDER 或供错 token。

建议：统一 entry typedef 和切片；同步容量表。

验收：pass=5,lane=2,idx=1 进出 FIFO 必须相等；当前整数探针解为 pass=10,lane=4。

验证状态：静态源码审计；除明确列出的 Python 探针外，尚无 HDL 编译或 VCS 动态复现。

- `Tile_eval/rev4/rtl/pe4_bus.sv:99` · SHA-256 `8cafd232c4f9ae45d7a522880b60aa53ca3c37acca50162bd922871cf3946704`
- `Tile_eval/rev4/rtl/pe4_bus.sv:114` · SHA-256 `8cafd232c4f9ae45d7a522880b60aa53ca3c37acca50162bd922871cf3946704`

### R4-006 · P0 · FIFO/队列计数与环指针不能正确同时推进

分类：已确认不一致；模块：bus, scheduler, top

触发/证据：fcount/rq_cnt/cap_cnt 在一个 always 中分别加减，后一个 NBA 覆盖前一个；rq_cons 是3-bit却直接索引4项；STATUS指针2-bit直接索引2项。

影响：并发 push/pop 时计数错误；多次周转后越界读取。

建议：合并 next-state 计数，按深度截取/回绕指针并做守恒断言。

验收：连续同时入出、至少3次绕回、满空边界无丢失/重复/越界。

验证状态：静态源码审计；除明确列出的 Python 探针外，尚无 HDL 编译或 VCS 动态复现。

- `Tile_eval/rev4/rtl/pe4_bus.sv:132` · SHA-256 `8cafd232c4f9ae45d7a522880b60aa53ca3c37acca50162bd922871cf3946704`
- `Tile_eval/rev4/rtl/pe4_sched.sv:329` · SHA-256 `c0bfa68a93b1e4a919aeffd94776eecc6d10a210640859cebf2ac18747db37bc`
- `Tile_eval/rev4/rtl/tile_ffn_v4.sv:345` · SHA-256 `998820560119269db6f84c9e79f0a81440e80ae6db5e954e477e07e5bbc392a6`

### R4-007 · P0 · valid 延迟了，运算数据未配套延迟

分类：已确认不一致；模块：fmul, quant

触发/证据：fmul 的 out_valid 经 v0/v1/v2，而结果读取最近 prod；quant 类似从最近 hq/tag_q 读取。

影响：连续不同事务时输出对应后续输入而非该 valid 的原事务。孤立单笔可能掩盖问题。

建议：为数据、特殊值和 tag 增加匹配级或统一 valid 深度。

验收：A/B/C 连续输入及随机空泡逐项比较，无串事务。

验证状态：静态源码审计；除明确列出的 Python 探针外，尚无 HDL 编译或 VCS 动态复现。

- `Tile_eval/rev4/rtl/pe4_fmul.sv:33` · SHA-256 `7c7705d34a92e1ecc955fe1486a25c904bb9f764bcae17ad70e9252027187a55`
- `Tile_eval/rev4/rtl/pe4_fmul.sv:121` · SHA-256 `7c7705d34a92e1ecc955fe1486a25c904bb9f764bcae17ad70e9252027187a55`
- `Tile_eval/rev4/rtl/pe4_quant.sv:66` · SHA-256 `c7ecf7d743fd081ea691881c4dfa1d29be0e585283aa3d5a33042b52734a6863`

### R4-008 · P1 · E4M3 编码负指数与 RNE 中点处理不等价

分类：已确认不一致；模块：quant

触发/证据：RTL 对 signed e 用 {1'b0,e} 扩展成正数；subnormal sticky 掩码包含 guard 位。

影响：负 scale 指数错误；偶数中点也可能上舍入。Python 采用正确 signed 整数和不含 guard 的 sticky，无法验证 RTL。

建议：修正符号扩展与 sticky 位范围。

验收：e=-22/-9 以及 subnormal 两侧和 tie-even 逐位对比。

验证状态：静态源码审计；除明确列出的 Python 探针外，尚无 HDL 编译或 VCS 动态复现。

- `Tile_eval/rev4/rtl/pe4_pkg.sv:118` · SHA-256 `7c45f4e011862fe65b908648e9132987c43d4bfb42a5a9555a5a2243cad47de7`
- `Tile_eval/rev4/rtl/pe4_pkg.sv:137` · SHA-256 `7c45f4e011862fe65b908648e9132987c43d4bfb42a5a9555a5a2243cad47de7`

### R4-009 · P1 · Sigmoid 对 x<-100 提前清零丢失 FP32 subnormal

分类：已确认不一致；模块：rom, model

触发/证据：生成器和 golden 同时使用 -100 截断且共用算法。

影响：例如 BF16 -101 的 FP32 sigmoid 仍非零；ROM 哈希一致不能证明 2 ULP 精度。

建议：使用独立高精度参考和正确下溢边界，重新冻结 ROM。

验收：负尾区穷举对比；-101 当前为0，独立 double->FP32 为0x0000000a（后续高精度确认）。

验证状态：静态源码审计；除明确列出的 Python 探针外，尚无 HDL 编译或 VCS 动态复现。

- `Tile_eval/rev4/scripts/gen_sigmoid_rom.py:37` · SHA-256 `657d7691faae160aa10f124e895878e23bea4500567781cd66aa734811d8c15b`
- `Tile_eval/rev4/model/tile_reference.py:98` · SHA-256 `e409d758170993977703c15ce22e24536941453adb64d5eec5a97853144e6c9f`

### R4-010 · P1 · 通用 BF16 cast 未分类 NaN

分类：已确认不一致；模块：act, yacc, model

触发/证据：fp32_to_bf16 只做整数加舍入。

影响：0x7f800001 会变为 BF16 infinity；NaN 分类丢失，Python 与 RTL 共同存在。

建议：在 cast 前显式处理 NaN/inf 并冻结规则。

验收：覆盖全部特殊类和低 payload NaN；NaN 保持 NaN。

验证状态：静态源码审计；除明确列出的 Python 探针外，尚无 HDL 编译或 VCS 动态复现。

- `Tile_eval/rev4/rtl/pe4_pkg.sv:79` · SHA-256 `7c45f4e011862fe65b908648e9132987c43d4bfb42a5a9555a5a2243cad47de7`
- `Tile_eval/rev4/model/tile_reference.py:61` · SHA-256 `e409d758170993977703c15ce22e24536941453adb64d5eec5a97853144e6c9f`

### R4-011 · P0 · 仅为最后 k-block 入 capture 队列，却消费每个 PE 输出

分类：已确认不一致；模块：scheduler, pe

触发/证据：cap_q 只在 head.kb==head.nkb-1 时入队；所有 pe_out_valid 都出队。

影响：普通中间部分和会触发 SNAPSHOT 错误或错取最后块描述符。

建议：用输出 tag/last-block 对齐捕获条件或每笔都带 capture 描述符。

验收：K>32 的所有中间提交均不误取最终捕获描述符。

验证状态：静态源码审计；除明确列出的 Python 探针外，尚无 HDL 编译或 VCS 动态复现。

- `Tile_eval/rev4/rtl/pe4_sched.sv:675` · SHA-256 `c0bfa68a93b1e4a919aeffd94776eecc6d10a210640859cebf2ac18747db37bc`
- `Tile_eval/rev4/rtl/pe4_sched.sv:697` · SHA-256 `c0bfa68a93b1e4a919aeffd94776eecc6d10a210640859cebf2ac18747db37bc`

### R4-012 · P0 · X/XS 期望序列状态未初始化且 XS index 校验错误

分类：已确认不一致；模块：scheduler, staging

触发/证据：exp_grp/exp_kind/exp_lane/exp_idx 未在 reset/新 pass 初始化；XS 比较使用 exp_idx_full 而不是 group。

影响：启动即未知状态；后续 XS group 被当作 X 索引。

建议：明确每 pass 初始化及 kind 对应 index。

验收：reset 后和连续两 pass 均按 XS/X 规定顺序接受。

验证状态：静态源码审计；除明确列出的 Python 探针外，尚无 HDL 编译或 VCS 动态复现。

- `Tile_eval/rev4/rtl/pe4_sched.sv:807` · SHA-256 `c0bfa68a93b1e4a919aeffd94776eecc6d10a210640859cebf2ac18747db37bc`
- `Tile_eval/rev4/rtl/pe4_sched.sv:872` · SHA-256 `c0bfa68a93b1e4a919aeffd94776eecc6d10a210640859cebf2ac18747db37bc`

### R4-013 · P1 · 操作数 ready 标记早于全部 token 到齐，保持寄存器缺少生命周期验证

分类：静态分析风险；模块：scheduler, staging

触发/证据：每弹出一 lane 就设置 x_popped/xs_popped；hold_v 按奇偶复用，CMD 接收会全清。

影响：多 token 下可提前读未写 lane；下一 CMD/预取可能覆盖在途 operand。

建议：用 per-lane 到齐和 kb/pass 标签管理 holds，验证覆盖和读取安全。

验收：1～4 token、阻塞 PE、连续两 bank、CMD 同拍注入仍保持 payload。

验证状态：静态源码审计；除明确列出的 Python 探针外，尚无 HDL 编译或 VCS 动态复现。

- `Tile_eval/rev4/rtl/pe4_sched.sv:816` · SHA-256 `c0bfa68a93b1e4a919aeffd94776eecc6d10a210640859cebf2ac18747db37bc`
- `Tile_eval/rev4/rtl/pe4_sched.sv:547` · SHA-256 `c0bfa68a93b1e4a919aeffd94776eecc6d10a210640859cebf2ac18747db37bc`

### R4-014 · P0 · H tag 拼接、解包和 bank 延迟不一致

分类：已确认不一致；模块：scheduler, hbuf, quant

触发/证据：{hsel,quant_lane,10-bit idx}=14 bit 写入13-bit tag；解包 lane 取[9:7]实际是 idx，写 bank 用当前 hsel。

影响：lane/bank 丢失或跨事务；多 token H 可能重复写 lane0。

建议：统一 tag typedef，将 bank/lane/index 与数据一起流水。

验收：交错 bank/lane、tag最大值和连续H正确写入唯一地址。

验证状态：静态源码审计；除明确列出的 Python 探针外，尚无 HDL 编译或 VCS 动态复现。

- `Tile_eval/rev4/rtl/pe4_sched.sv:905` · SHA-256 `c0bfa68a93b1e4a919aeffd94776eecc6d10a210640859cebf2ac18747db37bc`

### R4-015 · P1 · 非法 H 写仍送入数据 SRAM

分类：已确认不一致；模块：hbuf

触发/证据：wr_bad 仅阻止 lane_seen/hscale 更新，bank SRAM we 只检查 wr_valid/bank。

影响：重复或未拥有 bank 的写会污染已有数据，即使报错。wr_idx 也未局部检查范围。

建议：把合法性检查用于数据与元数据的同一个写使能。

验收：非法写前后已存数据不变，状态正确报错。

验证状态：静态源码审计；除明确列出的 Python 探针外，尚无 HDL 编译或 VCS 动态复现。

- `Tile_eval/rev4/rtl/pe4_hbuf.sv:71` · SHA-256 `df774a154d0af6a44916ca75224c3e407fc8d8f602f783ae74afc6f37ed3107d`
- `Tile_eval/rev4/rtl/pe4_hbuf.sv:123` · SHA-256 `df774a154d0af6a44916ca75224c3e407fc8d8f602f783ae74afc6f37ed3107d`

### R4-016 · P0 · ACT 收集窗口不能覆盖流式返回，权重/有效信号需重对齐

分类：已确认不一致；模块：act, scheduler

触发/证据：只在 P_ACTW 收集返回，但前36列发射期间已开始输出；act_in_valid 最后一列同拍被清零；wq独立18级与加法前段未对齐。

影响：丢首尾列或等待永远达不到36个返回，权重可能串事务。

建议：独立发射/接收计数并绑定身份；根据真实 pe3_add 7级重新画边沿表。

验收：36列输入/36列输出逐项一一对应，变化w可验证。

验证状态：静态源码审计；除明确列出的 Python 探针外，尚无 HDL 编译或 VCS 动态复现。

- `Tile_eval/rev4/rtl/pe4_sched.sv:753` · SHA-256 `c0bfa68a93b1e4a919aeffd94776eecc6d10a210640859cebf2ac18747db37bc`
- `Tile_eval/rev4/rtl/pe4_act.sv:71` · SHA-256 `ea32b209cade9453ac97e3f552c9714383cc60a00ce9d41aa502895e10f12601`

### R4-017 · P0 · y SRAM 行地址与规定的 slot*10+row 不一致

分类：已确认不一致；模块：yacc

触发/证据：commit 拼接 slot 和4-bit row，即slot*16；DRAIN 拼接7-bit row，即slot*128。

影响：读写不同地址，较大 slot 超过640行或截断。

建议：统一行地址函数并做边界断言。

验收：slot1,row0必须为10；slot63,row9必须为639，commit/drain相同。

验证状态：静态源码审计；除明确列出的 Python 探针外，尚无 HDL 编译或 VCS 动态复现。

- `Tile_eval/rev4/rtl/pe4_yacc.sv:172` · SHA-256 `66b34ba3ad533d047169c94f258352639cdf9ebe4d459c55716cf33b631907af`
- `Tile_eval/rev4/rtl/pe4_yacc.sv:265` · SHA-256 `66b34ba3ad533d047169c94f258352639cdf9ebe4d459c55716cf33b631907af`

### R4-018 · P0 · D 列使能仅4位；bias latch 每拍被清零

分类：已确认不一致；模块：scheduler, yacc

触发/证据：scheduler 的 yacc_load_cen[3:0] 被循环写8列；yacc 每拍清 bias_lat/db_lat，未保持到 RMW 完成。

影响：FP4/INT4后4列丢失；bias无法跨所有行稳定。

建议：保持8-bit列掩码并将bias context保存整个commit。

验收：8列非零数据及末4个bias列不同值，全部80列逐位验收。

验证状态：静态源码审计；除明确列出的 Python 探针外，尚无 HDL 编译或 VCS 动态复现。

- `Tile_eval/rev4/rtl/pe4_sched.sv:99` · SHA-256 `c0bfa68a93b1e4a919aeffd94776eecc6d10a210640859cebf2ac18747db37bc`
- `Tile_eval/rev4/rtl/pe4_yacc.sv:146` · SHA-256 `66b34ba3ad533d047169c94f258352639cdf9ebe4d459c55716cf33b631907af`
- `Tile_eval/rev4/rtl/pe4_sched.sv:385` · SHA-256 `c0bfa68a93b1e4a919aeffd94776eecc6d10a210640859cebf2ac18747db37bc`

### R4-019 · P0 · 上行 packet 锁定时未检查源 valid；DRAIN valid/read 不撤销

分类：已确认不一致；模块：bus, yacc

触发/证据：beat_fire 只判断 grant 和 credit；yb_valid、dre 在状态离开后未默认清零。

影响：Y 分段读期间会发送陈旧/重复数据；停顿不能保证正确。

建议：以当前源 valid 形成fire，所有请求采用明确脉冲/保持语义。

验收：Y包内多拍空泡和credit停止时不得额外发送，完成后valid清零。

验证状态：静态源码审计；除明确列出的 Python 探针外，尚无 HDL 编译或 VCS 动态复现。

- `Tile_eval/rev4/rtl/pe4_bus.sv:172` · SHA-256 `8cafd232c4f9ae45d7a522880b60aa53ca3c37acca50162bd922871cf3946704`
- `Tile_eval/rev4/rtl/pe4_yacc.sv:282` · SHA-256 `66b34ba3ad533d047169c94f258352639cdf9ebe4d459c55716cf33b631907af`

### R4-020 · P1 · 上行 sideband 宽度与标签采样错位

分类：已确认不一致；模块：bus, top

触发/证据：src 端口8-bit而协议src为7-bit；拼接变25-bit赋给24-bit。首拍tag/src使用上拍_q值。

影响：tag/last/nphit/segment位置错位，首包元数据过期。

建议：按协议宽度打包并与 payload 同笔采样。

验收：逐字段穷举和连续不同tag包首拍比较。

验证状态：静态源码审计；除明确列出的 Python 探针外，尚无 HDL 编译或 VCS 动态复现。

- `Tile_eval/rev4/rtl/pe4_bus.sv:198` · SHA-256 `8cafd232c4f9ae45d7a522880b60aa53ca3c37acca50162bd922871cf3946704`
- `Tile_eval/rev4/rtl/pe4_bus.sv:228` · SHA-256 `8cafd232c4f9ae45d7a522880b60aa53ca3c37acca50162bd922871cf3946704`

### R4-021 · P1 · CTX0 地址别名、CTRL target 未过滤、计数器含义不一致

分类：已确认不一致；模块：scheduler, top

触发/证据：CTX0用addr[4:2]仅访问8项；CTRL未检查目标；GU/D计数均在每次sync1增加，stall/yield输入常量0。

影响：上下文ACT参数被覆盖；多Tile写入目标错误；网页不能使用这些计数宣称性能实测。

建议：修正地址和目标校验，接入真实事件，分别统计GU/D。

验收：16个CTX词读写互异；非目标CTRL无效；计数与trace一一对应。

验证状态：静态源码审计；除明确列出的 Python 探针外，尚无 HDL 编译或 VCS 动态复现。

- `Tile_eval/rev4/rtl/pe4_sched.sv:1025` · SHA-256 `c0bfa68a93b1e4a919aeffd94776eecc6d10a210640859cebf2ac18747db37bc`
- `Tile_eval/rev4/rtl/tile_ffn_v4.sv:284` · SHA-256 `998820560119269db6f84c9e79f0a81440e80ae6db5e954e477e07e5bbc392a6`
- `Tile_eval/rev4/rtl/pe4_sched.sv:1007` · SHA-256 `c0bfa68a93b1e4a919aeffd94776eecc6d10a210640859cebf2ac18747db37bc`
- `Tile_eval/rev4/rtl/tile_ffn_v4.sv:270` · SHA-256 `998820560119269db6f84c9e79f0a81440e80ae6db5e954e477e07e5bbc392a6`

### R4-022 · P1 · 重叠调度和所有权尚不支持原文的无局部分叉保证

分类：静态分析风险；模块：scheduler, top, yacc

触发/证据：GU sync1与slot释放位于HUP末拍ready；slot1→slot0后rq携带的slot/wsh未统一迁移；commit buffer可被后续D加载。

影响：本地credit可能改变阶段进度；跨phase预取和commit存在覆盖风险。

建议：先以多实例和资源不变量验证，再决定锁存/准入/迁移策略。

验收：不同上行credit下阶段顺序一致、所有权不丢失、旧commit数据不被覆盖。

验证状态：静态源码审计；除明确列出的 Python 探针外，尚无 HDL 编译或 VCS 动态复现。

- `Tile_eval/rev4/rtl/pe4_sched.sv:771` · SHA-256 `c0bfa68a93b1e4a919aeffd94776eecc6d10a210640859cebf2ac18747db37bc`
- `Tile_eval/rev4/rtl/pe4_yacc.sv:148` · SHA-256 `66b34ba3ad533d047169c94f258352639cdf9ebe4d459c55716cf33b631907af`

### R4-023 · P0 · RRAM 向量文件丢失稀疏地址；DRAIN 字段与RTL不一致

分类：已确认不一致；模块：tb, model

触发/证据：image按sorted地址只输出值，但bench从地址0连续写；向量ybank<<7而RTL取ctrl_addr[6]。

影响：CMD base64等不能对应生成的权重；DRAIN选错bank；后几个场景slots>=64且golden不mask。

建议：生成明确地址或补齐空洞，统一协议packing和slot范围。

验收：读回每个专家base及边界word；DRAIN字段roundtrip；slots均0..63。

验证状态：静态源码审计；除明确列出的 Python 探针外，尚无 HDL 编译或 VCS 动态复现。

- `Tile_eval/rev4/model/vectors.py:300` · SHA-256 `0a24dd9a06bbc16220ac8a311d9d91cc31791bd0378aa92d935099656c1ca228`
- `Tile_eval/rev4/tb/tb_tile_v4.sv:105` · SHA-256 `8ccc0a6f4f56b405d9d0f44d0762e7e50e36f7917179dad325b49a91a5f10fcd`
- `Tile_eval/rev4/model/vectors.py:281` · SHA-256 `0a24dd9a06bbc16220ac8a311d9d91cc31791bd0378aa92d935099656c1ca228`

### R4-024 · P1 · 测试平台驱动/解析及完成条件不足

分类：测试覆盖缺口；模块：tb, model

触发/证据：math fscanf统一读取5列但FM/QU/SG长度不同；posedge驱动与DUT竞争；valid保持跨两拍；缺少输入输出计数守恒及延迟检查。

影响：错读向量或丢重复输出仍可能出现局部PASS；无法验证II=1。

建议：逐行解析、稳定驱动/采样相位、scoreboard逐笔计数+超时。

验收：每类向量计数完全匹配，空向量/截断/重复/缺失输出均失败。

验证状态：静态源码审计；除明确列出的 Python 探针外，尚无 HDL 编译或 VCS 动态复现。

- `Tile_eval/rev4/tb/tb_math_v4.sv:87` · SHA-256 `ae4c3fc7e2986a69e980443a72be715dd5fa76448c2a3855594adb49524a7d4c`
- `Tile_eval/rev4/tb/tb_math_v4.sv:129` · SHA-256 `ae4c3fc7e2986a69e980443a72be715dd5fa76448c2a3855594adb49524a7d4c`

### R4-025 · P1 · Tile 场景不是真实 GU→gather→D 闭环，错误期望不一致

分类：测试覆盖缺口；模块：tb, model

触发/证据：H由随机常量生成而非GU/gather结果；CMD/CTX/DRAIN按flit间隔发送，无阶段完成等待；错误检查只允许RPGM/CMD_ILLEGAL。

影响：测试不能证明端到端FFN；PGM实际还置UNSUPPORTED，合法测试中也可能引入NUMERIC。

建议：建立协议驱动外部gather模型，明确期望错误及等待事件。

验收：非零完整FFN参考对应所有Y；六格式×1..4token和多pass闭环通过。

验证状态：静态源码审计；除明确列出的 Python 探针外，尚无 HDL 编译或 VCS 动态复现。

- `Tile_eval/rev4/model/vectors.py:266` · SHA-256 `0a24dd9a06bbc16220ac8a311d9d91cc31791bd0378aa92d935099656c1ca228`
- `Tile_eval/rev4/tb/tb_tile_v4.sv:180` · SHA-256 `8ccc0a6f4f56b405d9d0f44d0762e7e50e36f7917179dad325b49a91a5f10fcd`

### R4-026 · P1 · 周期模型信用释放与 RTL 不同，不是已校准 cycle-accurate

分类：已确认不一致；模块：model, rram, scheduler

触发/证据：模型st.issued-st.consumed覆盖未消费返回；RTL pe4_rram outstanding在rd_valid返回被采样时减，另有4项RQ。

影响：0.75 words/cycle等模型结论不能直接归因于当前硬件；回压差异可超过±1拍。

建议：以同一事件trace校准issue/return/consume，独立统计两种信用。

验收：相同输入下每一事件周期、队列占用和计数匹配，不接受仅平均速率容差。

验证状态：静态源码审计；除明确列出的 Python 探针外，尚无 HDL 编译或 VCS 动态复现。

- `Tile_eval/rev4/model/tile_cycles.py:330` · SHA-256 `52e9ad94c7354dbfa0efcb1a071680de2066ab18f11ea7c886e7cad61ffdde44`
- `Tile_eval/rev4/rtl/pe4_sram.sv:129` · SHA-256 `04cc0297f4fe41624785e2ded8b08cb30a6847249316801177bc3ec7e9492ff9`

### R4-027 · P1 · 周期模型提前安排Y输出且超时未报失败

分类：已确认不一致；模块：model, yacc

触发/证据：_arm_dcommit在末行启动+1即可排Y，而该行尚未完成；_simulate达到max_cycles后仍返回report。

影响：finish_cycle可能先于最后写入；死锁可被报告成有限完成时间。

建议：完成事件依赖真实row write；超时必须raise/失败状态。

验收：强制阻塞时返回失败；所有Y均晚于对应commit和valid位发布。

验证状态：静态源码审计；除明确列出的 Python 探针外，尚无 HDL 编译或 VCS 动态复现。

- `Tile_eval/rev4/model/tile_cycles.py:431` · SHA-256 `52e9ad94c7354dbfa0efcb1a071680de2066ab18f11ea7c886e7cad61ffdde44`
- `Tile_eval/rev4/model/tile_cycles.py:239` · SHA-256 `52e9ad94c7354dbfa0efcb1a071680de2066ab18f11ea7c886e7cad61ffdde44`

### R4-028 · P2 · 容量及 ROM 摘要与源码不一致

分类：已确认不一致；模块：staging, rom

触发/证据：WIDTHS写X/XS各4096 B和各8宏；RTL各4个512-bit×2。部分文档ROM hash前缀仍dab74aaf。

影响：误导面积和版本归属；实际X/XS各512 B，总1024 B；当前ROM hash以证据清单为准。

建议：本次报告并列保留文档声明与源码推导，不修改旧文档。

验收：8个staging宏总1024 B；ROM 65536×32×4=1 MiB，哈希可重算。

验证状态：静态源码审计；除明确列出的 Python 探针外，尚无 HDL 编译或 VCS 动态复现。

- `Tile_eval/rev4/docs/WIDTHS.md:8` · SHA-256 `dc3ec44d71fa7981dcf2cafc1f1b764c88b3b593b2f54a46ceb1c4329fb8f85b`
- `Tile_eval/rev4/docs/SPEC.md:17` · SHA-256 `ef1b94ee322dad95c255f640dd4658ee65a5b76749c6ff40145e588bb430eb7a`

### R4-029 · P2 · 运行参数与实际行为不一致

分类：已确认不一致；模块：scripts

触发/证据：--suite未控制向量规模；WAVES=1未转--waves；DC_CORES只写settings而无set_host_options调用。

影响：smoke/full标签、VCD开关和16核声明不能代表实际执行。

建议：使入口参数可测试地影响行为，并记录实际工具版本/时长。

验收：stub工具验证参数传递；实际DC报告核设置；WAVES请求生成波形。

验证状态：静态源码审计；除明确列出的 Python 探针外，尚无 HDL 编译或 VCS 动态复现。

- `Tile_eval/rev4/scripts/run_vcs.sh:15` · SHA-256 `24b2bae4e6c9087825f3926d751c5268453943c6c987f6d2bacecc072a8f0021`
- `Tile_eval/rev4/syn/constraints.tcl:29` · SHA-256 `f558ebf22a8c6c02500bffbf2d12058c78ff1ea72023d214d505bb01b49e4291`
- `Tile_eval/rev4/scripts/run.py:48` · SHA-256 `f2b51970a490e92909684c6c63cd70178319464e36863b21d8a3b50c5f5b313b`

### R4-030 · P1 · 多驱动、未复位及未赋值控制信号需 elaboration 检查

分类：静态分析风险；模块：yacc, act, scheduler

触发/证据：yacc的re/raddr在两个always_ff写，vbit在commit与drain两进程写；ACT addg_v高4位未驱动但用于归约；部分输出未赋值。

影响：X传播、多驱动综合错误或时序不确定；单靠文本模块数扫描无法发现。

建议：逐信号单驱动/完整赋值检查；必要时拆分next-state。

验收：全部tops无多驱动、未连接功能输出和意外latch，复位无valid X。

验证状态：静态源码审计；除明确列出的 Python 探针外，尚无 HDL 编译或 VCS 动态复现。

- `Tile_eval/rev4/rtl/pe4_act.sv:54` · SHA-256 `ea32b209cade9453ac97e3f552c9714383cc60a00ce9d41aa502895e10f12601`
- `Tile_eval/rev4/rtl/pe4_yacc.sv:134` · SHA-256 `66b34ba3ad533d047169c94f258352639cdf9ebe4d459c55716cf33b631907af`

### R4-031 · P1 · VCS 编译/数值/协议回归未运行

分类：工具待验证；模块：top, scripts

触发/证据：本地未发现VCS/Verilator/Icarus；当前manifest仅Python通过。

影响：无法给出RTL运行成功结论；静态发现需后续编译确认。

建议：修复审计阻塞项后在已许可Linux环境运行交付脚本。

验收：bash scripts/run_vcs.sh --test all --suite full；编译/运行无错误、逐位比较及超时检查通过。

验证状态：静态源码审计；除明确列出的 Python 探针外，尚无 HDL 编译或 VCS 动态复现。

- `Tile_eval/rev4/docs/VALIDATION.md:15` · SHA-256 `4b5501cec362c18deb6c212d9cad8d0af337940027115c37bf91ab709a479102`

### R4-032 · P1 · DC 1 ns 及 SRAM/ROM 宏实现未验证

分类：工具待验证；模块：top, scripts, sram, rram, rom

触发/证据：宏替换点未绑定，DC默认空模块逻辑检查；无当前版本DC证据。

影响：不能报告实际硅面积、功耗或1GHz达标；黑盒边界无法证明存储路径收敛。

建议：提供宏模型/.db并审查黑盒保留，再执行setup/hold/未约束路径验收。

验收：同库预算下无时序违例且无非预期黑盒；面积单列SRAM/ROM，功耗另需活动文件。

验证状态：静态源码审计；除明确列出的 Python 探针外，尚无 HDL 编译或 VCS 动态复现。

- `Tile_eval/rev4/rtl/pe4_sram.sv:39` · SHA-256 `04cc0297f4fe41624785e2ded8b08cb30a6847249316801177bc3ec7e9492ff9`
- `Tile_eval/rev4/syn/run_dc.tcl:29` · SHA-256 `96bb8b12d7f6ec0e3506dbb99d096fd90f5f43c96962932b99b00a483a5f85f9`

### R4-033 · P0 · BF16 weight scale 放在高16位，与 PE 输入契约不符

分类：已确认不一致；模块：scheduler, model, pe

触发/证据：Rev4 将16-bit scale左移16；复用的 pe3_scale 对非FP32乘法取 weight_scale[15:0] 再拓宽。

影响：fp8-bf16/int4 scale进入PE后变为0。golden _wslot也作同样左移，且run_phase没有执行，因此原测试未暴露。

建议：按冻结PE槽位定义传递16-bit scale，加入非单位scale定向向量。

验收：BF16 scale=1/2/负值时，各格式结果与独立oracle一致。

验证状态：静态接口核查；尚无HDL动态验证。

- `Tile_eval/rev4/rtl/pe4_sched.sv:667` · SHA-256 `c0bfa68a93b1e4a919aeffd94776eecc6d10a210640859cebf2ac18747db37bc`
- `Tile_eval/rev4/model/tile_reference.py:390` · SHA-256 `e409d758170993977703c15ce22e24536941453adb64d5eec5a97853144e6c9f`

## 周期模型与 RTL 对照

|事件|RTL|模型|状态|
|---|---|---|---|
|issue|rram_req && rram_ready；保留RQ描述符|_issue：issued-consumed信用|结构性差异 R4-026|
|return|E0接受→E2沿后rd_valid→E3 scheduler可采样|ret=t+RRAM_LAT；可在同次_consume消费|返回/消费必须分开校准|
|operand|SRAM E1沿后返回，scheduler E2可采样|x_popped/h_ready flags|未逐拍建模SRAM holds，R4-013|
|accept|pe_in_valid && pe_in_ready|release[col]与pe_last_accept|PE合同相近，RTL组宽有错 R4-004|
|commit|PE接受E0→E35沿后输出；scheduler下一沿观察|commits=t+35；同tick触发后处理|消费边沿仍需对齐 R4-011|
|ACT|输入/加bias/ROM/三个乘法/输出链|ACT=24 + ACT_COLS=36|valid及数据对齐未成立 R4-016|
|y row|CRD/CWT握手加法+实际SRAM写|固定YACC_ROW=17|非严格cycle-accurate R4-027|
|release / SYNC|HUP last ready后GU sync；D trigger时release|_launcher/_arm_dcommit标retired|局部credit影响阶段等待 R4-022|
|counters|GU/D均随sync；部分stall常量0|分别计数，UP_PKT按packet|统计口径不等价 R4-021|

## 逐文件审阅清单

|文件|审阅范围|关联发现|SHA-256|
|---|---|---|---|
|`Tile_eval/rev4/rtl/pe4_act.sv`|全文静态审阅：接口、数据/valid、位宽、复位、状态和集成；未编译|R4-002, R4-003, R4-016, R4-030|`ea32b209cade9453ac97e3f552c9714383cc60a00ce9d41aa502895e10f12601`|
|`Tile_eval/rev4/rtl/pe4_blackbox.sv`|全文静态审阅：接口、数据/valid、位宽、复位、状态和集成；未编译|未独立列项；不代表形式验证通过|`5cf795b76ab46f5a444d40769ca62a900745077dc1978729aba811232c362bc6`|
|`Tile_eval/rev4/rtl/pe4_bus.sv`|全文静态审阅：接口、数据/valid、位宽、复位、状态和集成；未编译|R4-005, R4-006, R4-019, R4-020|`8cafd232c4f9ae45d7a522880b60aa53ca3c37acca50162bd922871cf3946704`|
|`Tile_eval/rev4/rtl/pe4_fmul.sv`|全文静态审阅：接口、数据/valid、位宽、复位、状态和集成；未编译|R4-007|`7c7705d34a92e1ecc955fe1486a25c904bb9f764bcae17ad70e9252027187a55`|
|`Tile_eval/rev4/rtl/pe4_hbuf.sv`|全文静态审阅：接口、数据/valid、位宽、复位、状态和集成；未编译|R4-015|`df774a154d0af6a44916ca75224c3e407fc8d8f602f783ae74afc6f37ed3107d`|
|`Tile_eval/rev4/rtl/pe4_pkg.sv`|全文静态审阅：接口、数据/valid、位宽、复位、状态和集成；未编译|R4-008, R4-010|`7c45f4e011862fe65b908648e9132987c43d4bfb42a5a9555a5a2243cad47de7`|
|`Tile_eval/rev4/rtl/pe4_probes.sv`|全文静态审阅：接口、数据/valid、位宽、复位、状态和集成；未编译|未独立列项；不代表形式验证通过|`6b6d778670a9314c77365c13b7dc2e18c940d0cf3d4bc957a1e35f985df5531e`|
|`Tile_eval/rev4/rtl/pe4_quant.sv`|全文静态审阅：接口、数据/valid、位宽、复位、状态和集成；未编译|R4-007|`c7ecf7d743fd081ea691881c4dfa1d29be0e585283aa3d5a33042b52734a6863`|
|`Tile_eval/rev4/rtl/pe4_sched.sv`|全文静态审阅：接口、数据/valid、位宽、复位、状态和集成；未编译|R4-002, R4-004, R4-006, R4-011, R4-012, R4-013, R4-014, R4-016, R4-018, R4-021, R4-022, R4-033|`c0bfa68a93b1e4a919aeffd94776eecc6d10a210640859cebf2ac18747db37bc`|
|`Tile_eval/rev4/rtl/pe4_sigmoid_rom.hex`|逐项与当前生成公式核对65536项 + 哈希；发现同源算法精度缺陷，不是独立验证|未独立列项；不代表形式验证通过|`5f4f3acca25368fc4aedcb6e106114d81ff9c8998846cf4be2882b0538a7172c`|
|`Tile_eval/rev4/rtl/pe4_sram.sv`|全文静态审阅：接口、数据/valid、位宽、复位、状态和集成；未编译|R4-026, R4-032|`04cc0297f4fe41624785e2ded8b08cb30a6847249316801177bc3ec7e9492ff9`|
|`Tile_eval/rev4/rtl/pe4_staging.sv`|全文静态审阅：接口、数据/valid、位宽、复位、状态和集成；未编译|未独立列项；不代表形式验证通过|`cfcd6015fdbb7ed79de243f07adad0d205a2433b885f3f695c5248baecf66bb8`|
|`Tile_eval/rev4/rtl/pe4_yacc.sv`|全文静态审阅：接口、数据/valid、位宽、复位、状态和集成；未编译|R4-017, R4-018, R4-019, R4-022, R4-030|`66b34ba3ad533d047169c94f258352639cdf9ebe4d459c55716cf33b631907af`|
|`Tile_eval/rev4/rtl/tile_ffn_v4.sv`|全文静态审阅：接口、数据/valid、位宽、复位、状态和集成；未编译|R4-006, R4-021|`998820560119269db6f84c9e79f0a81440e80ae6db5e954e477e07e5bbc392a6`|
|`Tile_eval/rev4/tb/tb_math_v4.sv`|全文静态审阅：驱动、解析、scoreboard、结束与错误条件；未执行SV|R4-024|`ae4c3fc7e2986a69e980443a72be715dd5fa76448c2a3855594adb49524a7d4c`|
|`Tile_eval/rev4/tb/tb_tile_v4.sv`|全文静态审阅：驱动、解析、scoreboard、结束与错误条件；未执行SV|R4-003, R4-023, R4-025|`8ccc0a6f4f56b405d9d0f44d0762e7e50e36f7917179dad325b49a91a5f10fcd`|
|`Tile_eval/rev4/model/test_tile_cycles.py`|全文审阅 + 现有测试执行；模型通过不等同RTL正确|未独立列项；不代表形式验证通过|`6769d5fae2f0b30e2ade4357f4d23d0c4b0ab8401fe7358033d506d7ab363c3f`|
|`Tile_eval/rev4/model/test_tile_reference.py`|全文审阅 + 现有测试执行；模型通过不等同RTL正确|R4-001|`329f968d76c970463977fb4ba3155c0b28b65703845214342b1a764a9a63fc2a`|
|`Tile_eval/rev4/model/tile_cycles.py`|全文审阅 + 现有测试执行；模型通过不等同RTL正确|R4-026, R4-027|`52e9ad94c7354dbfa0efcb1a071680de2066ab18f11ea7c886e7cad61ffdde44`|
|`Tile_eval/rev4/model/tile_reference.py`|全文审阅 + 现有测试执行；模型通过不等同RTL正确|R4-001, R4-009, R4-010, R4-033|`e409d758170993977703c15ce22e24536941453adb64d5eec5a97853144e6c9f`|
|`Tile_eval/rev4/model/vectors.py`|全文审阅 + 现有测试执行；模型通过不等同RTL正确|R4-023, R4-025|`0a24dd9a06bbc16220ac8a311d9d91cc31791bd0378aa92d935099656c1ca228`|
|`Tile_eval/rev4/scripts/gen_sigmoid_rom.py`|全文审阅参数、快照、工具与返回码；工具路径未实际执行|R4-009|`657d7691faae160aa10f124e895878e23bea4500567781cd66aa734811d8c15b`|
|`Tile_eval/rev4/scripts/rtl.f`|全文审阅参数、快照、工具与返回码；工具路径未实际执行|未独立列项；不代表形式验证通过|`0287e0840bf5d71ed3ef18c2a12d3a99a28892d8b7216fe76f212c35e83bd747`|
|`Tile_eval/rev4/scripts/run.py`|全文审阅参数、快照、工具与返回码；工具路径未实际执行|R4-029|`f2b51970a490e92909684c6c63cd70178319464e36863b21d8a3b50c5f5b313b`|
|`Tile_eval/rev4/scripts/run_vcs.sh`|全文审阅参数、快照、工具与返回码；工具路径未实际执行|R4-029|`24b2bae4e6c9087825f3926d751c5268453943c6c987f6d2bacecc072a8f0021`|
|`Tile_eval/rev4/scripts/summarize_dc.py`|全文审阅参数、快照、工具与返回码；工具路径未实际执行|未独立列项；不代表形式验证通过|`8ab67afc3cd25dd3003d69b805f6e98a8baa5f8ad24f5e72d4cf72fa98c5984b`|
|`Tile_eval/rev4/syn/constraints.tcl`|全文审阅约束/黑盒/编译/报告；未执行DC|R4-029|`f558ebf22a8c6c02500bffbf2d12058c78ff1ea72023d214d505bb01b49e4291`|
|`Tile_eval/rev4/syn/run_dc.sh`|全文审阅约束/黑盒/编译/报告；未执行DC|未独立列项；不代表形式验证通过|`17b69967c67f330dd384da0ada1ad09b3efc3e413d0e5e0056e0e98e5520ef49`|
|`Tile_eval/rev4/syn/run_dc.tcl`|全文审阅约束/黑盒/编译/报告；未执行DC|R4-032|`96bb8b12d7f6ec0e3506dbb99d096fd90f5f43c96962932b99b00a483a5f85f9`|
|`Tile_eval/rev4/docs/baseline.json`|文档/manifest与当前源码交叉核对；保留原文，不覆盖|未独立列项；不代表形式验证通过|`ef34c0ea0341887f7a4c0637c79ef546c0a65fbaae1a61b0e2aabf42d965e799`|
|`Tile_eval/rev4/docs/CYCLE_MODEL.md`|文档/manifest与当前源码交叉核对；保留原文，不覆盖|未独立列项；不代表形式验证通过|`8ad73e77943dbecd3d293e0ddbe4359f749a8e657ae36b07a2525ff878d3627b`|
|`Tile_eval/rev4/docs/SPEC.md`|文档/manifest与当前源码交叉核对；保留原文，不覆盖|R4-028|`ef1b94ee322dad95c255f640dd4658ee65a5b76749c6ff40145e588bb430eb7a`|
|`Tile_eval/rev4/docs/VALIDATION.md`|文档/manifest与当前源码交叉核对；保留原文，不覆盖|R4-031|`4b5501cec362c18deb6c212d9cad8d0af337940027115c37bf91ab709a479102`|
|`Tile_eval/rev4/docs/WIDTHS.md`|文档/manifest与当前源码交叉核对；保留原文，不覆盖|R4-028|`dc3ec44d71fa7981dcf2cafc1f1b764c88b3b593b2f54a46ceb1c4329fb8f85b`|

## 展示边界

网页展示当前源码声明与风险，不把存在连线当成已验证功能。所有Rev4模块端口在网页JSON/详情中列出；Rev3仅展示使用边界。文档称X/XS各4096 B，实际各512 B；FIFO当前533-bit声明为8528 B，而完整字段需534-bit（8544 B）。原文档不修改。

## 网页交付验收

- 路由：现有网站 `#/tensor/rev4`，位于 TensorCore 设计下；沿用导航，没有引入框架。
- `node tools/run-console-tests.mjs`：200项，199通过、1项原有平台相关测试跳过、0失败，退出码0。原始日志见 `node-tests.log`。
- `node tools/check-rev4-browser.mjs`：本地隔离静态预览，禁用API和外网请求；不启动远端任务。
- 浏览器检查1920/1440/1024桌面宽度、图形缩放、无模块/边标签重叠、筛选与展开、15个顶层端口、键盘Enter/Escape、焦点恢复、200ms动画、reduced-motion及路由切换；结果见 `web-checks.json`。
- 页面展示17个模块/流程分组、21个SV模块的386个端口、33条问题/待验证记录、34份文件哈希。
- 截图：`diagram-1440.png`、`detail-1440.png`、`page-1920.png`、`page-1440.png`、`page-1024.png`。
- 隔离预览未验证真实后台API/远端链路；不把网页检查或Python通过用于升级RTL、周期校准、时序和宏映射状态。

