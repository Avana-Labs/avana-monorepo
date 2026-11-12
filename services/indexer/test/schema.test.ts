// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Ponder refuses to start when a table has a column whose snake_case name it reserves for its own bookkeeping
// (`operation_id`, `operation`, `checkpoint`), and neither codegen nor typecheck reports it. This test reads every
// table of ponder.schema.ts and fails on such a column, so the indexer cannot ship a schema it cannot start with.

import { getTableColumns, isTable } from "drizzle-orm";
import { describe, expect, it } from "vitest";
import * as schema from "../ponder.schema.ts";

const RESERVED = new Set(["operation_id", "operation", "checkpoint"]);

function snakeCase(name: string): string {
  return name.replace(/([a-z0-9])([A-Z])/g, "$1_$2").toLowerCase();
}

const tables = Object.entries(schema).filter(([, value]) => isTable(value));

describe("indexer schema", () => {
  it("has tables to check", () => {
    expect(tables.length).toBeGreaterThan(0);
  });

  it("uses no column name Ponder reserves", () => {
    const offending: string[] = [];
    for (const [tableName, table] of tables) {
      for (const column of Object.keys(getTableColumns(table as never))) {
        if (RESERVED.has(snakeCase(column))) offending.push(`${tableName}.${column}`);
      }
    }
    expect(offending).toEqual([]);
  });
});
