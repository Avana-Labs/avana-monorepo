// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Decodes one export record into the rows Convex keeps: the log with the scope keys its page feeds filter by, the
// wallet ↔ proxy binding, configuration changes for the changelogs and listing operations for the metadata load.
// Each page reads its own events: the Lend page the Lend Spoke's supplies and withdrawals and the CDP Spokes' draws
// on the asset, a Borrow asset page its CDP Spoke's reserve events, a pool page Avana's account events. No event is
// shown twice on one page.

import type { ExportRecord } from "@avana/services-common/export";
import { compactUsd, liquidationBonusBps, shortHash, shortWallet } from "./format.ts";
import type { DetailTxKind, DetailTxRow } from "./uiTypes.ts";

type Args = Readonly<Record<string, unknown>>;

/** Lookups against the rows Convex already holds; every key is lower-case. */
export interface Resolver {
  readonly chainId: number;
  isLendSpoke(spoke: string): boolean;
  /** Hub asset key `chainId:hub:assetId` of a reserve on any Spoke, or null for an unknown reserve. */
  hubAssetOfReserve(spoke: string, reserveId: string): Promise<string | null>;
  /** Spoke reserve key `chainId:spoke:reserveId` of a CDP Spoke's debt reserve, by the Hub asset key it draws from. */
  spokeReserveOfHubAsset(spoke: string, hubAssetKey: string): Promise<string | null>;
  /** Market key `chainId:integrationId:marketId` of a vault-token reserve, or null when the reserve is a debt reserve. */
  marketOfCollateralReserve(spoke: string, reserveId: string): Promise<string | null>;
  account(proxy: string): Promise<{ wallet: string; marketKey: string } | null>;
  /**
   * The integration whose core stack (LPVault, RiskModule, LiquidationModule, AaveAdapter, FlashloanRepay) holds the
   * address, or null. Each integration's RiskModule numbers its own markets, so a marketId is read under its emitter's.
   */
  integrationOf(address: string): number | null;
  /** The CDP Spoke of a market of the deployment, or null for a market it does not list. */
  marketSpoke(integrationId: number, marketId: string): string | null;
  /** Last value recorded for a parameter, for "previous" in the changelog. */
  previous(scope: ChangeScope, key: string, parameter: string): Promise<string | null>;
}

export type ChangeScope = "lend" | "asset" | "pool" | "chain";

export interface IngestedLog {
  readonly key: string;
  readonly chainId: number;
  readonly kind: string;
  readonly blockNumber: string;
  readonly blockHash: string;
  readonly txHash: string;
  readonly logIndex: number;
  readonly address: string;
  readonly at: number;
  readonly args: Args;
  readonly hubAssetKey?: string;
  readonly spokeReserveKey?: string;
  /** `chainId:integrationId:marketId`. */
  readonly marketKey?: string;
  readonly wallet?: string;
}

export interface ParameterChange {
  readonly scope: ChangeScope;
  readonly key: string;
  readonly parameter: string;
  readonly previous: string;
  readonly current: string;
}

export interface Decoded {
  readonly log: IngestedLog;
  readonly account?: { readonly spoke: string; readonly proxy: string; readonly wallet: string; readonly integrationId: number; readonly marketId: string };
  readonly changes: readonly ParameterChange[];
  readonly listing?: { readonly operationId: string; readonly salt?: string; readonly executed: boolean };
}

const a = (x: unknown): string => String(x).toLowerCase();

/** Decodes one record; `at` is its block's timestamp in milliseconds. */
export async function decodeRecord(r: ExportRecord, at: number, res: Resolver): Promise<Decoded> {
  const args = r.args;
  const base: IngestedLog = { key: r.key, chainId: res.chainId, kind: r.kind, blockNumber: r.blockNumber, blockHash: r.blockHash, txHash: r.txHash, logIndex: r.logIndex, address: a(r.address), at, args };
  const spoke = a(r.address);
  const changes: ParameterChange[] = [];
  const change = async (scope: ChangeScope, key: string, parameter: string, current: string) => {
    const previous = (await res.previous(scope, key, parameter)) ?? "—";
    if (previous !== current) changes.push({ scope, key, parameter, previous, current });
  };
  const spokeReserveKey = (reserveId: unknown) => `${res.chainId}:${spoke}:${String(reserveId)}`;
  // An Avana core contract's event names a market of its own integration (market IDs are numbered per RiskModule).
  const integrationId = res.integrationOf(spoke);
  const marketOf = (marketId: unknown) => (integrationId === null ? {} : { marketKey: `${res.chainId}:${integrationId}:${String(marketId)}` });

  switch (r.kind) {
    case "AaveSpoke.Supply":
    case "AaveSpoke.Withdraw": {
      if (!res.isLendSpoke(spoke)) return { log: base, changes };
      const hubAssetKey = await res.hubAssetOfReserve(spoke, String(args.reserveId));
      return { log: { ...base, ...(hubAssetKey ? { hubAssetKey } : {}), wallet: a(args.user) }, changes };
    }
    case "AaveSpoke.Borrow":
    case "AaveSpoke.Repay":
    case "AaveSpoke.ReportDeficit":
    case "AaveSpoke.LiquidationCall": {
      const reserveId = String(r.kind === "AaveSpoke.LiquidationCall" ? args.debtReserveId : args.reserveId);
      const hubAssetKey = await res.hubAssetOfReserve(spoke, reserveId);
      const account = await res.account(a(args.user));
      // A deficit is also filed under its market, for the market's bad debt; no pool feed shows Spoke events.
      const marketKey = r.kind === "AaveSpoke.ReportDeficit" && account ? { marketKey: account.marketKey } : {};
      return {
        log: { ...base, spokeReserveKey: spokeReserveKey(reserveId), ...(hubAssetKey ? { hubAssetKey } : {}), ...marketKey, ...(account ? { wallet: account.wallet } : {}) },
        changes,
      };
    }
    case "AaveAdapter.AccountCreated": {
      // The account is keyed under its market's Spoke: the market of that ID on the announcing AaveAdapter's integration.
      const marketId = String(args.marketId);
      const accountSpoke = integrationId === null ? null : res.marketSpoke(integrationId, marketId);
      return {
        log: { ...base, ...marketOf(marketId), wallet: a(args.wallet) },
        ...(integrationId !== null && accountSpoke ? { account: { spoke: accountSpoke, proxy: a(args.account), wallet: a(args.wallet), integrationId, marketId } } : {}),
        changes,
      };
    }
    case "AaveAdapter.Pledged":
    case "AaveAdapter.Borrowed":
    case "AaveAdapter.Repaid":
      return { log: { ...base, ...marketOf(args.marketId), wallet: a(args.wallet) }, changes };
    case "LiquidationModule.Liquidated": {
      const account = await res.account(a(args.account));
      return { log: { ...base, ...marketOf(args.marketId), ...(account ? { wallet: account.wallet } : {}) }, changes };
    }
    case "AccessManager.OperationScheduled":
    case "AccessManager.OperationExecuted":
      return { log: base, changes };
    case "AaveHub.UpdateSpokeConfig": {
      const hubKey = `${res.chainId}:${spoke}:${String(args.assetId)}`;
      const target = a(args.spoke);
      const config = args.config as Args;
      if (res.isLendSpoke(target)) await change("lend", hubKey, "Supply cap", String(config.addCap));
      else {
        const reserveKey = await res.spokeReserveOfHubAsset(target, hubKey);
        if (reserveKey) await change("asset", reserveKey, "Draw cap", String(config.drawCap));
      }
      return { log: { ...base, hubAssetKey: hubKey }, changes };
    }
    case "AaveHub.UpdateAssetConfig": {
      const hubKey = `${res.chainId}:${spoke}:${String(args.assetId)}`;
      await change("lend", hubKey, "Reserve factor", `${Number((args.config as Args).liquidityFee) / 100}%`);
      return { log: { ...base, hubAssetKey: hubKey }, changes };
    }
    case "AaveSpoke.UpdateReserveConfig": {
      const reserveId = String(args.reserveId);
      const config = args.config as Args;
      const market = await res.marketOfCollateralReserve(spoke, reserveId);
      if (market) await change("pool", market, "Collateral risk", `${Number(config.collateralRisk) / 100}%`);
      else if (res.isLendSpoke(spoke)) {
        const hubKey = await res.hubAssetOfReserve(spoke, reserveId);
        if (hubKey) await change("lend", hubKey, "Reserve status", flags(config));
      } else await change("asset", spokeReserveKey(reserveId), "Reserve status", flags(config));
      return { log: base, changes };
    }
    case "AaveSpoke.UpdateDynamicReserveConfig":
    case "AaveSpoke.AddDynamicReserveConfig": {
      const market = await res.marketOfCollateralReserve(spoke, String(args.reserveId));
      if (market) {
        const config = args.config as Args;
        await change("pool", market, "Collateral factor", `${Number(config.collateralFactor) / 100}%`);
        await change("pool", market, "Max liquidation bonus", `${liquidationBonusBps(Number(config.maxLiquidationBonus)) / 100}%`);
      }
      return { log: { ...base, ...(market ? { marketKey: market } : {}) }, changes };
    }
    default:
      return { log: base, changes };
  }
}

function flags(config: Args): string {
  const on = (["paused", "frozen", "borrowable"] as const).filter((f) => config[f] === true);
  return on.length === 0 ? "active" : on.join(", ");
}

/** Which events each page's feed shows, and as what. */
const FEED_KINDS: Readonly<Record<"lend" | "asset" | "pool", Readonly<Record<string, DetailTxKind>>>> = {
  lend: { "AaveSpoke.Supply": "supply", "AaveSpoke.Withdraw": "withdraw", "AaveSpoke.Borrow": "borrow", "AaveSpoke.Repay": "repay", "AaveSpoke.LiquidationCall": "liquidation" },
  asset: { "AaveSpoke.Borrow": "borrow", "AaveSpoke.Repay": "repay", "AaveSpoke.LiquidationCall": "liquidation" },
  pool: {
    "AaveAdapter.Pledged": "supply",
    "AaveAdapter.Borrowed": "borrow",
    "AaveAdapter.Repaid": "repay",
    "LiquidationModule.Liquidated": "liquidation",
  },
};

/** The token amount a feed row shows, in base units, and which token it is in. */
function amountOf(log: IngestedLog): { units: bigint; token: "asset" | "collateral" } | null {
  const x = log.args;
  switch (log.kind) {
    case "AaveSpoke.Supply":
      return { units: BigInt(String(x.suppliedAmount)), token: "asset" };
    case "AaveSpoke.Withdraw":
      return { units: BigInt(String(x.withdrawnAmount)), token: "asset" };
    case "AaveSpoke.Borrow":
      return { units: BigInt(String(x.drawnAmount)), token: "asset" };
    case "AaveSpoke.Repay":
      return { units: BigInt(String(x.totalAmountRepaid)), token: "asset" };
    case "AaveSpoke.LiquidationCall":
      return { units: BigInt(String(x.debtAmountRestored)), token: "asset" };
    case "AaveAdapter.Borrowed":
      return { units: BigInt(String(x.amount)), token: "asset" };
    case "AaveAdapter.Repaid":
      return { units: BigInt(String(x.amount)), token: "asset" };
    case "LiquidationModule.Liquidated":
      return { units: BigInt(String(x.debtRepaid)), token: "asset" };
    case "AaveAdapter.Pledged":
      // The floor credit pledged is the vault-token units supplied as collateral.
      return { units: BigInt(String(x.credit)), token: "collateral" };
    default:
      return null;
  }
}

/** Price and symbol of the token a row is denominated in (the debt asset, or the market's vault token). */
export interface Pricing {
  readonly symbol: string;
  readonly decimals: number;
  readonly priceUsd8: bigint;
}

/** Maps a stored log to the feed row of a page, or null when the page does not show that event. */
export function feedRow(log: IngestedLog, page: "lend" | "asset" | "pool", pricingOf: (log: IngestedLog, token: "asset" | "collateral") => Pricing | null): DetailTxRow | null {
  const kind = FEED_KINDS[page][log.kind];
  if (!kind) return null;
  const amount = amountOf(log);
  const pricing = amount ? pricingOf(log, amount.token) : null;
  const amountUsd = amount && pricing ? Number((amount.units * pricing.priceUsd8) / 10n ** BigInt(pricing.decimals)) / 1e8 : undefined;
  const tokens = amount && pricing ? Number(amount.units) / 10 ** pricing.decimals : undefined;
  return {
    id: log.key,
    at: new Date(log.at).toISOString(),
    kind,
    amountLabel: amountUsd === undefined ? "—" : compactUsd(amountUsd),
    ...(amountUsd === undefined ? {} : { amountUsd }),
    ...(tokens === undefined || !pricing ? {} : { tokenAmountLabel: `${tokens.toLocaleString("en-US", { maximumFractionDigits: 4 })} ${pricing.symbol}`, tokenSymbol: pricing.symbol }),
    walletLabel: log.wallet ? shortWallet(log.wallet) : "—",
    txHashShort: shortHash(log.txHash),
    source: "seed",
  };
}
