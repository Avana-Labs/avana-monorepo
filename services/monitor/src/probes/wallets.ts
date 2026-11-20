// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// M-35: the gas balance of each keeper wallet (the liquidation bots the RiskModules' keeper registry lists, from the
// manifest's `roles.keepers`, the flash liquidators' operators, and any named in MONITOR_KEEPER_WALLETS) and of the
// keeper top-up wallet that refills them (`roles.keeperTopUp`: deploy config `keeperTopUp`, or KEEPER_TOPUP_WALLET).
// The limits are the refill rule of `11_FundKeepers`: a keeper wallet below `minBalanceWei` warns (the top-up step is
// due), below a third of it pages (a bot that cannot pay gas cannot liquidate). The top-up wallet warns when it holds
// less than one full refill of every keeper wallet (`targetBalanceWei` each). MONITOR_KEEPER_WALLET_WARN_WEI and
// MONITOR_KEEPER_WALLET_PAGE_WEI override the two keeper limits.

import type { Address } from "viem";
import { type Probe, text } from "../probe.ts";
import type { Level } from "../signals.ts";
import type { Finding } from "../types.ts";

export interface WalletOverrides {
  readonly warnWei: bigint | null;
  readonly pageWei: bigint | null;
  /** Extra keeper wallets to watch on this chain. */
  readonly extra: readonly Address[];
}

export interface WalletLimits {
  readonly warnWei: bigint;
  readonly pageWei: bigint;
  readonly targetWei: bigint;
}

export interface WalletsInput {
  readonly limits: WalletLimits | null;
  readonly keepers: ReadonlyMap<string, bigint | null>;
  readonly topUp: { readonly address: Address; readonly balance: bigint | null } | null;
}

/** The keeper wallet limits: the overrides, else the manifest's refill rule; null when neither gives any. */
export function walletLimits(topUp: { minBalanceWei: string; targetBalanceWei: string } | null, o: Pick<WalletOverrides, "warnWei" | "pageWei">): WalletLimits | null {
  const min = topUp ? BigInt(topUp.minBalanceWei) : 0n;
  const warnWei = o.warnWei ?? min;
  const pageWei = o.pageWei ?? min / 3n;
  if (warnWei === 0n && pageWei === 0n) return null;
  return { warnWei, pageWei, targetWei: topUp ? BigInt(topUp.targetBalanceWei) : 0n };
}

/** A keeper wallet below `pageWei` pages, below `warnWei` warns. */
export function m35Keeper(balance: bigint, l: Pick<WalletLimits, "warnWei" | "pageWei">): Level {
  return balance < l.pageWei ? "page" : balance < l.warnWei ? "warn" : "ok";
}

export function walletsProbe(o: WalletOverrides): Probe<WalletsInput> {
  return {
    name: "wallets",

    async read(ctx) {
      const m = ctx.manifest;
      const keepers = [...new Set([...m.roles.keepers, ...m.avana.flashLiquidators.map((f) => f.operator), ...o.extra].map((a) => a.toLowerCase() as Address))];
      const topUp = m.roles.keeperTopUp;
      const balance = (a: Address) => ctx.rpc.getBalance(a).catch(() => null);
      const out = new Map<string, bigint | null>();
      for (const k of keepers) out.set(k, await balance(k));
      const topUpAddress = topUp?.wallet.toLowerCase() as Address | undefined;
      return { limits: walletLimits(topUp, o), keepers: out, topUp: topUpAddress ? { address: topUpAddress, balance: await balance(topUpAddress) } : null };
    },

    evaluate(input) {
      const out: Finding[] = [];
      const l = input.limits;
      if (!l) return out;
      for (const [wallet, b] of input.keepers) {
        const subject = `keeperWallet:${wallet}`;
        if (b === null) {
          out.push({ signal: "M-35", kind: "unread", level: "ok", subject, detail: {} });
          continue;
        }
        out.push({
          signal: "M-35",
          kind: "condition",
          level: m35Keeper(b, l),
          subject,
          detail: {
            wallet,
            balanceWei: b.toString(10),
            warnWei: l.warnWei.toString(10),
            pageWei: l.pageWei.toString(10),
            topUpWallet: input.topUp?.address ?? "none configured (keeperTopUp, KEEPER_TOPUP_WALLET)",
            action: "run step 11-fund-keepers",
          },
        });
      }
      if (input.topUp && l.targetWei > 0n) {
        const subject = `topUpWallet:${input.topUp.address}`;
        const needed = l.targetWei * BigInt(input.keepers.size);
        if (input.topUp.balance === null) out.push({ signal: "M-35", kind: "unread", level: "ok", subject, detail: {} });
        else
          out.push({
            signal: "M-35",
            kind: "condition",
            level: input.topUp.balance < needed ? "warn" : "ok",
            subject,
            detail: { wallet: input.topUp.address, role: "keeper top-up wallet", balanceWei: input.topUp.balance.toString(10), fullRefillWei: needed.toString(10) },
          });
      }
      return out;
    },

    evidence(input, subject) {
      const [kind, a] = subject.split(":");
      if (kind === "keeperWallet") return input.keepers.get(a!) != null ? text(input.keepers.get(a!)) : null;
      if (kind === "topUpWallet") return input.topUp?.balance != null ? text(input.topUp.balance) : null;
      return null;
    },
  };
}
