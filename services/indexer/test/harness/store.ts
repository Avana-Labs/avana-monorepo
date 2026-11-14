// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// An in-memory stand-in for the part of Ponder's indexing store the handlers use (`insert … onConflictDoNothing /
// onConflictDoUpdate`, `find`, `update … set`, `delete`), keyed by each table's primary key, with hex columns written in
// lower case as Ponder's `PgHex` does. `snapshot` and `restore` stand for Ponder's revert to a common ancestor on a
// reorg; `dump` gives every table's rows in key order, so two runs can be compared.

import { getTableColumns, getTableName } from "drizzle-orm";
import { getTableConfig, type PgTable } from "drizzle-orm/pg-core";

type Row = Record<string, unknown>;
type Patch = Row | ((row: Row) => Row);

interface TableInfo {
  readonly name: string;
  readonly keys: readonly string[];
  readonly hex: ReadonlySet<string>;
  readonly required: ReadonlySet<string>;
  readonly columns: readonly string[];
}

const infoCache = new WeakMap<object, TableInfo>();

function infoOf(table: PgTable): TableInfo {
  const cached = infoCache.get(table);
  if (cached) return cached;
  const columns = getTableColumns(table) as unknown as Record<string, { name: string; columnType: string; notNull: boolean; hasDefault: boolean; primary: boolean }>;
  const byName = new Map(Object.entries(columns).map(([k, c]) => [c.name, k]));
  const config = getTableConfig(table);
  const keys = config.primaryKeys.length > 0
    ? config.primaryKeys[0]!.columns.map((c) => byName.get(c.name)!)
    : Object.entries(columns).filter(([, c]) => c.primary).map(([k]) => k);
  if (keys.length === 0) throw new Error(`table ${getTableName(table)} has no primary key`);
  const info: TableInfo = {
    name: getTableName(table),
    keys,
    hex: new Set(Object.entries(columns).filter(([, c]) => c.columnType === "PgHex").map(([k]) => k)),
    required: new Set(Object.entries(columns).filter(([, c]) => c.notNull && !c.hasDefault).map(([k]) => k)),
    columns: Object.keys(columns),
  };
  infoCache.set(table, info);
  return info;
}

const keyText = (v: unknown): string => (typeof v === "bigint" ? `${v}n` : JSON.stringify(v));

function clone<T>(v: T): T {
  if (Array.isArray(v)) return v.map(clone) as T;
  if (v !== null && typeof v === "object") return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, clone(x)])) as T;
  return v;
}

const byKey = <T>(entries: Iterable<[string, T]>) => [...entries].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));

export class MemoryStore {
  private tables = new Map<string, { info: TableInfo; rows: Map<string, Row> }>();

  private tableOf(table: PgTable) {
    const info = infoOf(table);
    let t = this.tables.get(info.name);
    if (!t) this.tables.set(info.name, (t = { info, rows: new Map() }));
    return t;
  }

  private normalise(info: TableInfo, row: Row): Row {
    const out: Row = {};
    for (const [k, v] of Object.entries(row)) {
      if (!info.columns.includes(k)) throw new Error(`${info.name}: unknown column ${k}`);
      out[k] = info.hex.has(k) && typeof v === "string" ? v.toLowerCase() : clone(v);
    }
    return out;
  }

  private key(info: TableInfo, row: Row): string {
    return info.keys
      .map((k) => {
        if (row[k] === undefined) throw new Error(`${info.name}: key column ${k} missing`);
        return keyText(row[k]);
      })
      .join("|");
  }

  private complete(info: TableInfo, row: Row): Row {
    for (const c of info.required) if (row[c] === undefined || row[c] === null) throw new Error(`${info.name}: required column ${c} missing`);
    for (const c of info.columns) if (row[c] === undefined) row[c] = null;
    return row;
  }

  find(table: PgTable, key: Row): Row | null {
    const t = this.tableOf(table);
    const row = t.rows.get(this.key(t.info, this.normalise(t.info, key)));
    return row ? clone(row) : null;
  }

  insert(table: PgTable, values: Row, conflict: "error" | "nothing" | { update: Patch }): Row | null {
    const t = this.tableOf(table);
    const row = this.normalise(t.info, values);
    const key = this.key(t.info, row);
    const existing = t.rows.get(key);
    if (!existing) {
      t.rows.set(key, this.complete(t.info, row));
      return clone(t.rows.get(key)!);
    }
    if (conflict === "error") throw new Error(`${t.info.name}: duplicate key ${key}`);
    if (conflict === "nothing") return null;
    const patch = typeof conflict.update === "function" ? conflict.update(clone(existing)) : conflict.update;
    const updated = { ...existing, ...this.normalise(t.info, patch) };
    t.rows.set(key, updated);
    return clone(updated);
  }

  update(table: PgTable, key: Row, set: Patch): Row {
    const t = this.tableOf(table);
    const k = this.key(t.info, this.normalise(t.info, key));
    const existing = t.rows.get(k);
    if (!existing) throw new Error(`${t.info.name}: update of missing row ${k}`);
    const patch = typeof set === "function" ? set(clone(existing)) : set;
    const updated = { ...existing, ...this.normalise(t.info, patch) };
    t.rows.set(k, updated);
    return clone(updated);
  }

  delete(table: PgTable, key: Row): boolean {
    const t = this.tableOf(table);
    return t.rows.delete(this.key(t.info, this.normalise(t.info, key)));
  }

  /** Every row of one table, in key order. */
  rows(table: PgTable): Row[] {
    return byKey(this.tableOf(table).rows.entries()).map(([, r]) => clone(r));
  }

  /** Every non-empty table's rows in key order, for comparing two runs. */
  dump(): Record<string, Row[]> {
    const out: Record<string, Row[]> = {};
    for (const name of [...this.tables.keys()].sort()) {
      const rows = byKey(this.tables.get(name)!.rows.entries()).map(([, r]) => clone(r));
      if (rows.length > 0) out[name] = rows;
    }
    return out;
  }

  snapshot(): Map<string, Map<string, Row>> {
    return new Map([...this.tables.entries()].map(([n, t]) => [n, new Map([...t.rows.entries()].map(([k, r]) => [k, clone(r)]))]));
  }

  restore(snap: Map<string, Map<string, Row>>): void {
    for (const [n, t] of this.tables) t.rows = new Map([...(snap.get(n) ?? new Map<string, Row>()).entries()].map(([k, r]) => [k, clone(r)]));
  }

  /** The `context.db` the handlers call. */
  api() {
    const store = this;
    return {
      insert(table: PgTable) {
        return {
          values(v: Row | Row[]) {
            const run = (conflict: "error" | "nothing" | { update: Patch }) =>
              Array.isArray(v) ? v.map((r) => store.insert(table, r, conflict)) : store.insert(table, v, conflict);
            return {
              onConflictDoNothing: async () => run("nothing"),
              onConflictDoUpdate: async (update: Patch) => run({ update }),
              then: (ok: (x: unknown) => unknown, fail: (e: unknown) => unknown) => Promise.resolve().then(() => run("error")).then(ok, fail),
            };
          },
        };
      },
      find: async (table: PgTable, key: Row) => store.find(table, key),
      update: (table: PgTable, key: Row) => ({ set: async (set: Patch) => store.update(table, key, set) }),
      delete: async (table: PgTable, key: Row) => store.delete(table, key),
      get sql(): never {
        throw new Error("context.db.sql is not available in the handler harness");
      },
    };
  }
}
