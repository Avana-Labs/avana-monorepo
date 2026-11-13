// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The Lens views the app reads for one wallet's account or one Hub asset, beside the chain snapshot: uncollected fees
// of pledged positions, the account before and after a borrow, repay, pledge or withdrawal, inverse sizing (largest
// withdrawal, smallest deleverage, everything to close) and one Hub asset with its Spoke slices. Fragments mirror the
// Solidity declarations of contracts/src/lens/lens/ field for field (struct fields decode by position); each reader
// pins no block itself, so the client decides the block, and a view that reverts throws.

import { parseAbi } from "viem";
import { type ContractCall, type ViewClient, all } from "./client.ts";
import type { Address } from "./types.ts";

export const lensAppViewsAbi = parseAbi([
  "struct PositionFeesView { uint256 blockNumber; uint256 timestamp; uint256 marketId; bytes32 positionKey; bool supported; bool inCustody; address depositor; uint128 liquidity; uint256[] tokensOwed; uint256[] amounts; }",
  "struct ActionPreview { uint256 blockNumber; uint256 timestamp; address proxy; uint256 amount; uint256 healthFactorBefore; uint256 healthFactorAfter; uint256 liquidationPriceBefore; uint256 liquidationPriceAfter; uint256 collateralValueAfter; uint256 debtValueAfterRay; }",
  "struct RecordRemoval { bytes32 positionKey; uint256 units; bool fits; }",
  "struct RemovalSizing { uint256 blockNumber; uint256 timestamp; address proxy; uint256 target; uint256 maxUnits; uint256 bestIndex; RecordRemoval[] records; }",
  "struct DeleverageSizing { uint256 blockNumber; uint256 timestamp; address proxy; bool reachable; uint256 units; uint256 debtRepaid; uint256 debtAssetToWallet; uint256 healthFactorAfter; }",
  "struct DebtClose { uint256 reserveId; address asset; uint256 total; uint256 maxRepaySpend; }",
  "struct RecordClose { bytes32 positionKey; uint256 units; uint256[] amounts; }",
  "struct CloseAccountView { uint256 blockNumber; uint256 timestamp; address proxy; DebtClose[] debts; RecordClose[] records; }",
  "struct SpokeDraw { address spoke; address homeHub; uint256 drawCap; uint256 drawn; uint256 deficit; uint8 kind; uint256 added; uint256 addedShares; uint256 addCap; uint256 drawnOwed; uint256 premiumOwed; uint256 drawnShares; uint256 premiumShares; bool active; bool halted; }",
  "struct HubAssetView { uint256 blockNumber; uint256 timestamp; address hub; uint256 assetId; address underlying; uint8 decimals; uint256 added; uint256 addedShares; uint256 drawn; uint256 premium; uint256 owed; uint256 drawnShares; uint256 premiumShares; uint256 liquidity; uint256 swept; uint256 deficit; uint256 accruedFees; uint256 utilizationBps; uint256 drawnRateRay; uint256 supplyRateRay; uint256 liquidityFeeBps; address feeReceiver; address irStrategy; uint256 optimalUsageBps; uint256 baseDrawnRateBps; uint256 rateGrowthBeforeOptimalBps; uint256 rateGrowthAfterOptimalBps; address lendSpoke; uint256 priceUsd8; SpokeDraw[] spokes; }",
  "function getPositionFees(uint256 marketId, bytes32 positionKey) view returns (PositionFeesView fees)",
  "function getAccountFees(address wallet, uint256 marketId) view returns (PositionFeesView[] fees)",
  "function previewBorrowAfter(address wallet, uint256 marketId, uint256 debtReserveId, uint256 amount) view returns (ActionPreview preview)",
  "function previewRepayAfter(address wallet, uint256 marketId, uint256 debtReserveId, uint256 amount) view returns (ActionPreview preview)",
  "function previewPledgeAfter(address wallet, uint256 marketId, bytes32 positionKey) view returns (ActionPreview preview)",
  "function previewWithdrawAfter(address wallet, uint256 marketId, bytes32 positionKey) view returns (ActionPreview preview)",
  "function previewMaxWithdraw(address wallet, uint256 marketId, uint256 targetHealthFactor) view returns (RemovalSizing sizing)",
  "function previewDeleverageTo(address wallet, uint256 marketId, bytes32 positionKey, uint256 debtReserveId, uint256 targetHealthFactor) view returns (DeleverageSizing sizing)",
  "function previewCloseAccount(address wallet, uint256 marketId, uint256 deadline) view returns (CloseAccountView close)",
  "function getHubAsset(address hub, uint256 assetId) view returns (HubAssetView asset)",
]);

/** `SpokeKind` of the Lens, by enum index (REQ-LENS-059). */
export const LENS_SPOKE_KINDS = ["lend", "cdp", "coverage", "feeReceiver", "other", "deficitOffset"] as const;

/** Uncollected fees of one position: what `collectFees` pays in this block, pool order, base units. */
export interface PositionFeesView {
  readonly blockNumber: bigint;
  readonly timestamp: bigint;
  readonly marketId: bigint;
  readonly positionKey: `0x${string}`;
  /** False for an AMM protocol without a fee reader or a position outside the market's pool; amounts are then 0. */
  readonly supported: boolean;
  readonly inCustody: boolean;
  readonly depositor: Address;
  readonly liquidity: bigint;
  readonly tokensOwed: readonly bigint[];
  readonly amounts: readonly bigint[];
}

/**
 * The account before and after one action at the block's prices. Health factors WAD (`2^256 − 1` with no debt),
 * liquidation prices USD 8 decimals per whole vault token, `collateralValueAfter` Aave value units (USD × 1e26),
 * `debtValueAfterRay` the same × RAY.
 */
export interface ActionPreview {
  readonly blockNumber: bigint;
  readonly timestamp: bigint;
  readonly proxy: Address;
  readonly amount: bigint;
  readonly healthFactorBefore: bigint;
  readonly healthFactorAfter: bigint;
  readonly liquidationPriceBefore: bigint;
  readonly liquidationPriceAfter: bigint;
  readonly collateralValueAfter: bigint;
  readonly debtValueAfterRay: bigint;
}

/** The largest withdrawal that keeps `target`; `bestIndex` is `2^256 − 1` when no single record fits. */
export interface RemovalSizing {
  readonly blockNumber: bigint;
  readonly timestamp: bigint;
  readonly proxy: Address;
  readonly target: bigint;
  readonly maxUnits: bigint;
  readonly bestIndex: bigint;
  readonly records: readonly { readonly positionKey: `0x${string}`; readonly units: bigint; readonly fits: boolean }[];
}

/** The fewest units of one record whose repay with collateral reaches the target health factor. */
export interface DeleverageSizing {
  readonly blockNumber: bigint;
  readonly timestamp: bigint;
  readonly proxy: Address;
  readonly reachable: boolean;
  readonly units: bigint;
  readonly debtRepaid: bigint;
  readonly debtAssetToWallet: bigint;
  readonly healthFactorAfter: bigint;
}

/** Every debt the account repays (with `repayAll`'s spend cap) and every record it withdraws to close. */
export interface CloseAccountView {
  readonly blockNumber: bigint;
  readonly timestamp: bigint;
  readonly proxy: Address;
  readonly debts: readonly { readonly reserveId: bigint; readonly asset: Address; readonly total: bigint; readonly maxRepaySpend: bigint }[];
  readonly records: readonly { readonly positionKey: `0x${string}`; readonly units: bigint; readonly amounts: readonly bigint[] }[];
}

/** One Spoke's slice of a Hub asset as the Lens reports it; `kind` indexes `LENS_SPOKE_KINDS`. */
export interface LensSpokeDraw {
  readonly spoke: Address;
  readonly homeHub: Address;
  readonly drawCap: bigint;
  readonly drawn: bigint;
  readonly deficit: bigint;
  readonly kind: number;
  readonly added: bigint;
  readonly addedShares: bigint;
  readonly addCap: bigint;
  readonly drawnOwed: bigint;
  readonly premiumOwed: bigint;
  readonly drawnShares: bigint;
  readonly premiumShares: bigint;
  readonly active: boolean;
  readonly halted: boolean;
}

/** One Hub asset with totals, rates, rate curve, its Lend Spoke's price and one slice per Spoke. */
export interface HubAssetView {
  readonly blockNumber: bigint;
  readonly timestamp: bigint;
  readonly hub: Address;
  readonly assetId: bigint;
  readonly underlying: Address;
  readonly decimals: number;
  readonly added: bigint;
  readonly addedShares: bigint;
  readonly drawn: bigint;
  readonly premium: bigint;
  readonly owed: bigint;
  readonly drawnShares: bigint;
  readonly premiumShares: bigint;
  readonly liquidity: bigint;
  readonly swept: bigint;
  readonly deficit: bigint;
  readonly accruedFees: bigint;
  readonly utilizationBps: bigint;
  readonly drawnRateRay: bigint;
  readonly supplyRateRay: bigint;
  readonly liquidityFeeBps: bigint;
  readonly feeReceiver: Address;
  readonly irStrategy: Address;
  readonly optimalUsageBps: bigint;
  readonly baseDrawnRateBps: bigint;
  readonly rateGrowthBeforeOptimalBps: bigint;
  readonly rateGrowthAfterOptimalBps: bigint;
  readonly lendSpoke: Address;
  readonly priceUsd8: bigint;
  readonly spokes: readonly LensSpokeDraw[];
}

async function lensView<T>(client: ViewClient, lens: Address, functionName: string, args: readonly unknown[]): Promise<T> {
  const call: ContractCall = { address: lens, abi: lensAppViewsAbi, functionName, args };
  const [result] = await all(client, [call]);
  return result as T;
}

/** `getPositionFees`: uncollected fees of one position of a market. */
export const readPositionFees = (client: ViewClient, lens: Address, marketId: bigint, positionKey: `0x${string}`) =>
  lensView<PositionFeesView>(client, lens, "getPositionFees", [marketId, positionKey]);

/** `getAccountFees`: uncollected fees of every record of a wallet's account in a market, in seizure-list order. */
export const readAccountFees = (client: ViewClient, lens: Address, wallet: Address, marketId: bigint) =>
  lensView<readonly PositionFeesView[]>(client, lens, "getAccountFees", [wallet, marketId]);

/** The account before and after one action: `amount` in debt-asset base units for borrow and repay. */
export function readActionPreview(
  client: ViewClient,
  lens: Address,
  action: { readonly kind: "borrow" | "repay"; readonly debtReserveId: bigint; readonly amount: bigint } | { readonly kind: "pledge" | "withdraw"; readonly positionKey: `0x${string}` },
  wallet: Address,
  marketId: bigint,
): Promise<ActionPreview> {
  switch (action.kind) {
    case "borrow":
      return lensView(client, lens, "previewBorrowAfter", [wallet, marketId, action.debtReserveId, action.amount]);
    case "repay":
      return lensView(client, lens, "previewRepayAfter", [wallet, marketId, action.debtReserveId, action.amount]);
    case "pledge":
      return lensView(client, lens, "previewPledgeAfter", [wallet, marketId, action.positionKey]);
    case "withdraw":
      return lensView(client, lens, "previewWithdrawAfter", [wallet, marketId, action.positionKey]);
  }
}

/** `previewMaxWithdraw`: the most units the account can withdraw and stay at or above `targetHealthFactorWad`. */
export const readMaxWithdraw = (client: ViewClient, lens: Address, wallet: Address, marketId: bigint, targetHealthFactorWad: bigint) =>
  lensView<RemovalSizing>(client, lens, "previewMaxWithdraw", [wallet, marketId, targetHealthFactorWad]);

/** `previewDeleverageTo`: the fewest units of one record whose repay with collateral reaches the target. */
export const readDeleverageTo = (
  client: ViewClient,
  lens: Address,
  wallet: Address,
  marketId: bigint,
  positionKey: `0x${string}`,
  debtReserveId: bigint,
  targetHealthFactorWad: bigint,
) => lensView<DeleverageSizing>(client, lens, "previewDeleverageTo", [wallet, marketId, positionKey, debtReserveId, targetHealthFactorWad]);

/** `previewCloseAccount`: every repay (spend caps for `deadline`) and withdrawal that closes the account. */
export const readCloseAccount = (client: ViewClient, lens: Address, wallet: Address, marketId: bigint, deadline: bigint) =>
  lensView<CloseAccountView>(client, lens, "previewCloseAccount", [wallet, marketId, deadline]);

/** `getHubAsset`: one Hub asset with its slices; reverts `UnknownHubAsset` for an asset the Hub does not list. */
export const readHubAsset = (client: ViewClient, lens: Address, hub: Address, assetId: bigint) => lensView<HubAssetView>(client, lens, "getHubAsset", [hub, assetId]);
