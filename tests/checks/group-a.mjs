/**
 * A 组（A1–A3）+ D 组 D1/D2 的静态检查。
 *
 * 契约见 tests/SPEC.md：detect(ctx) 返回 { status, evidence }，
 * status = 'present' 表示缺陷仍在，'fixed' 表示已不存在。
 * 行号只作定位参考，一律以搜到的真实源码行为准。
 */
const PS = 'make-rescue-kit.ps1';

/** 把证据压成单行并截断，避免报告被超长行撑爆（SPEC 要求 evidence ≤200 字符）。 */
function clip(s, max = 200) {
  const one = String(s ?? '').replace(/\s+/g, ' ').trim();
  return one.length > max ? one.slice(0, max - 1) + '…' : one;
}

/** 拼接证据片段，自动丢掉空项。 */
function joinEvidence(...parts) {
  return parts.filter(Boolean).join(' | ');
}

export default [
  {
    id: 'A1',
    severity: 'P1',
    title: 'version 检查恒真 PASS',
    file: PS,
    detect(ctx) {
      // 缺陷本体是比较式，不是初始化那一行：哨兵是整句 'unknown (...)',
      // 比较却只拿 'unknown' 去比，两者永不相等 → version 永远走 ok 分支。
      const sentinel = ctx.find(
        PS,
        /\$hostVer\s*=\s*'unknown \(agent not running, or path not readable\)'/
      );
      const compare = ctx.find(PS, /\$hostVer\s+-ne\s+'unknown'/);

      if (compare && sentinel) {
        return {
          status: 'present',
          evidence: joinEvidence(
            `L${compare.line}: ${clip(compare.text)}`,
            `哨兵 L${sentinel.line} 是整句 'unknown (agent not running, or path not readable)'，-ne 'unknown' 恒真`
          ),
        };
      }
      if (compare && !sentinel) {
        return {
          status: 'fixed',
          evidence: `L${compare.line} 仍有 -ne 'unknown'，但未再找到整句哨兵初始化；比较式可能已合法，建议人工复核`,
        };
      }
      return {
        status: 'fixed',
        evidence: `未找到 $hostVer -ne 'unknown' 恒真比较（已搜 ${PS} 全文），疑似已修`,
      };
    },
    fixHint: '用 -like 或 StartsWith 判断整句哨兵，或把哨兵改成恰好 "unknown"。',
  },

  {
    id: 'A2',
    severity: 'P1',
    title: 'dump-config runner .cmd 用 ASCII 写出',
    file: PS,
    detect(ctx) {
      const write = ctx.find(PS, /\[System\.IO\.File\]::WriteAllLines\(\s*\$runnerPath/);
      const ascii = ctx.find(PS, /ASCIIEncoding/);
      // 确认 ASCII 编码真的落在写 runner 的这一段，而不是别处无关用法。
      const inSameBlock =
        write && ascii && ctx.near(PS, write.line, 2).includes('ASCIIEncoding');

      if (write && ascii && inSameBlock) {
        const runner = ctx.find(
          PS,
          /\$runnerPath\s*=\s*Join-Path\s+\$dumpScratch\s+\$runnerName/
        );
        return {
          status: 'present',
          evidence: joinEvidence(
            `L${write.line}: ${clip(write.text, 150)}`,
            `dump-config 的 .cmd runner${runner ? `（L${runner.line} 拼出）` : ''} 以 ASCII 落盘，非 ASCII 路径/用户名写成 ?`
          ),
        };
      }
      return {
        status: 'fixed',
        evidence: write
          ? `L${write.line} 仍用 WriteAllLines 写 runner，但附近未见 ASCIIEncoding，疑似已改用 UTF-8`
          : `未找到写 $runnerPath 的 WriteAllLines（已搜 ${PS} 全文），疑似已修`,
      };
    },
    fixHint: '改用 UTF8Encoding（或 -Encoding UTF8 的 Set-Content），别用 ASCIIEncoding。',
  },

  {
    id: 'A3',
    severity: 'P2',
    title: '事件日志假声明（文案与 $triageSkip 矛盾）',
    file: PS,
    detect(ctx) {
      // 文案说事件日志「不在本次扫描里」，但采集步骤确实写了 recent-errors.txt，
      // 而且这个文件并不在 $triageSkip 里 —— 它反而会被模式扫描。
      const claim = ctx.find(PS, /The Windows event log is not part of this scan/);
      const skip = ctx.find(PS, /\$triageSkip\s*=\s*@\(/);
      const collector = ctx.find(PS, /Add-Text\s+'recent-errors\.txt'/);
      const skipHasRecent = !!skip && /recent-errors\.txt/.test(skip.text);

      if (claim && skip && collector && !skipHasRecent) {
        return {
          status: 'present',
          evidence: joinEvidence(
            `L${claim.line}: ${clip(claim.text, 110)}`,
            `L${skip.line} $triageSkip 不含 recent-errors.txt；L${collector.line} 又采集事件日志写入该文件`
          ),
        };
      }
      if (!claim) {
        return {
          status: 'fixed',
          evidence: `未找到「The Windows event log is not part of this scan」文案（已搜 ${PS} 全文），疑似已修`,
        };
      }
      return {
        status: 'fixed',
        evidence: `L${claim.line} 文案仍在，但跳过表 L${skip ? skip.line : '?'} 已含 recent-errors.txt 或采集步骤缺失，矛盾已消除`,
      };
    },
    fixHint: '改文案说明 recent-errors.txt 来自事件日志；或把 recent-errors.txt 加进 $triageSkip。',
  },

  {
    id: 'D1',
    severity: 'P1',
    title: 'token 字符类不含 . + / =（base64/JWT 类 token 掩不干净）',
    file: PS,
    detect(ctx) {
      // 在 Mask-Secrets 函数体内找 token 前缀规则；sk- 这条是代表，
      // 同类 gh_/github_pat_/hf_/xox 用的也是只含字母数字下划线连字符的字符类。
      const fn = ctx.find(PS, /function\s+Mask-Secrets\s*\(/);
      if (!fn) {
        return {
          status: 'fixed',
          evidence: `未找到 Mask-Secrets 函数（已搜 ${PS} 全文），疑似结构已改，需人工复核`,
        };
      }
      const skRule = ctx.find(PS, /sk-\[A-Za-z0-9_\\-\]\{20,\}/, fn.line);
      if (!skRule) {
        return {
          status: 'fixed',
          evidence: `Mask-Secrets（L${fn.line}）里未找到 sk-[A-Za-z0-9_\\-]{20,} 规则，疑似已改字符类`,
        };
      }

      const m = skRule.text.match(/\[([^\]]+)\]\{20,\}/);
      const cls = m ? m[1] : '';
      const missing = ['.', '+', '/', '='].filter((ch) => !cls.includes(ch));
      // 负字符类 [^...] 本身就是宽匹配，不算这个缺陷。
      const isNegated = cls.startsWith('^');

      if (cls && !isNegated && missing.length > 0) {
        return {
          status: 'present',
          evidence: joinEvidence(
            `L${skRule.line}: ${clip(skRule.text, 120)}`,
            `字符类缺 ${missing.join(' ')}，base64/JWT 类 token 只掩到第一个断点，剩余字符外泄`
          ),
        };
      }
      return {
        status: 'fixed',
        evidence: `L${skRule.line} 的 char class 为 [${cls}]，已覆盖 . + / = 或改成宽匹配，缺陷不再`,
      };
    },
    fixHint: '字符类扩到 [A-Za-z0-9_.+\\-/=]（或改成 [^\\s"\'] 宽匹配），并同步 gh_/hf_/xox 等同类规则。',
  },

  {
    id: 'D2',
    severity: 'P2',
    title: '清理临时目录用 dump-* 通配删除',
    file: PS,
    detect(ctx) {
      // 本进程的临时目录名是确定的 'dump-' + $PID，通配删除会顺手带走
      // 别的并发进程的目录（并发问题由 C5 判，这里只看「通配 vs 精确」）。
      const wild = ctx.find(
        PS,
        /GetDirectories\(\s*\$rootL\s*,\s*'dump-\*'\s*\)/
      );
      if (wild) {
        const exactName = ctx.find(
          PS,
          /\$dumpScratch\s*=\s*Join-Path\s+\$TmpRoot\s+\('dump-'\s*\+\s*\$PID\)/
        );
        return {
          status: 'present',
          evidence: joinEvidence(
            `L${wild.line}: ${clip(wild.text, 130)}`,
            exactName
              ? `通配删所有 dump-*；L${exactName.line} 本进程目录名是 'dump-' + $PID，可精确删`
              : '通配删所有 dump-*，应改为按已知目录名精确删除'
          ),
        };
      }
      return {
        status: 'fixed',
        evidence: `未找到 GetDirectories($rootL, 'dump-*') 通配删除（已搜 ${PS} 全文），疑似已改精确删除`,
      };
    },
    fixHint: "用 $dumpScratch（'dump-' + $PID）精确删除，别用 'dump-*' 通配。",
  },
];
