/**
 * C 组前半（C1–C6）：Qwen3.8-Max 盲测独有发现的静态回归检查。
 *
 * 判定语义（见 tests/SPEC.md）：
 *   present = v5.1.1 源码里缺陷仍在，evidence 必须是真实行文本
 *   fixed   = 已看不到该缺陷，evidence 说明查了哪里 / 现在长什么样
 *
 * 行号一律以实际源码为准：全部用 ctx.find / ctx.lines 现场定位，
 * 不信任盲测报告里的旧行号（可能偏几十到几百行）。
 */
import { trim } from '../lib.mjs';

const F = 'make-rescue-kit.ps1';

/** 把 ctx.find 的命中压成一行证据：L123: 源码原文（超长截断）。 */
function cite(hit, max = 200) {
  if (!hit) return '';
  return `L${hit.line}: ${trim(hit.text, max)}`;
}

/** 多行证据，空段丢掉。 */
function ev(...parts) {
  return parts.filter(Boolean).join('\n');
}

/** 取某行之前 n 行（带行号），用于判断分支条件。 */
function beforeLine(ctx, line, n) {
  const ls = ctx.lines(F);
  const out = [];
  for (let i = Math.max(0, line - 1 - n); i <= line - 2; i++) {
    out.push({ line: i + 1, text: ls[i] });
  }
  return out;
}

export default [
  // ---------------------------------------------------------------------------
  {
    id: 'C1',
    severity: 'P2', // 报告标 P0，人工复核后建议 P2：要 DSH_HOME 恰好指向文件才复现
    title: 'dsh home 用 Test-Path 只判存在、未判目录（DSH_HOME 指向文件也 PASS）',
    file: F,
    detect(ctx) {
      const ok = ctx.find(F, /Add-Check\s+'dsh home'\s+'ok'/);
      if (!ok) {
        return {
          status: 'fixed',
          evidence: `未找到 Add-Check 'dsh home' 'ok' 分支（查遍 ${F} 全文）；dsh home 检查可能已重写，需人工确认它现在判目录而不是判存在。`,
        };
      }

      // ok 分支的条件就在它前面几行：命中 "elseif (Test-Path $Dsh)" 即为缺陷形态。
      const window = beforeLine(ctx, ok.line, 3);
      const cond = window.find((w) => /Test-Path\s+\$Dsh/.test(w.text));
      const dirAware = window.some((w) =>
        /-PathType\s+Container|PSIsContainer|\[System\.IO\.Directory\]::Exists/.test(w.text)
      );

      if (!cond) {
        return {
          status: 'fixed',
          evidence: `L${ok.line} 的 ok 分支前 3 行已不含 Test-Path $Dsh（现为 ${trim(
            window.map((w) => w.text).join(' / '),
            160
          )}），疑似已改为判目录。`,
        };
      }
      if (dirAware) {
        return {
          status: 'fixed',
          evidence: ev(cite(cond), '同一分支窗口里已出现 -PathType Container / PSIsContainer 目录判定。'),
        };
      }

      const exists = ctx.find(F, /dsh_home_exists/);
      return {
        status: 'present',
        evidence: ev(
          cite(cond),
          cite(ok),
          exists ? cite(exists) : '',
          'Test-Path 只判存在、没带 -PathType Container：DSH_HOME 指向一个普通文件时，这一条照样判 ok。'
        ),
      };
    },
    fixHint:
      "改为 elseif (Test-Path -LiteralPath $Dsh -PathType Container) { ... }；系统快照里的 dsh_home_exists 也顺手记成 path_type，别只记存不存在。",
  },

  // ---------------------------------------------------------------------------
  {
    id: 'C2',
    severity: 'P1',
    title: '凭据读不出来时静默报 key_count = 0（不区分「读取失败」和「没配 key」）',
    file: F,
    detect(ctx) {
      const cred = ctx.find(F, /\$cred\s*=\s*Join-Path\s+\$Dsh\s+'\.credentials\.yaml'/);
      const count = ctx.find(F, /key_count\s*=\s*\$\(\s*\$seen\.Count\s*\)/);

      if (!cred) {
        return {
          status: 'fixed',
          evidence: '未找到 .credentials.yaml 的收集入口（查了 $cred / Join-Path $Dsh）；这一段可能已删除或重写，需人工确认。',
        };
      }
      if (!count) {
        return {
          status: 'fixed',
          evidence: `L${cred.line} 起是凭据段，但已找不到 key_count = $($seen.Count) 那一行；计数很可能已改成能表达「读失败」。`,
        };
      }

      // 读取失败在 Read-TextAuto 内部被 catch 成 "<unreadable: …>" 哨兵，
      // 所以关键看凭据段有没有判这个哨兵。
      const raw = ctx.find(F, /Read-TextAuto\s+\$cred\b/);
      const ls = ctx.lines(F);
      const block = ls
        .slice(cred.line - 1, Math.min(ls.length, count.line + 6))
        .join('\n');
      const guarded = /<unreadable|<undecodable|read[-_ ]?fail|readFailed/i.test(block);
      if (guarded) {
        return {
          status: 'fixed',
          evidence: ev(
            cite(raw),
            `key_count 段（L${cred.line}–L${Math.min(ls.length, count.line + 6)}）已出现读取失败分支，不再把失败统一报成 0。`
          ),
        };
      }

      const sentinel = ctx.find(F, /return\s+"<unreadable:/);
      return {
        status: 'present',
        evidence: ev(
          cite(raw),
          cite(count),
          cite(sentinel),
          'Read-TextAuto 读失败时返回 "<unreadable: …>" 哨兵而不是抛异常：正则匹配不到任何 key，key_count 就静默变成 0，支持人员会当成「一个 key 都没配」。'
        ),
      };
    },
    fixHint:
      "读回后先判 $raw -like '<unreadable:*' / '<undecodable:*'，命中就写 key_count = unknown (read failed: …)；别把「读失败」和「没配 key」印成同一行。",
  },

  // ---------------------------------------------------------------------------
  {
    id: 'C3',
    severity: 'P3',
    title: '多帧 zstd 帧链的选择条件不严密（部分成立，当前环境不触发）',
    file: F,
    detect(ctx) {
      const cond = ctx.find(F, /if\s*\(\s*lines\.length\s*<\s*n\s*\|\|\s*frameCount\s*>\s*1\s*\)/);
      const pick = ctx.find(F, /if\s*\(\s*collected\.length\s*>\s*lines\.length\s*\)/);

      if (!pick) {
        return {
          status: 'fixed',
          evidence: '未找到 collected.length > lines.length 这个帧链选择条件（查了 zstd 解码段）；疑似已改成按帧数或解码来源判定。',
        };
      }

      const whole = ctx.find(F, /zstdDecompressSync\(buf\)/);
      return {
        status: 'present',
        evidence: ev(
          cond ? cite(cond) : '',
          cite(pick),
          whole ? cite(whole) : '',
          '部分成立：本机 Node 24 整文件解码不截断，实测不触发。但条件只比行数——整文件只解出第 1 帧、而它的行数又多于从尾部回填的帧数时，仍会把文件开头当成会话尾部。'
        ),
      };
    },
    fixHint:
      "按解码来源判定而不是比行数：帧数 > 1 时一律采用帧链结果，或比较最后一帧的偏移位置是否真的落在文件尾。",
  },

  // ---------------------------------------------------------------------------
  {
    id: 'C4',
    severity: 'P1',
    title: 'global.md 标签写 first 40 lines，实际取的是最后 40 行',
    file: F,
    detect(ctx) {
      const label = ctx.find(F, /==\s*global\.md[^\r\n]*first\s+40/i);
      const read = ctx.find(F, /Read-TextAuto\s+\$memOld\s+40\b/);

      if (!label) {
        const any = ctx.find(F, /global\.md/);
        return {
          status: 'fixed',
          evidence: any
            ? `L${any.line} 仍有 global.md 段，但已没有 "first 40 lines" 字样（现为 ${trim(any.text, 140)}），标签可能已改对。`
            : '未找到 global.md 段（查了 $memOld / global.md），该段可能已删除。',
        };
      }
      if (!read) {
        return {
          status: 'fixed',
          evidence: `L${label.line} 的标签还在，但已找不到 Read-TextAuto $memOld 40；截断参数可能已改。`,
        };
      }

      const cut = ctx.find(F, /\$lines\s*=\s*\$lines\[\s*\(\s*\$lines\.Count\s*-\s*\$maxLines\s*\)/);
      if (!cut) {
        return {
          status: 'fixed',
          evidence: ev(
            cite(label),
            cite(read),
            '未找到 Read-TextAuto 里「取最后 N 行」的切片，需人工确认 maxLines 现在取头还是取尾。'
          ),
        };
      }

      return {
        status: 'present',
        evidence: ev(
          cite(label),
          cite(read),
          cite(cut),
          'Read-TextAuto 的 maxLines > 0 走的就是这个「取最后 N 行」切片，所以传 40 拿到的是尾部 40 行——标签里的 first 是假的。'
        ),
      };
    },
    fixHint:
      '标签改成 last 40 lines；若确实想给开头，另写一段读前 40 行，别让「first」把证据解读带偏。',
  },

  // ---------------------------------------------------------------------------
  {
    id: 'C5',
    severity: 'P1',
    title: 'finally 按通配删共享 _tmp 下的 work-* / dump-*，并发运行互删',
    file: F,
    detect(ctx) {
      const root = ctx.find(F, /\$TmpRoot\s*=\s*Join-Path\s+\$KitDir\s+'_tmp'/);
      const work = ctx.find(F, /GetDirectories\(\s*\$rootL\s*,\s*'work-\*'\s*\)/);
      const dump = ctx.find(F, /GetDirectories\(\s*\$rootL\s*,\s*'dump-\*'\s*\)/);

      if (!work && !dump) {
        return {
          status: 'fixed',
          evidence: '未找到对 work-* / dump-* 的通配删除（查了 rootL / GetDirectories）；可能已改成只删本次运行的目录。',
        };
      }

      const fin = ctx.find(F, /^finally\s*\{/);
      if (!fin) {
        return {
          status: 'fixed',
          evidence: '未找到顶层 finally 块，通配删除可能已挪走，需人工确认现在由谁清理。',
        };
      }
      const hits = [work, dump].filter(Boolean);
      if (!hits.every((h) => h.line > fin.line)) {
        return {
          status: 'fixed',
          evidence: ev(`顶层 finally 在 L${fin.line}，通配删除已不在它里面，需人工确认是否还有调用方。`),
        };
      }

      const workDir = ctx.find(F, /\$workDir\s*=\s*Join-Path\s+\$TmpRoot/);
      return {
        status: 'present',
        evidence: ev(
          cite(root),
          workDir ? cite(workDir) : '',
          cite(work),
          cite(dump),
          '工作目录都建在共享的 _tmp 根下，finally 却按 work-* / dump-* 通配整批删：两次运行重叠时，后结束的一次会把还在跑的那次的工作目录一起删掉（rescue-kit.bat 连点两下就够）。'
        ),
      };
    },
    fixHint:
      '按本次运行的完整目录名删（$workDir / $dumpScratch），或给名字加 $PID 后缀再精确匹配；通配只该匹配自己这一轮的产物。',
  },

  // ---------------------------------------------------------------------------
  {
    id: 'C6',
    severity: 'P1',
    title: 'zip 用 LongPath 创建，回读却 Get-Item 不带 LongPath（超 MAX_PATH 报假 FAILED）',
    file: F,
    detect(ctx) {
      const create = ctx.find(F, /\[System\.IO\.Compression\.ZipFile\]::CreateFromDirectory/);
      const longZip = ctx.find(F, /\(LongPath\s+\$zip\)/);
      const getItem = ctx.find(F, /Get-Item\s+\$zip\b/);

      if (!longZip) {
        return {
          status: 'fixed',
          evidence: '未找到 (LongPath $zip)（查了 CreateFromDirectory 段），创建侧的长路径处理可能已改。',
        };
      }
      if (!getItem) {
        return {
          status: 'fixed',
          evidence: '未找到裸的 Get-Item $zip（查了 $sizeKB / 结尾段），回读很可能已改用 LongPath。',
        };
      }

      const exitLine = ctx.find(F, /if\s*\(\s*-not\s+\$ok\s*\)\s*\{\s*exit\s+1\s*\}/);
      const outside = Boolean(exitLine && exitLine.line < getItem.line);
      return {
        status: 'present',
        evidence: ev(
          cite(create),
          cite(longZip),
          cite(getItem),
          outside
            ? `Get-Item 在 L${exitLine.line} 之后、try/finally 之外：超过 MAX_PATH 时 zip 其实已经写成功，这一行一抛异常就成了假 FAILED（也不会进 salvage 分支）。`
            : 'Get-Item $zip 没套 LongPath：路径超过 MAX_PATH 时读不回包大小，已生成的 zip 会被报成失败。'
        ),
      };
    },
    fixHint:
      '回读也走 LongPath：$sizeKB = [math]::Round((Get-Item -LiteralPath (LongPath $zip)).Length / 1KB, 1)；并用 try 包住，读不回大小不该否定已经生成的 zip。',
  },
];
