/**
 * Shared static-content generators (FAQs) for the detail pages. Pure and
 * deterministic — the single source for BOTH the UI fallback and the Convex content
 * seed (so seeded FAQs are identical to the fallback). Answers are plain text; the
 * UI wraps them in a <p>.
 *
 * Each product page ships five questions that answer the decisions people actually
 * make on that page: what the market is, how yield or leverage is formed, how to
 * enter/exit, and what can go wrong.
 */

export type FaqContent = { question: string; answer: string }

/** Editorial About copy for a multiply market — same length and shape as lend. */
export function buildMultiplyAboutDescription(options: {
  collateralName: string
  collateralSymbol: string
  borrowName: string
  borrowSymbol: string
  maxLeverage: string
  riskTier?: "low" | "medium" | "high"
}): string {
  const marketType =
    options.riskTier === "low" ? "lower-risk" : options.riskTier === "medium" ? "tier-medium" : "tier-high"
  return (
    `${options.collateralName} (${options.collateralSymbol}) / ${options.borrowName} (${options.borrowSymbol}) is a leveraged multiply market on Avana. ` +
    `Supply ${options.collateralSymbol} as collateral to loop into ${options.borrowSymbol} exposure, up to ${options.maxLeverage}, in a route dedicated to leveraged positions rather than LP collateral pools. ` +
    `Net returns track the supply/borrow spread, utilization, and the selected multiplier, so looping results can move as rates and available liquidity rebalance. ` +
    `The page focuses on the live leverage limit, the supply/borrow mix, available liquidity, and the latest risk posture for this ${marketType} market. ` +
    `Users should watch collateral factor, liquidation threshold, borrow cost, and available liquidity because those inputs affect both looping returns and how quickly a position can be unwound during stressed conditions.`
  )
}

/** General FAQs for a borrowable asset (templated by symbol + name). */
export function buildAssetFaqs(symbol: string, name: string): FaqContent[] {
  return [
    {
      question: `What is ${symbol}?`,
      answer: `${name} is a borrowable asset on Avana. You can take a ${symbol} loan against supported LP collateral, with the rate, available liquidity, and limits set by the active market.`,
    },
    {
      question: `How do I borrow ${symbol}?`,
      answer: `Choose a collateral pool that lists ${symbol}, supply that LP position, then open Borrow and enter the amount. Confirm in your wallet. Debt, health factor, and available borrow update after the transaction settles.`,
    },
    {
      question: `What determines the ${symbol} borrow rate?`,
      answer: `Borrow APY moves with utilization and available liquidity. When more of the market is borrowed, the rate usually rises so new borrowers pay more and suppliers earn more.`,
    },
    {
      question: "What is health factor, and when is a position liquidated?",
      answer:
        "Health factor compares your collateral value to your debt after risk parameters. If it falls to 1.0, the position can be liquidated. Volatile collateral, a rising borrow rate, or a thinner pool all reduce the buffer.",
    },
    {
      question: `How do I repay ${symbol}?`,
      answer: `Open Repay on the same market, choose the amount or repay in full, and confirm. Repaying lowers debt and raises health factor. You can then withdraw unused collateral if the remaining position stays healthy.`,
    },
  ]
}

/** General FAQs for a lend (single-asset supply) market (templated by symbol + name). */
export function buildLendFaqs(symbol: string, name: string): FaqContent[] {
  return [
    {
      question: `What is supplying ${symbol}?`,
      answer: `Supplying ${name} deposits it into the Avana lending market to earn yield. You earn the supply APY plus any active rewards, and you can withdraw available liquidity at any time.`,
    },
    {
      question: `How is the ${symbol} supply APY determined?`,
      answer: `Supply APY tracks borrow demand. As utilization rises, borrowers pay more and a larger share goes to suppliers. Rewards APY, when present, is an extra incentive on top of that base rate.`,
    },
    {
      question: `Can I withdraw my ${symbol} anytime?`,
      answer: `You can withdraw up to the market's available liquidity. When utilization is very high, withdrawable cash can be limited until borrowers repay or new supply arrives.`,
    },
    {
      question: "What is the reserve factor?",
      answer:
        "The reserve factor is the share of borrower interest the protocol keeps as a safety buffer instead of paying suppliers. Lower-risk markets use a smaller reserve factor.",
    },
    {
      question: `What risks should I watch when supplying ${symbol}?`,
      answer: `Watch smart-contract risk, ${name}'s own volatility or de-peg risk, and utilization spikes that can delay withdrawals. Higher-risk-tier markets keep a larger reserve and can move more when demand shifts.`,
    },
  ]
}

/** General FAQs for a multiply (leveraged loop) market (templated by the pair). */
export function buildMultiplyFaqs(collateral: string, borrow: string): FaqContent[] {
  return [
    {
      question: `What is the ${collateral} / ${borrow} multiply market?`,
      answer: `It is a leveraged loop: you post ${collateral} as collateral, borrow ${borrow}, and recycle that exposure to increase size. The route is separate from LP collateral pools and is built only for this pair.`,
    },
    {
      question: `How do I open a ${collateral} / ${borrow} position?`,
      answer: `Enter the ${collateral} amount, choose a multiplier at or below the public cap, and confirm. Avana supplies the collateral, borrows ${borrow}, and loops in one transaction. Equity, debt, and health factor show after settlement.`,
    },
    {
      question: "How is max APY calculated?",
      answer:
        "Max APY is the net of collateral carry minus borrow cost at the public leverage cap. It is a ceiling from current rates, not a guaranteed return. If borrow cost rises or supply APY falls, the net number moves.",
    },
    {
      question: "Why is leverage capped, and what is liquidation risk?",
      answer: `The cap keeps the loop inside this pair's collateral factor, liquidation threshold, and available liquidity. Higher leverage increases capital efficiency and also how fast health factor can fall if ${collateral} drops or ${borrow} cost jumps.`,
    },
    {
      question: "How do I deleverage or close the position?",
      answer:
        "Use Deleverage to unwind part of the loop, or close the position to repay debt and return leftover collateral. Reducing leverage raises health factor. Closing needs enough liquidity in the borrow leg to buy back the debt.",
    },
  ]
}

/** General FAQs for an LP collateral pool (templated by pair name). */
export function buildPoolFaqs(name: string): FaqContent[] {
  return [
    {
      question: `What is ${name}?`,
      answer: `${name} is an LP pool you can post as collateral on Avana. The position earns swap fees in the underlying DEX, and Avana uses its value — after risk parameters — to unlock borrow power.`,
    },
    {
      question: "How do I use this pool as collateral?",
      answer:
        "Supply the LP position to this market, then borrow a supported asset against it. Borrowing power follows the pool's collateral factor and your health factor. You can add or remove collateral as long as the remaining position stays healthy.",
    },
    {
      question: "How do liquidity providers earn?",
      answer:
        "The LP earns a share of swap fees in the pool. More trading usually means more fee flow, but returns still depend on price movement, fee tier, and how much of the time the position stays in range.",
    },
    {
      question: "What is impermanent loss?",
      answer:
        "Impermanent loss is the gap between holding the two tokens and providing them in the pool while the price moves. It is usually smaller in calmer pairs and larger when one side moves sharply. That change also moves collateral value on Avana.",
    },
    {
      question: "What happens if price leaves the active range?",
      answer:
        "In concentrated-liquidity pools, the position can stop earning fees until price returns to range. Collateral value can also concentrate into one token, which changes health factor. Tighter ranges can earn more but need more active management.",
    },
  ]
}
