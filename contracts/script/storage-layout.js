#!/usr/bin/env node
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Storage-layout snapshots of every upgradeable src/ contract and of every contract that shares an ERC-7201
// namespace with one (the logic contracts the ParameterStore and MarketRegistry delegatecall).
//
//   node script/storage-layout.js <forge-out-dir> --snapshots security/storage-layout [--update]
//
// <forge-out-dir> is a `forge build --build-info --extra-output storageLayout` output (security-fast.sh's build). For
// each build-info file whose src/ sources declare `@custom:storage-location erc7201:<id>`, the script recompiles the
// sources with every namespaced struct turned into a state variable (OpenZeppelin upgrades-core makeNamespacedInput,
// the method of the OpenZeppelin upgrade plugins) with the build's own solc, so each namespace member gets its slot
// and byte offset from the compiler. A snapshot, one file per contract, lists:
//
//   storage     the contract's plain storage variables (the `storageLayout` artifact of `forge inspect <C>
//               storageLayout`); empty for Avana's contracts, whose state is namespaced
//   namespaces  per ERC-7201 id: the base slot erc7201(id), and every field reachable from the namespace struct,
//               flattened: path (`g.maxLtvBps`, `market[].hardHealthFloor`), slot relative to its base (the namespace
//               base, or the hashed location of a mapping value or dynamic array element), byte offset, size, and
//               canonical type label
//
// The check fails when:
//   - a field of a snapshot is missing, or its slot, offset, size or type changed (any change to an existing slot);
//   - a new field overlaps a slot range that an existing field of the same base used;
//   - a namespace's base slot is not erc7201(id), or the hex value of erc7201(id) does not appear in the source file
//     that declares the namespace (the slot constant the code uses);
//   - two contracts that declare the same namespace disagree on its layout;
//   - a contract to snapshot has no snapshot file, or a snapshot file has no contract (run with --update after review).
// Fields appended after the last used slot of their base pass and are reported; --update then records them.

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const core = require(path.join(ROOT, 'node_modules/@openzeppelin/upgrades-core'));
// unfoldStorageLayout is not re-exported by the package index.
const { unfoldStorageLayout } = require(path.join(ROOT, 'node_modules/@openzeppelin/upgrades-core/dist/validate/query'));
const { keccak256 } = require(path.join(ROOT, 'node_modules/ethereum-cryptography/keccak'));

const UPGRADEABLE_BASES = new Set(['Initializable', 'UUPSUpgradeable']);

function usage(msg) {
  if (msg) console.error(`storage-layout: ${msg}`);
  console.error('usage: node script/storage-layout.js <forge-out-dir> --snapshots <dir> [--update]');
  process.exit(2);
}

function parseArgs() {
  const args = process.argv.slice(2);
  const out = { update: false };
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--snapshots') out.snapshots = args[++i];
    else if (args[i] === '--update') out.update = true;
    else if (!out.build) out.build = args[i];
    else usage(`unexpected argument ${args[i]}`);
  }
  if (!out.build || !out.snapshots) usage();
  return out;
}

function erc7201(id) {
  const inner = BigInt('0x' + Buffer.from(keccak256(Buffer.from(id, 'utf8'))).toString('hex')) - 1n;
  const word = Buffer.from(inner.toString(16).padStart(64, '0'), 'hex');
  const outer = BigInt('0x' + Buffer.from(keccak256(word)).toString('hex'));
  return '0x' + (outer & ~0xffn).toString(16).padStart(64, '0');
}

function findSolc(version) {
  const candidates = [
    process.env.SOLC,
    path.join(os.homedir(), 'Library/Application Support/svm', version, `solc-${version}`),
    path.join(process.env.XDG_DATA_HOME || path.join(os.homedir(), '.local/share'), 'svm', version, `solc-${version}`),
    path.join(os.homedir(), '.svm', version, `solc-${version}`),
    path.join(ROOT, 'tools/bin', `solc-${version}`),
  ].filter(Boolean);
  for (const c of candidates) if (fs.existsSync(c)) return c;
  throw new Error(`solc ${version} not found (looked in ${candidates.join(', ')}); set SOLC=<path>`);
}

function compileNamespaced(buildInfo) {
  const input = core.makeNamespacedInput(buildInfo.input, buildInfo.output, buildInfo.solcVersion);
  const settings = { ...input.settings, outputSelection: { '*': { '': ['ast'], '*': ['storageLayout'] } } };
  delete settings.libraries;
  // Only the standard-JSON keys: forge's build-info input also carries version, allowPaths, basePath, includePaths.
  const solcInput = { language: input.language, sources: input.sources, settings };
  const solc = findSolc(buildInfo.solcVersion);
  const raw = execFileSync(solc, ['--standard-json', '--base-path', ROOT, '--allow-paths', ROOT], {
    input: JSON.stringify(solcInput),
    maxBuffer: 1 << 30,
    cwd: ROOT,
  });
  const output = JSON.parse(raw.toString('utf8'));
  const errors = (output.errors || []).filter(e => e.severity === 'error');
  if (errors.length) throw new Error(`namespaced compilation failed: ${errors.map(e => e.formattedMessage).join('\n')}`);
  return output;
}

// Canonical label of a type, independent of AST ids.
function typeLabel(types, typeId) {
  const t = types[typeId];
  return t ? t.label : typeId;
}

function bytesOf(types, typeId) {
  const t = types[typeId];
  return t && t.numberOfBytes !== undefined ? BigInt(t.numberOfBytes) : 32n;
}

// Flattens a field: a struct expands into its members, a mapping's value and a dynamic array's element start a new
// base (path suffix `[]`), a static array keeps its element type in the label.
function flatten(types, prefix, typeId, slot, offset, out, depth = 0) {
  const t = types[typeId] || {};
  out.push({ path: prefix, slot: slot.toString(), offset, bytes: bytesOf(types, typeId).toString(), type: typeLabel(types, typeId) });
  if (depth > 16) return;
  if (t.members && t.members.length && typeof t.members[0] === 'object') {
    for (const m of t.members) {
      if (m.slot === undefined) throw new Error(`no slot for member ${prefix}.${m.label}: namespaced compilation missing`);
      flatten(types, `${prefix}.${m.label}`, m.type, slot + BigInt(m.slot), m.offset || 0, out, depth + 1);
    }
  }
  const mapping = /^t_mapping\((.+)\)$/.exec(typeId);
  if (mapping) {
    // t_mapping(<key>,<value>): the value type is the rest after the key type id.
    const value = t.value || splitMapping(typeId)[1];
    if (value) flatten(types, `${prefix}[]`, value, 0n, 0, out, depth + 1);
  } else if (/^t_array\(.+\)dyn_storage$/.test(typeId)) {
    const element = t.base || /^t_array\((.+)\)dyn_storage$/.exec(typeId)[1];
    flatten(types, `${prefix}[]`, element, 0n, 0, out, depth + 1);
  }
}

function splitMapping(typeId) {
  const body = typeId.slice('t_mapping('.length, -1);
  let depth = 0;
  for (let i = 0; i < body.length; i++) {
    if (body[i] === '(') depth++;
    else if (body[i] === ')') depth--;
    else if (body[i] === ',' && depth === 0) return [body.slice(0, i), body.slice(i + 1)];
  }
  return [body, undefined];
}

function isUpgradeable(contractDef, deref) {
  for (const id of contractDef.linearizedBaseContracts) {
    const base = deref(['ContractDefinition'], id);
    if (UPGRADEABLE_BASES.has(base.name)) return true;
  }
  return false;
}

function namespaceSources(buildInfo) {
  return Object.keys(buildInfo.input.sources).filter(
    s => s.startsWith('src/') && /@custom:storage-location\s+erc7201:/.test(buildInfo.input.sources[s].content || ''),
  );
}

function snapshotsOf(buildDir) {
  const dir = path.join(buildDir, 'build-info');
  const result = {};
  for (const file of fs.readdirSync(dir).filter(f => f.endsWith('.json')).sort()) {
    const buildInfo = JSON.parse(fs.readFileSync(path.join(dir, file), 'utf8'));
    const declaring = namespaceSources(buildInfo);
    const decodeSrc = core.solcInputOutputDecoder(buildInfo.input, buildInfo.output);
    const namespacedOutput = declaring.length ? compileNamespaced(buildInfo) : undefined;
    const runData = core.validate(buildInfo.output, decodeSrc, buildInfo.solcVersion, buildInfo.input, namespacedOutput);
    const { astDereferencer } = require(path.join(ROOT, 'node_modules/solidity-ast/utils'));
    const deref = astDereferencer(buildInfo.output);
    const { findAll } = require(path.join(ROOT, 'node_modules/solidity-ast/utils'));
    for (const source of Object.keys(buildInfo.output.sources).filter(s => s.startsWith('src/'))) {
      for (const c of findAll('ContractDefinition', buildInfo.output.sources[source].ast)) {
        if (c.contractKind !== 'contract' || c.abstract) continue;
        const fqn = `${source}:${c.name}`;
        const layout = unfoldStorageLayout(runData, fqn);
        const namespaces = layout.namespaces || {};
        if (!isUpgradeable(c, deref) && Object.keys(namespaces).length === 0) continue;
        // The artifact's storageLayout is what `forge inspect <C> storageLayout` prints.
        const artifactFile = path.join(buildDir, path.basename(source), `${c.name}.json`);
        const plain = fs.existsSync(artifactFile) ? JSON.parse(fs.readFileSync(artifactFile, 'utf8')).storageLayout : undefined;
        if (!plain) throw new Error(`no storageLayout in ${artifactFile}: build with --extra-output storageLayout`);
        const snapshot = { contract: c.name, source, storage: [], namespaces: {} };
        for (const item of plain.storage) {
          flatten(plain.types, item.label, item.type, BigInt(item.slot), item.offset, snapshot.storage);
        }
        for (const [ns, items] of Object.entries(namespaces).sort()) {
          const id = ns.replace(/^erc7201:/, '');
          const fields = [];
          for (const item of items) {
            if (item.slot === undefined) throw new Error(`no slot for ${ns} ${item.label}`);
            flatten(layout.types, item.label, item.type, BigInt(item.slot), item.offset || 0, fields);
          }
          snapshot.namespaces[ns] = { baseSlot: erc7201(id), declaredIn: items.length ? items[0].src.split(':')[0] : '', fields };
        }
        // A source compiled under several compiler profiles (via-IR or optimizer-run restrictions on files that import
        // it) appears in more than one build-info; its layout must then be the same in each.
        if (result[c.name]) {
          if (result[c.name].source !== source) {
            throw new Error(`two contracts named ${c.name} (${result[c.name].source}, ${source})`);
          }
          if (JSON.stringify(result[c.name]) !== JSON.stringify(snapshot)) {
            throw new Error(`${source}:${c.name} has different storage layouts in two compiler profiles`);
          }
          continue;
        }
        result[c.name] = snapshot;
      }
    }
  }
  return result;
}

const key = f => f.path;
const range = f => [BigInt(f.slot) * 32n + BigInt(f.offset), BigInt(f.slot) * 32n + BigInt(f.offset) + BigInt(f.bytes)];
// The base a field's slot is relative to: the part of its path up to the last `[]`.
const baseOf = f => (f.path.includes('[]') ? f.path.slice(0, f.path.lastIndexOf('[]') + 2) : '');

function compareFields(where, oldFields, newFields, problems, notes) {
  const now = new Map(newFields.map(f => [key(f), f]));
  const before = new Map(oldFields.map(f => [key(f), f]));
  for (const o of oldFields) {
    const n = now.get(key(o));
    if (!n) {
      problems.push(`${where}: field ${o.path} (slot ${o.slot}, offset ${o.offset}, ${o.type}) was removed or renamed`);
      continue;
    }
    for (const prop of ['slot', 'offset', 'bytes', 'type']) {
      if (String(o[prop]) !== String(n[prop])) {
        problems.push(`${where}: field ${o.path} ${prop} changed from ${o[prop]} to ${n[prop]}`);
      }
    }
  }
  for (const n of newFields) {
    if (before.has(key(n))) continue;
    const [lo, hi] = range(n);
    const parent = n.path.includes('.') ? n.path.slice(0, n.path.lastIndexOf('.')) : null;
    const clash = oldFields.find(o => {
      if (baseOf(o) !== baseOf(n) || o.path === parent || (parent && parent.startsWith(o.path + '.'))) return false;
      if (n.path.startsWith(o.path + '.') || n.path.startsWith(o.path + '[]')) return false;
      const [a, b] = range(o);
      return lo < b && a < hi;
    });
    if (clash) problems.push(`${where}: new field ${n.path} (slot ${n.slot}, offset ${n.offset}) overlaps ${clash.path}`);
    else notes.push(`${where}: new field ${n.path} at slot ${n.slot}, offset ${n.offset} (${n.type})`);
  }
}

function main() {
  const args = parseArgs();
  const current = snapshotsOf(path.resolve(ROOT, args.build));
  const snapDir = path.resolve(ROOT, args.snapshots);
  fs.mkdirSync(snapDir, { recursive: true });
  const problems = [];
  const notes = [];

  // Shared namespaces: every contract that declares a namespace must agree on it, and the slot constant of the
  // declaring source must be erc7201(id).
  const byNamespace = {};
  for (const snap of Object.values(current)) {
    for (const [ns, data] of Object.entries(snap.namespaces)) {
      const text = JSON.stringify(data);
      (byNamespace[ns] = byNamespace[ns] || []).push([snap.contract, text, data]);
    }
  }
  for (const [ns, list] of Object.entries(byNamespace)) {
    const [first, text, data] = list[0];
    for (const [other, otherText] of list.slice(1)) {
      if (otherText !== text) problems.push(`${ns}: ${first} and ${other} disagree on the namespace layout`);
    }
    const declared = data.declaredIn && fs.existsSync(path.join(ROOT, data.declaredIn)) ? fs.readFileSync(path.join(ROOT, data.declaredIn), 'utf8') : '';
    if (!declared.toLowerCase().includes(data.baseSlot.slice(2))) {
      problems.push(`${ns}: ${data.declaredIn || '?'} does not contain erc7201 base slot ${data.baseSlot}`);
    }
  }

  const existing = new Set(fs.readdirSync(snapDir).filter(f => f.endsWith('.json')).map(f => f.slice(0, -5)));
  for (const name of Object.keys(current).sort()) {
    const file = path.join(snapDir, `${name}.json`);
    if (!existing.has(name)) {
      if (args.update) notes.push(`${name}: new snapshot ${path.relative(ROOT, file)}`);
      else problems.push(`${name}: no snapshot ${path.relative(ROOT, file)} (review the layout, then run with --update)`);
      continue;
    }
    const old = JSON.parse(fs.readFileSync(file, 'utf8'));
    compareFields(`${name} storage`, old.storage || [], current[name].storage, problems, notes);
    for (const ns of new Set([...Object.keys(old.namespaces || {}), ...Object.keys(current[name].namespaces)])) {
      const o = (old.namespaces || {})[ns];
      const n = current[name].namespaces[ns];
      if (!n) {
        problems.push(`${name}: namespace ${ns} was removed`);
        continue;
      }
      if (!o) {
        notes.push(`${name}: new namespace ${ns}`);
        continue;
      }
      if (o.baseSlot !== n.baseSlot) problems.push(`${name}: ${ns} base slot changed from ${o.baseSlot} to ${n.baseSlot}`);
      compareFields(`${name} ${ns}`, o.fields, n.fields, problems, notes);
    }
  }
  for (const name of [...existing].sort()) {
    if (!current[name]) {
      if (args.update) {
        fs.unlinkSync(path.join(snapDir, `${name}.json`));
        notes.push(`${name}: snapshot removed (no such contract in the build)`);
      } else {
        problems.push(`${name}: snapshot without a contract in the build (removed or renamed)`);
      }
    }
  }

  for (const name of Object.keys(current).sort()) {
    const s = current[name];
    const counts = Object.entries(s.namespaces).map(([ns, d]) => `${ns} ${d.fields.length} field(s)`);
    console.log(`  ${name}: ${s.storage.length} plain storage field(s)${counts.length ? '; ' + counts.join('; ') : ''}`);
  }
  for (const n of notes) console.log(`  note  ${n}`);
  if (args.update) {
    if (problems.length) {
      for (const p of problems) console.log(`  FAIL  ${p}`);
      console.log(`storage-layout: snapshots not written, ${problems.length} problem(s) above`);
      return 1;
    }
    for (const [name, snap] of Object.entries(current)) {
      fs.writeFileSync(path.join(snapDir, `${name}.json`), JSON.stringify(snap, null, 2) + '\n');
    }
    console.log(`storage-layout: wrote ${Object.keys(current).length} snapshot(s) to ${path.relative(ROOT, snapDir)}`);
    return 0;
  }
  for (const p of problems) console.log(`  FAIL  ${p}`);
  console.log(`storage-layout: ${problems.length ? 'FAIL' : 'pass'} (${Object.keys(current).length} contract(s), ${problems.length} problem(s))`);
  return problems.length ? 1 : 0;
}

try {
  process.exitCode = main();
} catch (e) {
  console.error(`storage-layout: ${e.stack || e}`);
  process.exitCode = 1;
}
