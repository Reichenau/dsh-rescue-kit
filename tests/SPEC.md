# 静态回归夹具（v5.1.1 → v5.1.2）

把第三只眼盲测里**已逐条核实**的问题固化成静态检查，模型不再需要每次重新发现已知缺陷。

## 为什么

- 盲测确认了 23 条真问题（含两家都漏的 2 条），每次让模型重读 164KB 全文是浪费。
- 夹具零成本、秒级、可进 CI；模型只负责看**本次改动**新增的问题。

## 文件

| 文件 | 作用 |
|---|---|
| `run.mjs` | 总入口：加载 `checks/*.mjs`，逐条 detect，与 `baseline.json` 比对 |
| `selftest.mjs` | 单模块自测：`node tests/selftest.mjs group-a.mjs` |
| `lib.mjs` | 构造 ctx（text / lines / find / findAll / near / count） |
| `baseline.json` | 期望状态表：v5.1.1 全部 `present`；修完后 `--update-baseline` |
| `results.json` | 最近一次跑分结果（自动生成） |
| `false-claims.json` | 禁报项（模型报出即判误报，见方案 3.3） |
| `checks/*.mjs` | 检查模块，按 A/B/C 分组 |

## 用法

在仓库根目录：

```powershell
node tests/run.mjs                    # 全量跑，PASS/FAIL 对照 baseline
node tests/run.mjs --verbose          # 连通过的也打印证据
node tests/run.mjs --only=A1,B4       # 只跑指定条目
node tests/run.mjs --update-baseline  # 修完 v5.1.2 后刷新基线
```

退出码：0 = 全部符合基线；1 = 有条目与基线不符（回归或修好未更新基线）。

## 检查契约

每个 `checks/group-*.mjs` 默认导出检查对象数组：

```js
export default [
  {
    id: 'A1',
    severity: 'P1',
    title: 'version 检查恒真 PASS',
    file: 'make-rescue-kit.ps1',
    detect(ctx) {
      const hit = ctx.find('make-rescue-kit.ps1', /\$hostVer\s+-ne\s+'unknown'/);
      return hit
        ? { status: 'present', evidence: `L${hit.line}: ${hit.text.trim()}` }
        : { status: 'fixed', evidence: '未找到恒真比较，疑似已修' };
    },
    fixHint: '改为 -like 或用 StartsWith 判断整句哨兵',
  },
];
```

`status` 语义：

- `present`：当前源码里缺陷仍在（证据必须引用真实行文本）。
- `fixed`：缺陷已不存在/已修好（说明改了哪里）。
- 找不到证据时**不许编造**，如实返回并在 evidence 里写清楚你查了哪些位置。

## 条目清单（23 应报 + 1 禁报）

- A 组（3，双方共同命中）：A1 version 假 PASS、A2 ASCII runner、A3 事件日志假声明
- B 组（7，K3 独有）：B1 cookie 承诺失效、B2 patch.yml/cordis.yml 矛盾、B3 timeline 深度遍历、B4 HOMEPATH 短名裸奔、B5 disk 行消失、B6 无 BOM UTF-16、B7 profile 名进 zip 条目
- C 组（11，Qwen 独有；C3 为部分成立）：C1 dsh home Test-Path、C2 凭据读失败静默 0、C3 多帧 zstd 条件、C4 global.md first/last、C5 通配删共享 _tmp、C6 LongPath 假 FAILED、C7 TreeOf 通配、C8 Show-Node 不压平、C9 Add-Text 假计数、C10 link: 空目标、C11 崩溃转储泛化
- D 组（2，两家都漏、MiMo 确认）：D1 token 字符类缺 `. + / =`、D2 `dump-*` 通配改精确删

禁报项：F1「奇数长度 UTF-16 解码会抛异常」——实测只返回替换字符，不抛。

## 注意

- 行号来自盲测报告与人工核对，**可能偏**；检查应以源码实际内容为准。
- 夹具只做静态判定；「思考预算」「diff 审」等改造不在这里验证。
- 夹具只增不减：每次发现新的误报/漏报，先补进 `false-claims.json` 或新增检查。
