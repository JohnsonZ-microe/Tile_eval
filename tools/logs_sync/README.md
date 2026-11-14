# tile-logs-sync

把 ECE VDI 上每次 VCS 仿真结束后的日志目录，自动回收到本地
`C:\Users\Administrator\Dropbox\LNS_DSE\Tile_eval\logs\<tag>\`；
`run.py --waves` 产生的波形（`*.vcd`）也会自动回收到
`C:\Users\Administrator\Dropbox\LNS_DSE\Tile_eval\vcd\<name>.vcd`；
仿真侧 CSV 跟踪（`tile-events.csv`、`calibration-events.csv` 等）则合并进
`logs\<tag>\`。

## 为什么是"推"而不是"拉"

VDI（`ecelvd713`，`10.21.222.213` / `10.132.222.213`）在私网里，笔记本没有到它的回程路由，
所以**笔记本无法主动连 VDI**。反过来 VDI 的出口（NAT 成 `143.89.44.11`）能连到笔记本，
因此方向固定为：**VDI → 笔记本**，由 VDI 侧主动推送。

```
VDI: ~/Desktop/Products/logs/<tag>/        （仿真日志，exit_code.txt 是完成标记）
        │  tar czf - | curl --data-binary @-
        ▼
笔记本: 143.89.176.1:8000  receiver.py     （校验 token、路径、gzip、幂等）
        ▼
    C:\Users\Administrator\Dropbox\LNS_DSE\Tile_eval\logs\<tag>\

VDI: ~/Desktop/Products/<tag>/*.vcd        （--waves 波形，位于 products 目录）
        │  每个文件单独打包，POST /vcd/<name>.vcd.tgz
        ▼
    C:\Users\Administrator\Dropbox\LNS_DSE\Tile_eval\vcd\<name>.vcd

VDI: ~/Desktop/Products/<tag>/*.csv        （+TRACE/+CALIBRATION_TRACE 跟踪）
        │  按 <tag>/<name>.csv 成员打包，POST /push/<tag>.tgz
        ▼
    C:\Users\Administrator\Dropbox\LNS_DSE\Tile_eval\logs\<tag>\<name>.csv
```

## 一次性部署

### 1. 笔记本侧（只需一次）

```powershell
cd C:\Users\Administrator\Dropbox\LNS_DSE\Tile_eval\tools\logs_sync
powershell -ExecutionPolicy Bypass -File .\install_task.ps1
```

它会：注册计划任务 `TileLogsSyncReceiver`（登录即启动，无窗口）、立刻启动接收端、
打印 `token` 和一条给 VDI 用的引导命令。配置写在
`%LOCALAPPDATA%\tile-logs-sync\sync_config.json`（不进 git）。

需要放行入站端口（管理员执行一次）：

```powershell
New-NetFirewallRule -DisplayName "TileLogsSync-8000" -Direction Inbound `
  -Protocol TCP -LocalPort 8000 -Action Allow -Profile Any
```

### 2. VDI 侧（每个新会话一次）

```bash
curl -fsS http://143.89.176.1:8000/vdi_push_logs.sh -o ~/vdi_push_logs.sh
chmod +x ~/vdi_push_logs.sh
```

> 脚本更新后（例如新增的 vcd 推送），在 VDI 上重新执行一次上面的两条命令
> 即可拿到新版，token 会由接收端自动注入。

脚本会自己生成 `~/.tile-logs-sync.conf`，里面已经带好 URL 和 token（由接收端注入）。
如果拿到的是干净版本，手工建这个文件：

```
PUSH_URL=http://143.89.176.1:8000
PUSH_TOKEN=<接收端打印的 token>
```

## 日常使用

```bash
# 每 15 秒扫一次，做完一个推一个，适合跑多个 case 时开着
nohup ~/vdi_push_logs.sh --watch > ~/tile-logs-sync.log 2>&1 &

# 或者每次仿真结束后手动推一次
~/vdi_push_logs.sh --once

# 只看状态，不推
~/vdi_push_logs.sh --status
```

在 `run.py` 之后串一条即可自动化：

```bash
python3 scripts/run.py ... && ~/vdi_push_logs.sh --once
```

**完成判定**：目录里出现 `exit_code.txt`（`run.py` 最后写的）且 8 秒内没有新写入。
所以仿真还在跑时不会被误传。

## 行为细节

| 场景 | 行为 |
|---|---|
| 同一 run 推第二次 | 接收端比对 tar 的 sha256，一致返回 `409`，脚本记为已发送 |
| 传了一半断开 | 接收端只在整包校验通过后才落盘，坏包不会污染 logs |
| 本地已有额外文件 | **合并覆盖**，不删除本地独有的 `manifest.json` / `checks.json` |
| 端口/网络不通 | 每次尝试间隔 3/6 秒重试，失败后下一轮扫描继续 |
| 不是 vcs-* 目录 | 忽略 |
| 恶意 tar | 拒绝绝对路径、`..`、符号链接；`<tag>` 必须匹配 `^[A-Za-z0-9][A-Za-z0-9._-]*$` |
| 同名 vcd 已存在且内容相同 | 返回 `409`，脚本记为已发送 |
| 同名 vcd 但内容更新 | **原子覆盖**为新版本，`vcd\.sync.json` 记录 sha256/大小/来源 tag/时间 |
| 单个波形 > `VCD_MAX_MB`（默认 400MB） | VDI 侧**警告一次并跳过不传**（`.skip` 标记，`--force` 也不传）；接收端兜底拒绝 `413` |
| products 目录的 `*.csv` | 每个文件单独推送，**合并**进 `logs\<tag>\`（不覆盖已有日志）；失败下轮自动补推 |

接收端只写文件，**从不执行任何东西**；写完后在目标目录留一份 `.sync.json`
（sha256、推送时间、文件清单），便于核对来源。

## 配置项

VDI 侧（`~/.tile-logs-sync.conf` 或环境变量）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `PUSH_URL` | `http://143.89.176.1:8000` | 接收端地址 |
| `PUSH_TOKEN` | 空（必填） | 与接收端一致 |
| `LOGS_DIR` | `~/Desktop/Products/logs` | 远端日志根 |
| `PRODUCTS_DIR` | `LOGS_DIR` 的上级目录 | `--waves` 波形（`*.vcd`）所在的 products 目录 |
| `VCD_MAX_MB` | `400` | 单个波形大小上限（MB），超过则警告一次并跳过不传 |
| `INTERVAL` | 15 | `--watch` 扫描间隔（秒） |
| `SETTLE` | 8 | 目录静默多久算写完（秒） |
| `STATE_DIR` | `~/.cache/tile-logs-sync` | 已发送标记目录 |

笔记本侧：`receiver.py --port 8000 --dest <dir> --vcd-dest <dir> --config <file>`。

## 故障排查

| 现象 | 处理 |
|---|---|
| `curl: (7) Failed to connect` | 笔记本 IP 变了：`ipconfig` 看 `143.89.*` 地址，改 VDI 的 `~/.tile-logs-sync.conf` |
| `http=401` | token 不一致：重新下载一遍脚本（会带新 token），或手工对齐配置 |
| `http=000` 且无其他信息 | 接收端没起：笔记本上 `Get-NetTCPConnection -LocalPort 8000 -State Listen` |
| 一直 `skip ... not finished` | 该 run 没有 `exit_code.txt`，说明 `run.py` 没走到收尾；确认仿真真的结束 |
| 想强制重推 | `--force`（或 `--tag <tag> --force`） |

## 卸载

```powershell
schtasks /delete /tn TileLogsSyncReceiver /f
Remove-NetFirewallRule -DisplayName "TileLogsSync-8000"
```
