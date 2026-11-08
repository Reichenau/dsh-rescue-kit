#!/usr/bin/env node
/**
 * 单模块自测：node tests/selftest.mjs group-a.mjs
 * 只加载指定检查模块，打印每条 detect() 的结果，便于写检查时调试。
 */
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createContext } from './lib.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const KIT = join(__dirname, '..');
const FILES = ['make-rescue-kit.ps1', 'rescue-kit.bat', 'README.md', 'README.zh-CN.md', 'README.en.md'];
const ctx = createContext(KIT, FILES);

const moduleFile = process.argv[2];
if (!moduleFile) {
  console.error('用法: node tests/selftest.mjs <group-x.mjs>');
  process.exit(2);
}

const mod = await import(pathToFileURL(join(__dirname, 'checks', moduleFile)).href);
const list = mod.default || [];
for (const c of list) {
  let res;
  try {
    res = c.detect(ctx);
  } catch (e) {
    res = { status: 'error', evidence: String((e && e.message) || e) };
  }
  console.log(`[${res.status}] ${c.id}  ${c.title}`);
  console.log(`    ${String(res.evidence || '').replace(/\r?\n/g, '\n    ')}`);
}
console.log(`\n${list.length} checks loaded from ${moduleFile}`);
