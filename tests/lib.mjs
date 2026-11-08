import { readFileSync } from 'node:fs';
import { join } from 'node:path';

/**
 * 构造检查上下文。所有检查模块通过 detect(ctx) 使用它。
 * 文件按需读取并缓存，避免重复 IO。
 */
export function createContext(kitDir, fileNames = []) {
  const cache = new Map();

  const text = (name) => {
    if (!cache.has(name)) cache.set(name, readFileSync(join(kitDir, name), 'utf8'));
    return cache.get(name);
  };

  const lines = (name) => text(name).split(/\r?\n/);

  const find = (name, re, fromLine = 0) => {
    const ls = lines(name);
    for (let i = Math.max(0, (fromLine || 1) - 1); i < ls.length; i++) {
      re.lastIndex = 0;
      if (re.test(ls[i])) return { line: i + 1, text: ls[i] };
    }
    return null;
  };

  const findAll = (name, re) => {
    const out = [];
    lines(name).forEach((t, i) => {
      re.lastIndex = 0;
      if (re.test(t)) out.push({ line: i + 1, text: t });
    });
    return out;
  };

  const near = (name, line, radius = 3) => {
    const ls = lines(name);
    const from = Math.max(0, line - 1 - radius);
    return ls.slice(from, line + radius).join('\n');
  };

  const count = (name, re) => {
    const m = text(name).match(re);
    return m ? m.length : 0;
  };

  const exists = (name) => fileNames.length === 0 || fileNames.includes(name);

  return { text, lines, find, findAll, near, count, exists };
}

/** 截断证据文本，避免单行过长撑爆报告。 */
export function trim(s, max = 220) {
  const one = String(s ?? '').replace(/\r?\n/g, ' ');
  return one.length > max ? one.slice(0, max) + '…' : one;
}
