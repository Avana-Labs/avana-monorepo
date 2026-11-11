// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Liquidation job: every account below HF 1, profitable or not, through this instance's operator helper as the
// committed operator, one debt reserve per call, repeated block after block until the account is at HF ≥ 1, has
// no debt or has its deficit recorded (Q-381, Q-395, TEST-142). No swap calldata is built: LPVaultSwap holds the
// routes and sets every leg's minimum from the oracle.

import { type Address, encodeFunctionData } from "viem";
import { flashLiquidatorAbi } from "@avana/protocol/abis";
import type { ManifestDebtReserve, ManifestMarket, ServiceManifest } from "@avana/services-common";
import type { AccountCache, CachedAccount } from "../discovery/accountCache.ts";
import { mayAct } from "../shard.ts";
import type { BlockContext, CodeTarget, Job, TxPlan } from "../types.ts";
import * as R from "./liquidationRules.ts";

type Preview = Awaited<ReturnType<BlockContext["reader"]["previewLiquidation"]>>;

interface Decision {
  readonly account: CachedAccount;
  readonly market: ManifestMarket;
  readonly reserve: ManifestDebtReserve;
  readonly preview: Preview;
  readonly deadline: bigint;
}

export interface LiquidationDeps {
  readonly cache: AccountCache;
  readonly role: "primary" | "standby";
  readonly shard: { index: number; count: number } | null;
  /** This instance's operator helper (bound to its signer and funding Safe). */
  readonly helper: { address: Address; maxTopUpBps: bigint };
  /** eth_call of `flashLiquidate` with `minPayout = 0`: the signed net result keeperOut − debtToCover − premium. */
  simulateNet(ctx: BlockContext, request: FlashRequest): Promise<bigint>;
}

export interface FlashRequest {
  readonly params: Preview["params"];
  readonly flashAmount: bigint;
  readonly maxPremium: bigint;
  readonly maxTopUp: bigint;
  readonly minPayout: bigint;
}

export function liquidationJob(d: LiquidationDeps): Job<CachedAccount, Decision> {
  return {
    kind: "liquidation",

    async discover(ctx) {
      const accounts = d.cache.ofChain(ctx.config.chain.id);
      const data = await ctx.reader.accountData(accounts);
      const out: CachedAccount[] = [];
      for (const a of accounts) {
        const ad = data.get(a.proxy);
        if (!ad) continue;
        d.cache.recordRead(a, ad.healthFactor, ctx.blockNumber);
        if (R.candidateReason(ad.healthFactor, ad.totalCollateralValue) !== null) continue;
        if (!mayAct(ctx.config.chain, d.role, d.shard, a.proxy, a.liquidatableSince ?? ctx.blockNumber, ctx.blockNumber)) continue;
        out.push(a);
      }
      return out;
    },

    async check(ctx, a) {
      const m = ctx.config.manifest;
      const market = m.markets.find((x) => x.marketId === a.marketId);
      if (!market) return { act: false, reason: "marketNotLiquidatable", detail: "market not in manifest" };
      const pv = await ctx.reader.priceState(market.vaultToken.address);
      const gate = R.marketGate({
        liquidationState: Number(pv.liquidationState),
        disagreementPauseActive: pv.disagreementPauseActive,
        disagreementExpired: pv.disagreementExpired,
        now: ctx.blockTimestamp,
        graceEndsAt: pv.graceEndsAt,
        graceHealthFactor: pv.graceHealthFactor,
        healthFactor: a.lastHealthFactor ?? 0n,
      });
      if (gate) return { act: false, reason: gate };

      const options = await Promise.all(
        reservesOf(m, a.spoke).map(async (r) => {
          const [debt, dp] = await Promise.all([ctx.reader.userTotalDebt(a.spoke, r.debtReserveId, a.proxy), ctx.reader.debtPriceState(a.spoke, r.debtReserveId)]);
          const pricePasses = dp.fixedPrice || (Number(dp.state) === 0 && dp.liquidationFresh);
          return { debtReserveId: r.debtReserveId, value: (debt * dp.price) / 10n ** BigInt(r.decimals), pricePasses };
        }),
      );
      const chosen = R.chooseDebtReserve(options);
      if (chosen === null) return { act: false, reason: "noPricedDebtReserve" };
      const reserve = reservesOf(m, a.spoke).find((r) => r.debtReserveId === chosen)!;

      const deadline = R.deadlineFor(ctx.blockTimestamp, ctx.config.chain.blockTimeSeconds);
      const preview = await ctx.reader.previewLiquidation(a.proxy, chosen, deadline);
      const pg = R.previewGate({ ...preview, debtToCover: preview.params.debtToCover });
      if (pg) return { act: false, reason: pg.reason, detail: pg.detail };
      return { act: true, decision: { account: a, market, reserve, preview, deadline } };
    },

    async build(ctx, { account, market, reserve, preview, deadline }) {
      const debtToCover = preview.params.debtToCover;
      const { max: idle } = await ctx.reader.flashQuote(d.helper.address, reserve.asset, debtToCover);
      const split = R.splitFunding(debtToCover, idle);
      if (!split) throw new Error(`no flash liquidity for ${reserve.asset}; inventory-only path required`);
      const { premium } = await ctx.reader.flashQuote(d.helper.address, reserve.asset, split.flashAmount);
      const maxTopUp = R.topUpBound({
        premium,
        expectedCallerLoss: preview.expectedCallerLoss,
        expectedNetPayout: preview.expectedNetPayout,
        expectedDebtRepaid: preview.expectedDebtRepaid,
        maxTopUpBps: d.helper.maxTopUpBps,
      });
      const params = { ...preview.params, routeMode: R.routeMode(preview.routeUsable), minAmounts: [], deadline, minPayout: 0n, maxShortfall: 0n };
      const draft: FlashRequest = { params, flashAmount: split.flashAmount, maxPremium: premium, maxTopUp, minPayout: 0n };
      const net = await d.simulateNet(ctx, draft);
      const request: FlashRequest = { ...draft, minPayout: R.requestMinPayout(split.inventoryAmount, net) };

      const plan: TxPlan = {
        job: "liquidation",
        subject: `${ctx.config.chain.id}:${account.spoke}:${account.proxy}`,
        to: d.helper.address,
        data: encodeFunctionData({ abi: flashLiquidatorAbi, functionName: "flashLiquidate", args: [request] }),
        deadline,
        reservations: [{ asset: reserve.asset, amount: split.inventoryAmount + maxTopUp }],
        targets: liquidationTargets(ctx.config.manifest, market, reserve, d.helper.address),
        params: { ...request, debtReserveId: reserve.debtReserveId, healthFactor: preview.healthFactor },
      };
      return plan;
    },

    exclusive: (a, pass) => d.cache.exclusive(a, pass).then(() => undefined),
  };
}

function reservesOf(m: ServiceManifest, spoke: Address): ManifestDebtReserve[] {
  return m.debtReserves.filter((r) => r.spoke.toLowerCase() === spoke.toLowerCase());
}

/** Every contract the call reaches, as listed in services/README.md (Safety controls > Code check). */
export function liquidationTargets(m: ServiceManifest, market: ManifestMarket, reserve: ManifestDebtReserve, helper: Address): CodeTarget[] {
  const up = (x: { address: Address; implementation: Address }): CodeTarget => ({ kind: "upgradeable", address: x.address, implementation: x.implementation });
  const im = (x: { address: Address; codeHash: `0x${string}` }): CodeTarget => ({ kind: "immutable", address: x.address, codeHash: x.codeHash });
  const helperEntry = m.avana.operatorHelpers.find((h) => h.address.toLowerCase() === helper.toLowerCase());
  const lpVault = m.avana.lpVaults.find((v) => v.integrationId === market.integrationId);
  const spoke = m.aave.borrowSpokes.find((s) => s.address.toLowerCase() === market.spoke.toLowerCase());
  if (!helperEntry || !lpVault || !spoke) throw new Error("helper, LPVault or CDP Spoke missing from the manifest");
  return [
    up(m.avana.lpVaultSwap), up(m.avana.aaveAdapter), up(m.avana.marketRegistry), up(m.avana.parameterStore), up(m.avana.riskModule),
    up(spoke), up(market.lpOracle), ...(reserve.debtOracle ? [up(reserve.debtOracle)] : []),
    im(helperEntry), im(m.avana.proxyManager), im(lpVault), im(m.avana.collateralization), im(market.vaultToken), im(m.avana.payoutEscrow),
    im(m.avana.lock), im(m.avana.lens), ...market.routes.map(im),
    up(m.aave.v3Pool), ...(m.aave.ghoFlashMinter ? [im(m.aave.ghoFlashMinter)] : []),
  ];
}
