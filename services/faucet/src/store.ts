// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Grants already given, one per (chain, wallet), kept in a JSON file in FAUCET_DATA_DIR so a second request returns
// the first grant instead of funding the wallet again.

import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import type { GrantStep } from "./setup.ts";

export interface GrantRecord {
  readonly chain: string;
  readonly wallet: string;
  readonly grantedAt: string;
  readonly steps: readonly GrantStep[];
}

export class GrantStore {
  private readonly file: string;
  private records: Record<string, GrantRecord>;

  constructor(dataDir: string) {
    this.file = join(dataDir, "grants.json");
    try {
      this.records = JSON.parse(readFileSync(this.file, "utf8")) as Record<string, GrantRecord>;
    } catch {
      this.records = {};
    }
  }

  private static key(chain: string, wallet: string): string {
    return `${chain}:${wallet.toLowerCase()}`;
  }

  get(chain: string, wallet: string): GrantRecord | null {
    return this.records[GrantStore.key(chain, wallet)] ?? null;
  }

  put(record: GrantRecord): void {
    this.records[GrantStore.key(record.chain, record.wallet)] = record;
    mkdirSync(dirname(this.file), { recursive: true });
    const tmp = `${this.file}.tmp`;
    writeFileSync(tmp, `${JSON.stringify(this.records, null, 2)}\n`);
    renameSync(tmp, this.file);
  }
}
