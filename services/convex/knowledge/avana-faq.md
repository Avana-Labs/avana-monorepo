# Avana FAQ

_Frequently asked questions extracted from the Avana FAQ knowledge base._


---

## General Questions

### What is Avana?

Avana is a lending protocol built for LP collateral. It lets users deposit supported AMM positions, keep those positions active in the underlying pool, and borrow against them through Aave v4 infrastructure.

The core idea is that LP capital does not have to become unusable just because it is inside a pool. Avana turns supported LP positions into collateral that can back credit while the original position continues to support swaps, earn fees, and remain tied to its AMM market.

### What problem does Avana solve?

Liquidity providers often have to remove liquidity before they can borrow against their capital. That means exiting the pool, giving up fee exposure, and interrupting the market position they already built.

Avana solves this by making supported LP positions usable as collateral. The LP stays live, Avana tracks and values the position, and Aave v4 handles the borrow-side accounting through an internal vault collateral token.

### How is Avana different from a standard lending market?

Standard lending markets usually treat collateral as simple token balances: ETH, BTC, stablecoins, or other ERC-20 assets. Avana is built for collateral that changes shape over time. LP positions can contain multiple assets, accrue fees, drift with price movement, become one-sided, or require a specific unwind path.

Because of that, Avana underwrites collateral at the LP market level. Each supported pool or LP family can have its own valuation logic, collateral factors, borrowable assets, liquidation assumptions, and risk limits.

### Which AMMs can Avana support?

Avana supports curated LP collateral markets across AMMs such as Uniswap, Balancer, Curve, and Aerodrome as markets are launched. Support is approved pool by approved pool, not automatically granted to every pool on a venue.

Each supported market has clear requirements: reliable asset pricing, enough liquidity depth, a defined unwind route, market caps, and collateral settings that match the pool type. This is why launch markets stay curated before broader coverage expands.

### Does Avana replace the AMM where my liquidity sits?

No. The AMM still handles swaps, pool state, price movement, and fee generation. Avana adds a collateral and credit layer around supported LP positions.

When you deposit an eligible position into Avana, the protocol tracks the real LP collateral and connects it to borrow-side accounting. The underlying AMM remains the venue where the liquidity position exists and earns fees.


---

## Protocol Architecture

### How does Avana work at a high level?

Avana works in three steps. First, a user deposits a supported LP position into Avana. Second, Avana evaluates the position by reading its underlying assets, pool structure, volatility, correlation, liquidity depth, and liquidation risk. Third, once the position clears the market checks, the user can borrow against its risk-adjusted value.

The LP position remains active in the AMM. Avana manages the collateral record, valuation, and LP-specific risk logic, while Aave v4 handles the borrow-side credit and accounting through the connected Hub-and-Spoke model.

### Why does Avana use Aave v4 Hub-and-Spoke infrastructure?

Avana uses Aave v4 because LP collateral needs shared liquidity and isolated risk logic at the same time. The Hub handles the common monetary layer: reserves, accounting, interest rate models, and global credit coordination.

The Spokes handle LP-specific work: pool collateral registration, position valuation, risk enforcement, and liquidation execution. This lets stable pools, correlated pairs, volatile pairs, and concentrated liquidity markets use the rules they actually need instead of being forced into one generic risk model.

### What is a Borrow Spoke?

A Borrow Spoke is an isolated LP-collateral market. It decides which pools are supported, how each LP position is valued, what collateral factors apply, which assets can be borrowed, and how liquidation works for that market.

Borrow Spokes are separated because LP positions do not all behave the same. A stablecoin LP, a correlated ETH-staked ETH LP, and a volatile governance-token LP need different risk settings, different caps, and sometimes different liquidation routes.

### What are Avana vault tokens?

Vault tokens are internal ERC-20 accounting assets that represent approved LP collateral on the Aave-facing side of the system. For example, a supported LINK/ETH position can map to a vaultLINKETH-style collateral token, while a WETH/USDC position can map to a vaultWETHUSDC-style token.

The vault token is the bridge. Avana keeps track of the real LP position and its value, the Aave Adapter supplies the matching vault token into Aave v4, and Aave uses that token for collateral accounting. The user is not borrowing against an abstract wrapper alone; the vault token remains backed by the tracked LP position behind it.

### What are the main parts of the Avana protocol?

Avana is built around several narrow modules. The LP Position Manager records the real LP position, including owner, pool, pair, fee tier, range, liquidity, current value, accrued fees, and collateral status. The Risk Module approves the pool, assets, depth, range, and market caps before the position backs debt.

The Collateralization Module pulls in pricing, values the position, decides the supported collateral amount, and mints or removes the internal vault token. The Aave Adapter handles the Aave-facing side by supplying vault collateral, withdrawing it, and keeping the Aave integration separate from LP-specific logic.


---

## LP Collateral

### What happens when I deposit LP collateral?

When you deposit a supported LP position, Avana records the position and routes it into the relevant Borrow Spoke. The protocol verifies that the pool is approved, reconstructs the position, checks its risk settings, and calculates the collateral value attached to that market.

Once the position clears those checks, Avana mints the matching internal vault token for borrow-side accounting. Depositing does not automatically borrow assets; it creates borrowing capacity that the account can use while it remains healthy and the market has available liquidity.

### Does my LP position stay active after deposit?

Yes. Supported LP positions stay active while they serve as collateral. The liquidity remains tied to the underlying AMM position, so the pool continues processing swaps and the position continues accruing fees and incentives according to the AMM rules.

Actions that change collateral value are checked by Avana while debt is open. Withdrawing liquidity, claiming fees, changing a range, or modifying the position runs through the Borrow Spoke because those actions affect the value backing the loan.

### Can I claim LP fees while borrowing?

Avana separates principal liquidity from accrued fees in its valuation model. That lets the protocol recognize fee income and release claimable fees while keeping LP principal active as collateral.

Fee claims pass through before-and-after health checks. If removing the fee value leaves the account under its required collateral boundary, Avana blocks the claim until the user repays debt or adds more collateral.

### Are LP fees included in collateral value?

Accrued fees are tracked separately from principal liquidity. Avana’s oracle model distinguishes principal value from fee value, so the protocol understands how much of the position is core liquidity and how much is claimable fee income.

That distinction matters during liquidation. Avana applies accrued fees before principal liquidity when the market route supports it, reducing how much of the core LP position has to be unwound to cover debt.

### When can I withdraw LP collateral?

You can withdraw collateral after debt is fully repaid, or after Avana confirms that the remaining account still passes health checks after the withdrawal. Full repayment is the cleanest withdrawal path because the LP position no longer secures open debt.

Partial collateral changes run through the Borrow Spoke. Avana recalculates the account after removing or modifying the requested LP position, then releases collateral only when the remaining approved collateral still supports the outstanding debt.


---

## Valuation & Oracles

### How does Avana price LP collateral?

Avana prices LP collateral by reconstructing the position and valuing the assets inside it. For fungible LPs, the protocol derives value from external asset prices and pool balance reconstruction. For concentrated liquidity, it decomposes the position by liquidity, range, current tick, token exposure, and accrued fees.

The result is then discounted into recoverable collateral value. Borrow power is based on what the position can realistically support under the market’s risk assumptions, not on an optimistic net asset value.

### How does Avana reduce oracle and pricing risk?

Avana uses a dual-oracle pricing framework for LP collateral. Chainlink price feeds provide the primary reference for the underlying assets, while AMM-derived TWAPs act as an independent verification layer sourced from onchain liquidity.

Borrowing power is granted only when the pricing sources stay within the market’s tolerance band. This reduces exposure to flash-loan manipulation, transient AMM price distortions, stale updates, and bad collateral marks that create unsafe debt.

### What is recoverable value?

Recoverable value is the discounted collateral value Avana uses for borrowing and liquidation decisions. It reflects what the LP position is worth after accounting for its unwind, sale, transfer, or settlement path under stress.

Recoverable value is lower than theoretical LP value when the liquidation route includes slippage, price impact, range movement, volatility, fee handling, or limited route depth. Avana sizes borrowing against recoverable value because that is the value protecting the debt.

### Why are concentrated liquidity positions treated carefully?

Concentrated liquidity positions change exposure quickly as price moves. A position can become mostly one asset, move out of range, stop earning fees, or require settlement at the full NFT-position level.

Avana values concentrated positions by decomposing the actual position state instead of treating the NFT as a static token balance. The market then applies collateral factors, caps, and liquidation assumptions that match the position’s range, inventory, and unwind risk.

### What market data does Avana monitor?

Borrow Spokes monitor the signals that affect LP collateral quality: pool composition, token prices, asset correlation, volatility, liquidity depth, fee accrual, oracle reliability, and unwind cost.

Those signals feed the market’s collateral treatment. Stable and highly correlated pools receive different limits than volatile or thinly traded pairs because their liquidation and slippage profiles are different.


---

## Borrowing Markets

### How does borrowing work on Avana?

Borrowing happens after the Borrow Spoke admits and values your LP collateral. When you request an asset, the spoke checks your remaining capacity, confirms the position stays healthy after the new debt, and draws liquidity from the Hub if the asset is available.

The borrowed asset is sent to the user, and the account records debt through the borrow-side accounting layer. Interest accrues over time, so health can change even if the collateral position itself is unchanged.

### How is borrowing capacity calculated?

Borrowing capacity comes from the risk-adjusted value of approved LP positions inside a Borrow Spoke. Avana reconstructs each position, prices the underlying exposure, applies pool-level risk treatment, and then applies the market’s collateral factor.

The Borrow Spoke reports that capacity to the Hub for enforcement. When a user has multiple approved positions in the same market, Avana aggregates their capacity while still valuing each position under its own pool, range, liquidity, and risk assumptions.

### Why is borrow power lower than my LP value?

Borrow power is lower because Avana uses conservative collateral value, not the full LP mark. LP positions can lose value through price divergence, impermanent loss, range drift, liquidity stress, and liquidation slippage.

The difference between LP value and borrow power is the safety buffer. It protects the market by making sure debt is sized against recoverable collateral value rather than the best-case value shown during normal conditions.

### What assets can I borrow?

Borrowable assets are set per market. Avana borrow markets focus on liquid assets such as major stablecoins, GHO, ETH, BTC, and other assets that fit the market’s liquidity, cap, and risk configuration.

The interface shows the active borrow set for each market. A supported LP collateral type does not automatically unlock every borrow asset; each debt asset is part of the market configuration.

### Can I borrow against multiple LP positions at once?

Yes, when the positions are supported inside the relevant market. Avana can aggregate borrowing power across multiple approved LP positions in the same Borrow Spoke, giving the user one combined credit surface for that market.

Aggregation does not merge risk blindly. Each position still contributes capacity based on its own pool, range, liquidity, fees, and risk treatment, and the total account must remain above the required health threshold.


---

## Supplying & Earning

### How do lenders use Avana?

Lenders supply assets such as ETH, BTC, GHO, USDC, USDT, or other supported assets into the lender-facing side of the protocol. That capital routes through the Hub to support borrowing across LP-collateral markets.

Lenders do not manage LP ranges, impermanent loss, or AMM-specific collateral operations. Borrow Spokes handle LP underwriting and liquidation logic, while lender capital powers the credit layer.

### Where does supplier yield come from?

Supplier yield comes from borrowers paying interest to access liquidity backed by LP collateral. Avana’s model combines the shared Hub base rate with spoke-level risk premiums tied to the LP markets being funded.

This means yield can reflect both normal utilization and the additional demand created by LP-backed borrowing. Rates still move with market conditions, available liquidity, utilization, and the risk profile of the underlying borrower markets.

### Do lenders manage LP collateral themselves?

No. Lenders supply clean capital into supported lending markets. They are not choosing LP ranges, claiming LP fees, or deciding how a specific AMM position is unwound.

That separation is the point of the Lend Spoke. Lender capital supports specialized LP-backed borrower demand while Borrow Spokes keep collateral valuation, health checks, and liquidation handling isolated from the lender workflow.

### What protects lender capital?

Avana protects lender capital through overcollateralized borrowing, conservative LP valuation, dual-oracle checks, market caps, health-factor enforcement, and LP-specific liquidation paths. Each Borrow Spoke prices collateral according to its own pool risks before debt is drawn from Hub liquidity.

The protocol still carries DeFi risk: smart contract risk, oracle risk, liquidation execution risk, and market stress. Avana contains that risk by measuring LP collateral at the market level instead of treating every LP position like a simple token balance.


---

## Health & Liquidation

### What is health factor?

Health factor measures the relationship between risk-adjusted collateral value and outstanding debt inside a Borrow Spoke. The simplified model is adjusted collateral value divided by outstanding debt.

Adjusted collateral value already includes Avana’s LP valuation, collateral factors, pool-level risk treatment, and recoverable-value assumptions. If health falls below the liquidation boundary, the position becomes eligible for liquidation.

### What affects my health factor?

Health factor changes when collateral value changes, debt changes, fees are claimed, collateral is withdrawn, leverage is added, or market parameters update. LP positions can also change because token prices move, pool inventory shifts, fees accrue, or concentrated positions drift in and out of range.

Borrowing more lowers health because debt rises. Repaying debt, adding approved collateral, or reducing exposure improves health because the account has more collateral support relative to debt.

### How does liquidation work on Avana?

Liquidation starts when an account’s health factor falls below the liquidation threshold. Aave handles debt accounting, health checks, and the liquidation entry point against the ERC-20 vault collateral.

Avana handles the LP settlement behind that vault token. The Adapter burns the vault collateral, maps the liquidation back to the real LP position, and the settlement layer follows the market route: unwind, sell, auction, or transfer the backing position. Debt is covered first, then liquidator reward and settlement costs, with surplus handled by the market rule.

### Who can liquidate an unhealthy position?

Liquidations are permissionless once a position crosses the liquidation threshold. Any eligible liquidator can repay the allowed debt amount and trigger the settlement path.

LP collateral is harder to unwind than simple token collateral, so Avana also accounts for specialized liquidation coverage. Liquidators track the same risk state, vault-token mapping, route depth, and unwind assumptions used by the protocol.

### What happens to LP fees during liquidation?

Avana distinguishes accrued fees from principal liquidity. During liquidation, the settlement path applies accrued fees before principal liquidity when the market route supports that sequence.

This reduces how much of the core LP position has to be disturbed. If fee value does not cover enough debt, the settlement layer unwinds or transfers the required LP collateral according to that market’s liquidation path.


---

## Governance Process

### How are new LP pools added?

New LP pools are added through market review and approval. A pool needs reliable underlying asset pricing, sufficient liquidity, clear unwind assumptions, and risk parameters that fit the collateral type.

Avana starts with curated LP markets so valuation and liquidation stay clean. Broader pool coverage can expand over time as oracle support, liquidity depth, and risk data improve.

### Can risk parameters change after launch?

Yes. Risk parameters can change as market conditions change. A pool can become less liquid, more volatile, less correlated, or harder to unwind than it was when first listed.

Parameter updates can affect collateral factors, caps, supported pools, borrowable assets, pauses, liquidation thresholds, and liquidation bonuses. Users with open debt follow these updates because parameter changes affect borrow power and health factor.

### Where can I follow governance discussion?

Most Avana governance updates and market discussion happen through Avana Labs on X at https://twitter.com/avana_labs. That channel covers new pools, market parameters, integrations, safety reviews, and product phases.

Longer proposals, risk notes, and external governance threads are linked from Avana Labs when they are relevant. For large positions, users review the latest Avana Labs updates and the live market parameters before relying on a pool.

### Can interface fees change over time?

Yes. Avana interface and service fees are operational settings for official frontends. They are separate from the core protocol mechanics that govern collateral, debt, oracle checks, and liquidation.

When an interface fee applies, the transaction flow displays it before signature so users can distinguish frontend cost from gas, swap execution, protocol interest, and liquidation economics.


---

## GHO Stablecoin

### Can I borrow GHO through Avana?

GHO is one of Avana’s supported borrow-side assets for markets that include GHO liquidity. When a market offers GHO, users can borrow it against approved LP collateral while the account remains above the required health threshold.

Borrowing GHO works like any other debt asset in Avana: it increases outstanding debt, affects health factor, accrues interest, and is repaid in GHO plus any applicable costs.

### Can GHO be part of LP collateral?

Yes. GHO can be part of LP collateral when the specific GHO pool is approved for an Avana market. The pool is evaluated like other LP markets: asset pricing, liquidity depth, correlation, token composition, caps, and liquidation route all matter.

This means GHO is not treated as a blanket approval for every pair. Avana supports the pool configuration, not just the asset symbol.

### How do I repay GHO debt?

GHO debt is repaid in GHO plus accrued interest and any applicable costs. Once repayment confirms, Avana reduces the account’s outstanding debt and the health factor improves.

After full repayment, collateral restrictions tied to that debt are released according to the market rules, allowing the LP position to be withdrawn or modified when no other debt remains.


---

## Automation Features

### Can automation help manage position risk?

Automation monitors account health and can trigger predefined actions such as repayment, deleveraging, or exposure reduction before liquidation. This matters because LP-backed positions move with both debt accrual and pool-level market changes.

Automation is a risk-management tool, not a guarantee. Execution can still be affected by market moves, liquidity conditions, transaction delays, oracle updates, and route availability.

### Can LP collateral support perps-style exposure?

LP collateral supports approved leverage or perps-style exposure through markets and integrations that route LP-backed credit into controlled strategies. The LP position creates borrowing power, and that credit can be deployed through supported exposure paths instead of used only as a simple wallet borrow.

Availability is defined by the active market configuration: collateral type, market parameters, oracle confidence, liquidity, debt asset, and integration route. The interface shows the supported routes for each market.

### What do users monitor after opening a position?

Users monitor health factor, borrow usage, collateral value, debt growth, LP range status, fee accrual, and liquidation buffer.

Avana surfaces these values in the interface so users can see when a position is healthy, when it needs attention, and when risk is moving closer to liquidation.
