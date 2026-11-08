/**
 * 组 C2：Qwen3.8-Max 独有发现里已人工复核成立的那 5 条（C7–C11，均 P2）。
 * 被测文件：make-rescue-kit.ps1（v5.1.1，UTF-8 BOM）。
 *
 * 契约见 tests/SPEC.md：detect(ctx) 返回 { status: 'present' | 'fixed', evidence }。
 * 行号来自盲测报告、可能偏移，这里一律按源码关键词定位，evidence 引用真实行文本。
 */

const PS1 = 'make-rescue-kit.ps1';

/** 单行证据：压平换行 + 截断；不动行内空白，保证引用的是源码原文。 */
function clip(s, max = 130) {
  const one = String(s ?? '').replace(/\r?\n/g, ' ').trim();
  return one.length > max ? one.slice(0, max) + '…' : one;
}

function lineOf(hit, max = 130) {
  return `L${hit.line}: ${clip(hit.text, max)}`;
}

/** 从 function 声明行取到顶层 `}` 为止（本文件函数收尾都在第 0 列）。 */
function fnBody(ctx, declLine, maxLines = 80) {
  const ls = ctx.lines(PS1);
  const start = declLine - 1;
  const out = [];
  for (let i = start; i < Math.min(ls.length, start + maxLines); i++) {
    out.push({ line: i + 1, text: ls[i] });
    if (i > start && /^\}/.test(ls[i])) break;
  }
  return out;
}

export default [
  {
    id: 'C7',
    severity: 'P2',
    title: 'TreeOf 的 Test-Path / Get-ChildItem 未用 -LiteralPath，-ExtraDirs 含 [ ] 时被当通配报 missing',
    file: PS1,
    detect(ctx) {
      const fn = ctx.find(PS1, /^\s*function\s+TreeOf\b/);
      if (!fn) {
        return { status: 'fixed', evidence: '未找到 function TreeOf，函数已移除或改名，旧的通配展开路径不复存在' };
      }
      const body = fnBody(ctx, fn.line);
      const testPath = body.find((l) => /\bTest-Path\s+\$root\b/.test(l.text));
      const badTest = testPath && !/-LiteralPath\b/.test(testPath.text) ? testPath : null;
      const badChildren = body.filter(
        (l) => /\bGet-ChildItem\b/.test(l.text) && !/-LiteralPath\b/.test(l.text)
      );

      if (!badTest && badChildren.length === 0) {
        const fixed = body.find((l) => /\bGet-ChildItem\b/.test(l.text) || /\bTest-Path\b/.test(l.text));
        return {
          status: 'fixed',
          evidence: fixed
            ? `TreeOf 内的路径参数已带 -LiteralPath：${lineOf(fixed)}`
            : 'TreeOf 内已无 Test-Path / Get-ChildItem 调用',
        };
      }

      const quoted = [badTest, ...badChildren].filter(Boolean).slice(0, 2).map((h) => lineOf(h));
      return {
        status: 'present',
        evidence:
          `${quoted.join(' ｜ ')} ｜ 位置参数绑定 -Path，[ ] 按通配模式解析；` +
          '字面路径的 -ExtraDirs 于是走到 "missing:" 分支，Get-ChildItem 也会枚举错目标。',
      };
    },
    fixHint:
      '改为 Test-Path -LiteralPath $root；Get-ChildItem -LiteralPath $root / -LiteralPath $_.FullName（其余参数不动）。',
  },

  {
    id: 'C8',
    severity: 'P2',
    title: 'Show-Node 不压平 CR/LF/TAB，命令行里带换行会撕碎进程树图',
    file: PS1,
    detect(ctx) {
      const fn = ctx.find(PS1, /^\s*function\s+Show-Node\b/);
      if (!fn) {
        return { status: 'fixed', evidence: '未找到 function Show-Node，进程树渲染已重写' };
      }
      const body = fnBody(ctx, fn.line);
      const cmd = body.find((l) => /\$cmd\s*=/.test(l.text));
      if (!cmd) {
        return { status: 'fixed', evidence: `Show-Node 内已无 $cmd 赋值（从 L${fn.line} 起）` };
      }

      const flatten = body.filter(
        (l) =>
          /-replace/.test(l.text) &&
          (/`[rn]/.test(l.text) || /`t/.test(l.text) || /\\[rnt]/.test(l.text))
      );
      if (flatten.length > 0) {
        return { status: 'fixed', evidence: `Show-Node 已压平换行/制表符：${lineOf(flatten[0])}` };
      }

      // 对照组：同一个 CommandLine 在 processes.tsv 里是压平过的，说明作者知道这个坑。
      const contrast = ctx.find(PS1, /\$cmd\s*=.*-replace\s+"`r\?`n"/);
      const quoted = [lineOf(cmd)];
      if (contrast) quoted.push(`processes.tsv 同一字段已压平 → ${lineOf(contrast)}`);
      return {
        status: 'present',
        evidence:
          `${quoted.join(' ｜ ')} ｜ 树行按 "\`r\`n" 拼接、$cmd 原样入行，` +
          '命令行里的 CR/LF/TAB 会把一条记录切成多行，进程树错位。',
      };
    },
    fixHint:
      '与 processes.tsv 对齐：$cmd = (Mask-Secrets $node.CommandLine) -replace "`r?`n", \' \' 后再 -replace "`t", \' \'，然后截断到 150。',
  },

  {
    id: 'C9',
    severity: 'P2',
    title: 'Add-Text 写失败只记录仍 $found++，logs 检查按计数报「N 个文件」但包内实际缺失',
    file: PS1,
    detect(ctx) {
      const fn = ctx.find(PS1, /^\s*function\s+Add-Text\b/);
      const addCall = ctx.find(PS1, /Add-Text\s+\(Join-Path\s+'logs'/);
      const inc = ctx.find(PS1, /\$found\+\+/);
      const report = ctx.find(PS1, /\$found\.ToString\(\)/);

      if (!fn || !addCall || !inc || !report) {
        return {
          status: 'fixed',
          evidence:
            `关键结构已变：Add-Text=${fn ? '有' : '无'} / logs 调用=${addCall ? '有' : '无'} / ` +
            `$found++=${inc ? '有' : '无'} / 计数上报=${report ? '有' : '无'}`,
        };
      }

      const body = fnBody(ctx, fn.line);
      const catchIdx = body.findIndex((l) => /catch\s*\{/.test(l.text));
      const inCatch = catchIdx >= 0 ? body.slice(catchIdx) : [];
      const reportsUp = inCatch.some((l) => /\bthrow\b/.test(l.text) || /\breturn\b/.test(l.text));
      const records = body.find((l) => /WriteFailures\s*\+=/.test(l.text));

      if (!records || reportsUp) {
        return {
          status: 'fixed',
          evidence: reportsUp
            ? `Add-Text 的 catch 已向调用方报错（throw/return）：${lineOf(
                inCatch.find((l) => /\bthrow\b|\breturn\b/.test(l.text))
              )}`
            : 'Add-Text 不再把写失败记进 $script:WriteFailures',
        };
      }

      // 计数前是否核对过落盘结果（修好后的典型形态）。
      const afterCall = ctx
        .lines(PS1)
        .slice(addCall.line, inc.line)
        .map((text, i) => ({ line: addCall.line + 1 + i, text }));
      const guarded = afterCall.find((l) =>
        /WriteFailures|\[System\.IO\.File\]::Exists|\bTest-Path\b/.test(l.text)
      );
      if (guarded) {
        return { status: 'fixed', evidence: `logs 计数前已核对落盘结果：${lineOf(guarded)}` };
      }

      return {
        status: 'present',
        evidence:
          `${lineOf(addCall)} ｜ ${lineOf(inc)} ｜ ${lineOf(report)} ｜ ` +
          `Add-Text 的 catch 里（L${records.line}）只 $script:WriteFailures +=，不抛也不返回，` +
          '失败照样被计进 logs 的「N file(s)」ok 项。',
      };
    },
    fixHint:
      '让 Add-Text 返回是否落盘（或抛错），logs 循环只在成功时 $found++；或 logs 检查改用 $script:WriteFailures 里属于 logs 的条目核对。',
  },

  {
    id: 'C10',
    severity: 'P2',
    title: 'link: 空目标经 Join-Path 变成 profile 目录本身，检查通过，畸形 package.json 漏检',
    file: PS1,
    detect(ctx) {
      const sub = ctx.find(PS1, /\.Substring\(5\)/);
      if (!sub) {
        return { status: 'fixed', evidence: '未找到 .Substring(5)，link: 目标的解析方式已改写' };
      }
      const likeLine = ctx.find(PS1, /-like\s+'link:\*'/);
      const joinLine = ctx.find(PS1, /Join-Path\s+\$pd\.FullName\s+\$target/, sub.line);
      const testLine = ctx.find(PS1, /Test-Path\s+\$target\b/, sub.line);
      if (!likeLine || (!joinLine && !testLine)) {
        return {
          status: 'fixed',
          evidence: `link: 依赖的判定结构已变（link 匹配=${likeLine ? '有' : '无'}，Join-Path/Test-Path=${
            joinLine || testLine ? '有' : '无'
          }）`,
        };
      }

      const end = (testLine || joinLine).line;
      const between = ctx.lines(PS1).slice(sub.line, end);
      const guardIdx = between.findIndex((t) =>
        /IsNullOrEmpty|-eq\s*''|-ne\s*''|Length\s+-(?:gt|le|lt|ge)\s+5|-not\s+\$target\b|\.Trim\(/.test(t)
      );
      if (guardIdx >= 0) {
        return {
          status: 'fixed',
          evidence: `已先校验 link: 的目标非空：L${sub.line + 1 + guardIdx}: ${clip(between[guardIdx])}`,
        };
      }

      const quoted = [lineOf(sub)];
      if (joinLine) quoted.push(lineOf(joinLine));
      if (testLine) quoted.push(lineOf(testLine));
      return {
        status: 'present',
        evidence:
          `${quoted.join(' ｜ ')} ｜ "link:" 时 Substring(5) 得空串，` +
          'Join-Path $pd.FullName \'\' 返回 profile 目录本身，Test-Path 恒真，畸形依赖被当成存在。',
      };
    },
    fixHint:
      'Substring 后先判空：$raw -eq \'link:\' 时记 $badLinks（空目标），或 if ([string]::IsNullOrWhiteSpace($target)) { ... }；再做 IsPathRooted / Join-Path。',
  },

  {
    id: 'C11',
    severity: 'P2',
    title: 'CrashDumps 里任何 node.exe / electron.exe 的崩溃都算 DSH-related（VS Code 等会误报 WARN）',
    file: PS1,
    detect(ctx) {
      const broad = ctx.find(
        PS1,
        /\$_.Process\s+-match\s+'\(\?i\)\^\(dsh\|deepseek\|electron\|node\)/
      );
      const root = ctx.find(PS1, /\$dumpRoots\s*\+=\s*\(Join-Path\s+\$localAppDir\s+'CrashDumps'\)/);
      if (!broad) {
        return {
          status: 'fixed',
          evidence:
            '已不再用 ^(dsh|deepseek|electron|node) 的进程名前缀正则判定 DSH 相关转储',
        };
      }

      const quoted = [lineOf(broad)];
      if (root) quoted.push(lineOf(root));
      return {
        status: 'present',
        evidence:
          `${quoted.join(' ｜ ')} ｜ 整个 %LOCALAPPDATA%\\CrashDumps 是系统级目录，` +
          '只看进程名前缀、不关联可执行文件路径/命令行；任意 node.exe、electron.exe 的转储都会计入 ' +
          '「DSH-related」并触发 48h WARN。',
      };
    },
    fixHint:
      '按转储对应的 exe 路径/命令行是否落在 DSH 安装目录或 DSH 的 Crashpad 根来判断；仅进程名匹配 node/electron 的一律归入 unrelated（保持现有 "unrelated, e.g. adb" 文案）。',
  },
];
