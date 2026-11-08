/**
 * group-b.mjs — B1..B7
 *
 * B 组：Kimi-K3 盲测独有、已人工复核成立的 7 条（v5.1.1 全部 present）。
 * 只做静态文本判定：不执行 PowerShell、不读系统状态、不引入依赖。
 * 行号来自报告但可能漂移，所有定位一律走 ctx.find/ctx.findAll，evidence 引用现场命中的真实行文本。
 */

const PS = 'make-rescue-kit.ps1';
const READMES = ['README.md', 'README.zh-CN.md', 'README.en.md'];

/** 证据里的单行文本：压掉多余空白、截到 200 字符以内。 */
function one(s, max = 200) {
  const t = String(s ?? '').replace(/\s+/g, ' ').trim();
  return t.length > max ? t.slice(0, max) + '…' : t;
}

/** 命中 → "L123: 原文"；没命中 → 空串（调用方自己 filter）。 */
function ev(hit) {
  return hit ? `L${hit.line}: ${one(hit.text)}` : '';
}

/**
 * 定位函数体：从函数定义行到下一个顶格 '}'。
 * 不用花括号配对，因为 Mask-Secrets 的正则字符串里有 [^"\s,;}] 这种字符类花括号，会配对错。
 */
function functionBody(lines, fnIdx) {
  for (let i = fnIdx + 1; i < lines.length; i++) {
    if (/^\}/.test(lines[i])) return { from: fnIdx + 1, to: i };
  }
  return { from: fnIdx + 1, to: lines.length - 1 };
}

/** 花括号配对，返回块结束行（0-based）；失败返回 -1。只用于不含花括号字符串的简单块。 */
function blockEnd(lines, startIdx) {
  let depth = 0;
  let opened = false;
  for (let i = startIdx; i < lines.length; i++) {
    for (const ch of lines[i]) {
      if (ch === '{') {
        depth++;
        opened = true;
      } else if (ch === '}') {
        depth--;
        if (opened && depth === 0) return i;
      }
    }
  }
  return -1;
}

export default [
  // ---------------------------------------------------------------- B1 -----
  {
    id: 'B1',
    severity: 'P1',
    title: '三份 README 承诺 cookie 会被掩码，Mask-Secrets 规则里没有 cookie/session 规则',
    file: 'make-rescue-kit.ps1',
    detect(ctx) {
      const promised = READMES.map((f) => ({
        file: f,
        hit: ctx.findAll(f, /cookie/i).find((h) => /占位|placeholder|masked|替换|打码/i.test(h.text)) || null,
      }));
      const promisedCount = promised.filter((p) => p.hit).length;

      const ls = ctx.lines(PS);
      const fn = ctx.find(PS, /^function Mask-Secrets\(/);
      let body = null;
      let range = '';
      let cookieRule = null;
      if (fn) {
        body = functionBody(ls, fn.line - 1);
        range = `L${fn.line}–L${body.to + 1}`;
        // 只看函数体里的非注释行：注释里提到 cookie 不算规则。
        cookieRule =
          ctx
            .findAll(PS, /cookie|sessionid|session_id|set-cookie|jsessionid|phpsessid/i)
            .find((h) => h.line > fn.line && h.line <= body.to && !/^\s*#/.test(h.text)) || null;
      }

      if (promisedCount === 3 && !cookieRule) {
        const logTail = ctx.find(PS, /Mask-Secrets \(Read-TextAuto \$lf\.FullName 300\)/);
        return {
          status: 'present',
          evidence: [
            ...promised.map((p) => `${p.file} ${ev(p.hit)}`),
            `Mask-Secrets ${range} 的规则表内无 cookie / sessionid 规则（匹配 0 行）`,
            logTail ? `日志尾部只经过这个函数：${ev(logTail)}` : '',
          ]
            .filter(Boolean)
            .join('\n'),
        };
      }
      if (cookieRule) {
        return { status: 'fixed', evidence: `Mask-Secrets ${range} 已出现 cookie/session 规则：${ev(cookieRule)}` };
      }
      return {
        status: 'fixed',
        evidence: `只找到 ${promisedCount}/3 处 README cookie 掩码承诺，承诺与实现的矛盾已不成立`,
      };
    },
    fixHint: '在 Mask-Secrets 里补 Cookie/Set-Cookie/sessionid 规则（或删掉 README 承诺，但那是降级）',
  },

  // ---------------------------------------------------------------- B2 -----
  {
    id: 'B2',
    severity: 'P2',
    title: 'profile · files 只认 cordis.patch.yml，compose 段却接受 cordis.patch.yml 或 cordis.yml',
    file: 'make-rescue-kit.ps1',
    detect(ctx) {
      // compose 段：任一存在就继续。
      const compose = ctx.find(PS, /Test-Path.*cordis\.patch\.yml.*cordis\.yml/);
      // · files 检查：循环体只遍历 package.json + cordis.patch.yml。
      const req = ctx.find(PS, /foreach \(\$req in @\([^)]*cordis\.patch\.yml/);
      const reqTest = req ? ctx.find(PS, /Test-Path \(Join-Path \$pd\.FullName \$req\)/, req.line) : null;

      if (compose && req && reqTest && !/cordis\.yml/.test(req.text)) {
        return {
          status: 'present',
          evidence: [
            ev(compose),
            ev(req),
            ev(reqTest),
            'compose 段两者都收，· files 检查只认 cordis.patch.yml：只有 cordis.yml 的合法 profile 会被判 missing',
          ].join('\n'),
        };
      }
      return {
        status: 'fixed',
        evidence: '未找到「compose 收两者、files 只认一种」的并存结构，疑似已统一',
      };
    },
    fixHint: "· files 检查也接受 cordis.yml 之一（或按 compose 段同样的两者判断）",
  },

  // ---------------------------------------------------------------- B3 -----
  {
    id: 'B3',
    severity: 'P2',
    title: 'timeline 只跳过顶层 node_modules，profiles 下的 node_modules 仍按深度 99 全遍历',
    file: 'make-rescue-kit.ps1',
    detect(ctx) {
      const skip = ctx.find(PS, /\$tlSkip = @\('node_modules'/);
      if (!skip) {
        return { status: 'fixed', evidence: '未找到 $tlSkip 定义，timeline 遍历逻辑已改' };
      }
      const topOnly = ctx.find(PS, /if \(\$tlSkip -contains \$td\.Name\) \{ continue \}/, skip.line);
      const deep = ctx.find(PS, /Find-Files \$td\.FullName @\('\*'\) 99/, skip.line);
      const post = deep ? ctx.find(PS, /-notmatch '\\\\node_modules\\\\'/, deep.line) : null;
      // Find-Files 只有 (root, patterns, maxDepth) 三个参数，遍历途中没有跳过名单。
      const fn = ctx.find(PS, /^function Find-Files\(\$root, \$patterns, \$maxDepth\)/);

      if (topOnly && deep && post && fn && topOnly.line < deep.line && deep.line < post.line) {
        return {
          status: 'present',
          evidence: [
            ev(skip),
            ev(topOnly),
            ev(deep),
            ev(post),
            `${ev(fn)}（遍历途中无 node_modules 跳过参数，只在事后过滤结果）`,
          ].join('\n'),
        };
      }
      return {
        status: 'fixed',
        evidence: '未找到「顶层跳过 + 深度 99 全走 + 事后过滤」的组合，疑似已在遍历中剪枝',
      };
    },
    fixHint: '给 Find-Files 加跳过名单（或 timeline 遍历时传入），在下降前剪掉 node_modules',
  },

  // ---------------------------------------------------------------- B4 -----
  {
    id: 'B4',
    severity: 'P2',
    title: 'HOMEPATH 进包但短名/常见名规则要求名字后有分隔符，行尾的 \\Users\\test 不掩',
    file: 'make-rescue-kit.ps1',
    detect(ctx) {
      const envKeep = ctx.find(PS, /\$envKeep = @\('/);
      const homepath = ctx
        .findAll(PS, /HOMEPATH/)
        .find((h) => envKeep && h.line >= envKeep.line && h.line <= envKeep.line + 6);
      const envMask = ctx.find(PS, /\$v = Mask-Secrets \(\[string\]\$_\.Value\)/);
      // 常见名/短名专用的回退规则：Lookahead 只认后面跟 [\\/]。
      const commonGuard = ctx.find(PS, /if \(\$isCommon -or \$userName\.Length -lt 4\)/);
      const commonRule = ctx
        .findAll(PS, /\(\?=\[\\\\\/\]\)/)
        .find((h) => /\$esc/.test(h.text) && /Users/.test(h.text));

      if (homepath && envMask && commonGuard && commonRule) {
        return {
          status: 'present',
          evidence: [
            ev(homepath),
            ev(envMask),
            ev(commonGuard),
            ev(commonRule),
            'HOMEPATH 的值形如 \\Users\\test，结尾没有分隔符，lookahead 不成立 → 短名/常见名原样进包',
          ].join('\n'),
        };
      }
      return {
        status: 'fixed',
        evidence: '未同时找到 HOMEPATH 保留 + 强制要求尾部分隔符的常见名规则，疑似已补行尾边界',
      };
    },
    fixHint: '常见名规则允许行尾：(?=[\\\\/]|$)；或干脆不收集 HOMEPATH',
  },

  // ---------------------------------------------------------------- B5 -----
  {
    id: 'B5',
    severity: 'P3',
    title: '拿不到磁盘剩余空间时 disk 检查整行消失（if 无 else）',
    file: 'make-rescue-kit.ps1',
    detect(ctx) {
      const guard = ctx.find(PS, /^if \(\$null -ne \$outFreeMB\) \{/);
      if (!guard) {
        return { status: 'fixed', evidence: '未找到 $outFreeMB 判空守卫，disk 检查结构已改' };
      }
      const ls = ctx.lines(PS);
      const gEnd = blockEnd(ls, guard.line - 1);
      const disks = ctx.findAll(PS, /Add-Check 'disk'/);
      const outside = disks.filter((h) => h.line - 1 < guard.line - 1 || h.line - 1 > gEnd);
      const elseAfter =
        gEnd >= 0 &&
        (/\belse\b/.test(ls[gEnd] || '') || /^\s*else\b/.test(ls[gEnd + 1] || ''));

      if (gEnd > 0 && disks.length > 0 && outside.length === 0 && !elseAfter) {
        return {
          status: 'present',
          evidence: [
            ev(guard),
            ...disks.map(ev),
            `全部 ${disks.length} 处 disk Add-Check 都在这一个 if 内，且无 else 分支：$outFreeMB 为 $null 时整行不出现`,
          ].join('\n'),
        };
      }
      return {
        status: 'fixed',
        evidence: '已存在 null 分支（else 或守卫外的 disk Add-Check），磁盘未知时不再静默',
      };
    },
    fixHint: "补 else { Add-Check 'disk' 'warn' 'free space unknown' ... }",
  },

  // ---------------------------------------------------------------- B6 -----
  {
    id: 'B6',
    severity: 'P3',
    title: '无 BOM 的 UTF-16 小文件按严格 UTF-8 解码成 NUL 交积（NUL 嗅探只在 tailOnly 分支）',
    file: 'make-rescue-kit.ps1',
    detect(ctx) {
      const fn = ctx.find(PS, /^function Read-TextAuto\(/);
      if (!fn) return { status: 'fixed', evidence: '未找到 Read-TextAuto' };
      const ls = ctx.lines(PS);
      const body = functionBody(ls, fn.line - 1);
      const guard = ctx.find(PS, /^\s*if \(\$tailOnly\) \{/, fn.line); // UTF-16 嗅探所在的分支
      const sniff = ctx.findAll(PS, /\$hb\[1\] -eq 0 -and \$hb\[3\] -eq 0/)[0] || null;
      const gEnd = guard ? blockEnd(ls, guard.line - 1) : -1;
      const sniffInside = !!sniff && guard && sniff.line - 1 >= guard.line && sniff.line - 1 <= gEnd;
      // \b 避开 $hb[1] -eq 0xFE（那是 BOM 判断，不是 NUL 嗅探）。
      const sniffCount = ctx.count(PS, /\$hb\[1\] -eq 0\b/g);
      const readAll = ctx.find(PS, /\[System\.IO\.File\]::ReadAllBytes\(\$path\)/, fn.line);
      const bomOnly = ctx.find(PS, /elseif \(\$bytes\.Length -ge 2 -and \$bytes\[0\] -eq 0xFF/, fn.line);

      if (sniffInside && sniffCount === 1 && readAll && bomOnly) {
        return {
          status: 'present',
          evidence: [
            ev(guard),
            ev(sniff),
            ev(readAll),
            ev(bomOnly),
            'NUL 嗅探只在 $tailOnly 分支里；整文件分支只查 BOM，无 BOM 的 UTF-16 掉进严格 UTF-8，解出 NUL 交积',
          ].join('\n'),
        };
      }
      if (sniff && !sniffInside) {
        return { status: 'fixed', evidence: `NUL 嗅探已移出 $tailOnly 分支：${ev(sniff)}` };
      }
      return {
        status: 'fixed',
        evidence: sniffCount > 1 ? '已出现多处 NUL 嗅探，整文件分支疑似补上' : '未找到原有 NUL 嗅探结构，疑似已改',
      };
    },
    fixHint: '把 UTF-16 NUL 嗅探提到 ReadAllBytes 之后、解码之前，两条路径共用',
  },

  // ---------------------------------------------------------------- B7 -----
  {
    id: 'B7',
    severity: 'P3',
    title: '自定义 profile 名未经掩码直接进 zip 条目名（dump-config-<name>.txt）',
    file: 'make-rescue-kit.ps1',
    detect(ctx) {
      const call = ctx.find(PS, /Add-Text \('dump-config-' \+ \$pd\.Name \+ '\.txt'\)/);
      const fn = ctx.find(PS, /^function Add-Text\(\$name, \$text\)/);
      const ls = ctx.lines(PS);
      let nameMasked = true;
      if (fn) {
        const body = functionBody(ls, fn.line - 1);
        nameMasked = ls.slice(body.from, body.to).some((t) => /\$name/.test(t) && /Mask-Secrets/.test(t));
      }
      const maskText = ctx.find(PS, /\$masked = Mask-Secrets \(\[string\]\$text\)/);
      const zip = ctx.find(PS, /ZipFile\]::CreateFromDirectory/);
      const contrast = ctx.find(PS, /\$relPath = \(Mask-Secrets \$relPath\)/);

      if (call && fn && !nameMasked && maskText && zip) {
        return {
          status: 'present',
          evidence: [
            ev(call),
            ev(maskText),
            ev(zip),
            contrast ? `对照（日志条目名单独掩码过）：${ev(contrast)}` : '',
          ]
            .filter(Boolean)
            .join('\n'),
        };
      }
      return {
        status: 'fixed',
        evidence: nameMasked
          ? 'Add-Text 已对 $name 做 Mask-Secrets，条目名不再裸奔'
          : '未找到「profile 名直接拼文件名」的调用，疑似已改',
      };
    },
    fixHint: "Add-Text 里对 $name 也过一遍 Mask-Secrets（注意先掩码再拼路径），或调用处用掩码后的 profile 名",
  },
];
