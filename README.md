# DSH Rescue Kit

> 非官方工具，与 DeepSeek 官方无关。Unofficial tool, not affiliated with DeepSeek.

**简体中文** · [English](README.en.md) · 完整文档 [中文全文](README.zh-CN.md) / [English full](README.en.md)

---

## 第一页 · 隐私：哪些打码，哪些没打

**这是一份「现场照片」，不是脱敏文件。不要发给不认识的人、公开群、论坛或 issue。**

**已打码：**

| 内容 | 处理 |
|---|---|
| 用户名 | 全包替换成 `%USERNAME%` |
| 用户目录路径 | 替换成 `%USERPROFILE%` |
| token / key / cookie / 密码 / API 凭据 | 替换成占位符；`credentials.yaml` 只报配了几个 key |
| MAC 地址 | 只留厂商前三段，后三段 `xx:xx:xx` |

**没打码（诊断需要，但会暴露设备信息）：局域网 / 回环 IP、端口、PID、进程名、机器型号、会话 id、盘符容量、安装路径、Windows 事件日志原文、`logs/` 里的日志尾部片段（可能有你聊过的话）。**

<details>
<summary>English — Page 1 · Privacy</summary>

**This is a scene photograph, not a sanitized document. Do not hand it to strangers, public groups, forums or issue trackers.**

**Masked:** user name (`%USERNAME%`), profile paths (`%USERPROFILE%`), tokens / keys / cookies /
passwords / API credentials, the last three MAC octets.

**Not masked:** LAN and loopback IPs, ports, PIDs, process names, machine model, session ids, drive
letters and capacity, install paths, raw Windows event log text, and log tails under `logs/` (which
may contain pieces of your conversation).

</details>

---

## 第二页 · 怎么用

1. 把这几个文件放进任意一个空文件夹；
2. 双击 `rescue-kit.bat`，它会问一句「屏幕上看到的是什么 / What did you actually see on screen」，输一行或直接回车；
3. 等 30–60 秒（本机实测约 36–52 秒），得到 `reports\11-05 23点00分 2026.zip`；
4. **先打开 `index.md` 自己看一遍**，再把整个 zip 拖给另一个 AI（豆包 / Kimi / Claude 都行）。

想带上屏幕上的原话：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File make-rescue-kit.ps1 -Symptom "窗口白屏，消息发不出去"
```

**交出去之前**：先打开 `session-tail.txt` 和 `logs/` 扫一眼；想再脱一层，就删掉 `network.txt`、
`sessions.txt`、`logs/` 再给，代价是诊断信息变少。

<details>
<summary>English — Page 2 · How to use</summary>

1. Put the files in any empty folder.
2. Double-click `rescue-kit.bat`; it asks "what do you see on screen?" — type one line or press Enter.
3. Wait 30–60 seconds (about 36–52s on our test machines); you get `reports\11-05 23点00分 2026.zip`.
4. **Open `index.md` and read it yourself first**, then drag the zip to another AI (Doubao / Kimi /
   Claude, any of them).

To include the exact message you saw:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File make-rescue-kit.ps1 -Symptom "window is white, messages will not send"
```

**Before handing it over**: open `session-tail.txt` and `logs/` and glance through them; for one more
layer, delete `network.txt`, `sessions.txt` and `logs/` first — at the cost of less diagnostic evidence.

</details>

---

## 完整文档 / Full documentation

- 中文 → **[README.zh-CN.md](README.zh-CN.md)**（版本记录、收集清单、不会收集什么、踩过的坑）
- English → **[README.en.md](README.en.md)** (versions, what it collects, what it never collects, pitfalls)

当前版本 / Current: **v5.2**（2026-11-08）

Requires / 依赖：Windows 10 / 11 + PowerShell 5.1（系统自带 / built in）。License: MIT
