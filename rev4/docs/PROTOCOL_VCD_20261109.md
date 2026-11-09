# Protocol VCD 与当前待验证事项

## 运行与波形

在服务器 Rev4 工程根目录运行：

```bash
bash scripts/run_vcs.sh --test protocol --suite full --seed 817 --waves
```

新 Products 运行目录产生 `protocol_v4.vcd`，层次为
`tb_protocol_v4.dut`。dump 从时间零开始，包含 testbench 与 DUT 层次内
可被 VCS 导出的信号。VCD 不承诺导出所有未打包 memory 元素。
未指定 `--waves` 且环境变量 WAVES 不为 1 时不生成波形。
`--test all --waves` 为 protocol 和 tile 分别产生不同文件。
manifest 保存仿真命令与实际生成的 VCD 文件名、字节数。

建议观察 dn_valid/dn_sideband、xfifo_pop/xfifo_level/xfifo_empty、
sync0、up_credit、up_valid/up_payload/up_sideband，以及 DUT credit、
active_valid；按 FIFO 填满、同时入出、绕回、credit 停止/恢复分段查看。
详细结果以 run_protocol.log 与逐拍 scoreboard 为准，波形不能替代 PASS。

## 已有结论与新版本边界

历史 full/all seed817 的 protocol 已 PASS：FIFO 728 项，上行430拍，
H115/Y150/STATUS165。三个 seed 的 full Tile 也已通过。
本补丁仅增加可选波形与运行记录，不修改计算 RTL、驱动刺激或比较规则。
但 testbench/脚本源码哈希已经变化：历史 PASS 只属于原快照，不能将
新增 dump 功能标为已在 VCS 验证。服务器需重新运行上述命令，确认
退出码0、同样的 protocol PASS、非空 VCD，并在 Verdi 确认 DUT 层次。

## 问题与待验证项（当前摘要）

| 范围 | 已有证据 | 剩余验证 |
|---|---|---|
| 原编译阻塞 R4-002/003 | 全专项编译运行；valid/空泡/复位专项通过 | 原缺陷关闭，不表示全部复位场景通过 |
| scale R4-033 | 1404 个 scale 向量通过 | 原缺陷关闭，不表示数值全集穷举 |
| FIFO/STATUS R4-006 | 满空、同时入出、绕回、回复与恢复通过 | 超容量 STATUS 请求处置规格复核 |
| 序列与生命周期 R4-012/013/022 | 串行 full 三 seed 通过 | 非法 XS、在途复位、双 CMD、slot/RQ/scale 迁移与广泛重叠 |
| Y 输出 R4-018/019/021 | 全 slot 遍历、上行停顿与恢复通过 | 同 bank commit/DRAIN 压力、yield 计数与清除 |
| 协议边界 R4-020/023 | payload/sideband 逐拍比较、存储专项通过 | 字段组合与地址边界非穷举 |
| 平台 R4-024/031 | 三 seed full 与模块专项通过 | 部分 VCS 故障注入、修复版 legacy817 独立兼容回归 |
| 周期模型 R4-026/027 | 本地模型测试与 trace 工具 | 同刺激 RTL 逐事件校准；不得称为已校准 |
| 物理验证 R4-029/030/032 | VCS 编译与功能通过 | DC 核数、latch/多驱动、setup/hold、宏绑定、面积与功耗 |
| 新增 protocol dump | 接口与源码本地检查 | 实际 VCS 生成及 Verdi 波形验收 |

33 条逐项记录见网站新版验证复核报告；历史报告与日志不覆盖。
“已关闭”只针对原问题验收范围，不能解释为模块完全验证。
