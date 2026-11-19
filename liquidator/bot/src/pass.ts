// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// One pass over the known accounts: read each health factor, and liquidate every account below 1 through the
// LiquidationModule, with the bot's own funds or through the FlashLiquidator. Every send is simulated first.

import type { Address, Hash } from "viem";
import { erc20Abi, flashLiquidatorAbi, liquidationModuleAbi, lpVaultAbi, riskModuleAbi, spokeAbi } from "./abis.ts";
import type { Chain } from "./chain.ts";
import type { Config } from "./config.ts";
import { type Decision, ONE, decide, minProfit } from "./decide.ts";
import type { Account } from "./discovery.ts";
import { buildSwaps } from "./swaps.ts";

export interface Outcome {
  readonly account: Address;
  readonly marketId: bigint;
  readonly decision: Decision | { readonly kind: "error"; readonly message: string };
  readonly hash?: Hash;
}

export type Log = (message: string, fields?: Record<string, unknown>) => void;

interface Market {
  readonly spoke: Address;
  readonly token0: Address;
  readonly token1: Address;
}

export class Liquidator {
  private riskModule?: Address;
  private lpVault?: Address;
  private readonly markets = new Map<bigint, Market>();

  constructor(
    private readonly chain: Chain,
    private readonly config: Config,
    private readonly operator: Address,
    private readonly log: Log = () => {},
  ) {}

  async pass(accounts: readonly Account[]): Promise<Outcome[]> {
    const out: Outcome[] = [];
    for (const a of accounts) {
      try {
        const o = await this.one(a);
        if (o) out.push(o);
      } catch (e) {
        const message = e instanceof Error ? e.message : String(e);
        this.log("liquidation failed", { account: a.account, marketId: a.marketId, message });
        out.push({ ...a, decision: { kind: "error", message } });
      }
    }
    return out;
  }

  private async one(a: Account): Promise<Outcome | undefined> {
    const m = await this.market(a.marketId);
    const data = await this.chain.read<{ healthFactor: bigint }>({ address: m.spoke, abi: spokeAbi, functionName: "getUserAccountData", args: [a.account] });
    if (data.healthFactor >= ONE) return undefined;

    let reserveId = this.config.debtReserves[0]!;
    let debt = 0n;
    for (const r of this.config.debtReserves) {
      const d = await this.chain.read<bigint>({ address: m.spoke, abi: spokeAbi, functionName: "getUserTotalDebt", args: [r, a.account] });
      if (d > debt) [reserveId, debt] = [r, d];
    }
    const reserve = await this.chain.read<{ underlying: Address }>({ address: m.spoke, abi: spokeAbi, functionName: "getReserve", args: [reserveId] });
    const asset = reserve.underlying;
    const balance = await this.chain.read<bigint>({ address: asset, abi: erc20Abi, functionName: "balanceOf", args: [this.operator] });
    const flash = this.config.flashLiquidator;
    const flashBorrower = flash ? await this.chain.read<boolean>({ address: flash, abi: flashLiquidatorAbi, functionName: "isFlashBorrower" }) : false;

    const decision = decide({ healthFactor: data.healthFactor, debt, balance, flash: flash !== undefined, flashBorrower });
    this.log("liquidatable", { account: a.account, marketId: a.marketId, healthFactor: data.healthFactor, debt, decision: decision.kind });
    const params = { marketId: a.marketId, debtReserveId: reserveId, account: a.account, debtToCover: 0n, minAmount0: 0n, minAmount1: 0n, receiver: this.operator };

    if (decision.kind === "direct") {
      const module = this.config.liquidationModule;
      const allowance = await this.chain.read<bigint>({ address: asset, abi: erc20Abi, functionName: "allowance", args: [this.operator, module] });
      if (allowance < decision.debtToCover) {
        await this.chain.send({ address: asset, abi: erc20Abi, functionName: "approve", args: [module, decision.debtToCover], account: this.operator });
      }
      const call = { address: module, abi: liquidationModuleAbi, functionName: "liquidate", args: [{ ...params, debtToCover: decision.debtToCover }], account: this.operator } as const;
      await this.chain.simulate(call);
      return { ...a, decision, hash: await this.chain.send(call) };
    }
    if (decision.kind === "flash") {
      const swaps = buildSwaps(this.config.swapRouter!, flash!, asset, [m.token0, m.token1], this.config.swapLegs);
      const request = { params, flashAmount: decision.flashAmount, swaps, maxTopUp: this.config.maxTopUp, minProfit: 0n, recipient: this.operator };
      const base = { address: flash!, abi: flashLiquidatorAbi, functionName: "flashLiquidate", account: this.operator } as const;
      const profit = await this.chain.simulate<bigint>({ ...base, args: [request] });
      const floor = minProfit(profit, this.config.profitSlippageBps);
      return { ...a, decision, hash: await this.chain.send({ ...base, args: [{ ...request, minProfit: floor }] }) };
    }
    if (decision.kind === "unfunded") this.log("ALERT: no funds and no flash path for a liquidatable account", { account: a.account, debt });
    return { ...a, decision };
  }

  private async market(marketId: bigint): Promise<Market> {
    const known = this.markets.get(marketId);
    if (known) return known;
    const module = this.config.liquidationModule;
    this.riskModule ??= await this.chain.read<Address>({ address: module, abi: liquidationModuleAbi, functionName: "RISK_MODULE" });
    this.lpVault ??= await this.chain.read<Address>({ address: module, abi: liquidationModuleAbi, functionName: "LP_VAULT" });
    const rm = await this.chain.read<{ spoke: Address }>({ address: this.riskModule, abi: riskModuleAbi, functionName: "getMarket", args: [marketId] });
    const v = await this.chain.read<{ token0: Address; token1: Address }>({ address: this.lpVault, abi: lpVaultAbi, functionName: "getMarket", args: [marketId] });
    const m = { spoke: rm.spoke, token0: v.token0, token1: v.token1 };
    this.markets.set(marketId, m);
    return m;
  }
}
