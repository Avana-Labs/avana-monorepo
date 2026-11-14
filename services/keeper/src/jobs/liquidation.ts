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
import { type RetryHint, RevertError, decodeRevert, failureAction, hintFor, revertData, topUpCap, widen } from "./failureReasons.ts";
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
  /** What a failed attempt left for the account's next build, keyed by plan subject (failureReasons.ts). */
  readonly hints: Map<string, RetryHint>;
  /** Sends a monitoring alert: M-10 for liquidation reverts, M-24 for a frozen helper. */
  alert(signal: `M-${string}`, level: "warn" | "page", subject: string, detail: Readonly<Record<string, string>>): void;
  /** Stops submissions from this instance's helper on this chain (REQ-SWAP-105). */
  stopHelper(chainId: number): void;
  /** The Aave V3 Pool's implementation is not the manifest's: flash funding stops on the chain (paged once, M-26). */
  onPoolMismatch(chainId: number, mismatch: { address: Address; expected: Address; found: Address }): void;
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
      const subject = `${ctx.config.chain.id}:${account.spoke}:${account.proxy}`;
      const debtToCover = preview.params.debtToCover;
      // A change of the Aave V3 Pool's implementation stops flash funding only: every call goes through inventory until
      // a verified manifest records the new Pool code (services/README.md, Safety controls > Code check).
      const pool = ctx.config.manifest.aave.v3Pool;
      const poolFound = await ctx.reader.implementationOf(pool.address);
      const poolKnown = poolFound.toLowerCase() === pool.implementation.toLowerCase();
      if (!poolKnown) d.onPoolMismatch(ctx.config.chain.id, { address: pool.address, expected: pool.implementation, found: poolFound });
      // No flash loan from a reserve one of the market's routes into this asset draws on (an ERC-4626 wrapper or
      // static aToken of its aToken): the loan would take the liquidity the route's leg needs.
      const draws = poolKnown ? await ctx.reader.routeDraws(pool.address, market.routes.map((r) => r.address), reserve.asset) : null;
      const sameReserve = draws !== null && R.routeDrawsOnReserve(draws.deps, draws.aToken);
      const flashUsable = poolKnown && !sameReserve;
      const idle = flashUsable ? (await ctx.reader.flashQuote(d.helper.address, reserve.asset, debtToCover)).max : 0n;
      const split = R.fundingPlan(debtToCover, idle, flashUsable);
      const premium = split.inventoryOnly ? 0n : (await ctx.reader.flashQuote(d.helper.address, reserve.asset, split.flashAmount)).premium;
      // With no loan nothing is owed after LPVaultSwap returns, so the helper pulls no top-up (REQ-HELPER-003).
      const maxTopUp = split.inventoryOnly
        ? 0n
        : R.topUpBound({
            premium,
            expectedCallerLoss: preview.expectedCallerLoss,
            expectedNetPayout: preview.expectedNetPayout,
            expectedDebtRepaid: preview.expectedDebtRepaid,
            maxTopUpBps: d.helper.maxTopUpBps,
          });
      const params = { ...preview.params, routeMode: R.routeMode(preview.routeUsable), minAmounts: [], deadline, minPayout: 0n, maxShortfall: 0n };
      // Failure reasons a larger bound cures (RecoveryBelowFloor, TopUpExceeded): a hint from an earlier block widens
      // the request at once, and the same revert in this build's own simulation widens it and simulates once more.
      const cap = topUpCap(preview.expectedDebtRepaid, d.helper.maxTopUpBps);
      let bounds = { maxShortfall: 0n, maxTopUp };
      const earlier = d.hints.get(subject);
      d.hints.delete(subject);
      if (earlier) bounds = widen(bounds, earlier, cap) ?? bounds;
      // The inventory-only call's shortfall budget is prefunded with the repayment; it never takes a top-up.
      const fit = (b: typeof bounds) => (split.inventoryOnly ? { ...b, maxTopUp: 0n } : b);
      bounds = fit(bounds);
      const draftOf = (b: typeof bounds): FlashRequest => ({
        params: { ...params, maxShortfall: b.maxShortfall },
        flashAmount: split.flashAmount,
        maxPremium: premium,
        maxTopUp: b.maxTopUp,
        minPayout: 0n,
      });
      let draft = draftOf(bounds);
      let net: bigint;
      try {
        net = await d.simulateNet(ctx, draft);
      } catch (err) {
        const revert = decodeRevert(revertData(err));
        if (!revert) throw err;
        const hint = hintFor(revert);
        const wider = hint ? widen(bounds, hint, cap) : null;
        if (!wider) throw new RevertError(revert, subject);
        if (hint?.shortfall) d.alert("M-10", "warn", subject, { reason: revert.name, retry: "maxShortfall", maxShortfall: wider.maxShortfall.toString(10) });
        bounds = fit(wider);
        draft = draftOf(bounds);
        try {
          net = await d.simulateNet(ctx, draft);
        } catch (again) {
          const r = decodeRevert(revertData(again));
          throw r ? new RevertError(r, subject) : again;
        }
      }
      const request: FlashRequest = { ...draft, minPayout: R.requestMinPayout(split.inventoryAmount, net) };
      const pull = bounds.maxTopUp > bounds.maxShortfall ? bounds.maxTopUp : bounds.maxShortfall;

      const plan: TxPlan = {
        job: "liquidation",
        subject,
        to: d.helper.address,
        data: encodeFunctionData({ abi: flashLiquidatorAbi, functionName: "flashLiquidate", args: [request] }),
        deadline,
        reservations: [{ asset: reserve.asset, amount: split.inventoryAmount + pull }],
        targets: liquidationTargets(ctx.config.manifest, market, reserve, d.helper.address, !split.inventoryOnly),
        params: { ...request, debtReserveId: reserve.debtReserveId, healthFactor: preview.healthFactor, inventoryOnly: split.inventoryOnly, sameReserve },
      };
      return plan;
    },

    exclusive: (a, pass) => d.cache.exclusive(a, pass).then(() => undefined),

    // services/README.md, Submission > Failure reasons.
    onFailure(ctx, subject, revert) {
      const action = failureAction(revert.name);
      const detail = { reason: revert.name, selector: revert.selector, ...(revert.args?.length ? { args: revert.args.join(",") } : {}) };
      switch (action.kind) {
        case "retryWithShortfall":
        case "retryWithTopUp": {
          const hint = hintFor(revert);
          if (hint) d.hints.set(subject, hint);
          if (action.kind === "retryWithShortfall") d.alert(action.signal, action.level, subject, detail);
          return;
        }
        case "fault":
        case "retryAndPage":
          d.alert(action.signal, action.level, subject, { ...detail, ...(action.kind === "retryAndPage" ? { playbook: "P-04" } : {}) });
          return;
        case "stopHelper":
          d.stopHelper(ctx.config.chain.id);
          d.alert(action.signal, action.level, subject, detail);
          return;
        // NotLiquidatable (another caller won or the account recovered), stale prices and the next-block retries need
        // no state: the next block re-reads the account and the gates and decides afresh.
        case "clearAccount":
        case "waitForPrice":
        case "retryNextBlock":
        case "unknown":
          return;
      }
    },
  };
}

function reservesOf(m: ServiceManifest, spoke: Address): ManifestDebtReserve[] {
  return m.debtReserves.filter((r) => r.spoke.toLowerCase() === spoke.toLowerCase());
}

/**
 * Every contract the call reaches, as listed in services/README.md (Safety controls > Code check). The Aave V3 Pool
 * is a target only of a flash-funded call: an inventory-only call never reaches it.
 */
export function liquidationTargets(m: ServiceManifest, market: ManifestMarket, reserve: ManifestDebtReserve, helper: Address, flash = true): CodeTarget[] {
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
    ...(flash ? [up(m.aave.v3Pool)] : []),
  ];
}
