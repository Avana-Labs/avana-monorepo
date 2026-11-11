#!/usr/bin/env node
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Runs 4naly3er (tools/4naly3er) without the issues listed under `excluded_detectors` of security/4naly3er-triage.json,
// so a detector that cannot run on Avana's sources (one whose regex backtracks exponentially) is skipped with a
// recorded reason instead of patched. Writes report.md into the working directory, as 4naly3er itself does.
//
//   node script/4naly3er-run.js <base-path> <scope.txt>
//
// The TypeScript sources are transpiled without type checking (ts-node transpileOnly), which cuts start-up time;
// 4naly3er's behaviour is unchanged.

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const TOOL = path.join(ROOT, 'tools/4naly3er');

const [basePath, scopeFile] = process.argv.slice(2);
if (!basePath || !scopeFile) {
  console.error('usage: node script/4naly3er-run.js <base-path> <scope.txt>');
  process.exit(2);
}

require(path.join(TOOL, 'node_modules/ts-node')).register({
  project: path.join(TOOL, 'tsconfig.json'),
  transpileOnly: true,
});

const triageFile = path.join(ROOT, 'security/4naly3er-triage.json');
const triage = fs.existsSync(triageFile) ? JSON.parse(fs.readFileSync(triageFile, 'utf8')) : {};
const skipped = new Set((triage.excluded_detectors || []).map(e => e.check));

const issues = require(path.join(TOOL, 'src/issues')).default;
const known = new Set(issues.map(i => i.title));
for (const title of skipped) {
  if (!known.has(title)) {
    console.error(`4naly3er-run: excluded detector "${title}" is not a 4naly3er issue title`);
    process.exit(2);
  }
}
// main.ts reads the same module instance, so removing entries here removes them from the run.
for (let i = issues.length - 1; i >= 0; i--) if (skipped.has(issues[i].title)) issues.splice(i, 1);

const main = require(path.join(TOOL, 'src/main')).default;
Promise.resolve(main(basePath.endsWith('/') ? basePath : basePath + '/', scopeFile, null, 'report.md')).catch(e => {
  console.error(e);
  process.exit(1);
});
