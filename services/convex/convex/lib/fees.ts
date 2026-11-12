// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The frontend fee and the total shown before signing (Q-409). The app charges 10 bps on every app action (supply,
// withdraw, pledge, withdraw collateral, borrow, repay, repay with collateral, deleverage, swap), never above
// MAX_FEE_BPS, the 25 bps ceiling of the listing ARFC; keeper liquidations are not app actions and pay none. No
// contract charges a fee (Q-231): the app adds one ERC-20 transfer to the action's batch (EIP-5792 `wallet_sendCalls`,
// or a smart account's multicall), so the fee and the action succeed or fail together. The transfer goes to the
// ParameterStore's `feeRecipient`, which the app reads on chain before building the batch (never from Convex or the
// manifest); it is the same timelocked address that receives the liquidation fee share. The app simulates the batch,
// and if the fee transfer would revert (a token that blocklists `feeRecipient`, for example), it drops the fee leg and
// sends the action alone. The rules live in Convex (`feeConfig`); this module is the one place that turns them into
// amounts, and the app calls the same function to build the transfer, so the amount shown is the amount sent. The
// gas estimate is the simulation of the whole batch, fee transfer included.

export type FeeAction =
  | "supply"
  | "withdraw"
  | "pledge"
  | "borrow"
  | "repay"
  | "withdrawCollateral"
  | "repayWithCollateral"
  | "deleverage"
  | "swap";

export const FEE_ACTIONS: readonly FeeAction[] = ["supply", "withdraw", "pledge", "borrow", "repay", "withdrawCollateral", "repayWithCollateral", "deleverage", "swap"];

/** Ceiling the listing ARFC commits to: the app never charges more without a new ARFC. */
export const MAX_FEE_BPS = 25;

/** Whether the user pays the amount (supply, pledge, repay) or receives it (withdraw, borrow). */
export const DIRECTION: Readonly<Record<FeeAction, "pay" | "receive">> = {
  supply: "pay",
  pledge: "pay",
  repay: "pay",
  repayWithCollateral: "pay",
  deleverage: "pay",
  swap: "pay",
  withdraw: "receive",
  borrow: "receive",
  withdrawCollateral: "receive",
};

/** Actions that move an LP position: their basis is the position's oracle USD value, paid in the debt stablecoin. */
export const LP_VALUE_ACTIONS: ReadonlySet<FeeAction> = new Set<FeeAction>(["pledge", "withdrawCollateral"]);

export interface FeeRules {
  readonly enabled: boolean;
  readonly defaultBps: number;
  readonly actionBps: Readonly<Partial<Record<string, number>>>;
  readonly exemptActions: readonly string[];
  /** Largest fee in USD per action; null for no cap. */
  readonly maxFeeUsd: number | null;
}

export interface GasInputs {
  /** Gas of the whole batch from the wallet's simulation. */
  readonly gasUnits: bigint;
  readonly baseFeeWei: bigint;
  readonly priorityFeeWei: bigint;
  /** L1 data fee of the batch on an L2 (the OP Stack gas price oracle's `getL1Fee`), 0 on Ethereum. */
  readonly l1FeeWei: bigint;
  /** Native token price, USD with 8 decimals. */
  readonly nativeUsd8: bigint;
}

/** Basis of every action that does not move an LP position: the action amount, fee paid in the same token. */
export interface AmountBasis {
  readonly kind: "amount";
  /** Action amount in the token's base units. */
  readonly amount: bigint;
  readonly decimals: number;
  /** The token's Lend Spoke price, USD with 8 decimals. */
  readonly priceUsd8: bigint;
}

/** Basis of pledge and withdraw collateral: the position's oracle USD value, fee paid in the debt stablecoin. */
export interface LpValueBasis {
  readonly kind: "lpValue";
  /** The position's LPOracle value as Lens reports it, USD with 8 decimals. */
  readonly valueUsd8: bigint;
  /** Decimals of the stablecoin the fee is paid in. */
  readonly decimals: number;
  /** The stablecoin's price, USD with 8 decimals. */
  readonly priceUsd8: bigint;
}

export interface FeeQuoteInput {
  readonly action: FeeAction;
  readonly basis: AmountBasis | LpValueBasis;
  readonly gas: GasInputs;
}

export interface FeeQuote {
  readonly feeBps: number;
  /** Fee in the fee token's base units (the action token, or the debt stablecoin for an LP action); the app transfers exactly this. */
  readonly feeAmount: bigint;
  readonly capped: boolean;
  readonly amountUsd: number;
  readonly feeUsd: number;
  readonly gasWei: bigint;
  readonly gasUsd: number;
  /** Fee + gas. */
  readonly costUsd: number;
  /** What leaves the wallet (pay: amount + fee + gas) or what the wallet nets (receive: amount − fee − gas). */
  readonly totalUsd: number;
  readonly direction: "pay" | "receive";
}

const usd = (units: bigint, decimals: number, price8: bigint): number => Number((units * price8) / 10n ** BigInt(decimals)) / 1e8;

function checkBps(bps: number, what: string): void {
  if (!Number.isInteger(bps) || bps < 0 || bps > MAX_FEE_BPS) throw new Error(`fee rate ${bps} bps for ${what} is outside 0..${MAX_FEE_BPS}`);
}

/** Throws when any rate in the rules is not an integer in 0..MAX_FEE_BPS. */
export function checkFeeRules(rules: Pick<FeeRules, "defaultBps" | "actionBps">): void {
  checkBps(rules.defaultBps, "the default");
  for (const [action, bps] of Object.entries(rules.actionBps)) if (bps !== undefined) checkBps(bps, action);
}

/** The rate that applies to an action: 0 when fees are off or the action is exempt. Rules above the ceiling throw. */
export function feeBpsFor(rules: FeeRules, action: FeeAction): number {
  checkFeeRules(rules);
  if (!rules.enabled || rules.exemptActions.includes(action)) return 0;
  return rules.actionBps[action] ?? rules.defaultBps;
}

/**
 * LP-value fee in the stablecoin's base units: `⌊valueUsd8 × bps × 10^decimals / (10⁴ × priceUsd8)⌋`, one division,
 * so it rounds down once and never exceeds `bps` of the position's value.
 */
export function lpValueFee(valueUsd8: bigint, bps: number, decimals: number, priceUsd8: bigint): bigint {
  if (priceUsd8 <= 0n) throw new Error("stablecoin price must be positive");
  return (valueUsd8 * BigInt(bps) * 10n ** BigInt(decimals)) / (10_000n * priceUsd8);
}

/**
 * Fee `⌊amount × bps / 10⁴⌋` (or the LP-value fee for pledge and withdraw collateral), rounded down so the user never
 * pays above the stated rate, then cut to the USD cap (also rounded down). Gas `gasUnits × (baseFee + priorityFee) +
 * l1Fee`, valued at the native price.
 */
export function quoteFee(rules: FeeRules, q: FeeQuoteInput): FeeQuote {
  if (q.gas.gasUnits < 0n) throw new Error("gas must be non-negative");
  const lp = LP_VALUE_ACTIONS.has(q.action);
  if (lp !== (q.basis.kind === "lpValue")) throw new Error(`${q.action} takes the ${lp ? "lpValue" : "amount"} basis`);
  const feeBps = feeBpsFor(rules, q.action);
  const b = q.basis;
  let feeAmount: bigint;
  let amountUsd: number;
  if (b.kind === "lpValue") {
    if (b.valueUsd8 < 0n) throw new Error("position value must be non-negative");
    feeAmount = lpValueFee(b.valueUsd8, feeBps, b.decimals, b.priceUsd8);
    amountUsd = Number(b.valueUsd8) / 1e8;
  } else {
    if (b.amount < 0n) throw new Error("amount must be non-negative");
    feeAmount = (b.amount * BigInt(feeBps)) / 10_000n;
    amountUsd = usd(b.amount, b.decimals, b.priceUsd8);
  }
  let capped = false;
  if (rules.maxFeeUsd !== null && b.priceUsd8 > 0n) {
    const capAmount = (BigInt(Math.round(rules.maxFeeUsd * 1e8)) * 10n ** BigInt(b.decimals)) / b.priceUsd8;
    if (feeAmount > capAmount) {
      feeAmount = capAmount;
      capped = true;
    }
  }
  const gasWei = q.gas.gasUnits * (q.gas.baseFeeWei + q.gas.priorityFeeWei) + q.gas.l1FeeWei;
  const gasUsd = Number((gasWei * q.gas.nativeUsd8) / 10n ** 18n) / 1e8;
  const feeUsd = usd(feeAmount, b.decimals, b.priceUsd8);
  const costUsd = feeUsd + gasUsd;
  const direction = DIRECTION[q.action];
  return {
    feeBps,
    feeAmount,
    capped,
    amountUsd,
    feeUsd,
    gasWei,
    gasUsd,
    costUsd,
    totalUsd: direction === "pay" ? amountUsd + costUsd : amountUsd - costUsd,
    direction,
  };
}

/** Rules in force until a `feeConfig` row is written: 10 bps on every app action, no exemptions, no USD cap. */
export const DEFAULT_FEE_RULES: FeeRules = { enabled: true, defaultBps: 10, actionBps: {}, exemptActions: [], maxFeeUsd: null };
