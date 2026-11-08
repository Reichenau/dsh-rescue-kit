# DSH Rescue Kit

> 非官方工具，与 DeepSeek 官方无关。

> AI 助手崩了的时候，双击一下，把它当时的现场打成 zip，丢给另一个 AI 看。

你的 AI 卡住、报错、或者干脆不吭声了 —— 这时候你手里只有一句「它突然就不动了」。
日志在哪、报什么错、上下文有多长、上次改了哪个配置，全在那台机器上，而对面那个
帮你诊断的 AI 看不见。

这个脚本做的就是：**把现场拍成照片，装进 zip**。

## 隐私：哪些打了码，哪些没打

**这是一份「现场照片」，不是脱敏文件。不要把它发给不认识的人、公开群、论坛或 issue。**

**已打码：**

| 内容 | 处理 |
|---|---|
| 用户名 | 全包替换成 `%USERNAME%`（检索不到真实用户名） |
| 用户目录路径 | 替换成 `%USERPROFILE%` |
| token / key / cookie / 密码 / API 凭据 | 替换成占位符；`credentials.yaml` 只报配了几个 key，不写键名和值 |
| MAC 地址 | 只留厂商前三段，后三段写成 `xx:xx:xx` |

**没打码（诊断需要，但会暴露设备信息）：**

| 内容 | 在哪 | 例子 |
|---|---|---|
| 局域网 / 回环 IP | `network.txt` | `192.168.x.x`、`127.0.0.1` |
| 端口、PID、进程名 | `network.txt`、`processes.tsv` | `3443  pid=22868  DeepSeek Harness` |
| 机器型号 | `system.txt` | `LENOVO 82XX` |
| 会话 id | `sessions.txt`、`session-tail.txt` | `session-d4747a37-…` |
| 盘符与容量 | `system.txt` | `C: free=12.8GB` |
| 安装路径 | `system.txt`、`processes.tsv` | `D:\deepseek\DeepSeek Harness.exe` |
| Windows 事件日志原文 | `recent-errors.txt` | 含出错程序名与路径 |
| 日志尾部片段 | `logs/` | 可能夹着你自己的对话碎片 |

## 交出去之前

1. 只发给你信得过的人，或你信任的 AI 服务；
2. 不要发到公开群、论坛、issue；
3. 打开 `session-tail.txt` 和 `logs/` 自己扫一眼——那里可能有你聊过的话；
4. 想再脱一层，就先删掉 `network.txt`、`sessions.txt`、`logs/` 再给，代价是诊断信息变少。


---

## 快速开始

1. 把这几个文件放到任意一个空文件夹里（放哪都行，脚本靠自己的位置定位）。
2. 双击 `rescue-kit.bat`。它会先问你一句：**屏幕上看到的是什么？**（输一行，直接回车跳过也行）
3. 等 30–60 秒（本机实测约 36–52 秒），窗口里每做完一步打一行，最后出现：

   ```
   OK C:\...\reports\11-04 20点18分 2026.zip (79.6 KB)
   ```

4. 打开 `reports\`，**先自己看一眼 `index.md`**，再把整个 zip 拖给另一个 AI。旧 zip 可以直接删，保留最新一份即可。

zip 的名字就是生成时间：**日期 几点几分 年份**。同一分钟跑两次不会互相覆盖，
第二份会自动变成 `... (2).zip` —— 出事的时候人容易手抖连点两下，少一份现场就白采了。

**万一采集中途出错**，脚本不会把已经收好的东西扔掉：它会打成
`PARTIAL-11-04 20点18分 2026.zip`，半成品，照样能读。连打包都失败时（磁盘满、
路径太长），它会停手、**不删**临时目录，并把那个目录的完整路径打给你 ——
拿去手动 zip 一下，证据还在。

### 带上你看到的那句话

最好的用法是把它当时给你的报错一起带上：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File make-rescue-kit.ps1 -Symptom "窗口白屏，消息发不出去"
```

这句话会写进 `index.md` 开头。诊断的人第一句就知道该往哪找，而不是从头猜。

双击 `.bat` 时那句提示就是这么做的：提问在 PowerShell 侧用 `Read-Host` 完成（Unicode 原生，
中文不会变乱码），不再经过 cmd 的 `set /p` 和 `chcp`，GBK 控制台也照样能输。命令行里也可以用
`-SymptomFile <路径>` 走同一条路。

开跑前脚本还会查一下 `reports\` 所在盘还剩多少空间：不足 200 MB 就当场喊一声。
采集要 30–60 秒，等它跑完才因为磁盘满打包失败，是最冤的一种白跑。

---

---

## 版本

**v5.2** · 2026-11-08（首个正式版）

对比上一次发布的 v5.0.3，这一版把「能取证」升级成了「能看懂、能自己复现」：

- **会体检打分了**：压缩包里多了 `checks.json`，`index.md` 顶部直接给一张 PASS / WARN / FAIL 表——不用翻几十个文件，先看几行就知道哪出问题。
- **会照着你的配置重跑一遍**：对每个能跑命令行的 profile 执行 `dsh --profile <名字> --dump-config`，把 YAML 报错、缺失插件（比如 `patch: entry "tool-ralph" not found`）直接抓出来。这是这次最大的升级。
- **更会认钥匙**：除了 `sk-`、`AKIA` 这些老形态，新增 `ak-`、`org-`、`lin_api_`、`xai-` 等新 token；打包前还会把整个包再扫一遍，免得把 API key 带出去。
- **抓不到输出会自动换通道**：cmd 卡住或没输出时，自动用 PowerShell 再试一次；30 秒还不回来就杀掉进程，不会把整个包卡死。dump 文件头会写清楚走哪条通道、有没有重试、退出码是多少。
- **中文提问不炸弹了**：提问挪到 PowerShell 里（中英双语），不再经过 cmd 的 `set /p` 和 `chcp`，GBK 控制台也能正常输入；真乱码了会记一条警告。
- **会主动喊结果**：跑完在窗口里固定打印 `checks: X ok / Y warn / Z fail`；如果窗口被强关、只留下 `_tmp` 目录，bat 会提示你手工打包。
- **现场更细**：系统盘 / DSH 所在盘 / 报告盘三块磁盘剩余空间都报；崩溃转储写清楚 48 小时窗口内外各有几个；desktop 前端和 CLI 版本不一致会提示。
- **自带 23 条回归测试**：仓库里的 `tests/` 用已知 bug 当探针，改一处不会悄悄弄坏另一处（本轮 23 checks / 0 mismatch）。

**v5.1.5** · 2026-11-08

Marvis 对 v5.1.4 的复评是 **ship（0 P0 / 0 P1）**，顺手补的两条 P2：

- **symptom 告警口径统一**：交互中直接回车跳过，现在也记一条 `symptom` WARN（detail 区分 `skipped at the prompt` 与 `non-interactive run`），下游不再分不清「用户主动跳过」和「工具没问」。
- **强杀后的 `_tmp` 提示**：bat 开头先说明「窗口中途被关，旁边的 `_tmp` 请手工打包」；正常结尾也会检查 `_tmp` 是否还在，在就提醒。
- **说明书措辞**：明确 bat 结尾会打开 `reports` 文件夹，但不会自动打开具体报告文件。

**v5.1.4** · 2026-11-08

按 Marvis 对 v5.1.3 的黑盒复评修的一轮（0 P0 / 2 P1 / 7 P2）：

- **`exit_note` 只在 stdout 真为空时写**：旧条件是「exit code 为 0 且状态非 ok」，会把「有正文、只有 stderr 警告」的 profile 误标成 `stdout was empty`（bili-duty 就是 417 行正文配这句）。现在只看 stdout 是否为空，并在文案里带上真实 exit code。
- **dump 头新增 `retry`**：`0` 或 `1 (powershell empty -> cmd)`，不用再从 `channel` 里猜有没有重试过。
- **中文提问**：`Read-Host` 提示改成中英双语（PowerShell 侧，Unicode 安全）。
- **非交互运行补 `symptom` WARN**：没有 `-Symptom`、stdin 又被重定向时不再静默丢失，checks 里会记一条。
- **截断标注**：dump 分隔行改成 `first 250 of N lines`，不再和头部的 396/417/1185 行打架。
- **README 旧文案对齐**：删掉「bat 里 `chcp 65001` / `set /p` / `DSH_RESCUE_SYMPTOM`」这些已成为历史的话。
- **reports 清理提示**：旧 zip 可直接删，保留最新一份即可。

**v5.1.3** · 2026-11-08

按 Marvis 对 v5.1.2 的黑盒复评修的一轮，重点是「CLI 取证」这条命根子：

- **dump-config 主通道换成 PowerShell（`dsh.ps1`）**：Marvis 机器上经 `cmd.exe` / `dsh.cmd` 的调用返回 0 字节，PowerShell 直调 `dsh --profile <p> --dump-config` 稳定 407 行。现在先走 PowerShell，空输出才用 cmd 重试一次；两条都空才判 FAIL，并写明「这是 kit 抓不到，不是你装坏了」。
- **真超时与真清理**：两条通道都强制 30 秒，超时按进程树杀（原来只杀 `cmd.exe`，node 子进程可能还挂着）。
- **dump 文件头补通道字段**：`cli_exe` / `channel`（含是否重试）/ `exit_note`，不用再对着 `exit_code=0` 猜。
- **版本同源采集**：CLI 版本优先走 `dsh.ps1`，读不到就在 `system.txt` 写 `dsh_cli = (not detected)`，version 检查对应记 WARN（不再假装 PASS）。
- **凭据复扫常驻**：`credentials` 检查每次都会出现（命中记 WARN，未命中记 PASS），不再「只在命中时才有一行」。
- **crash dump 摘要补齐**：汇总行同时报「48h 内无关数」和「磁盘上无关总数（含窗口外/无名 dump）」，不再出现明细 5 个、摘要 3 个。
- **中文症状不再变乱码**：提问移到 PowerShell 的 `Read-Host`（Unicode 原生），bat 保持纯 ASCII；PS 侧检测到 U+FFFD 仍会记一条 `symptom` WARN，并提示改用 `-Symptom`。
- **控制台也报汇总**：打包后多打一行 `checks: X ok / Y warn / Z fail`，有 FAIL 时提示先看 `index.md`。

**v5.1.2** · 2026-11-08

从社区的 `dsh-doctor` 借了两样东西，但没抄它的自动修复——急救包还是只读取证，只把「判断」做得更硬：

- **结构化 checks**：每项检查记 `kind / status / detail / fix_hint`，落成 `checks.json`；`index.md` 顶部加 PASS / WARN / FAIL 表和 `N passed, N warnings, N failures` 这样的摘要。
- **主动复现配置错误**：对每个能 CLI 复现的 profile 跑 `dsh --profile <p> --dump-config`，把首个 `Error:` / `YAMLException:` 行顶进 triage；`desktop` 由 Electron 独占，跳过并记 warn。
- **exit code 不可信就以 stderr 为准**：`dsh.cmd` 不传 node 的退出码（坏 YAML 也报 0），所以按 stderr 的特征判 FAIL / WARN；`dump-config-*.txt` 里会记 `exit_note`。
- **原始输出不再进包**：dump 的 `.out/.err` 重定向到临时目录、脱敏写入后即删；zip 里只有打过码的 `dump-config-*.txt`。
- **假 FAIL 清理**：bundle 解析交给 compose 结果，不再按 `profiles\<name>\node_modules` 误判；triage 不再把 dump 文件里的 `timeoutMs` 当超时。
- 环境检查更细：`package.json` 可解析、`link:` 依赖真存在、compose 结果、磁盘余量、crash dump。

**v5.0.3** · 2026-11-05

按一份第三方复核（Marvis 对 v5.0.2 的实测）修的一轮，重点是「别自己给自己制造假警报」：

- **事件日志不再把「区间内没有」当成「读不到」**：`Get-WinEvent` 查不到匹配事件时会抛 `NoMatchingEventsFound`，旧代码一律记进 `$evErrors`，于是几乎每台健康机器都顶着一条假 NOTE。现在按 `FullyQualifiedErrorId` 区分，真失败才记。
- **端口表降级说明改看来源**：判据从「条数 < 5」改成 `$portSource -ne 'Get-NetTCPConnection'`。用 `IPGlobalProperties` 兜底时 pid 和进程名会是空的，这种「最该说明」的情况现在会写明。
- **DSH 端口改成 pid 匹配**：真机命令行里没有端口（宿主监听在 LAN 地址，如 `192.168.x.x:3443`），原来猜端口的探测 0 命中。现在拿 DSH 进程 pid 与监听表的 `OwningProcess` 比对，命中行打 `[dsh]`；命令行探测保留作补充。
- **`TreeOf` 枚举子目录时也跳过 reparse point**：junction 自环不会在目录树里留下 `loop\loop` 这种怪条目。
- **`system.txt` 的 time 统一用 `$CapturedAt`**，不再各打各的钟。
- **事件消息里的制表符也压成空格**，TSV 不会因为消息含 TAB 而错列。

**v5.0.2** · 2026-11-05

一次自查（自己审自己的 1700 行），修的是「包明明打出来了，工具却说自己失败」这类问题：

- **`$ok` 不再一名两用**：端口探测结果改成 `$probeOk`。宿主卡死、探测端口连不上时，zip 已经写出却会 `exit 1`，bat 报 FAILED、连 reports 都不开——偏偏这正是最需要它的场景。
- **`APPDATA` / `LOCALAPPDATA` 为空不再炸**：SYSTEM、部分计划任务下这两个变量是空的，`Join-Path` 会抛参数绑定异常并带走后面所有段落。现在统一走 `EnvDir`，拿不到就跳过并写进日志。
- **目录大小不再被 junction 卡死**：`TreeOf` 之前用 `Get-ChildItem -Recurse` 算大小，`-ExtraDirs` 指到带 junction 的目录会一直走下去。改用带重解析点跳过、文件数/时间双上限的 `DirSize`。
- **`tree-extra-*.txt` 文件名不泄露目录名**：改成 `tree-extra-1.txt`，真实路径写在文件里（路径明文，只有用户名替换成 `%USERNAME%`）。
- **事件日志区分「读不到」和「没有」**：`Get-WinEvent` 失败时在 `recent-errors.txt` 头部写明，不再把权限问题说成「没有错误」。
- **bat 不再把 `PARTIAL-*.zip` 当成最新报告**上报 OK。

**v5.0.1** · 2026-11-05

按一份真实用户报告（朋友机器上的 v5.0.0 输出）修的几处，前三处会直接让「把包丢给另一个 AI」失真：

- **`processes.tsv` 表头现在是真 tab**。之前用了单引号 `'name`tpid...'`，反引号 t 被原样写出，`Import-Csv` 只得到一列。
- **命令行里的换行 / 制表符会被压成空格**，不再把一条进程折成两行、把后面的列全错位。
- **端口表加了兜底与声明**：低完整性上下文里 `Get-NetTCPConnection` 会被拒，退回 `IPGlobalProperties`；还拿不到就明写「本表不完整」。另外从 DSH 自己的命令行里找 `--port` / `127.0.0.1:<port>` 主动探测一次，尽量把 Web 端口补回来。
- **时间戳分开**：`captured_at` 是采集开始时刻，`packaged_at` 是打包时刻，`index.md` 两个都列，不再拿后者当前者。
- **自动初判写明扫描范围**：只说「扫描过的 DSH 状态/日志里没有错误串」，并指向 `recent-errors.txt`；Windows 事件日志本来就不在扫描范围里。
- **`recent-errors.txt` 加了表头**（时间 / 通道 / 提供程序 / ID / 消息）和聚合说明；一条都没有时也会明确写出来。
- **自动初判补了中文关键词**：原来 9 组全是英文，中文日志占多数时会误报「没发现错误」。现在内存不足 / 连接被重置 / 超时 / 未响应 / 端口占用这些中文写法也能命中。
- `tree-dsh.txt` 的描述改成「两层目录概览」，不再自称完整目录树。

**v5.0.0** · 2026-11-04

这一版主要是把「拿到的包可能是错的」那几处堵上：

- **超过 32 MB 的中文日志不会再变成乱码**（v5 测试版引入的回归）。截尾 8 MB 时切点落在汉字中间，严格 UTF-8 解码抛异常后退回 GBK，整段就成了 `浜嬩欢缂栧彿`。现在先对齐到行边界再解码；UTF-16 的截尾也改成偶数偏移。
- **`[tail of N MB file, last 8 MB only]` 这行提示不会再被切掉**：原来它先写进文本、再取末尾 300 行，正好把自己截没。
- `soul-md` 不再被当成普通日志目录扫进包 —— 之前就算 `-IncludeMemory` 关着，记忆里的 `.txt` 也会从 `logs\` 漏进来。
- 名字里带 `cookie` / `token` / `secret` / `password` / `credential` 的文本不再当日志收：真机上有个插件把 cookie 罐存成 `.dsh\douyin-duty\douyin_cookie.txt`，6 KB 的活 `sessionid` 就这样进了包。
- 8.3 短名（`C:\Users\LAIYUH~1\...`）现在整体换成 `%USERNAME%`，不再留下畸形的 `%USERNAME%~1`。
- `environment.txt` 不再出现 `COMPUTERNAME = %COMPUTERNAME%` 这种自指行；长值按 `;` / `\` 边界截断，PATH 不会断在半个目录名上。
- 自动初判里的 `module missing` 不再把插件市场 62 条 `level=info` 的 toggle 当成故障。
- `Mask-Secrets` 的调用补了括号：PowerShell 7 下原来的写法会参数绑定报错，用户名就漏打了。
- 版本号统一成一处语义化版本（脚本头、`$KitVersion`、README、`index.md` 同源），不再是 `v0.3.0` 和 `5` 混着。

v5 测试版那批功能也正式记一笔：日志名用短别名（不再拿 `..` 硬拼长前缀）、崩溃日志按 `crash_<时间>_<角色>.log` 重建文件名（缩短也不丢时间戳）、日志扫描扩到 `.ndjson` / `.jsonl` 和 `.dsh-*` 兄弟目录、`-Minimal` 只留 DSH 进程、症状改走环境变量（`&` `%` 不再被 cmd 吃掉）。

上一版（v0.4）：长路径打包、会话尾部多帧解码、环境变量白名单、崩溃日志保留时间戳。
再往前（v0.3.x）：密钥打码扩展到 JWT / 非 HTTP 协议 / `*_KEY=`，自动初判要求错误码带上下文，失败时先打 `PARTIAL` 包再谈退出码。

**已知边界**：Windows 上若有第三方压缩软件接管了 `.zip` 关联，打包可能被拦下来。
真被拦了，脚本会先打一行 `PARTIAL: ...` 再打 `PARTIAL-*.zip`，看到那行就说明主路径失败、这个包是兜底产物。

---
## 先看 `index.md`

包里每个文件都是原始证据，`index.md` 是这一堆证据的**导读**：

- 采集时刻 / DSH 版本 / **当时在不在跑**
- 你写的那句症状
- 文件导航表（哪个文件回答哪个问题）
- **自动初判**：把日志里 `out of memory` / `port in use` / `unauthorized` / `rate limit` /
  `context window` / `timeout` / `module missing` 这些痕迹数出来，按文件分组，**并附上第一条命中的原文**
  —— 判断是真错误还是误报不用翻文件。（纯数字那几条要求带上 HTTP 上下文才算，免得把 UUID 里的
  `401`、端口号、`592.3 MB` 当成 401/592 错误）
- **阈值告警**：磁盘只剩几 GB、内存不够、有进程 `Responding=False`、48 小时内有没有崩溃转储

诊断的人先读这一页，通常三十秒就知道该不该往下翻。

---

## 它会收集什么

| 文件 | 内容 |
|---|---|
| `index.md` | **导读 + 自动初判 + 告警** —— 先看这个 |
| `dsh-status.txt` | 采集那一刻 DSH 在不在跑、版本、找到几个日志 |
| `session-tail.txt` | 最近 25 条会话事件 —— 「它卡在哪一步」，**含你对话的片段，见下面隐私一节** |
| `timeline.txt` | 新装的还是用很久了、48 小时内改过哪些文件 |
| `dsh-process-tree.txt` | 以 DSH 为根的进程树 —— 哪个插件拉起了哪个 helper |
| `logs\` | 日志尾部 300 行：**崩溃日志排最前**，然后 `.log` / `.txt` / `.ndjson` / `.jsonl` |
| `crash-dumps.txt` | 有没有真的写出转储文件、什么时候写的 |
| `network.txt` | 代理、网卡/网关/MAC、本地监听端口、DNS |
| `processes.tsv` | 当时所有进程 + 命令行 + **响应状态 + 占用内存**（密钥已打码） |
| `system.txt` | 系统版本、各盘剩余、内存、开机时间、**显卡型号 + 驱动版本**、DSH 版本 |
| `environment.txt` | 环境变量（**值已打码**）—— `PATH` / `NODE_OPTIONS` / `DSH_HOME` 被改坏是最常见的「突然不工作」 |
| `tree-dsh.txt` | `.dsh` 的两层目录概览：第一层是完整路径 + 大小，第二层只列名字，不展开文件 |
| `tree-extra-*.txt` | 你额外指定的项目目录（可选） |
| `sessions.txt` | 所有工作区、所有会话文件夹及大小 |
| `recent-errors.txt` | Windows 最近 24 小时错误（Application + System，重复项已合并计数，单条截 500 字符） |
| `credentials-meta.txt` | 凭据配置了**几个**（只给数量，连服务商名字都不给） |
| `memory-head.txt` | 记忆文件（**仅当加 `-IncludeMemory`**） |
| 配置副本 | `cordis.patch.yml`、`package.json`、guardian 状态 |

日志不只在 `.dsh\logs` 里。0.2.1-rc.3 往后，运行日志**根本不写** `.dsh\logs` ——
你在那儿看到的是旧版本留下的。真正会写的是崩溃日志，在
`%APPDATA%\@deepseek-ai\dsh-desktop\logs\crash-*.log`，所以那批排最前面。
有些插件写 `.ndjson`，有些把 trace 放在 `.dsh` **旁边**的兄弟目录（比如
`.dsh-wallpaper-engine\diag\`），脚本三层都扫。

它**只读**，不改任何东西，也不需要管理员权限，不联网、不上传。

---

## 它**不会**收集什么

- **凭据文件**：`.credentials.yaml` 永远不拷，`credentials-meta.txt` 只报「存在 / 多大 / 配了几个」，连服务商名字和键名都不给。
- **API key**：命令行和日志里长得像 key 的字符串会被替换成 `***`。
  认得的形态包括 OpenAI / Anthropic / Google / 火山 / AWS / GitHub / Slack / JWT /
  各种 `*_KEY=` `*_TOKEN=` 环境变量 / URL 里的 `user:pass@` / PEM 私钥块。
- **你的用户名和路径**：`%USERPROFILE%` 和用户名在写盘前就换掉了。
- **你的记忆**：默认不打包。想看那一份就手动加开关：

  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File make-rescue-kit.ps1 -IncludeMemory
  ```

- **`.dsh` 以外的目录**：只读 `.dsh` 旁边同级的 `.dsh-*` 兄弟目录里的日志文件，
  别的目录一个都不碰。想加自己的项目目录，用 `-ExtraDirs` 点名：

  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File make-rescue-kit.ps1 -ExtraDirs "D:\my-project","C:\my-work"
  ```

- **你自己的那个 txt**：`.dsh` 里那些文件名带 `cookie` / `token` / `secret` /
  `password` / `credential` 的文本（比如某个插件把 cookie 罐存在
  `douyin_cookie.txt`）不当日志收。它们不算「凭据文件」的格式，但内容一样是活凭据。
  跳过几个会记在 `dsh-status.txt` 的 `skipped_secret_named_logs` 里。

### 关于 `session-tail.txt` —— 交出去之前请自己过一眼

这个文件是「它卡在哪一步」唯一的证据，所以它里面**必然有你自己的话**：
最近 25 条会话事件，每条截到 600 字符。密钥和用户名已经打码，但对话内容没法打码 ——
打掉了就失去诊断价值。

所以：**把包给任何人之前，先打开 `session-tail.txt` 看一眼。**觉得哪句不想给出去，
删掉那一段就行，其余文件照常有用。

### 只想给最少的东西

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File make-rescue-kit.ps1 -Minimal
```

`-Minimal` 只保留**命令行里带** `dsh` / `deepseek` / `electron` / `cordis` 的进程
（按命令行匹配，不是按进程名），`processes.tsv` 从两百多行缩到几十行 —— 别的软件在跑什么，跟这次故障无关。（只影响进程表；network / timeline / 环境变量照常收集。）

---

## 为什么需要单独一个包

因为**出事的时候你打不开 AI，也就问不了它**。

而另一个 AI（豆包、Kimi、Claude 随便谁）只要拿到这个 zip，就能看出：
上下文是不是顶到窗口了、哪个进程卡住了、配置有没有写错、日志最后一句是什么。
不用远程连你的电脑，也不用你一条条复制粘贴。

---

## 依赖

- Windows 10 / 11
- PowerShell 5.1（系统自带，不用装）

没有第三方模块，没有 Node，没有 Python。
`session-tail.txt` 需要一个 node 才能解开 `.zstd` 会话文件 —— 脚本会去 DSH 自带的
运行时里找，找不到就跳过这个文件，其余照常出包。

---

## 踩过的坑（都修好了，写下来免得你重踩）

1. **脚本必须存成 UTF-8 with BOM**。Windows PowerShell 5.1 默认按 ANSI 代码页读
   脚本，无 BOM 的 UTF-8 会让里面每一个中文字符串变成乱码 —— 文件名会变成 `.zip`，
   格式串里全是问号。仓库里的版本是带 BOM 的，**你用任何编辑器改完都要确认 BOM 还在**
   （VS Code 右下角选 `UTF-8 with BOM`）。
2. **别用 `Get-Content` 读日志**。中文日志有一半是 UTF-8、一半是 GBK，`Get-Content`
   靠 ANSI 猜，猜错就整篇乱码。脚本里用 `Read-TextAuto`：先看 UTF-16 BOM，再严格按
   UTF-8 解，失败退回 GBK，并且用共享读方式打开正在被占用的文件。
3. **`catch` 里再抛异常会逃出整个脚本**。第一版在解码失败的 `catch` 里又调了一次
   `[IO.File]::Open`，那个调用自己也会失败，异常穿过 `catch` 直接把整个脚本送走 ——
   一个读不了的文件能让整份报告一份都生成不出来。现在 `catch` 里再套 `try`，
   并且主流程包在 `try/catch/finally` 里，失败也照样出报告。
4. **中文文件名没问题**，但 zip 存的是 UTF-8 文件名，个别老解压工具会显示成乱码 ——
   用 Windows 自带的解压不会有问题。打包时显式指定了 UTF-8 编码标志。
5. **抓日志别按文件大小排序**。Chromium 的 LevelDB 日志能有几 MB 且是二进制，按大小
   排序会把真正有用的 `desktop-next.log` 全挤出去 —— 包涨到 890 KB 还全是乱码。脚本
   改成「核心日志无条件保留 + 其余按修改时间取最近几条 + 噪音过滤」。
6. **同一个错误会刷屏**。显卡驱动（`nvlddmkm`）一秒内能刷二十条，把别的事件全埋了。
   `recent-errors.txt` 按「同一分钟 + 同一 provider + 同一事件 ID」合并成一行。
7. **别把中间文件放在打包目录里**。第一版把解码后的会话临时文件放进了临时目录，
   临时目录整个被打进 zip —— 一个 800 KB 的会话尾巴让包从 67 KB 涨到 511 KB。
8. **别在日志里放完整对话**。会话文件里一条工具结果能有几十万字符，不截断的话
   光一个文件就比其余全部加起来还大。现在每条截 600 字符。

---

## 目录结构

```
dsh-rescue-kit\
  rescue-kit.bat          双击这个
  make-rescue-kit.ps1     干活的脚本
  reports\                生成的结果（已 gitignore）
  icon\rescue-kit.ico     图标
  README.md
  LICENSE
```

---

## License

MIT，详见 [LICENSE](LICENSE)。
