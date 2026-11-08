#!/usr/bin/env node
/**
 * DSH 急救包静态回归夹具。
 *
 * 用法（在仓库根目录）：
 *   node tests/run.mjs                    跑全部检查，与 baseline.json 比对
 *   node tests/run.mjs --verbose          连通过的检查也打印证据
 *   node tests/run.mjs --only=A1,B4       只跑指定条目（仍按 baseline 比对）
 *   node tests/run.mjs --update-baseline  把当前 detect 结果写回 baseline（修完 v5.1.2 后用）
 *
 * 语义：detect() 返回 'present' = 缺陷仍在；'fixed' = 缺陷已修/已不存在。
 * v5.1.1 的 baseline 是 23 条全部 'present'；修完后跑 --update-baseline 翻成 'fixed'。
 */
import { readdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createContext } from './lib.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const kitArg = args.find((a) => a.startsWith('--kit='));
const KIT = kitArg ? resolve(kitArg.slice(6)) : join(__dirname, '..');
const FILES = ['make-rescue-kit.ps1', 'rescue-kit.bat', 'README.md', 'README.zh-CN.md', 'README.en.md'];
if (!existsSync(join(KIT, FILES[0]))) {
  console.error(`找不到目标套件：${KIT}（缺 ${FILES[0]}）`);
  process.exit(2);
}
const ctx = createContext(KIT, FILES);

const onlyArg = args.find((a) => a.startsWith('--only='));
const only = onlyArg ? onlyArg.slice(7).split(',').map((s) => s.trim()).filter(Boolean) : null;
const update = args.includes('--update-baseline');
const verbose = args.includes('--verbose');
// --report：只报告每条 present/fixed，不跟 baseline 对错（用来扫桌面旧版/别的副本）
const report = args.includes('--report');

const checksDir = join(__dirname, 'checks');
const moduleFiles = existsSync(checksDir)
  ? readdirSync(checksDir).filter((f) => f.endsWith('.mjs')).sort()
  : [];
const checks = [];
for (const f of moduleFiles) {
  const mod = await import(pathToFileURL(join(checksDir, f)).href);
  for (const c of mod.default || []) checks.push({ ...c, module: f });
}

const baselinePath = join(__dirname, 'baseline.json');
const baseline = existsSync(baselinePath) ? JSON.parse(readFileSync(baselinePath, 'utf8')) : {};

const selected = only ? checks.filter((c) => only.includes(c.id)) : checks;
const results = [];
let failed = 0;

for (const c of selected) {
  let res;
  try {
    res = c.detect(ctx);
  } catch (err) {
    res = { status: 'error', evidence: String((err && err.message) || err) };
  }
  if (!res || typeof res.status !== 'string') {
    res = { status: 'error', evidence: 'detect() 没有返回 { status, evidence }' };
  }
  const expected = report ? null : baseline[c.id] ?? 'present';
  const pass = report ? res.status !== 'error' : res.status === expected;
  if (!pass) failed++;
  results.push({
    id: c.id,
    title: c.title,
    severity: c.severity || '',
    file: c.file || '',
    module: c.module,
    status: res.status,
    expected,
    pass,
    evidence: res.evidence || '',
  });
}

const idWidth = Math.max(...results.map((r) => r.id.length), 2);
for (const r of results) {
  const mark = report ? r.status.toUpperCase() : r.pass ? 'PASS' : 'FAIL';
  const expect = report ? '' : `(expect ${r.expected})`;
  console.log(`[${mark}] ${r.id.padEnd(idWidth)} ${r.status.padEnd(7)} ${expect} ${r.title}`.replace(/\s+$/, ''));
  if (report || !r.pass || verbose) {
    console.log(`        ${String(r.evidence || '').split('\n').join('\n        ')}`);
  }
}

const summary = {
  generatedAt: new Date().toISOString(),
  kit: KIT,
  total: results.length,
  failed,
  results,
};
writeFileSync(join(__dirname, 'results.json'), JSON.stringify(summary, null, 2));

if (update) {
  for (const r of results) baseline[r.id] = r.status;
  const sorted = Object.fromEntries(Object.entries(baseline).sort(([a], [b]) => a.localeCompare(b)));
  writeFileSync(baselinePath, JSON.stringify(sorted, null, 2));
  console.log(`\nbaseline.json 已更新（${results.length} 条）。`);
}

if (report) {
  console.log(`\n${results.length} checks reported on ${KIT}${failed ? `, ${failed} error(s)` : ''}.`);
} else {
  console.log(`\n${results.length} checks, ${failed} mismatch(es).`);
}
process.exitCode = failed ? 1 : 0;
