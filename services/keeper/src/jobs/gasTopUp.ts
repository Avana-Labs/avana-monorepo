// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Gas top-up (2.24, EMG-115): when the chain's AvanaGasVault lists this instance's signer and the signer's balance is
// below its `minBalance`, call the vault's `topUpAll()`. The call is permissionless and pays only the vault's listed
// signers, each to its target within its 24 h cap, so the keeper sends it as any caller could; it refills the standby
// in the same call when the standby is below its minimum too. It is sent only when the vault would send this signer
// something now (`quoteTopUp` > 0): a paused vault, a used-up 24 h cap or an empty vault is logged and left to the
// monitor (M-35, M-36) and to the signer's own runway alert (M-17). The pipeline simulates the call before the send.
// Class: urgent. A signer that runs dry stops every other job, so the refill is never held behind the daily budget
// or a base-fee wait; it is rare (the 24 h cap allows at most four refills per signer per day).

import { type Address, encodeFunctionData } from "viem";
import { avanaGasVaultAbi } from "@avana/protocol/abis";
import type { BlockContext, Job } from "../types.ts";

export interface GasVaultRef {
  readonly address: Address;
  readonly codeHash: `0x${string}`;
}

interface Decision {
  readonly vault: GasVaultRef;
  readonly balance: bigint;
  readonly minBalance: bigint;
  readonly amount: bigint;
  readonly requested: bigint;
}

/** `signer` is the instance's own signer (in observe-only mode, the manifest's helper signer). */
export function gasTopUpJob(signer: Address): Job<GasVaultRef, Decision> {
  return {
    kind: "gasTopUp",

    // The vault from the manifest; none before step 12-gas-vault has run on the chain.
    async discover(ctx: BlockContext) {
      const v = ctx.config.manifest.avana.gasVault;
      return v ? [{ address: v.address, codeHash: v.codeHash }] : [];
    },

    async check(ctx, vault) {
      const q = await ctx.reader.gasVaultQuote(vault.address, signer);
      if (!q.listed) return { act: false, reason: "notDue", detail: "signer not listed in the gas vault" };
      if (q.balance >= q.minBalance) return { act: false, reason: "notDue" };
      if (q.paused) return { act: false, reason: "conditionFalse", detail: "gas vault paused" };
      if (q.amount === 0n) return { act: false, reason: "conditionFalse", detail: "gas vault would send nothing: 24 h cap used or vault empty" };
      return { act: true, decision: { vault, balance: q.balance, minBalance: q.minBalance, amount: q.amount, requested: q.requested } };
    },

    async build(ctx, d) {
      return {
        job: "gasTopUp",
        jobClass: "urgent",
        subject: `${ctx.config.chain.id}:${d.vault.address}`,
        to: d.vault.address,
        data: encodeFunctionData({ abi: avanaGasVaultAbi, functionName: "topUpAll" }),
        deadline: null,
        reservations: [],
        targets: [{ kind: "immutable", address: d.vault.address, codeHash: d.vault.codeHash }],
        params: { signer, balance: d.balance, minBalance: d.minBalance, amount: d.amount, requested: d.requested },
      };
    },
  };
}
