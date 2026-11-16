// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// One grant per (chain, wallet): the first request runs the chain's setup strategy and records the result; a later
// request returns the recorded grant. Grants on one chain run one at a time, so two requests for the same wallet cannot
// both fund it.

import { getAddress, isAddress } from "viem";
import { GRANTS, type ChainName } from "./grants.ts";
import { StepFailed, type SetupStrategy } from "./setup.ts";
import type { GrantRecord, GrantStore } from "./store.ts";

export type GrantResult =
  | { readonly ok: true; readonly record: GrantRecord; readonly existing: boolean }
  | { readonly ok: false; readonly status: 400 | 409 | 500; readonly error: string; readonly failedStep?: string };

export class Faucet {
  private readonly queues = new Map<ChainName, Promise<unknown>>();

  constructor(
    private readonly strategies: Readonly<Partial<Record<ChainName, SetupStrategy>>>,
    private readonly store: GrantStore,
    private readonly now: () => Date = () => new Date(),
  ) {}

  lookup(chain: string, wallet: string): GrantRecord | null {
    return isAddress(wallet) ? this.store.get(chain, getAddress(wallet)) : null;
  }

  async grant(chain: string, wallet: string): Promise<GrantResult> {
    if (chain !== "ethereum" && chain !== "base") return { ok: false, status: 400, error: `unknown chain ${chain}` };
    if (!isAddress(wallet)) return { ok: false, status: 400, error: "wallet is not an address" };
    const strategy = this.strategies[chain];
    if (!strategy) return { ok: false, status: 400, error: `chain ${chain} is not configured` };
    const address = getAddress(wallet);

    const run = async (): Promise<GrantResult> => {
      const existing = this.store.get(chain, address);
      if (existing) return { ok: true, record: existing, existing: true };
      try {
        const steps = await strategy.run(address, GRANTS[chain]);
        const record: GrantRecord = { chain, wallet: address, grantedAt: this.now().toISOString(), steps };
        this.store.put(record);
        return { ok: true, record, existing: false };
      } catch (error) {
        // The cause goes to the faucet's own log; the answer names the step only.
        process.stderr.write(`faucet: grant ${chain} ${address} failed: ${error instanceof Error ? error.message : String(error)}
`);
        if (error instanceof StepFailed) {
          return { ok: false, status: error.step === "check chain" ? 409 : 500, error: `grant step "${error.step}" failed`, failedStep: error.step };
        }
        return { ok: false, status: 500, error: "grant failed" };
      }
    };

    const previous = this.queues.get(chain) ?? Promise.resolve();
    const next = previous.then(run, run);
    this.queues.set(chain, next);
    return next;
  }
}
