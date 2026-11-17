// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Run: node --test script/local/lib/services.test.ts (from contracts/)

import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { indexerSchema } from "./services.ts";

function manifests(...bodies: string[]): { paths: string[]; done: () => void } {
  const dir = mkdtempSync(join(tmpdir(), "indexer-schema-"));
  const paths = bodies.map((b, i) => {
    const p = join(dir, `manifest-${i}.json`);
    writeFileSync(p, b);
    return p;
  });
  return { paths, done: () => rmSync(dir, { recursive: true, force: true }) };
}

test("indexerSchema: the same manifests give the same schema, so a restart resumes it", () => {
  const a = manifests('{"hubs":[1]}', '{"hubs":[2]}');
  const b = manifests('{"hubs":[1]}', '{"hubs":[2]}');
  try {
    assert.equal(indexerSchema("live", a.paths), indexerSchema("live", b.paths));
    assert.match(indexerSchema("live", a.paths), /^live_[0-9a-f]{12}$/);
  } finally {
    a.done();
    b.done();
  }
});

test("indexerSchema: a Hub release that rewrites a manifest gives a new schema", () => {
  const before = manifests('{"hubs":[1]}', '{"hubs":[2]}');
  const after = manifests('{"hubs":[1,3]}', '{"hubs":[2]}');
  try {
    assert.notEqual(indexerSchema("live", before.paths), indexerSchema("live", after.paths));
  } finally {
    before.done();
    after.done();
  }
});

test("indexerSchema: the prefix names the app", () => {
  const m = manifests('{"hubs":[1]}');
  try {
    assert.match(indexerSchema("testnet", m.paths), /^testnet_[0-9a-f]{12}$/);
  } finally {
    m.done();
  }
});
