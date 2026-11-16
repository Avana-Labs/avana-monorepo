// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The liquidation fee split on one chain, checked from the chain alone. For every `LPVaultSwap.LiquidationSettled`
// (SettlementReport, SPEC-LIQ-008/009/010/022):
//   - the fee recipient (ParameterStore.feeRecipient, the stack's `treasury` keystore) received exactly the report's
//     Avana fee A in the debt asset, directly or credited in the PayoutEscrow (RemainderEscrowed);
//   - the caller (the keeper or its operator helper) netted exactly the report's keeper reward kr in the debt asset:
//     keeperOut paid to it, less the caller funds and any shortfall top-up it paid in (SPEC-LIQ-010: keeperOut =
//     Kf + R' − D − A − B, so the net is kr up to the rounding gap the report already absorbs);
//   - the fee recipient is neither the caller nor the keeper's account, and the keeper's account is not the fee
//     recipient.

import { type Address, type Hex, type PublicClient, createPublicClient, decodeEventLog, erc20Abi, http, parseAbi } from "viem";
import type { LocalChain } from "./env.ts";
import { manifestPath, rpcUrl } from "./env.ts";
import { addresses } from "./keys.ts";
import { readFileSync } from "node:fs";

export interface SplitResult {
  readonly ok: boolean;
  readonly settlements: number;
  readonly failures: string[];
}

const eq = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

export async function checkFeeSplit(c: LocalChain, fromBlock = 0n): Promise<SplitResult> {
  const { lpVaultSwapAbi, payoutEscrowAbi } = await import("@avana/protocol/abis");
  const client = createPublicClient({ transport: http(rpcUrl(c)) }) as PublicClient;
  const m = JSON.parse(readFileSync(manifestPath(c), "utf8")) as Record<string, any>;
  const lpVaultSwap = m.avana.lpVaultSwap.address as Address;
  const escrow = m.avana.payoutEscrow.address as Address;
  const store = m.avana.parameterStore.address as Address;
  const feeRecipient = (await client.readContract({ address: store, abi: parseAbi(["function feeRecipient() view returns (address)"]), functionName: "feeRecipient" })) as Address;
  const keeper = addresses().keeper;
  const failures: string[] = [];
  if (eq(feeRecipient, keeper)) failures.push(`feeRecipient ${feeRecipient} is the keeper's account`);
  if (!eq(feeRecipient, addresses().treasury)) failures.push(`feeRecipient ${feeRecipient} is not the treasury keystore's ${addresses().treasury}`);

  const settled = await client.getContractEvents({ address: lpVaultSwap, abi: lpVaultSwapAbi as any, eventName: "LiquidationSettled", fromBlock, toBlock: "latest" });
  for (const ev of settled as any[]) {
    const r = ev.args.report as Record<string, any>;
    const caller = ev.args.caller as Address;
    const asset = r.debtAsset as Address;
    const where = `${c.network} tx ${ev.transactionHash as Hex} market ${ev.args.marketId}`;
    if (eq(caller, feeRecipient)) failures.push(`${where}: the caller is the fee recipient`);
    const receipt = await client.getTransactionReceipt({ hash: ev.transactionHash });
    let toFee = 0n;
    let toCaller = 0n;
    let fromCaller = 0n;
    for (const l of receipt.logs) {
      if (eq(l.address, asset)) {
        try {
          const t = decodeEventLog({ abi: erc20Abi, data: l.data, topics: l.topics, eventName: "Transfer" }) as any;
          if (eq(t.args.from, lpVaultSwap) && eq(t.args.to, feeRecipient)) toFee += t.args.value as bigint;
          if (eq(t.args.from, lpVaultSwap) && eq(t.args.to, caller)) toCaller += t.args.value as bigint;
          if (eq(t.args.from, caller) && eq(t.args.to, lpVaultSwap)) fromCaller += t.args.value as bigint;
        } catch {}
      }
      if (eq(l.address, escrow)) {
        try {
          const e = decodeEventLog({ abi: payoutEscrowAbi as any, data: l.data, topics: l.topics }) as any;
          if (e.eventName === "RemainderEscrowed" && eq(e.args.token, asset) && eq(e.args.account, feeRecipient)) toFee += e.args.amount as bigint;
        } catch {}
      }
    }
    const fee = r.avanaFee as bigint;
    const reward = r.keeperReward as bigint;
    if (toFee !== fee) failures.push(`${where}: fee recipient received ${toFee}, report's Avana fee ${fee}`);
    if (toCaller !== (r.keeperOut as bigint)) failures.push(`${where}: caller received ${toCaller}, report's keeperOut ${r.keeperOut}`);
    const net = toCaller - fromCaller;
    if (net !== reward) failures.push(`${where}: caller netted ${net}, report's keeper reward ${reward} (Kf ${r.callerFunds}, shortfall ${r.shortfall})`);
  }
  return { ok: failures.length === 0, settlements: settled.length, failures };
}
