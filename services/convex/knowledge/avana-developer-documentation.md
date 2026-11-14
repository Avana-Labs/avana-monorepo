# Avana Developer Documentation

_Reference knowledge base extracted from the Avana developer docs._


---

## [Introduction](http://localhost:3000/developers/introduction)

_Source: `/developers/introduction`_

# Introduction

Your LP can keep earning fees in the pool while backing a loan. Avana makes that possible on Aave v4: spokes handle LP-specific risk, the Hub powers shared lending liquidity.

[Start with Key Concepts](http://localhost:3000/developers/introduction/key-concepts)[Explore Borrow Spoke](http://localhost:3000/developers/architecture)

## What is Avana?

Avana is a lending protocol built for LP collateral. It lets users deposit supported AMM positions, keep those positions active in the underlying pool, and borrow against them through Aave v4 infrastructure.

Liquidity providers often have to remove liquidity before they can borrow against their capital. That means exiting the pool, giving up fee exposure, and interrupting the market position they already built.

Avana solves this by making supported LP positions usable as collateral. The LP stays live, Avana tracks and values the position, and Aave v4 handles the borrow-side accounting through an internal vault collateral token.

## How It Works

The user-facing flow is short, but each stage hides LP-specific underwriting work. Later pages break down the mechanics behind each step.

01

### Deposit a supported LP position

A borrower deposits an approved LP position into the relevant Borrow Spoke, but the liquidity itself stays deployed in the underlying pool instead of being redeemed first.

02

### Value it conservatively

The spoke rebuilds the position from its pool data, prices the underlying exposure through the oracle stack, and then discounts that value through collateral factors and market-specific controls.

03

### Borrow through the Hub

If the resulting capacity is sufficient, the loan draws from shared Hub liquidity while health checks, collateral accounting, and liquidation behavior remain specific to that spoke.

## Why LP Collateral Matters

LP positions already sit in working capital. Without a lending layer, getting cash back out usually means shrinking or closing the pool position first.

### Liquidity stays in the pool

The protocol is built for LP positions that should keep doing LP work. A borrower does not have to pull liquidity out of the AMM just to access cash against it.

### Capacity follows the real LP

Borrowing power comes from the actual structure of the position: token mix, accrued fees, active range when relevant, available depth, and the way the position could be exited during stress.

### Liquidation has explicit rules

LP collateral is not handled as a generic token balance. Each supported market defines how value is recovered, what gets sold or unwound, and how debt is closed if the account becomes unsafe.

## Architecture

Avana uses Aave v4 because LP collateral needs shared liquidity and isolated risk logic at the same time. The Hub handles the common monetary layer while spokes handle LP-specific work: pool collateral registration, position valuation, risk enforcement, and liquidation execution.

### Borrow Spoke

Accepts supported LP collateral, turns it into spoke-level borrowing capacity, and owns the health and liquidation rules for that market.

### Hub

Holds the shared lending balance sheet: reserve accounting, interest-rate logic, and the liquidity that borrower-facing spokes draw from.

### Lend Spoke

Brings lender assets into the system and routes them to the Hub so LP underwriting can stay separate from capital onboarding.

Builders should think of the system in two halves. The Hub is the common balance sheet and debt engine, while Borrow Spokes decide what each LP market can safely support and how that market must be unwound if it fails. The Lend Spoke feeds capital into the Hub so suppliers do not need to reason about LP mechanics just to provide liquidity.

---

## [Introduction — Key Concepts](http://localhost:3000/developers/introduction/key-concepts)

_Source: `/developers/introduction/key-concepts`_

# Key Concepts

## Core Insight

Standard lending markets usually treat collateral as simple token balances: ETH, BTC, stablecoins, or other ERC-20 assets. Avana is built for collateral that changes shape over time. LP positions can contain multiple assets, accrue fees, drift with price movement, become one-sided, or require a specific unwind path.

Because of that, Avana underwrites collateral at the LP market level. Each supported pool or LP family can have its own valuation logic, collateral factors, borrowable assets, liquidation assumptions, and risk limits.

## Borrowing Model

Users deposit supported LP positions into a Borrow Spoke. The positions can remain active in their pools while the protocol takes custody for collateral accounting.

Each approved LP position is valued on its own. After collateral factors and pool risk controls are applied, its discounted contribution is added to borrowing capacity inside that Borrow Spoke.

When the user borrows, the spoke draws liquidity from the Hub. LP market risk stays in the spoke layer, while shared capital accounting stays at the Hub.

## Oracle & Valuation

Avana prices LP collateral by reconstructing the position and valuing the assets inside it. For fungible LPs, the protocol derives value from external asset prices and pool balance reconstruction. For concentrated liquidity, it decomposes the position by liquidity, range, current tick, token exposure, and accrued fees.

The result is then discounted into recoverable collateral value. Borrow power is based on what the position can realistically support under the market's risk assumptions, not on an optimistic net asset value.

Avana uses a dual-oracle pricing framework for LP collateral. Chainlink price feeds provide the primary reference for the underlying assets, while AMM-derived TWAPs act as an independent verification layer sourced from onchain liquidity.

## Borrowing Capacity

Borrowing capacity comes from the risk-adjusted value of approved LP positions inside a Borrow Spoke. Avana reconstructs each position, prices the underlying exposure, applies pool-level risk treatment, and then applies the market's collateral factor.

The Borrow Spoke reports that capacity to the Hub for enforcement. When a user has multiple approved positions in the same market, Avana aggregates their capacity while still valuing each position under its own pool, range, liquidity, and risk assumptions.

See [Collateral Factors](http://localhost:3000/developers/architecture/collateral-factors) for how each market sets collateral factors, liquidation thresholds, and liquidation bonus per asset.

## Health & Liquidation

Avana monitors account health inside each Borrow Spoke using the same valuation path that governs borrowing. Adjusted collateral value — already discounted through LP reconstruction, pricing, collateral factors, and recoverable-value assumptions — is compared against outstanding debt.

When health falls below the liquidation threshold, Aave handles debt accounting and the liquidation entry point against the ERC-20 vault collateral. Avana handles the LP settlement behind that vault token: burning vault collateral, mapping liquidation back to the real LP position, and following the market route to unwind, sell, auction, or transfer the backing position.

## Fee Treatment

LP positions may keep accruing trading fees while they are used as collateral. Avana can recognize those fees in valuation and, subject to health checks, let users claim them without fully exiting the principal LP position.

**Related docs:** [Price Oracles](http://localhost:3000/developers/integrations/price-oracles) and [Claim LP Fees](http://localhost:3000/developers/getting-started/claim-lp-fees).

---

## [Introduction — Glossary](http://localhost:3000/developers/introduction/glossary)

_Source: `/developers/introduction/glossary`_

# Glossary

## Core Concepts

Borrow SpokeThe borrower-facing Avana spoke that receives LP collateral, values positions, tracks debt, and coordinates borrowing and liquidation against Hub liquidity.Lend SpokeThe lender-facing capital entry point that routes supplied assets into the Hub so Borrow Spokes can draw shared liquidity.HubThe shared monetary layer in Aave v4 that manages liquidity, reserves, accounting, and protocol-wide capital coordination across connected spokes.Hub-and-Spoke ArchitectureA design where shared capital lives in the Hub while collateral-specific logic is isolated in spokes. Avana uses this model because LP collateral needs DEX-specific valuation and liquidation behavior.Liquidation NodeA protocol-operated runtime that indexes active positions and serves as a specialized liquidation backstop for complex LP collateral.

## LP & Collateral

LP PositionA liquidity position from a supported AMM. Depending on the DEX, it may be a fungible LP token, a concentrated-liquidity NFT, or another approved pool-share format.Collateral FactorThe portion of USD collateral value that may count toward borrowing power. In LP markets, this is applied at the position level rather than to the spoke as a whole.Borrowing CapacityThe amount a user can borrow inside a Borrow Spoke after each deposited LP position has been valued, risk-adjusted, and added to the user’s aggregate capacity.Allowed PoolA governance-approved pool that meets admissibility requirements such as oracle coverage, liquidity depth, unwind quality, and spoke compatibility.Loan-to-Value (LTV)The borrowing ratio associated with collateral after Avana’s position valuation and pool-specific risk controls have been applied.

## Debt & Interest

Debt SharesThe internal accounting unit used to track borrower obligations while interest accrues over time without rewriting every loan balance continuously.Borrow RateThe rate borrowers pay on outstanding debt. It reflects both shared Hub conditions and LP-specific risk considerations.Utilization RateThe proportion of borrowed liquidity relative to available supply in the relevant Hub-connected capital layer.Risk PremiumThe risk-specific component layered on top of base borrowing conditions to reflect the LP collateral profile being financed.Reserve FactorThe portion of protocol economics or interest flows reserved for the system rather than passed through entirely to liquidity suppliers.

### Liquidation

Health FactorThe ratio between adjusted collateral value and outstanding debt inside a Borrow Spoke. When it falls too low, the position approaches liquidation eligibility.LiquidationThe process of repaying debt against an unhealthy LP-backed position, unwinding enough collateral to restore solvency, and returning any residual value after settlement.Liquidation BonusThe liquidation premium paid to the party that executes the unwind, compensating them for capital use, routing complexity, and execution risk.

### Oracle & Transform

OracleAvana’s valuation engine for LP collateral. It combines external asset prices, LP position reconstruction, and recoverable-value safeguards.Recoverable ValueThe amount the protocol believes can realistically be realized during a stressed unwind after liquidation slippage, pool conditions, and risk buffers are considered.TransformA controlled modification of a collateralized LP position, such as a rebalance or range change, that is only allowed when the resulting position still satisfies protocol health checks.

## Risk & Security

Pool ApprovalThe rule that only pre-approved pools may be admitted as collateral, limiting exposure to unsupported or weakly monitored markets.Recovery HaircutA valuation discount applied so borrow power reflects recoverable unwind value rather than optimistic theoretical NAV.Exposure CapsRisk limits that bound borrowable exposure by pool family, collateral class, or liquidity depth.Circuit BreakerA risk control that can pause or restrict actions when prices, market behavior, or protocol dependencies become inconsistent or unsafe.Governance SafetyThe set of review, timelock, veto, and emergency roles used by the Risk Framework to keep parameter changes disciplined.Reentrancy ProtectionThe contract-level protection that prevents a state-changing workflow from being entered again before the first execution is complete.

## Metrics

TVLTotal value of assets supplied as LP collateral or capital across Avana-connected components.Outstanding DebtThe amount currently borrowed against approved collateral positions.Borrow UtilizationThe share of available Hub liquidity that has been drawn by borrowers.Borrowing HeadroomThe difference between a user’s current debt and remaining aggregate borrowing capacity inside a Borrow Spoke.Residual ValueAny value left in a position after debt, liquidation premium, and execution costs have been settled.

## Disclaimers

- **No Investment Advice:** Avana is a software protocol. This documentation does not constitute investment advice.
- **Risk of Loss:** Users can lose funds through smart contract vulnerabilities, market volatility, liquidation, or oracle manipulation.
- **Regulatory Status:** The regulatory status of Avana and its tokens (if any) is not guaranteed and may vary by jurisdiction.
- **No Warranty:** The software is provided "as is" without warranty of any kind.

---

## [Getting Started](http://localhost:3000/developers/getting-started)

_Source: `/developers/getting-started`_

# Deposit LP

Deposit a supported LP position into Avana to use it as collateral while it keeps earning fees in the pool.

## Overview

To borrow against LP collateral on Avana, start by depositing a supported position into the app. Pick an approved pool, connect your wallet, and submit the deposit for the LP you already hold on a supported DEX.

Avana records the position, values it, and adds it to your borrowing capacity in the relevant Borrow Spoke. Your liquidity stays in the pool and keeps accruing fees. Deposit does not borrow for you — it sets up the collateral you can borrow against next.

## Deposit Flow

### 1. Choose a supported pool

Open the Avana interface and select an LP market that is live on your deployment. Only approved pools can be deposited. See [Allowed LP Pools](http://localhost:3000/developers/integrations/allowed-pools) for how pool support is defined.

### 2. Approve and deposit your LP

Approve the LP token or position NFT if needed, then confirm the deposit. Avana routes the position into the Borrow Spoke for that market.

### 3. Wait for valuation

The spoke checks that the pool is approved, reconstructs the position, and applies collateral factors to calculate how much borrowing capacity the deposit adds.

### 4. Borrow when ready

Once the deposit clears, your borrowing capacity updates in the interface. You can move on to [Borrow Assets](http://localhost:3000/developers/getting-started/borrow-assets) when you want to draw liquidity from the Hub.

## Technical Details

**Borrowing power updates with the market.** Your capacity is recalculated from the live LP position as prices, fees, and pool state change — not locked at the deposit-time mark.

**LP formats differ by DEX.** Some pools issue fungible LP tokens; concentrated-liquidity DEXs use position NFTs or position-manager shares. Avana handles both through the same spoke custody model.

**No unwind on deposit.** You are not removing liquidity from the pool when you deposit. The position stays active in the AMM.

## Supported LP Position Types

| Family Examples Admission Notes |
| Concentrated liquidity positions Range-bound NFT or position-manager based LPs Range, tick position, and fee accrual are part of the valuation path. |
| Fungible stable or correlated LPs Stable-swap and tightly correlated pool shares Pool inventory and unwind quality drive conservative borrowing power. |
| Weighted and multi-asset LPs Weighted baskets and multi-token pools Each supported family is admitted only through approved pool templates. |

## After Deposit

- Your LP keeps earning trading fees in the underlying pool
- Borrowing capacity appears in the interface for that Borrow Spoke
- You can deposit more approved positions in the same market to add capacity
- Next step: [Borrow Assets](http://localhost:3000/developers/getting-started/borrow-assets)

---

## [Getting Started — Borrow Assets](http://localhost:3000/developers/getting-started/borrow-assets)

_Source: `/developers/getting-started/borrow-assets`_

# Borrow Assets

Borrow stablecoins, ETH, or other enabled assets against the LP collateral you have already deposited.

## Overview

After your LP is deposited and valued, you can borrow from the Hub using the capacity shown in the interface. Choose the asset and amount, confirm the transaction, and the borrowed tokens are sent to your wallet.

Interest accrues on open debt, so your health factor can change even if you do nothing. Leave a buffer below your maximum borrow rather than drawing the full amount.

## Borrow Checks

Position and ownership checks

The spoke confirms your LP positions are still in the account, still approved, and still recognized as collateral.

Capacity check

The borrow amount must fit within your remaining borrowing capacity in that Borrow Spoke.

Hub liquidity and cap checks

The Hub must have enough of the requested asset available, and protocol caps must allow the borrow.

Post-borrow health check

Your account must stay above the liquidation threshold after the new debt is added.

## Health Check

Before a borrow is approved, Avana checks that your account stays healthy after the new debt. Health factor is adjusted collateral value divided by outstanding debt. The adjusted collateral value already includes LP valuation, collateral factors, and recoverable-value discounts.

`healthFactor = adjustedCollateralValue / outstandingDebt`

If health falls below the liquidation boundary, the position becomes eligible for liquidation. See [Health Factor](http://localhost:3000/developers/architecture/health-factor) for the full model.

## Internal Accounting

**Debt shares:** new debt is recorded through a debt-share model so interest can accrue over time without rewriting the full account balance on every block.

**Hub draw:** the Borrow Spoke requests the asset from the Hub only after the spoke finishes the collateral, capacity, and health checks.

**State update:** the user receives the borrowed asset, and the spoke records the resulting debt state so future health checks, repayments, and liquidation logic all reference the same updated account.

## Borrowable Assets

Each market shows which assets you can borrow — typically major stablecoins, GHO, ETH, BTC, and other liquid assets configured for that deployment. A supported LP collateral type does not unlock every borrow asset automatically; each debt asset is part of the market configuration.

Check the Avana interface on your target deployment for the live borrow list.

## Borrowing Power

Borrowing power is the sum of your approved LP positions in one Borrow Spoke, after collateral factors and risk discounts. Each position contributes based on its own pool, range, liquidity, and risk settings.

The closer you borrow to your maximum, the less room you have for price moves or volatility. See [Collateral Factors](http://localhost:3000/developers/architecture/collateral-factors) and [Health Factor](http://localhost:3000/developers/architecture/health-factor) when sizing a borrow.

---

## [Getting Started — Manage Loans](http://localhost:3000/developers/getting-started/manage-loans)

_Source: `/developers/getting-started/manage-loans`_

# Manage Loans

Track health, repay debt, claim fees, and adjust collateral while your loan is open.

## Overview

An open loan on Avana is not static. Your LP keeps earning fees, token prices move, and interest accrues on debt. Check health factor in the interface regularly and act before you are close to liquidation.

## Borrowing More

You can borrow more if you still have unused capacity and the Hub has liquidity for the asset you want. Each additional borrow runs the same checks as the first one.

Partial repayment frees capacity immediately. It lowers debt, improves health, and can make room for withdrawals or fee claims later.

## Monitoring Health

**Healthy:** collateral value stays comfortably above debt, with room for normal market movement.

**Watchlist:** the account still passes checks, but the buffer is thin. Consider repaying, adding collateral, or reducing exposure.

**Liquidatable:** health has crossed the liquidation threshold. The liquidation framework can take over.

See [Health Factor](http://localhost:3000/developers/architecture/health-factor) for how health is calculated.

## Operational Control

1. Repay part of the debt to rebuild buffer
2. Add more approved LP collateral to the same Borrow Spoke
3. Claim accrued fees when the account still passes post-claim health checks
4. Withdraw or resize collateral only when the remaining account still stays healthy

## Position Changes

While debt is open, your LP position keeps running in the pool. Price moves, fee accrual, and pool inventory shifts can change your collateral value without you taking any action. Avana recalculates health on these changes automatically.

If you want to claim fees, withdraw collateral, or change the position on the DEX, those actions must go through Avana first. The Borrow Spoke checks whether your account stays healthy after the action before allowing it.

## Key Constraints

- Collateral changes cannot leave remaining debt above allowed spoke capacity
- New or replacement positions must stay inside the approved pool set
- Borrow actions still depend on Hub liquidity and active caps
- Repay or add collateral before health reaches liquidation territory

See [Liquidation Framework](http://localhost:3000/developers/liquidation) and [Collateral Factors](http://localhost:3000/developers/architecture/collateral-factors) when making changes to a live loan.

---

## [Getting Started — Repay Loans](http://localhost:3000/developers/getting-started/repay-loans)

_Source: `/developers/getting-started/repay-loans`_

# Repay Loans

Repay debt to improve health and regain control over your LP collateral.

## Overview

Repayment sends the borrowed asset back to the protocol and reduces your outstanding debt. Your LP collateral stays in place — only the debt side of the account changes. Health improves immediately because the same collateral now supports a smaller liability.

## Repay Process

1. Choose an amount

Select partial repayment to regain buffer, or repay the full balance to clear debt entirely.

2. Submit the debt asset

Approve and confirm the repayment transaction. The payment is routed through the Borrow Spoke and applied against your outstanding liability, including accrued interest.

3. Health updates

Once the repayment confirms, your health factor and remaining borrowing capacity update in the interface.

## Partial vs Full Repayment

Partial repayment is enough to improve safety when your account is drifting toward liquidation. You do not need to clear the full balance for repayment to matter.

Full repayment clears all debt for that borrow. At that point, collateral restrictions tied to the loan are released and you can withdraw your LP through [Withdraw Collateral](http://localhost:3000/developers/getting-started/withdraw-collateral).

Interest keeps accruing on open debt until you repay. The amount shown in the interface includes accrued interest, not just the original borrow.

## When Repayment Is Urgent

When health is near the liquidation threshold, repayment is the fastest way to improve safety. It directly reduces debt without waiting for markets to recover or adding more collateral first.

Once health crosses the liquidation boundary, see the [Liquidation Framework](http://localhost:3000/developers/liquidation) for what happens next.

---

## [Getting Started — Withdraw Collateral](http://localhost:3000/developers/getting-started/withdraw-collateral)

_Source: `/developers/getting-started/withdraw-collateral`_

# Withdraw Collateral

Withdraw your LP position from Avana when debt is cleared or your account stays healthy without it.

## Overview

Withdrawing returns your LP position from Avana custody back to your wallet. The easiest path is full debt repayment first — once debt is zero, collateral is no longer securing a loan and withdrawal is straightforward.

You can also withdraw while debt is still open if the remaining collateral still supports the outstanding debt after the withdrawal. Avana runs a health check before releasing the position.

## Withdrawal Process

1. Repay debt if needed

If you still owe debt, repay enough so the remaining collateral can support what is left. Full repayment is the simplest path.

2. Request withdrawal

In the Avana interface, select the LP position you want to withdraw and confirm the transaction.

3. Health check and release

The Borrow Spoke recalculates your account without the withdrawn position. If health is still valid, the LP token or position NFT is returned to your wallet.

## Partial Withdrawal

You can withdraw one LP position while keeping others deposited, or withdraw part of a fungible LP balance, as long as the remaining collateral still covers open debt. Each withdrawal is checked individually against your current health factor.

## After Withdrawal

- Your LP returns to your wallet and you control it directly again
- You can keep it in the pool, adjust the range on the DEX, or exit liquidity entirely
- You can deposit it again later through [Deposit LP](http://localhost:3000/developers/getting-started) if the pool is still approved

---

## [Getting Started — Claim LP Fees](http://localhost:3000/developers/getting-started/claim-lp-fees)

_Source: `/developers/getting-started/claim-lp-fees`_

# Claim LP Fees

Claim trading fees from your LP position while it stays active as collateral.

## Overview

Avana tracks principal liquidity and accrued fees separately. That means you can claim fee income from your LP without closing the position that backs your loan.

Fee claims still affect your collateral value, so Avana runs a health check before and after the claim. If claiming fees would push your account below the required collateral boundary, the claim is blocked until you repay debt or add more collateral.

## How It Works

In the Avana interface, open the claim-fees action for your deposited position. Avana routes the claim through the DEX-specific path for that LP type.

For concentrated-liquidity DEXs, that is typically a collect-style call that pulls accrued fees while leaving principal in the pool. For fungible LP tokens, Avana uses the DEX's native fee-claim path when one is available.

After fees are claimed, Avana syncs the updated position state back into the Borrow Spoke so health and borrowing capacity reflect the new balance.

## Health Checks

Accrued fees can count toward your collateral buffer until they are claimed. When you claim fees, that value leaves the position, which can lower health if your account is already close to the liquidation threshold.

Repay debt or add collateral first if a fee claim would leave your account under the required boundary.

## Fee Accounting

Avana's oracle model separates principal value from fee value so the protocol knows how much of the position is core liquidity and how much is claimable fee income.

During liquidation, accrued fees may be applied before principal liquidity is unwound, reducing how much of the core LP position has to be disturbed to cover debt.

See [Price Oracles](http://localhost:3000/developers/integrations/price-oracles) and [Liquidation Framework](http://localhost:3000/developers/liquidation).

## Key Benefits

- Your LP principal keeps earning fees and stays active in the pool while you borrow.
- You can realize fee income without unwinding the collateral position.
- Health checks prevent fee claims from pulling out too much value and leaving debt undersecured.

---

## [Protocol Architecture](http://localhost:3000/developers/architecture)

_Source: `/developers/architecture`_

# Borrow Spoke

The isolated LP-collateral market where users deposit positions, borrow assets, and manage loan health.

## Overview

A Borrow Spoke is an isolated LP-collateral market. It decides which pools are supported, how each LP position is valued, what collateral factors apply, which assets can be borrowed, and how liquidation works for that market.

Borrow Spokes are separated because LP positions do not all behave the same. A stablecoin LP, a correlated ETH-staked ETH LP, and a volatile governance-token LP need different risk settings, different caps, and sometimes different liquidation routes.

## Borrow Flow

From the user side, one spoke handles the full account lifecycle: deposit LP collateral, check borrowing capacity, borrow, repay, and claim fees when allowed. The interface stays consistent even when underlying LP formats differ across DEXs.

## Example Flow

### Step 1: Deposit LP collateral

The user deposits an approved LP position. The liquidity stays in the pool, but the spoke records it as collateral and starts tracking value and health.

### Step 2: Capacity is calculated

The spoke reconstructs the position, prices the underlying exposure, applies collateral factors, and shows the resulting borrowing capacity.

### Step 3: Borrow assets

The user draws assets from Hub liquidity up to their capacity. Debt and health update in the spoke after the borrow confirms.

### Step 4: Add more collateral

Additional approved LP positions can be deposited later. Each position is valued on its own before contributing to aggregate capacity.

## Three-Tier Architecture

### Borrowers

Users interact with the Borrow Spoke to deposit collateral, borrow, repay, and manage their loan.

### Borrow Spoke (Avana)

Values LP positions, enforces health checks, and coordinates liquidation when collateral no longer supports the debt.

### Aave v4 Hub

Shared liquidity and accounting layer. Borrow Spokes draw from Hub reserves after spoke-side checks pass.

## Data Flow

1. **Collateral enters the spoke** — the LP position is recorded and tracked for valuation and health.
2. **Borrow draws Hub liquidity** — once capacity checks pass, the spoke requests assets from the Hub.
3. **Debt accrues as debt shares** — interest compounds through the configured rate model while the spoke keeps account state in sync.
4. **Liquidation if required** — unhealthy accounts move through the liquidation path to restore solvency.

### Hub interaction

- • **Borrow:** spoke draws from the Hub when a user opens or extends debt
- • **Repay:** spoke restores debt to the Hub when a user repays
- • **Health check:** Hub reads spoke collateral data via `getCollateralData`
- • **Liquidation:** Hub can call `handleLiquidation` when risk thresholds are breached

## Spoke Responsibilities

| Component Responsibility |
| Borrow Spoke Tracks LP positions, aggregate collateral value, and debt for each AMM family. Exposes `getUserAggregate(user)` for frontends and liquidators. |
| LiquidationAdapter Runs penalty accrual, soft unwind, and hard liquidation for LP formats that need specialized handling. |

## Aave v4 Hub Role

The Borrow Spoke does not hold lender reserves. The Hub provides pooled liquidity, reserve accounting, and the balance-sheet side of borrowing while the spoke handles LP-specific risk.

### Capital supply

Assets such as USDC, DAI, and ETH enter through the Lend Spoke and Hub. The Borrow Spoke decides how much of that liquidity an LP-backed account may access.

### Credit lines

Each Borrow Spoke has a credit line that limits how much Hub liquidity it can draw, keeping LP underwriting isolated while sharing capital efficiency.

### Independent health factors

Collateral in multiple Borrow Spokes is evaluated separately. Surplus in one market does not automatically cover a deficit in another.

---

## [Architecture — Collateral Factors](http://localhost:3000/developers/architecture/collateral-factors)

_Source: `/developers/architecture/collateral-factors`_

# Collateral Factors

How much of an LP position counts toward borrowing capacity after risk discounts.

## Overview

Collateral factors define what fraction of an LP position's recoverable value can support debt. Avana does not use the LP's headline mark alone. The Borrow Spoke first reconstructs and discounts the position, then applies the market's collateral factor to determine borrowing capacity.

## How It Works

01

The spoke admits only approved pools. Unlisted positions never reach valuation.

02

The position is reconstructed, underlying assets are priced, and the result is discounted to recoverable collateral value.

03

Collateral factors and market settings are applied. The spoke reports aggregate borrowing capacity to the Hub for enforcement.

## Borrowable Value

Borrowable value is calculated per position, not as one flat number for the whole account. Two positions in different pools can produce different recoverable values and clear different collateral factors even if they look similar.

A supported LP position contributes borrowing capacity only after the spoke has admitted it, valued it conservatively, and applied the market's collateral factor.

## Notes

- • Exact collateral factors live in each supported pool's configuration.
- • Different LP families can have different factors, liquidation thresholds, and bonuses.
- • Read this together with Health Factor and Liquidation Framework when building monitoring tools.

---

## [Architecture — Health Factor](http://localhost:3000/developers/architecture/health-factor)

_Source: `/developers/architecture/health-factor`_

# Health Factor

The ratio between risk-adjusted collateral value and outstanding debt inside a Borrow Spoke.

## Overview

Health factor measures the relationship between risk-adjusted collateral value and outstanding debt inside a Borrow Spoke. Adjusted collateral value already includes Avana's LP valuation, collateral factors, pool-level risk treatment, and recoverable-value assumptions.

If health falls below the liquidation boundary, the position becomes eligible for liquidation. See the [Liquidation Framework](http://localhost:3000/developers/liquidation) for what happens next.

## Calculation

Health is computed per Borrow Spoke. The numerator is adjusted collateral value — already discounted through reconstruction, pricing, collateral factors, and recoverable-value assumptions.

`healthFactor = adjustedCollateralValue / outstandingDebt`

If a user has collateral in more than one Borrow Spoke, each spoke computes health independently. Extra margin in one market does not cover a deficit in another.

## Monitoring Bands

**Healthy:** collateral stays comfortably above debt, with room for normal market movement.

**Watchlist:** the account still passes checks, but the buffer is thin. Consider repaying, adding collateral, or reducing exposure.

**Liquidatable:** health has crossed the liquidation threshold. The recovery path can begin.

Interface warnings may appear earlier than the hard liquidation threshold to give users time to act.

## Response Path

When health weakens, the borrower can repay debt, add approved LP collateral, or take other actions that improve the account under the spoke's health checks.

Once health crosses the liquidation boundary, liquidators can unwind the required collateral path to restore solvency according to the market's liquidation rules.

## User Actions

- Borrowing more reduces health because debt rises against the same collateral.
- Repaying debt improves health immediately.
- Adding approved collateral can increase headroom if the spoke accepts and values it.
- Claiming fees, withdrawing collateral, or changing positions can reduce health — check the post-action state first.

See [Collateral Factors](http://localhost:3000/developers/architecture/collateral-factors) for how adjusted collateral value is calculated.

---

## [Architecture — Platform Fees](http://localhost:3000/developers/architecture/platform-fees)

_Source: `/developers/architecture/platform-fees`_

# Platform Fees

Interface-level fees on Avana frontends, separate from protocol borrowing economics.

## Overview

Avana may charge frontend or service fees on official interfaces. Those charges are separate from the protocol's collateral, oracle, and liquidation rules.

Fee rates, exemptions, and rollout status are operational settings. Verify them in the live interface or release materials before relying on them.

## Interface vs Protocol

Core contracts govern LP admission, borrowing capacity, and liquidation. Interface fees, if enabled, sit on top as frontend business policy rather than as a change to the borrow or risk engine.

- Protocol economics determine debt accrual, collateral treatment, and liquidation outcomes
- Interface fees are tied to a specific frontend or service path
- Direct contract integrations may follow different fee assumptions than the official UI

## Disclosure

Any interface fee should be shown clearly before signature so users can distinguish it from gas costs, swap fees, and protocol-level debt or liquidation effects.

## Treasury Usage

If interface fees are collected, they typically fund product operations such as infrastructure, monitoring, security work, and support. Governance may formalize or revise those policies over time.

## Integration Notes

- Verify current fee policy before quoting end-user costs
- Do not hard-code interface-fee assumptions into protocol integrations unless policy is formally versioned
- Keep fee policy separate from borrow capacity and liquidation logic in integration docs

---

## [Architecture — Incentives](http://localhost:3000/developers/architecture/incentives)

_Source: `/developers/architecture/incentives`_

# Incentives Programs

Optional reward campaigns that sit on top of Avana without changing core lending mechanics.

## Overview

Incentives are an overlay, not part of the lending core. The protocol is defined by LP valuation, Borrow Spoke risk controls, Hub liquidity, and liquidation. Campaigns can encourage participation, but they do not change those mechanics.

Campaigns are operational and time limited. This does not imply a specific rewards program is live on every deployment.

## Program Types

- Supplier-facing campaigns that deepen capital in the Lend Spoke or connected liquidity layer
- Borrower-facing campaigns that encourage healthy LP-backed borrowing
- Operator or ecosystem campaigns tied to testing, integrations, or risk-supporting activity

## Distribution Principles

When incentives exist, they should be understandable, auditable, and kept separate from core risk logic. Reward math may depend on activity, duration, or campaign rules, but it should not change how Avana values collateral or decides liquidation eligibility.

## Claiming & Reconciliation

Claim paths, vesting schedules, and reconciliation methods are campaign-specific. They may be handled onchain, through a dedicated rewards controller, or through offchain accounting published by the campaign operator.

Integrators should verify the active claim path and eligibility rules for the deployment they are targeting.

## Current Status

Treat incentives as deployment-specific and season-specific. If a campaign is live, its details should be announced separately with explicit dates, rules, and distribution terms.

---

## [Architecture — Lend Spoke](http://localhost:3000/developers/architecture/lend-spoke)

_Source: `/developers/architecture/lend-spoke`_

# Lend Spoke

How lenders supply assets that fund borrowing against LP collateral.

## Overview

Lenders supply assets such as ETH, BTC, GHO, USDC, USDT, or other supported tokens into the lender-facing side of the protocol. That capital routes through the Hub to support borrowing across LP-collateral markets.

Lenders do not manage LP ranges, impermanent loss, or AMM-specific collateral operations. Borrow Spokes handle LP underwriting and liquidation logic, while lender capital powers the credit layer.

## Capital Entry Point

Lender deposits come through the Lend Spoke first, then move into the shared Hub reserve layer. Capital does not need to be partitioned per LP market, even though borrowing rules stay separate on the spoke side.

### Supply capital

Lenders deposit ETH, BTC, stablecoins, and other supported assets through the Lend Spoke.

### Route through the Hub

Capital moves into the Hub reserve layer, where one pool can support multiple LP-collateral borrow markets.

### Fund Borrow Spokes

Borrow Spokes draw from Hub liquidity while keeping LP valuation and liquidation rules local to each market.

Early in the protocol lifecycle, Hub liquidity may also be supplemented by Aave v4 credit lines. Over time, Lend Spoke deposits can become a larger share of native lending capital.

## Risk-Adjusted Yield

Supplier yield comes from borrowers paying interest to access liquidity backed by LP collateral. Avana combines the shared Hub base rate with spoke-level risk premiums tied to the LP markets being funded.

Rates move with market conditions, available liquidity, utilization, and the risk profile of underlying borrower markets. Actual returns depend on live configuration, not a fixed assumption from documentation.

## Dynamic Risk Controls

LP collateral changes with pool composition, volume, divergence, volatility, and unwind depth. Risk controls can respond to those signals rather than relying on static settings alone.

### Signals that may inform risk updates

- Pool composition and changing inventory balance
- Trading volume and realized fee generation
- Price divergence between paired assets
- Volatility regime shifts and peg stability
- Liquidity depth available during stressed unwinds

---

## [Ask AI](http://localhost:3000/developers/copilot)

_Source: `/developers/copilot`_

# Ask AI

An AI-driven layer that simplifies how people discover, assess, and act on DeFi opportunities on Avana.

## Overview

Avana's Ask AI deploys independent operators to automate a wide range of DeFi tasks from a single, conversational interface. It combines language understanding with real-time data aggregation so users can execute complex operations, track project updates, and analyze market trends without stitching together separate tools.

Ask AI is built to lower the barrier to entry for liquidity provision. It identifies and implements pool strategies while abstracting away wallet selection, chain switching, and LP setup, so more users can reach the earning potential of active LP positions.

## Router Contract

Avana introduces a router contract that standardizes interaction between DeFi applications. It acts as a universal communication layer, much like a USB port for DeFi, giving the AI a consistent way to connect and act across protocols and fostering interoperability across the ecosystem.

See the [Router & Adapters](http://localhost:3000/developers/integrations/router-contract) reference and [Supported Protocols](http://localhost:3000/developers/copilot/protocols) for the adapter interfaces this relies on.

## Core Features

### Conversational interface

Engage with DeFi in natural language. Analyze assets, execute swaps, or track trends with simple commands, and receive real-time context through AI-driven alerts.

### Intelligence hub

Automated summaries and recaps on tracked assets turn raw data, historical patterns, and emerging market narratives into actionable insights you can drill into with a click.

### Multi-DEX integration

The router aggregates liquidity across decentralized exchanges for the best rates, and bridges assets between chains through secure cross-chain messaging.

## Trading Strategies

Ask AI navigates volatile markets with a combination of established indicators and adaptive machine learning.

### Market analysis engine

Uses moving averages, RSI, Bollinger Bands, MACD, and order book depth to identify trends, volatility, and momentum shifts.

### Real-time execution

Scans the market around the clock, executing at machine speed while managing risk with stop-losses and diversification.

### Strategy backtesting

Tests and refines strategies against historical data to optimize risk-reward ratios before any capital is deployed.

## Key Benefits

### 24/7 automation

Round-the-clock trading and market monitoring so opportunities are not missed while you are away.

### Emotion-free decisions

Replaces impulsive reactions with rule-based, AI-driven logic applied consistently.

### Speed and precision

Executes in milliseconds, capitalizing on short-lived opportunities across venues.

### Holistic risk management

Prioritizes capital preservation with dynamic stop-losses and cross-chain diversification.

---

## [Ask AI — Supported Protocols](http://localhost:3000/developers/copilot/protocols)

_Source: `/developers/copilot/protocols`_

# Supported Protocols

The protocols and functions the Avana router supports through standardized adapter interfaces.

## Overview

The router's reach is built on `ILiquidityAdapter` contracts. Each adapter is a standardized interface that bridges the router and Ask AI to a specific DeFi protocol, abstracting away protocol-specific complexity so new integrations can be added without changing the caller.

For developers, this means intricate cross-protocol transactions can be composed with simple, uniform calls. See the [Router & Adapters](http://localhost:3000/developers/integrations/router-contract) reference for the contract-level details.

## Adapter Responsibilities

### Approve protocol usage

Authorize contract interactions for deposits, withdrawals, buys, and sells.

### Claim rewards

Retrieve farming rewards earned within the protocol.

### Withdraw liquidity

Remove liquidity from a source pool.

### Apply fees

Deduct fees for the rollover service, keeping the flow transparent and sustainable.

### Deposit liquidity

Add liquidity tokens to the protocol's farming contract.

### Swap

Execute token swaps within the protocol's ecosystem.

### Event emission

Notify the frontend about critical stages, providing real-time feedback to users.

## Supported Adapters

The adapter set grows over time as new protocols are reviewed and added. The list below reflects the families currently supported through the router.

FE

### Frax Ether Adapter

Staking

Facilitates liquidity migration for Frax Ether (frxETH), a liquid staking derivative for Ethereum.

DepositWithdrawSwapRewardsmETH

### mETH Protocol Adapter

Staking

Handles mETH, a liquid staking token from Meta Pool or similar protocols.

StakeUnstakeRewardsU2

### Uniswap v2 Adapter

DEX

Supports liquidity migration for Uniswap V2 pools.

DepositWithdrawSwapU3

### Uniswap v3 Adapter

DEX

Enables concentrated liquidity management for Uniswap V3 pools.

DepositWithdrawSwapRewardsCRV

### Curve Adapter

DEX

Facilitates liquidity migration for Curve pools, known for stablecoin and pegged asset trading.

DepositWithdrawSwapRewardsAE

### Aerodrome Adapter

DEX

Supports Aerodrome, a fork of Velodrome optimized for Base chain.

DepositWithdrawRewardsBAL

### Balancer Adapter

DEX

Handles liquidity migration for Balancer pools, which support weighted and stable pools.

DepositWithdrawSwapRewardsVL

### Velodrome Adapter

DEX

Facilitates liquidity migration for Velodrome, an Optimism-native AMM.

DepositWithdrawRewardsBNT

### Bancor Adapter

DEX

Supports Bancor's single-sided exposure and impermanent loss protection.

DepositWithdrawRewardsPND

### Pendle Adapter

Yield

Facilitates liquidity migration for Pendle, a protocol for tokenized yield and fixed-rate assets.

DepositWithdrawRewardsCAKE

### PancakeSwap Adapter

DEX

Supports liquidity migration for PancakeSwap, a leading DEX on BNB Chain.

DepositWithdrawSwapRewardsCML

### Camelot Adapter

DEX

Facilitates liquidity migration for Camelot, an Arbitrum-native AMM.

DepositWithdrawRewardsU4

### Uniswap V4 Adapter

DEX

Supports Uniswap V4, which introduces hooks and custom pool logic.

DepositWithdrawSwapRewardsETH.FI

### Ether.fi Adapter

Staking

Handles eETH, a liquid staking token from Ether.fi.

StakeUnstakeRewardsUSDe

### Ethena USDe Adapter

Stablecoin

Facilitates liquidity migration for USDe, a delta-neutral stablecoin.

DepositWithdrawRewardsLDO

### Lido Adapter

Staking

Supports stETH, a liquid staking token from Lido.

StakeUnstakeRewardsAV3

### AAVE V3 Adapter

Lending

Facilitates liquidity migration for AAVE V3 lending pools.

SupplyWithdrawBorrowRepayRPL

### Rocket Pool Adapter

Staking

Handles rETH, a liquid staking token from Rocket Pool.

StakeUnstakeRewardsKELP

### Kelp Adapter

Restaking

Supports Kelp DAO's restaking mechanisms.

StakeUnstakeRewardsMKR

### MakerDAO Adapter

Lending

Facilitates liquidity migration for MakerDAO's DAI and collateral pools.

SupplyWithdrawBorrowRepayRNZ

### Renzo Adapter

Restaking

Handles ezETH, a liquid restaking token from Renzo.

StakeUnstakeRewardsMRPH

### Morpho Blue Adapter

Lending

Facilitates peer-to-peer lending on Morpho Blue.

SupplyWithdrawBorrowRepayCOMP

### Compound V2 Adapter

Lending

Supports liquidity migration for Compound V2 lending pools.

SupplyWithdrawBorrowRepayYFI

### Yearn Finance Adapter

Yield

Facilitates liquidity migration for Yearn Vaults.

DepositWithdrawRewardsFLD

### Fluid Lending Adapter

Lending

Supports Fluid Lending's dynamic interest rate model.

SupplyWithdrawBorrowRepaySWL

### Swell Liquid Restaking Adapter

Restaking

Handles sETH, a liquid restaking token from Swell.

StakeUnstakeRewardsDNR

### Dinero (pxETH) Adapter

Staking

Supports pxETH, a liquid staking token from Dinero.

StakeUnstakeRewardsRSV

### Reserve Protocol Adapter

Stablecoin

Facilitates liquidity migration for RSV, a decentralized stablecoin.

DepositWithdrawRewardsCVX

### Convex Finance Adapter

Yield

Supports CVX and CRV rewards from Convex.

StakeUnstakeRewardsGMX-V

### GMX - GLV Vault Adapter

Yield

Facilitates liquidity migration for GMX's GLV Vault.

StakeUnstakeRewardsGMX-P

### GMX - GM Pool Adapter

DEX

Supports GMX's liquidity pools.

DepositWithdrawRewardsSPK

### Spark Adapter

Lending

Facilitates interaction with the Spark Protocol, a fork of Aave.

SupplyWithdrawBorrowRepayVNS

### Venus Adapter

Lending

Supports the Venus Protocol on BNB Chain.

SupplyWithdrawBorrowRepayEUL

### Euler Adapter

Lending

Enables interaction with the Euler Finance lending protocol.

SupplyWithdrawBorrowRepayMOON

### Moonwell Adapter

Lending

Supports the Moonwell lending and borrowing protocol on Moonbeam and Moonriver.

SupplyWithdrawBorrowRepaySMR

### Sumer.money Adapter

Yield

Facilitates interaction with the Sumer.money yield aggregation platform.

DepositWithdrawRewardsGEAR

### Gearbox Adapter

Leverage

Supports the Gearbox Protocol for leveraged farming and trading.

SupplyWithdrawBorrowLeverageFLX

### Flux Finance Adapter

Lending

Enables interaction with the Flux Finance lending protocol.

SupplyWithdrawBorrowRepaySUSHI

### Sushi Adapter

DEX

Supports the SushiSwap DEX and related features.

DepositWithdrawSwapRewardsiZi

### iZiSwap Adapter

DEX

Supports the iZiSwap DEX.

DepositWithdrawSwapMAV

### Maverick Protocol Adapter

DEX

Enables interaction with the Maverick Protocol, a dynamic AMM.

DepositWithdrawSwapAURA

### Aura Adapter

Yield

Supports Aura Finance, a veBAL maximizer.

StakeUnstakeRewardsBAL2

### Balancer V2 Adapter

DEX

Enables interaction with Balancer V2, a flexible AMM.

DepositWithdrawSwapRewardsELIX

### Elixir Adapter

Liquidity

Supports the Elixir Protocol, focused on liquidity for order book exchanges.

DepositWithdrawSYM

### Symbiotic Adapter

Restaking

Supports the Symbiotic restaking protocol.

StakeUnstakeRewardsDSN

### DeSyn Basis Trading Adapter

Trading

Facilitates basic trading strategies on DeSyn.

TradeHedgeONDO

### Ondo Finance Adapter

RWA

Supports Ondo Finance's tokenized real-world assets.

---

## [Ask AI — Query Example](http://localhost:3000/developers/copilot/query-example)

_Source: `/developers/copilot/query-example`_

# Prompt Examples

Craft precise, actionable prompts so Ask AI executes exactly what you intend.

## Core Principles

### Clarity

Be specific. Instead of “manage my staking,” use:

`@lido (Ethereum): Stake 5 ETH`

### Modularity

Break complex tasks into sequential steps:

`@uniswapV3 (Polygon): Swap 1 ETH for USDC``@curve (Polygon): Provide liquidity with USDC`

### Context

Explicitly define networks, assets, and thresholds:

`@aaveV3 (Arbitrum): Borrow 1000 DAI when borrowing rate < 5%`

## How Prompts Are Read

Ask AI breaks each prompt into three components before it acts.

### Attributes

Protocols, networks, tokens, amounts, and conditions.

### Intent

Swap, stake, borrow, migrate, or lend.

### Execution plan

Step-by-step with safety checks for gas, slippage, and balance.

## Common Mistakes

- Missing network. “@makerdao: Repay DAI loan” fails without a network.
- Ambiguous amounts. “Withdraw some tokens” is rejected.

## Worked Example

A price-conditional trade, from prompt to settlement.

1

### User query

The user enters the request through an interface such as a web app, chatbot, or terminal.

```
> Check the price of ETH and buy 1 ETH if it's below $1,800.
```

2

### Off-chain processing

Ask AI parses the request into a target asset (ETH), a condition (price < $1,800), and an action (buy 1 ETH), then determines it needs real-time price data.

3

### Oracle data fetch

Ask AI triggers an oracle query via middleware, and the oracle returns the current price.

4

### Decision-making

It evaluates the condition: if ETH is below $1,800 it proceeds; otherwise it halts and reports that no trade was executed.

5

### Trade execution

When the condition is met, Ask AI prepares the transaction, signs it securely, and submits it to the network.

6

### On-chain result

The network processes the transaction and the trade settles.

```
> Trade executed. You bought 1 ETH at $1,790.
```

## More Scenarios

### Multi-condition trade

“If ETH < $1,700 and gas < 50 gwei, buy 2 ETH.”

- ETH price ($1,680) < $1,700
- Gas fee (45 gwei) < 50 gwei

```
> Trade executed. You bought 2 ETH at $1,680 with 45 gwei gas.
```

### Whale-activity trigger

“Buy $1,000 of ETH only if whale activity shows large ETH sells in the past hour.”

- Several large ETH sales detected

```
> Trade executed. Purchased 0.595 ETH ($1,000) based on detected whale activity.
```

### Condition not met

“Sell 2 ETH if price is above $2,000, but only if gas is below 30 gwei.”

- Gas fee (25 gwei) < 30 gwei
- ETH price ($1,980) is not above $2,000

```
> No trade executed. ETH is $1,980, below your $2,000 target.
```

### Stop-loss execution

“Sell 3 ETH if the price drops below $1,600 as a stop-loss.”

- Price dropped to $1,590, stop-loss triggered

```
> Stop-loss executed. Sold 3 ETH at $1,590 to mitigate losses.
```

---

## [Ask AI — Agent Workflow](http://localhost:3000/developers/copilot/workflow)

_Source: `/developers/copilot/workflow`_

# Agent Workflow

Ask AI's end-to-end workflow translates intent into secure, optimized results. Here is how a request moves from question to outcome.

01Query Processing

## Conversational intelligence

- Natural language interface. Ask questions like “What is Aave's current borrowing APR?” or issue commands such as “Swap ETH for USDC when gas drops below 10 Gwei.”
- Multi-query support. Handle market analysis, strategy validation, direct execution commands, and portfolio optimization in one request.
- Validation layer. Checks input integrity, user authentication, and compliance before anything proceeds.

02Analysis Engine

## Turning context into actionable insight

- Intent classification. Identifies the goal, such as arbitrage or liquidity migration.
- Parameter extraction. Gathers assets, timeframes, and risk tolerances.
- Risk & strategy validation. Cross-checks the request against historical data and preferences for viability.

Ask AI does not account for personal financial goals. Always validate suggestions against your own risk profile.

03Oracle Integration

## Real-time data, real-world context

#### On-chain metrics

Real-time prices, liquidity depths, large-wallet activity, gas trends, and contract interactions.

#### Market indicators

Volume and momentum analysis, sentiment scores, and volatility indices.

This lets users define compound triggers, such as “initiate ETH staking when APR is above 5%, gas is under 15 Gwei, and sentiment turns positive.”

04Decision Engine

## Risk-aware execution planning

- Risk assessment. Evaluates volatility, liquidity gaps, and slippage modeling.
- Opportunity validation. Assesses profit potential, cost-benefit ratios, and timing.

Time-based

“Unstake assets after 7 days.”

Gas-based

“Claim rewards only if Gwei is under 10.”

Price-based

“Sell 50% if BTC drops below $60K.”

05Trade Execution

## Precision and security in every transaction

Pre-execution checklist. Verifies balances, optimizes gas, and prioritizes the routing path.

Transaction flow. Interacts with the relevant contracts, handles signing and network broadcast, and monitors confirmations in real time.

Supported actions. Executes a wide range of operations across lending, staking, and yield protocols.

06Feedback System

## Continuous improvement and transparency

#### Post-trade analytics

Execution audit with confirmation status, finalized vs. expected price, gas breakdown, and slippage analysis.

#### User reporting

Real-time alerts, performance dashboards, and strategy-tweak suggestions based on evolving conditions.

## From question to outcome

Ask AI goes beyond simple trade execution. It turns unstructured queries into auditable, optimized strategies, with every action backed by real-time data and executed through the router's standardized protocol adapters.

---

## [Integrations](http://localhost:3000/developers/integrations)

_Source: `/developers/integrations`_

# Supported Integrations

Which DEXs Avana can work with and what must be reviewed before support goes live.

## Overview

Avana supports curated LP collateral markets across AMMs such as Uniswap, Balancer, Curve, and Aerodrome as markets are launched. Support is approved pool by approved pool, not automatically granted to every pool on a DEX.

Each supported market needs reliable asset pricing, enough liquidity depth, a defined unwind route, market caps, and collateral settings that match the pool type. See [Allowed LP Pools](http://localhost:3000/developers/integrations/allowed-pools) and [Price Oracles](http://localhost:3000/developers/integrations/price-oracles) for admission and valuation details.

## AppKit

AppKit lets DEXs, wallets, and portfolio apps embed Avana credit inside their existing user flows instead of sending users to a separate lending app.

See the [AppKit guide](http://localhost:3000/developers/integrations/appkit) for partner controls, handoff patterns, and launch notes.

## DEX Families

### Concentrated liquidity DEXs

Uniswap v3-style positions need position-level handling because value depends on current price, active range, and how inventory is split across the position.

### Fungible stable and weighted pools

Curve, Balancer, and similar DEXs expose ERC-20 LP shares whose value can be rebuilt from pool balances, external prices, and conservative unwind assumptions.

### Custom or hook-based designs

Advanced pool architectures need a clear oracle model, safe custody path, and liquidation adapter before they can be supported.

## Enablement Status

Whether a DEX is enabled on a given network is a deployment decision. A DEX family can be supportable in theory but still disabled on a specific deployment until oracle coverage, liquidation routing, and risk parameters are ready.

Check the Avana interface, release notes, or contract registry for what is live on your target deployment.

## Review Requirements

- Conservative position valuation from robust external prices and verifiable state reconstruction
- A dependable unwind path for liquidation, including fee collection and routing into the debt asset
- Pool depth, concentration risk, correlation assumptions, and operational monitoring that fit the risk framework
- Governance and risk review before new DEX or pool family support goes live

---

## [Integrations — Router Contract](http://localhost:3000/developers/integrations/router-contract)

_Source: `/developers/integrations/router-contract`_

# Router Contract

Execution layer for DEX-specific actions, adapter calls, and liquidation routing.

## Overview

The router coordinates DEX-specific mechanics — deposits, withdrawals, fee claims, and unwind steps — so those actions do not have to be scattered across every flow that touches LP collateral.

The router does not decide risk. Collateral factors, health checks, and liquidation eligibility remain in the Borrow Spoke, Hub, oracle stack, and risk framework. See [Borrow Spoke](http://localhost:3000/developers/architecture) and [Liquidation Framework](http://localhost:3000/developers/liquidation).

## Role in System

Different DEXs expose different entry, exit, and fee-collection methods. The router gives Avana one integration layer for those mechanics so builders are not forced to implement each DEX separately in every flow.

## Adapter Model

Each supported DEX family has an adapter that knows how to claim fees, remove liquidity, and expose the actions the protocol needs for that LP format. That keeps DEX-specific behavior isolated instead of leaking into every user-facing code path.

Adapter support only matters when valuation and liquidation support exist for that DEX. A new adapter by itself does not make a pool safe for collateral admission.

## Supported Operations

- Bundle DEX-specific deposit, withdraw, and fee-collection calls into one interface layer
- Coordinate unwind or routing steps needed for liquidation execution
- Support controlled position updates such as range changes when a DEX adapter exists
- Expose a consistent integration surface without deciding collateral factors or health checks

## Deployment Status

Router addresses, adapter registries, and enabled networks are deployment-specific. Verify chain-specific addresses from the published contract registry or release notes.

- Confirm the DEX adapter you rely on is enabled on the target deployment
- Router support does not mean a pool is admitted for collateral

---

## [Integrations — AppKit](http://localhost:3000/developers/integrations/appkit)

_Source: `/developers/integrations/appkit`_

# AppKit

How partners embed Avana LP-backed credit while Avana keeps responsibility for borrowing, risk, and settlement.

## Overview

AppKit is for third-party products that already own the user relationship, such as DEXs, wallets, and portfolio apps where LP positions are already visible. The partner product frames the moment, captures context, and decides where the borrow entry appears. Avana runs the actual loan path.

AppKit is for partners that already own the user relationship — DEXs, wallets, and portfolio apps where LP positions are already visible. The partner controls placement and handoff. Avana runs the actual loan path.

## Integration Model

### Intent capture

AppKit belongs where users already understand their LP positions, portfolio state, or swap context, so the borrow entry appears next to existing intent instead of forcing a brand-new flow.

### Protocol handoff

The partner passes wallet and market context into Avana. The borrow flow can then open with that context already set instead of asking the user to rebuild it by hand.

### Partner economics

Partners may use referral, routing, or integration revenue structures, but they do not become the lender or the risk engine. Avana keeps credit, risk, and settlement.

## Partner Controls

AppKit does not force one presentation model. Partners control the entry points and the amount of surrounding guidance, while leaving protocol decisions inside Avana.

- Where the credit surface appears in the product
- Which user segments see the borrow entry point
- How much education or explanation appears alongside the handoff
- Whether the product uses a full embedded handoff or a lighter context-preserving entry point

## Implementation Notes

The best integrations feel like a continuation of the existing product flow, not a hard jump into an unrelated lending app. These notes are the practical baseline for getting that handoff right.

Place the credit entry near the LP position or portfolio view the user already trusts.

Pass wallet and market context into the borrow flow so the handoff does not feel like a reset.

Leave risk and settlement on Avana. Do not rebuild spoke valuation or liquidation logic in the partner UI.

Decide copy, placement, and launch gating before go live because they shape the integration, not just the polish layer.

## Launch Notes

Launch AppKit as an integration project, not just a link placement. Confirm the user path, review where the entry sits, and make sure the Avana credit path stays clearly separated from the partner shell where responsibility changes.

Also check what happens when the credit surface is hidden, whether deep links into the borrow flow are safe, and how missing wallet, market, or collateral context is handled.

---

## [Integrations — Allowed Pools](http://localhost:3000/developers/integrations/allowed-pools)

_Source: `/developers/integrations/allowed-pools`_

# Allowed LP Pools

Governance-controlled allowlist for the pools and LP families Avana is prepared to accept as collateral.

## Overview

Avana only accepts LP collateral from pools that have been reviewed and approved. The allowlist exists because LP support is not automatic for every pool on a DEX. The protocol needs enough information to price the position, manage liquidation, and bound the risk it is taking on.

Pool approval works alongside [Collateral Factors](http://localhost:3000/developers/architecture/collateral-factors) and [Risk Framework](http://localhost:3000/developers/safety). The allowlist decides whether a pool may enter the system; collateral factors decide how much borrowable value each admitted position can contribute.

## Review Criteria

A pool enters the allowlist only when the protocol can answer the same basic questions every time: can it price the position, can it exit the position, and can it monitor the risk in production.

- Reliable external price coverage for the underlying assets
- Sufficient pool depth and credible unwind paths during liquidation
- Clear admissibility rules for the LP family or spoke template
- Acceptable concentration, volatility, and peg-stability profile
- Operational support for indexing, fee handling, and liquidation routing

## Pool Families

### Stable and correlated pools

Often the easiest to admit when pricing is reliable, peg behavior is understood, and unwind depth remains strong.

### Blue-chip volatile pools

Can be supported, but usually with more conservative collateral factors, liquidity checks, and tougher liquidation assumptions.

### Concentrated liquidity positions

Require position-level valuation and careful handling of active range, one-sided inventory, and fee state.

### Custom or experimental designs

Need explicit oracle, custody, and liquidation support before they can be considered for the allowlist at all.

## Risk Application

Pool approval does not mean a position gets generous credit treatment. After a pool is admitted, each LP position is still valued on its own, discounted according to its risk treatment, and then added to the user's borrowing capacity inside the Borrow Spoke.

That is why pool approval and collateral valuation are tightly linked. A pool can be safe enough to admit while still requiring conservative caps, lower LTVs, or stricter liquidation handling once it is live.

## Integration Notes

Builders should think in terms of approved pool templates and deployment-specific allowlists, not as if every LP on a DEX is automatically supported.

New pool families usually require coordinated work across oracle handling, liquidation routing, risk limits, and monitoring infrastructure before they are safe to enable.

---

## [Integrations — Price Oracles](http://localhost:3000/developers/integrations/price-oracles)

_Source: `/developers/integrations/price-oracles`_

# Price Oracles

How the protocol turns LP position state into credit-relevant collateral values.

## Overview

Avana prices LP collateral by reconstructing the position and valuing the assets inside it. For fungible LPs, the protocol derives value from external asset prices and pool balance reconstruction. For concentrated liquidity, it decomposes the position by liquidity, range, current tick, token exposure, and accrued fees.

The result is discounted into recoverable collateral value. Borrow power is based on what the position can realistically support under the market's risk assumptions, not on an optimistic net asset value.

That distinction between mark value and recoverable value is what keeps the oracle useful for lending instead of just analytics. ERC-20 LPs, NFT LPs, and multi-asset pools can share one high-level interface only because each class goes through its own validation and manipulation-resistance checks before the value reaches the spoke.

### LP collateral value depends on:

- The prices of the underlying assets
- The pool reserves or inventory split
- Fee accrual
- For concentrated liquidity, the current tick relative to the position range
- Whether the position is in-range or mostly one-sided

## Oracle Interface: IOracle

Borrow Spokes need one contract surface even though LP formats differ a lot across DEXs. `IOracle` provides that common shape and keeps principal value, accrued fees, and reserved buffers separate so later risk logic does not have to guess which part of the position it is looking at:

`function getValue(uint256 tokenId, address asset)  
  external view returns (  
    uint256 fullValue,  
    uint256 feeValue,  
    uint256 reserveValue  
  );`fullValueReconstructed value of the principal liquidity before later liquidation stress adjustments are applied.feeValueValue of the fees accrued by the position that can be recognized alongside principal.reserveValueReserved portion held back for oracle, unwind, and protocol risk buffers.

The interface hides DEX-specific plumbing from the spoke. That lets the same caller handle ERC-20 LPs, NFT LPs, and multi-asset pools through one return shape while still leaving room for conservative, collateral-family-specific treatment behind the scenes.

## Multi-Layer Architecture

LP valuation is a staged process rather than a single spot-price read. The oracle path moves through the following steps:

1

### Price underlying assets from external robust oracles

Start from resilient external feeds for the underlying assets so collateral does not inherit the full noise or manipulability of raw pool spot state.

2

### Derive LP value conservatively

Rebuild fungible LP balances or decompose concentrated-liquidity positions from reserves, liquidity, range, and fees using a deterministic path that the spoke can reason about.

3

### Haircut for impermanent loss and liquidation slippage

Discount the reconstructed mark to a recoverable collateral value that assumes stress, slippage, and imperfect exits rather than a clean redemption at theoretical NAV.

4

### Cap exposure by LP family and pool depth

Apply controls based on LP family, pool class, and available depth so thinner or more complex markets do not receive the same borrow limits as deeper and simpler ones.

5

### Liquidate based on recoverable unwind value, not optimistic NAV

Use the value that can reasonably be realized through the unwind path when granting borrow power and deciding liquidation, rather than the best-case mark value.

## DEX-Specific Handling

Different DEXs expose different pieces of state, and the oracle uses those inputs to reconstruct the position and verify pricing. Pool-derived data is not accepted blindly as a direct collateral mark.

| DEX / LP Type Oracle Source Notes |
| Curve Stable/Stable ERC-20 LPs External stablecoin feeds + pool-state checks + TWAP verification External prices anchor the assets while pool balances and fee accrual determine discounted collateral value. |
| Uniswap V2 ERC-20 LPs Chainlink + reserve reconstruction + TWAP verification Standard LP tokens are valued from reconstructed underlying balances, with TWAP used as a manipulation-resistant cross-check. |
| Uniswap V3 NFT LPs Chainlink + position decomposition + tick/TWAP checks The NFT is decomposed by liquidity, active range, and current price, then haircut for recoverable liquidation value. |
| Balancer Multi-Asset LPs Chainlink + weighted inventory reconstruction Multi-token pools use external prices and weighted pool inventory to estimate conservative collateral value. |
| SushiSwap / Aerodrome Chainlink + reserve reconstruction + TWAP verification Pool-derived observations verify reconstructed value and help resist same-transaction abuse in lower-liquidity markets. |
| PancakeSwap Chainlink + block-based TWAP verification External prices remain the anchor while block-based observations validate position state and unwind assumptions. |

## TWAP Computation by DEX

TWAPs are verification inputs. They sit beside external asset prices and deterministic position reconstruction to check whether the pool state being observed is consistent with a credible unwind path. They help reject suspicious or short-lived distortions, but they do not replace the broader oracle model on their own.

### Uniswap V2 & SushiSwap

On-chain cumulative price data over a 1-hour window is used to cross-check the reconstructed reserve picture and reduce sensitivity to flash swaps or other short-lived pool distortions.

### Uniswap V3

Position-aware checks incorporate tick range, liquidity distribution, and accrued fees so the protocol can verify the decomposed token exposure of each NFT LP rather than treating the NFT as a black box.

### Balancer

Weighted token observations are combined with pool weights to validate multi-asset inventory splits before the oracle assigns a conservative collateral value.

### Curve

Stablecoin observations are used mainly to detect stale feeds, reserve drift, and short-term anomalies while external prices remain the primary anchor.

### Trader Joe & Aerodrome

Cumulative price observations over a 30-60 minute window help validate lower-liquidity pool state and resist same-transaction manipulation during collateral checks.

## Safety & Manipulation Prevention

Deviation Thresholds

New loans or liquidations can be paused when pool-derived verification data moves too far away from external reference prices beyond `maxDifference`.

maxPoolPriceDifference

This keeps pool-implied state aligned with underlying token prices and limits instantaneous pool manipulation or same-transaction oracle abuse.

Open Interest Caps

Exposure is capped by LP family, pool depth, and collateral complexity so thinner markets receive tighter borrow limits.

Recovery Haircuts

The oracle discounts theoretical LP value for impermanent loss, unwind slippage, and stressed liquidation assumptions before any borrow power is granted.

Oracle Sentinel

Oracle Sentinel watches feed health and verification inputs and can trigger fallback behavior when data is stale, compromised, or inconsistent with position-state checks.

## Configurable Oracle Parameters

Pool-specific oracle settings are configured per token through `setTokenConfig`. The table below shows the parameters that define how a token and its associated pool should be checked:

| Parameter Description |
| Token Collateral token address |
| AggregatorV3Interface Chainlink feed for underlying token |
| maxFeedAge Maximum acceptable age for Chainlink feed |
| Pool Specific DEX pool (Uniswap V3, Balancer, Curve, etc.) |
| twapSeconds Window for TWAP computation |
| Mode Oracle operational mode (standard/fallback) |
| maxDifference Max allowed deviation between DEX and verification price |
In practice, oracle behavior comes from the combination of external asset pricing, LP reconstruction logic, recoverable-value treatment, and the per-token settings configured through `setTokenConfig`.

---

## [Liquidation Framework](http://localhost:3000/developers/liquidation)

_Source: `/developers/liquidation`_

# Liquidation Design

How liquidation entry, vault seizure, and LP settlement are split across Aave and Avana.

## Overview

Aave is the system that decides when a position can be liquidated, but it does not know how to settle the underlying LP. Avana uses Aave for debt accounting, health checks, and the liquidation entry point, then takes over to resolve the real position that sits behind the vault collateral.

The critical design constraint is that two views of collateral must stay aligned. Aave sees an ERC-20 vault token balance, while Avana tracks the LP position that actually backs that balance. Liquidation remains sound only if seizing the vault representation always leads to the correct LP settlement path.

For the operator-facing sequence, see [Liquidators](http://localhost:3000/developers/liquidation/liquidators). For the execution sequence, see [Liquidation Flow](http://localhost:3000/developers/liquidation/flow).

## Three Layers

### Aave layer

Tracks debt, vault collateral balance, health factor, and the liquidation entry point that authorizes seizure.

### Avana adapter layer

Receives the seized vault collateral, burns the corresponding vault token, and maps the liquidation event back to the LP position that actually backed it.

### Avana settlement layer

Identifies the real LP position, runs the appropriate unwind or sale path, repays debt, pays the liquidator reward, and routes any surplus according to the market rule.

## Core Rules

The main rule is simple but strict: Aave liquidates the ERC-20 vault collateral, and Avana settles the LP position behind that vault collateral. Everything else in the design exists to keep those two steps consistent.

Vault tokens must map to real value

A liquidated vault token amount must always correspond to real LP collateral value, not a synthetic balance that cannot be recovered.

Backing collateral cannot stay outstanding

Once the LP position is settled, the corresponding vault token must be burned so the representation does not outlive the asset it was meant to track.

No unbacked supply

Active vault token supply cannot exist without active LP collateral behind it.

Surplus follows the market rule

Debt gets covered first, then the liquidator reward, then settlement costs, and only then does any remaining value follow the market's surplus rule.

## LP Collateral Complexity

LP-backed positions do not all behave the same way during liquidation. A fungible LP token can often be redeemed or transferred proportionally, while a Uniswap v3 NFT is a single discrete position whose range, fee accrual, and unwind route matter at the position level.

That is why the settlement layer needs to know the collateral family, the exact backing position, and the intended unwind path before it clears the matching vault supply.

## Liquidation Pathways

The settlement path depends on what kind of LP collateral sits behind the vault token.

### Fungible LP collateral

- • Settlement can be proportional to the debt that must be covered, rather than forcing the entire LP balance through liquidation.
- • Avana can redeem or transfer only the amount needed for the liquidation when the market design supports partial recovery.
- • The remaining position can stay active if the account still satisfies the required health checks afterward.

### NFT-backed LP collateral

- • The full position moves into settlement when it is selected for liquidation because the NFT itself is the collateral unit being resolved.
- • The matching vault tokens are burned after Aave seizes the vault collateral and Avana maps that seizure back to the NFT position.
- • Avana can unwind, sell, auction, or transfer the real LP position based on the market rules for that collateral family.
- • Surplus does not automatically go to the liquidator unless the market rule explicitly says so.

## Position State

### ACTIVE

The position is still contributing collateral value, and the outstanding vault tokens remain fully backed by that live LP position.

### LIQUIDATING

The selected collateral is no longer withdrawable by the borrower and is actively moving through the settlement path.

### SETTLED

The LP position has been resolved, and the matching vault tokens must no longer be outstanding.

## Surplus Handling

Settlement value is applied in a fixed order. It first covers debt, then the liquidator reward, then settlement costs. Any value left after those obligations is surplus, and that surplus follows the market rule for the collateral being settled.

If settlement value is not enough to cover the debt and reward, the market needs an explicit bad-debt path. Liquidation documentation should describe that shortfall as a real state to handle, not as something that disappears automatically.

## Operator Model

Liquidations are permissionless once a position crosses the liquidation threshold. Any eligible liquidator can repay the allowed debt amount and trigger the settlement path. LP collateral is harder to unwind than simple token collateral, so Avana also accounts for specialized liquidation coverage.

- Liquidators must track the same risk state and collateral state that the protocol uses.
- Execution must remain atomic from debt repayment through settlement.
- Fee realization, route depth, and residual value should be modeled before optimizing only for speed.
- Partial coverage and full coverage are different cases and should not share the same routing assumptions.

---

## [Liquidation — Liquidators](http://localhost:3000/developers/liquidation/liquidators)

_Source: `/developers/liquidation/liquidators`_

# Liquidators

Who can liquidate unhealthy positions and what execution infrastructure is required.

## Overview

Liquidations are permissionless once a position crosses the liquidation threshold. Any eligible liquidator can repay the allowed debt amount and trigger the settlement path.

LP collateral is harder to unwind than simple token collateral. Liquidators track the same risk state, vault-token mapping, route depth, and unwind assumptions used by the protocol.

## Coverage Model

### Permissionless participation

Any keeper or execution desk can liquidate if it can monitor positions, source execution liquidity, and unwind the LP formats Avana supports.

### DEX-specific handling

Liquidation is not a generic token sale. Operators need DEX-aware logic for fee realization, position removal, routing, and settlement into the debt asset.

### Coverage quality

LP positions are harder to unwind than simple tokens. Operators that model the full route for supported DEXs usually handle stress better than bots that only react to a health trigger.

## Execution Requirements

A liquidator for Avana needs infrastructure to value positions, simulate exits, source capital, and deliver a transaction that completes the unwind path.

- Position monitoring and debt drift tracking
- Simulation for route depth, slippage, and liquidity availability
- Transaction delivery with flashloan or prefunded execution paths
- DEX adapters for the LP families the protocol supports

## Operational Notes

- Track the same risk state the protocol uses, not a separate heuristic.
- Unwind from a clean state transition in one atomic job whenever possible.
- Price fee realization, route depth, and residual value before optimizing for speed alone.
- Treat partial coverage and full coverage as separate cases with separate routing assumptions.

Build DEX-specific unwind, fee realization, and debt repayment as one workflow. Disconnected steps make it easier for a coverable liquidation to fail in execution.

---

## [Liquidation — Flow](http://localhost:3000/developers/liquidation/flow)

_Source: `/developers/liquidation/flow`_

# Liquidation Flow

Runtime sequence for how unhealthy LP-backed positions move from detection through settlement once liquidation starts.

## Overview

Liquidation starts when an account's health factor falls below the liquidation threshold. Aave handles debt accounting and the liquidation entry point against the ERC-20 vault collateral. Avana handles the LP settlement behind that vault token.

Debt is repaid, vault collateral is seized, the matching vault token is burned, the real LP position is settled, and any residual value is returned according to the market rule.

## Related Docs

Liquidation policy lives on the [Liquidation Framework](http://localhost:3000/developers/liquidation) page. This flow assumes the recoverable value model in [Price Oracles](http://localhost:3000/developers/integrations/price-oracles) and position-level aggregation in [Collateral Factors](http://localhost:3000/developers/architecture/collateral-factors).

## Runtime Sequence

1.

### Detect an unhealthy account

Liquidation nodes or external keepers watch the same risk-adjusted collateral values used by the protocol and flag accounts whose debt now exceeds allowed borrowing capacity.

2.

### Source execution liquidity

The liquidator acquires temporary liquidity, commonly through a flashloan-style path, so debt can be repaid without pre-funding the full unwind out of pocket.

3.

### Repay debt and seize the vault collateral

The relevant Borrow Spoke settles debt into the credit layer, takes custody of the vault collateral, and hands the position into LP-specific settlement.

4.

### Burn the vault token and mark the backing position

The adapter burns the seized vault token and marks the real LP position as in settlement so the backing supply cannot remain outstanding against a position that is already being unwound.

5.

### Settle the LP position and close the liquidation

Avana unwinds, sells, auctions, or transfers the real LP position, repays execution liquidity, pays the liquidator reward, and routes any surplus according to the market rule.

## State Transitions

Different LP families are all trying to reach the same end state, but they do not get there through identical exits. Adapter-based handling lets each pool family follow the unwind path that matches its own mechanics.

### ACTIVE to LIQUIDATING

Once Aave permits liquidation, the selected position leaves ACTIVE state and enters LIQUIDATING state. The borrower should no longer be able to withdraw it.

### LIQUIDATING to SETTLED

After the real LP position has been unwound or sold, the backing supply is cleared and the position becomes SETTLED.

### State rule

A vault token cannot remain outstanding after its backing LP position has been removed. If the vault tokens are burned, the LP position must be withdrawn, unwound, or moved into settlement.

## Operator Notes

Liquidation bots should index active positions, refresh debt drift, and price accounts from the same oracle stack used by the protocol rather than from raw AMM spot state alone.

Profitability checks should account for slippage, route depth, flashloan costs, and execution risk. Large or unusual unwinds may benefit from private execution paths to reduce adverse MEV exposure.

Thresholds, rewards, and admission rules come from the architecture and risk docs.

---

## [Liquidation — Examples](http://localhost:3000/developers/liquidation/examples)

_Source: `/developers/liquidation/examples`_

# Liquidation Examples

Worked scenarios that show how one liquidation framework is applied to different LP collateral shapes.

## Overview

These examples show how liquidation plays out across common LP formats under the [Liquidation Framework](http://localhost:3000/developers/liquidation).

In every case the job is the same: use conservative collateral marks, repay debt into the credit layer, unwind the LP through a supported path, and return any residual value left after execution costs and the liquidation reward.

## Fungible LP Example

A borrower has deposited a fungible LP token from an approved stable or weighted pool. Over time, pool composition and oracle inputs move enough that the account no longer has sufficient adjusted collateral value for its debt.

- • The liquidation node detects the shortfall and sources execution liquidity.
- • Debt is repaid and the LP token is redeemed into its underlying assets.
- • Claimable fees are realized if available and helpful to recovery.
- • Underlying assets are routed into the debt asset and the liquidation closes.
- • Any value left after repayment and reward is returned to the borrower.

## Concentrated Liquidity Example

A concentrated-liquidity position drifts toward the edge of its active range. The account may remain healthy for a while, then tip into liquidation once debt outpaces the recoverable value of the current position state.

- • The node values the position from its current range, liquidity, and token split.
- • Once liquidation begins, claimable fees are checked before principal is unwound.
- • Routing adapts to the actual inventory recovered rather than a static token mix.
- • Settlement follows the same pattern: repay execution liquidity, pay reward, return residual value.

## NFT Liquidation

A borrower deposits a Uniswap v3 NFT and later the position becomes underwater. The unwind is handled at the position level, not as a loose token slice, because the NFT represents one specific backing position.

- • Aave seizes the vault token balance tied to the NFT-backed position.
- • Avana burns the vault token and moves the real LP position into settlement.
- • The settlement module unwinds, sells, auctions, or transfers the position.
- • Debt is repaid first, the liquidator reward comes next, and any surplus follows the market rule.
- • The borrower does not keep a clean partial claim on the same NFT after liquidation.

## Multi-Position Account

A borrower may hold several LP positions inside one Borrow Spoke. Capacity is aggregated across those positions, but the unwind still has to happen at the position level once the account turns unhealthy.

- • The spoke reports one aggregate borrowing capacity to the Hub.
- • When the account becomes unhealthy, the liquidation node chooses the unwind path that best restores solvency.
- • One position may be enough to close the shortfall, or several may need to be partially or fully unwound.
- • Order of execution, oracle consistency, and route depth matter next to the mark itself.

## Edge Cases

- The position may be mostly one-sided by the time liquidation starts, especially for concentrated liquidity.
- Pool depth may be sufficient for valuation but still thin enough to require conservative unwind routing.
- Claimable fees can improve recoveries, but they should not be treated as guaranteed until actually realized.
- A borrower may have several positions contributing to one spoke-level borrowing capacity, so liquidation sequencing matters.

## Summary

Fungible LPs, concentrated ranges, NFT positions, and multi-position accounts have different unwind details. The shared goal is to repay debt from recoverable LP value, not optimistic NAV assumptions.

---

## [Safety Mechanisms](http://localhost:3000/developers/safety)

_Source: `/developers/safety`_

# Risk Framework

How Avana proposes, reviews, and executes risk changes across the Hub and LP Collateral Spokes.

## Overview

The Avana Risk Framework defines how parameter changes are proposed, checked, and executed across the Hub and LP Collateral Spokes. It covers the controls used when the protocol adjusts supply and borrow caps, LT/LTV settings, interest-rate inputs, market status, and other parameters that depend on prices, utilization, pool depth, concentration, volatility, peg behavior, circuit breakers, position health, and related state.

LP collateral is not one homogeneous asset class. Stable LPs, correlated-asset LPs, weighted pools, concentrated liquidity, and other AMM designs can each have their own spoke-specific valuation path, liquidation path, and failure mode. The framework exists so those differences are reflected in the update process instead of being hidden behind a single generic risk setting.

Three roles stay separate throughout that process: Avana Risk Initiator, Avana Risk Guardian, and Avana Risk Defender. The party that recommends a routine change is not the same party that independently checks it, and the role that can act during an emergency is intentionally narrower than the routine path.

**Operating rule:** reducing risk should be easier than expanding it.

## Core Principles

### Role Separation

The framework assigns proposing, reviewing, and emergency containment to different actors so one party does not control the full path alone.

### Constrained Execution

Routine risk changes execute only when they remain inside predefined policy bounds and pass validation checks.

### Public Consistency

The update described publicly should be the same update that is actually queued for execution.

### Spoke Awareness

Each LP collateral spoke carries its own listing rules, oracle assumptions, liquidation path, and risk profile.

### Defensive Asymmetry

The process is intentionally biased so reducing risk is faster and simpler than expanding it.

## Roles

### Avana Risk Initiator

The role that prepares and recommends routine risk changes for the Hub and LP Collateral Spokes.

- Publish the rationale and classify the update as defensive or growth-oriented
- Submit routine updates into the timelocked execution path
- Recommend supply caps, borrow caps, LT/LTV, reserve factor, and interest-rate changes inside approved ranges
- Initiate spoke-level de-risking and pool onboarding inside preapproved spoke templates

### Avana Risk Guardian

The independent reviewer with veto authority over queued routine changes.

- Verify that the queued update matches the public disclosure
- Check that the action stays inside approved policy bounds
- Reject updates based on invalid oracle, liquidity, or liquidation assumptions
- Cancel a queued update during the timelock window when it creates obvious spoke-level or hub-level instability

### Avana Risk Defender

The emergency-only role used to contain incidents when the normal timelocked path is too slow.

- Reduce borrow caps or supply caps to defensive levels
- Freeze new borrowing on a spoke or freeze collateral usage for a pool, template, or spoke
- Disable a specific adapter or borrow path when predefined failure conditions are met
- Block new debt origination under emergency conditions without being used for routine optimization or growth actions

## Update Flow

Routine changes follow a fixed path so the protocol can distinguish normal parameter maintenance from emergency containment. The standard sequence is public notice, submission, bound checks, timelock, Guardian review, and execution if the proposal is not vetoed.

1

### Public Notice

The Risk Initiator publishes the intended change, why it is needed, and the scope it is expected to affect.

2

### Submission

The Risk Initiator places the proposed change into the execution path used by the framework.

3

### Validation

Framework checks confirm that the update stays inside predefined constraints and approved policy bounds.

4

### Timelock

If validation passes, the change enters a timelock window instead of executing immediately.

5

### Guardian Review

During timelock, the Risk Guardian reviews the exact queued payload and can cancel it if needed.

6

### Execution

If the change survives review, it executes automatically after the timelock expires.

7

### Emergency Path

If emergency conditions are met, the Risk Defender can use a separate defensive path with narrower authority.

## Parameter Classes

Parameter changes do not all carry the same risk, so the framework groups them by how much authority they should require and how quickly they should be able to move.

### Defensive Changes

These are the fastest routine changes because they reduce protocol exposure.

- Lowering borrow caps
- Lowering supply caps
- Reducing LTV or liquidation threshold
- Freezing borrow or collateral usage
- Tightening spoke settings

### Routine Bounded Changes

These follow the standard Initiator -> Guardian -> timelock route inside approved bounds.

- Modest cap increases
- Modest parameter tuning inside approved ranges
- Adding new pools inside an existing spoke template

### Governance-Level Changes

These are outside the routine framework and require a higher-level decision path.

- Creating a new spoke family
- Enabling a new LP primitive
- Adding a new oracle model
- Enabling a new liquidation adapter
- Materially expanding the risk surface beyond preapproved assumptions

## Public Disclosure

Every routine update should be published before submission in a format that lets developers, users, and reviewers compare the notice with the exact action that is later queued.

### Minimum disclosure standard

- Affected spoke
- Affected pools or templates
- Current parameters
- Proposed parameters
- Reason for the update
- Whether the update is defensive or growth-oriented
- Expected submission timing
- Expected timelock window
- Relevant dependencies or assumptions

Consistent disclosure makes it easier to review a proposal for scope creep, mismatched assumptions, or simple execution mistakes.

## Emergency Actions

Emergency actions are for containment, not routine tuning. They should be used rarely, kept as narrow as possible, and structured so the protocol can return to the standard path once the immediate risk is understood. The Risk Defender should only act when a defined or highly probable failure condition makes the normal timelocked route unsafe.

### Emergency triggers

- Oracle inconsistency
- Liquidation path degradation
- Abnormal pool behavior
- Wrapper dependency failure
- Adapter-level compromise
- Sudden spoke-level instability

### Required post-action disclosure

- The trigger
- The action taken
- The intended duration
- The path back to normal operation

Emergency authority exists only for defined or highly probable failure cases where waiting on the normal timelock path is unsafe. It is not a path for routine growth or optimization.

Recommendation, review, and emergency containment remain separate because LP collateral is a collection of markets with different structures and failure modes, not one interchangeable asset list.

---

## [Safety — Contracts](http://localhost:3000/developers/safety/contracts)

_Source: `/developers/safety/contracts`_

# Contracts & Security

Security reference for the contract surfaces, external dependencies, and review boundaries behind LP-backed lending.

## Overview

Avana lends against LP collateral, so security review has to cover more than whether a contract compiles or transfers balances correctly. It also has to cover how pricing, custody, liquidation, and privileged controls behave when the market is under stress.

Contract review, economic review, and operational review all matter for LP markets. They reinforce each other and should be treated as one security program, not as three unrelated checklists.

## Security Challenges

- • LP value can be path dependent and often needs DEX-specific custody and unwind logic.
- • Oracle misuse or stale pricing can create economic loss even when contracts execute exactly as coded.
- • Governance, parameter control, and emergency response are all part of the attack surface.

## Multi-Layer Security

### Contract review

Core contract surfaces, adapters, and privileged control paths should be reviewed before new LP families or new execution paths are enabled.

### Economic stress testing

Test market shocks, oracle edge cases, and liquidation routing failures, not just unit-level contract behavior.

### External review channels

Formal audits and the [Bug Bounty](http://localhost:3000/developers/safety/bug-bounty) program should both stay active. One does not replace the other.

## Core Contract Surfaces

### Borrow Spoke logic

Handles collateral admission, user accounting, and the spoke-side lifecycle for LP-backed loans.

### Hub integration

Connects spoke-level borrowing capacity to shared credit and liquidity constraints in the Hub layer.

### Oracle and valuation adapters

Translate LP positions into conservative collateral values using external prices, position reconstruction, and recoverable-value assumptions.

### Liquidation execution layer

Coordinates unwind paths, fee realization, routing, and settlement when an unhealthy account must be closed or resized.

## Trust Boundaries

- • Onchain accounting and liquidation settlement should be deterministic once triggered.
- • Oracle sources, DEX adapters, and operational liquidator infrastructure are external dependencies and should be monitored as such.
- • Governance, pause authority, and upgrades are privileged powers that should remain bounded, reviewable, and timelocked wherever possible.

## Audit Readiness

This page does not publish speculative auditor schedules or placeholder milestones. Audit reports, scopes, and remediation notes should be published when they actually exist and can be reviewed in full.

High value audit targets usually include new LP family support, new liquidation paths, new oracle models, and any change that expands privileged control or recoverable value assumptions.

---

## [Safety — Insurance](http://localhost:3000/developers/safety/insurance)

_Source: `/developers/safety/insurance`_

# Insurance Funds

Planned backstop layer for handling residual bad debt after the normal LP liquidation path has already run.

## Overview

Avana's first lines of defense are conservative collateral valuation, bounded exposure, and timely liquidation. A future insurance fund would sit behind those controls and come into view only when liquidation still cannot fully close bad debt.

Insurance funds are a planned protection layer. A live insurance fund may not exist on every deployment today.

## Purpose

An insurance fund would exist to absorb qualifying residual protocol bad debt after the supported liquidation path has already tried to recover value from fees and principal.

## Funding Approach

If activated, the fund could be capitalized through governance-approved treasury allocations, reserve contributions, or a dedicated safety module. The exact funding mix is a risk-governance decision and should be published with the program terms.

## Activation Path

- • Detect a residual shortfall after an allowed liquidation path has completed.
- • Verify that the shortfall fits the fund's approved coverage policy.
- • Execute the recapitalization or deficit-coverage path defined by governance.
- • Publish a post-incident summary describing the trigger, response, and follow-up controls.

## Coverage Boundary

Coverage should stay narrow. The target is qualifying protocol bad debt after liquidation, not a blanket guarantee against user trading losses, impermanent loss, market moves, or every third-party failure in DeFi.

---

## [Safety — Bug Bounty](http://localhost:3000/developers/safety/bug-bounty)

_Source: `/developers/safety/bug-bounty`_

# Bug Bounty

Responsible disclosure scope and economic-impact triage guidance for Avana security research.

## Overview

The Avana Bug Bounty covers responsible disclosure across contracts, risk systems, and supporting infrastructure that can affect user funds or protocol solvency.

Because Avana uses AMM liquidity positions as collateral, scope includes both direct contract bugs and failures where liquidity, pricing, or market state can be turned into bad collateral value or broken liquidations.

**Severity is economic first:** rewards track exploitability and outcomes such as fund loss, insolvency, bad debt, or systemic collateral mispricing, not only how large the code change looks.

## Scope & System Architecture

Scope is split into subsystems so researchers can map a finding to the part of the stack it actually threatens: core lending, LP valuation, governance and admin, or offchain integrations.

### Program A - Core Lending

Covers the primary credit engine where accounting integrity, collateralization, and liquidation execution directly protect user funds.

#### Includes

- Deposit / withdraw flows
- Borrow / repay logic
- Health factor and interest accrual
- Reserve accounting and debt mint / burn
- Liquidation core execution and caps

#### Primary risks

- Theft of user funds
- Reserve insolvency
- Undercollateralized borrowing
- Blocked repayments, withdrawals, or liquidations

### Program B - LP Collateral & Valuation

Covers the Avana-specific valuation system for LP-backed credit, including how LP positions are priced, risk-weighted, and stress-tested under volatile market conditions.

Highest sensitivity

#### Includes

- LP token onboarding logic
- Collateral factor assignment for LP positions
- LP share pricing and oracle integration
- Concentrated liquidity position handling
- Edge cases during imbalance, depegs, low liquidity, or stale oracle states

#### Primary risks

- Overvaluation of LP collateral
- Oracle manipulation enabling bad debt
- Unfair liquidation from underpricing
- Recursive exploit paths against mispriced LP collateral

**Why it matters:** Highest severity ceiling: LP mispricing can create bad debt, insolvency, or unfair liquidations without a classic contract drain.

### Program C - Governance, Admin, and Protocol Infrastructure

Covers privileged control surfaces that can alter parameters, upgrade contracts, pause operations, or redirect protocol-owned assets.

#### Includes

- Governance executor and timelock
- Role management and upgradeability mechanisms
- Pause / guardian roles
- Parameter admin systems
- Treasury, collector, and privileged automation contracts

#### Primary risks

- Unauthorized admin action
- Upgrade hijack
- Parameter corruption
- Governance takeover or treasury loss

### Program D - Offchain / Integration Surfaces

Covers supporting systems whose compromise can influence trusted protocol operations, user interactions, or keeper behavior.

#### Includes

- Indexing or liquidation bots maintained by Avana
- Keeper assumptions and oracle relays
- SDK logic that can induce unsafe interactions
- Hosted APIs used in safety-critical paths
- Frontend issues with direct wallet-risk consequences

#### Primary risks

- Malicious transaction construction
- Compromised liquidation or oracle relay paths
- User fund loss through trusted integrations
- Operational outages that freeze critical actions

Subsystems are triaged separately, but impact is still scored across solvency, user fund safety, liquidation integrity, and related protocol risk.

## Severity Philosophy

Generic vulnerability scores are not the main ranking method here. Findings are judged by credible exploit paths and by the economic outcome they can create.

### Critical

Direct or indirect fund loss, creation of bad debt, protocol insolvency, or systemic manipulation of collateral valuation.

### High

Meaningful but bounded damage, such as incorrect liquidation behavior, partial bypass of risk controls, or contained accounting failures.

### Medium / Low

Limited-impact findings, edge-case inconsistencies, non-critical logic issues, or vulnerabilities without a credible path to major economic harm.

A bug that looks small in code can still be critical if it enables LP overvaluation or bad debt. A technically interesting issue can rank lower if it does not have a credible path to meaningful financial damage.

---

## [Legal & Compliance](http://localhost:3000/developers/legal)

_Source: `/developers/legal`_

# Restricted Territories

This page is maintained to reflect the most current list of Restricted Jurisdictions for the Avana domain.

## Overview

In accordance with our [Terms of Use](http://localhost:3000/terms), access to the Avana website and its associated services is restricted for individuals or entities in certain jurisdictions. This page provides the current list of restricted territories and explains the access restrictions in place.

**Important:** Any attempt to access the Avana platform from a Restricted Jurisdiction will result in immediate redirection to the Terms of Use and a denial of access.

## Access Restrictions

Access to the Avana website and its associated services is restricted for individuals or entities who:

- • **Reside within** any of the Restricted Jurisdictions
- • **Are citizens of** any of the Restricted Jurisdictions
- • **Are physically located within** any of the Restricted Jurisdictions
- • **Are incorporated within** any of the Restricted Jurisdictions
- • **Maintain a registered office within** any of the Restricted Jurisdictions

These restrictions are defined in Avana's [Terms of Use](http://localhost:3000/terms) and are enforced to comply with applicable laws and regulations.

## Current Restricted Jurisdictions

The following jurisdictions are currently restricted from accessing Avana services:

| Jurisdiction Reason |
| Iran OFAC sanctions |
| North Korea OFAC sanctions |
| Russia OFAC sanctions |
| Syria OFAC sanctions |
| Ukraine (Crimea, Donetsk, and Luhansk regions) OFAC sanctions |
| United States of America Pending regulatory clarity |
**Note:** This list may be updated from time to time in response to changes in applicable laws, regulations, or sanctions programs. Users are responsible for ensuring their continued compliance with these restrictions.

## Compliance

As stated in our Terms of Use (Section 1.2), you may not access or use the Services if you are:

- • The subject of any sanctions administered or enforced by the U.S. Department of the Treasury's Office of Foreign Assets Control (OFAC), the U.S. Department of State, or any other governmental authority with jurisdiction
- • Identified on the Denied Persons, Entity, or Unverified Lists of the U.S. Department of Commerce's Bureau of Industry and Security
- • Located, organized, or resident in a country or territory that is, or whose government is, the subject of economic sanctions

Users are solely responsible for ensuring their use of the protocol complies with all applicable laws and regulations in their jurisdiction.

## Related Policies

For complete information about your rights and obligations when using Avana, please review:

[

### Terms of Service

Complete terms and conditions governing your use of Avana services, including eligibility requirements, prohibited activities, and dispute resolution.

](http://localhost:3000/terms)[

### Privacy Policy

Information about how we collect, use, and protect your personal information when you use our services.

](http://localhost:3000/privacy)[

### Legal Disclaimer

Important disclaimers regarding risks, warranties, and liability limitations.

---

## [Legal — Disclaimer](http://localhost:3000/developers/legal/disclaimer)

_Source: `/developers/legal/disclaimer`_

# Legal Disclaimer

Legal notices governing use of the protocol and documentation.

**Important:** Please read this disclaimer carefully before using Avana. By using the protocol, you acknowledge that you have read, understood, and agree to be bound by these terms. For complete terms, please review our [Terms of Service](http://localhost:3000/terms) and [Privacy Policy](http://localhost:3000/privacy).

## Overview

This disclaimer supplements and should be read in conjunction with our full [Terms of Service](http://localhost:3000/terms). The Terms of Service constitute a legally binding agreement between you and Avana concerning your access to and use of the protocol and related services.

**From our homepage:**"Borrowing against LP tokens involves risk, including liquidation if market conditions move against your position. Avana does not custody your funds, rehypothecate LP positions, or alter how your liquidity operates on underlying AMMs. Only borrow amounts you are comfortable maintaining through market volatility."

## General Disclaimer

Avana is an experimental decentralized finance protocol. The protocol is provided "as is" without any representations or warranties of any kind, either express or implied.

As stated in our Terms of Service (Section 2): "The Avana Protocol includes functionality whereby certain open source smart contracts can receive and hold certain digital currency or other crypto assets. There is a risk that the open source software, including any upgrades, may introduce bugs, viruses, Trojan horses, or other vulnerabilities or changes that could result in a partial or complete disruption of the protocol or loss, damage, or destruction of your crypto assets."

Any reliance you place on such information is strictly at your own risk. We will not be liable for any loss or damage arising from the use of this protocol or documentation.

## No Financial Advice

As stated prominently in our Terms of Service: "THE SERVICES INCLUDE, AMONG OTHER THINGS, THE INFORMATIONAL RESOURCES, WHICH MAY PROVIDE INFORMATION RELATED TO AVANA. AVANA IS NOT A BROKER, DEALER, EXCHANGE, INVESTMENT ADVISER, CUSTODIAN OR FINANCIAL SERVICE PROVIDER OF ANY KIND. WE DO NOT HAVE A FIDUCIARY RELATIONSHIP WITH, OR OBLIGATION TO, YOU IN CONNECTION WITH THE SERVICES."

- • This material is for informational purposes only
- • It is not an offer or solicitation to invest in, buy, or sell any interests or shares
- • It is not intended to provide accounting, legal, tax advice, or investment recommendations
- • We are not registered investment advisors or broker-dealers
- • We do not provide personalized financial recommendations
- • Past performance does not guarantee future results
- • You should consult qualified professionals before making financial decisions
- • Cryptocurrency investments are highly volatile and risky

## Risks

Section 8 of our Terms of Service outlines the risks associated with using Avana:

### Experimental Technology

"The Services may incorporate experimental and novel technology and the use of such technology involves a high degree of risk. There are numerous reasons the Services or underlying blockchain networks could fail in an unexpected way, resulting in the total and absolute loss of any crypto assets held in your digital wallet."

### Operational Challenges

"The Services and/or underlying blockchain networks may experience or be the subject of cyber-attacks, unexpected surges in transaction volume, or other operational or technical difficulties or vulnerabilities that may cause interruptions related to your use of the Services."

### Regulatory Uncertainty

"The Services, the Avana Protocol and/or any underlying blockchain networks may not be available or appropriate for use in all jurisdictions and you may be subject to legal and regulatory compliance obligations in connection with your use of the Services in certain jurisdictions."

### LP-Specific Risks

- • Impermanent loss can reduce collateral value
- • Liquidation risk if market conditions move against your position
- • Underlying DEX smart contract risk
- • Concentrated liquidity positions can become worthless out of range

## No Warranties

As stated in Section 9.1 of our Terms of Service:

"THE SERVICES ARE ISSUED ON AN 'AS-IS' AND 'AS AVAILABLE' BASIS AND AVANA DOES NOT MAKE ANY WARRANTIES WITH RESPECT TO SUCH 'AS-IS' AND 'AS AVAILABLE' BASIS OR OTHERWISE IN CONNECTION WITH THE TERMS AND AVANA HEREBY DISCLAIMS ANY AND ALL EXPRESS, IMPLIED OR STATUTORY WARRANTIES AND CONDITIONS, INCLUDING ANY WARRANTIES OR CONDITIONS OF NON-INFRINGEMENT, MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, AVAILABILITY, ERROR-FREE OR UNINTERRUPTED OPERATION."

## Limitation of Liability

As stated in Section 9.2 of our Terms of Service:

"IN NO EVENT SHALL AVANA BE LIABLE TO YOU FOR ANY CONSEQUENTIAL, INDIRECT, INCIDENTAL OR SPECIAL DAMAGES OF ANY TYPE OR NATURE HOWEVER ARISING, INCLUDING, WITHOUT LIMITATION, EXEMPLARY OR PUNITIVE DAMAGES, LOST DATA, LOST PROFITS OR REVENUES OR DIMINUTION IN VALUE, ARISING OUT OF OR RELATING TO THE SERVICES OR YOUR USE OF THE AVANA PROTOCOL."

This limitation applies regardless of the theory of liability (contract, tort, strict liability, or otherwise) and even if we have been advised of the possibility of such damages. Under no circumstances shall Avana's aggregate liability exceed one-hundred U.S. dollars ($100.00).

## Related Policies

For complete legal information, please review the following documents:

[

### Terms of Service

The complete legally binding agreement governing your use of Avana, including eligibility, prohibited activities, intellectual property, dispute resolution, and more.

](http://localhost:3000/terms)[

### Privacy Policy

How we collect, use, and protect your personal information, including data retention, cookies, and your rights under GDPR, CCPA, and other privacy regulations.

](http://localhost:3000/privacy)[

### Restricted Territories

Current list of jurisdictions restricted from accessing Avana services.

](http://localhost:3000/developers/legal)

**Last Updated:** January 2026

This disclaimer may be updated from time to time. Continued use of the protocol constitutes acceptance of any changes. Please refer to our [Terms of Service](http://localhost:3000/terms) for the most current and complete legal terms.
