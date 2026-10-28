#!/usr/bin/env node
// Fails on any high or critical npm advisory that is not a reviewed exception.
//
// Usage: node scripts/npm-audit-check.mjs <package directory> [...]
// Exceptions live in scripts/npm-audit-exceptions.json, each with a reason and
// a review_by date; an exception past its date fails like a new advisory.
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const exceptions = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'npm-audit-exceptions.json'), 'utf8'));
const today = new Date().toISOString().slice(0, 10);
const failing = new Set(['high', 'critical']);
let failures = 0;

for (const dir of process.argv.slice(2)) {
  let report;
  try {
    report = execFileSync('npm', ['audit', '--json'], { cwd: dir, encoding: 'utf8' });
  } catch (error) {
    // npm audit exits non-zero when it finds anything; the JSON is still printed.
    report = error.stdout;
  }
  const advisories = new Map();
  for (const vulnerability of Object.values(JSON.parse(report).vulnerabilities ?? {})) {
    for (const via of vulnerability.via) {
      if (typeof via === 'object' && failing.has(via.severity)) {
        advisories.set(via.url.split('/').pop(), via);
      }
    }
  }
  for (const [id, via] of advisories) {
    const exception = exceptions[id];
    if (!exception) {
      console.log(`${dir}: ${via.severity} ${id} in ${via.name}: ${via.title}`);
      failures += 1;
    } else if (exception.review_by < today) {
      console.log(`${dir}: exception for ${id} expired on ${exception.review_by}; review it`);
      failures += 1;
    } else {
      console.log(`${dir}: ${id} in ${via.name} accepted until ${exception.review_by}`);
    }
  }
}
console.log(`npm-audit-check: ${failures} unaccepted high or critical advisory(ies)`);
process.exit(failures ? 1 : 0);
