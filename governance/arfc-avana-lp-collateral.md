# [ARFC] Onboard AMM LP Positions as Collateral on Aave V4 via Avana

Governance, New Market
Author: @avana
Created: 2026-11-04 · Updated: 2026-11-10

Related discussions
- [Temp Check] Aave's CDP for Uniswap V4 Positions: https://governance.aave.com/t/temp-check-aave-s-cdp-for-uniswap-v4-positions/21980
- [RFC] Aave's CDP for Uniswap V4 Positions (Uniswap forum): https://gov.uniswap.org/t/rfc-aave-s-cdp-for-uniswap-v4-positions/25568
- Gauntlet: Market Risks of Listing LP Tokens as Collateral: https://governance.aave.com/t/gauntlet-analysis-market-risks-of-listing-lp-tokens-as-collateral/10573

Spec references in parentheses, such as `(spec 3.5, LIQ-017)`, point to Avana's specification in [`spec/`](../spec/README.md). Each ID names one rule a reviewer can check. The current parameter values, and who sets each one, are listed in [Avana parameters](parameters.md).

## At a glance

| | |
|---|---|
| What Avana is | A set of contracts that lets liquidity providers borrow GHO against AMM positions without removing their liquidity from the pool. Avana holds the position, issues a transfer-restricted vault token for it, and lists that token as collateral on a standard, unmodified Aave V4 Spoke owned by the Aave DAO. |
| Launch chains and markets | Ethereum and Base together, one Avana Stable LP Hub on each. Ethereum: Uniswap v3 positions on the CDP Spoke "Uniswap v3 Stable". Base: Aerodrome Slipstream positions on "Aerodrome Slipstream Stable". Stablecoin pools only, such as USDC/USDT and pools containing GHO ([spec 1.1](../spec/01-architecture/01-protocol-overview.md), REQ-CHAIN-001, REQ-ARCH-015). |
| Debt asset | GHO, from a capped Aave DAO credit line on each chain: a proposed 2M GHO on Ethereum to start, and a Base line set in the funding ARFC. Each draw cap stays within its chain's GHO flash liquidity and swap-route depth ([spec 1.5](../spec/01-architecture/05-parameters.md), `creditLine`). |
| Collateral factor | `min(token Collateral Factors) × pool risk factor`, with the pool risk factor capped at 40% (spec 2.1, SPEC-HUB-001; spec 3.8, MKT-010). |
| Liquidation model | Aave's standard `liquidationCall`, always partial, run through Avana's LPVaultSwap, which any address can call once an account's health factor is below 1. The caller funds the debt asset, directly or through Avana's public flash liquidation helper. Only the seized share of the position is unwound and sold, inside one transaction. Proceeds are paid in the debt asset; Avana's fee is 20% of the oracle gain. Avana's keeper is the committed operator on each chain at launch ([spec 3.5](../spec/03-operations/05-liquidation.md)). |
| Loss coverage | One Avana Umbrella (Coverage Spoke) per (Hub, debt asset), Avana's protocol safety module, funded by Avana Labs and controlled by the Aave DAO. Its coverage ratio and minimum size are set in the funding ARFC with Aave's service providers ([spec 3.9](../spec/03-operations/09-deficit-coverage.md), DEF-019). |
| Governance | The Aave DAO owns and configures every Avana Hub and Spoke. Every change to Avana's own contracts goes through a per-chain timelock (5-day delay, 12 hours for risk-reducing changes) that the Aave governance executor can propose to and cancel ([spec 2.15](../spec/02-contracts/15-governance-and-timelock.md), REQ-ARCH-154). |
| Verification status | Specification, contract interfaces and formal models complete; interfaces compile. Z3, SymPy, Hypothesis and Quint suites, three internal formal-verification areas, a 1,000-user simulation and an adversarial design review all check the specification. Contract implementations and independent audits come next. |

## Summary
This ARFC seeks community approval and feedback on Avana's proposed implementation for onboarding AMM liquidity positions as collateral on Aave V4.

Aave has $30B in deposits but only $12B in active loans. At the same time, billions of dollars in AMM liquidity generate trading fees, yet options for borrowing against these positions remain limited. Avana would enable liquidity providers to borrow GHO against their positions while keeping their liquidity in the underlying pools, expanding GHO usage. We estimate the addressable AMM LP collateral TVL across Ethereum, Avalanche, Arbitrum and Base could reach $8 billion by 2028.

To borrow, a user pledges an LP position to Avana's LP Vault, which holds the position. Avana's AaveAdapter then mints a transfer-restricted, collateral-only ERC-20 vault token, one base unit per unit of the position's liquidity, to the user's Position Proxy for that market and supplies it to an Avana CDP Spoke, a standard Aave V4 Spoke. The user then borrows GHO from the Avana Hub through that Spoke (spec 2.4, REQ-VTOKEN-006; spec 1.1, REQ-ARCH-152).

Avana's LPOracle determines the LP collateral's value using the pool's liquidity math and Chainlink prices, with the pool's TWAP as a consistency check and an independent second price source required before any borrow (spec 2.10, REQ-ORACLE-100). Borrowing limits are then set by each reserve's Collateral Factor, which takes the lowest Collateral Factor among the pool's tokens as its starting point and applies an additional adjustment for pool-specific risks (spec 2.7, SPEC-CF-001). This separates collateral valuation from risk limits, so each LP market is assessed according to its own risk profile.

Borrowers can continue collecting trading fees while their LP positions are used as collateral. If a position becomes eligible for liquidation, a liquidator funds the debt asset, usually with a flash loan through Avana's public helper, and Avana's LPVaultSwap repays part of the debt through Aave's standard liquidation and unwinds and sells only the seized share of the position, all in one atomic transaction. Every liquidation is partial: the borrower keeps the rest of the position and all of its accrued fees.

## What This ARFC Asks
This ARFC asks the community for two things.

1. Support for a technical and risk assessment of Avana with Aave DAO service providers on Ethereum and Base, covering custody, valuation, liquidation, Aave V4 integration, governance roles, loss allocation and economic terms.
2. Support for preparing a capped GHO credit line request to the Avana Hubs. The request would propose an initial credit line of 2M GHO on Ethereum and a Base GHO line whose size the funding ARFC sets, within the GHO flash liquidity of the Aave V3 Base Pool and the depth of the Base swap routes. Capacity would scale toward 10M GHO only as live performance criteria are met.

If this ARFC passes, the follow-up ARFCs (see Next Steps) would ask the Aave DAO to:
- list each CDP Spoke as a standard Aave V4 Spoke and set three values on every Avana collateral reserve: `receiveSharesEnabled = false`, `liquidationFee = 0` and no reinvestment controller, with the vault-token reserve non-borrowable and its draw cap 0 (spec 2.1, REQ-HUB-003, REQ-HUB-092, REQ-HUB-094). For each CDP Spoke's liquidation settings, Avana recommends a target health factor of 1.10 and a minimum liquidation bonus of at least 2%; the Aave DAO decides both in the listing AIP;
- grant Avana's public flash liquidation helper and Avana's flash source (used for repay with collateral) the `FLASH_BORROWER` role on the Aave V3 Pool on Ethereum and on Base, so their flash loans carry no premium (spec 2.1, REQ-HUB-044);
- set a GHO credit line and draw caps per chain, each draw cap within that chain's flash liquidity and route depth (spec 2.1, SPEC-HUB-003), and register an Avana Umbrella (Coverage Spoke) for GHO on each chain's Stable LP Hub, with the coverage ratio and first-loss reserve minimum agreed with Aave's service providers (spec 3.9, DEF-016, DEF-019).

Avana's specification, contract interfaces and formal models are complete. The specification defines every contract, flow and parameter, its formulas are checked with formal models, and the contract interfaces compile cleanly. The contract implementations are written against that specification next, and every contract will be independently audited before deployment (spec 1.1, REQ-ARCH-025). Mainnet launch follows the independent audits and governance approval.

You can try Avana today. The public sandbox runs the borrow and liquidation flows with simulated assets and makes no onchain transactions.
- Learn more: https://avana.cc
- Try the Sandbox: https://app.avana.cc
- Follow on X: @avana_labs

## Motivation
AMM liquidity represents one of the largest sources of productive capital in DeFi. Yet liquidity providers who want to borrow against their positions often have to withdraw their liquidity, sacrificing trading fees and, for concentrated liquidity positions, their carefully selected price ranges. LP-backed lending remains one of DeFi's most underserved markets. The concept itself is not new: Aave was among the first major lending protocols to recognize the potential of LP tokens as collateral.

In 2020, Aave V1's Uniswap Market accepted Uniswap v1 LP tokens. From March 2021, the AMM Market accepted Uniswap v2 and Balancer LP tokens, and Proposal 51 added Gelato's G-UNI wrappers for Uniswap v3 positions in December 2021.

In 2025, Aave Labs proposed GHO borrowing against Uniswap v4 positions. On the Uniswap forum, it asked the Uniswap DAO for a $3.3M development grant over 18 months, plus 1.2M UNI released in tranches as borrowing reached $50M, $100M, $300M and $500M. The proposal did not advance past the RFC and Temp Check stage.

All previous attempts were built before the infrastructure caught up. Aave V4 changes that. The Hub-and-Spoke architecture allows LP collateral markets to operate with their own risk parameters, collateral requirements and exposure caps, while keeping their risks isolated from Aave's core markets. AMMs have also matured, oracle and liquidation infrastructure has improved, and years of market data now give a stronger foundation for evaluating LP collateral.

Fluid, developed by Instadapp, combines AMM liquidity and borrowing through its integrated DEX and lending architecture, with TVL above $3 billion by October 2026. Avana takes a different route. Rather than building another lending protocol or asking LPs to move their liquidity to a new AMM, Avana connects liquidity already deployed across established AMMs to Aave V4, so LPs in approved pools can borrow GHO against their existing positions.

That is the opportunity we see for GHO: long-term growth supported by real borrowing demand.

## Architecture

### Design Overview
Avana's integration keeps every Aave V4 contract unmodified and places custody, valuation and liquidation in Avana's own contracts (spec 1.1, REQ-ARCH-024; spec 2.1, REQ-HUB-095). It follows the pattern of transfer-restricted accounting tokens, per-user position proxies and dedicated liquidation contracts already reviewed for Aave V4 integrations.

Aave V4 accepts collateral through ERC-20 reserves. Each Spoke reserve references an asset on the Hub, and supplying it transfers that token into the Hub. Because most AMM positions are NFTs, Avana separates custody from collateral accounting: the LP Vault holds the position, while transfer-restricted vault tokens represent its liquidity on Aave V4.

The Risk Module checks position eligibility, and LPOracle prices the vault tokens. The Collateralization ledger records the liquidity credited from each position, and the AaveAdapter mints the matching vault tokens to the borrower's Position Proxy, supplies them to the CDP Spoke and enables them as collateral. LPVaultSwap handles liquidation settlement.

Each wallet gets one Position Proxy per (CDP Spoke, market). The proxy is a logic-free, immutable Aave account bound to that wallet, Spoke and market, and it executes only calls from Avana's AaveAdapter; all account logic lives in the Adapter (spec 1.1, REQ-ARCH-152, REQ-ARCH-208; [spec 2.5](../spec/02-contracts/05-position-proxy-and-proxy-manager.md), REQ-PROXY-001, REQ-PROXY-002). Because each market has its own proxy, each market has its own health factor and nothing is cross-collateralized. Every liquidation runs through LPVaultSwap and Aave's standard `liquidationCall`; the proxy has no settlement authority.

### Hubs and CDP Spokes
Avana builds on Aave V4's modular Hub-and-Spoke architecture to form a network of specialized lending markets for AMM liquidity. The Avana Hubs connect multiple Collateralized Debt Position (CDP) Spokes to shared borrowing liquidity, so each Spoke can support different LP collateral structures with dedicated risk parameters, exposure caps and liquidation mechanisms.

Each CDP Spoke is one standard Aave V4 Spoke per (chain, Hub, AMM protocol, risk tier), for example "Uniswap v3 Stable" on Ethereum, and lists several markets. A market is one pool with one exact position range, and each market is one collateral reserve of its Spoke (spec 1.1, REQ-ARCH-207, REQ-ARCH-016).

Liquidity is organized into three Hubs, because stable, correlated and volatile LPs carry different risks:
- **Stable LP Hub** (low risk): established stablecoin and blue-chip pools built for tight pricing, low slippage and minimal impermanent loss.
- **Correlated LP Hub** (high yield): blue-chip LP strategies for assets that move together, with tighter risk bands and cleaner borrowing power.
- **Volatile LP Hub** (high risk): major DeFi assets and emerging markets, such as governance-token pools, with wider price ranges under stricter exposure limits.

At launch, Ethereum and Base each have one Stable LP Hub. Correlated LP and Volatile LP Hubs can be added on any chain later (spec 2.1, REQ-HUB-002).

Each Hub connects to its own set of CDP Spokes. Each credit line is a draw cap per (Hub, asset, Spoke), so the Aave DAO decides how much each Spoke can draw (spec 2.1, SPEC-HUB-003).

Avana Hubs and Spokes are standard, unmodified Aave V4 contracts, owned and configured by the Aave DAO. Avana's external contracts handle LP custody, valuation and collateral representation. The design uses transfer-restricted ERC-20 vault tokens, one Position Proxy per wallet and market, one AaveAdapter per chain for borrower actions, and LPVaultSwap for liquidation.

Each CDP Spoke is the standard Spoke with its 5-argument `liquidationCall`. The listing payload sets three values on every Avana collateral reserve: `receiveSharesEnabled = false`, `liquidationFee = 0` and no reinvestment controller. Avana's on-chain drift check stops new borrowing in any market where one of them changes. Together with the vault token's transfer rule, these settings make LPVaultSwap the only contract that can complete a liquidation ([spec 2.1](../spec/02-contracts/01-avana-hub-and-spokes.md), REQ-HUB-092; spec 3.5, LIQ-064).

### Initial Scope
Avana launches on Ethereum and Base together, with an Avana Stable LP Hub on each: Uniswap v3 positions on Ethereum through the CDP Spoke "Uniswap v3 Stable", and Aerodrome Slipstream positions on Base through "Aerodrome Slipstream Stable". Launch pools are stablecoin pools that meet the listing rules, including USDC/USDT and pools containing GHO. Each market fixes one exact tick range, and a position must match it exactly; Slipstream positions must be unstaked ([spec 2.21](../spec/02-contracts/21-aerodrome-slipstream-integration.md), REQ-AMM-SLIP-009). Each candidate pool needs sufficient liquidity history, Chainlink price routes for each token, an independent second price source, and a primary and a backup swap route into each debt asset that never trade through the pool itself. Fee-on-transfer, rebasing and hook tokens are excluded (spec 1.1, REQ-ARCH-012 to REQ-ARCH-015). The core design also supports Uniswap v2, Curve, Balancer and Uniswap v4, but each needs its own integration, fork tests and gas measurements before its first listing, plus risk review and governance approval ([spec 2.22](../spec/02-contracts/22-amm-integration-readiness.md)). Each further chain comes through its own ARFC.

Together, the Hub-and-CDP-Spoke architecture makes Avana an extensible lending platform rather than a single LP collateral market. Each new Spoke expands the range of supported AMM positions, and additional Hubs let Avana establish distinct credit markets with their own liquidity and risk profiles.

## GHO Opportunity

### DAO Revenue
All interest attributable to Aave DAO-funded GHO credit lines would accrue to the Aave DAO. This differs from Aave Labs' 2025 Uniswap proposal, which initially proposed a 50/50 revenue split between the two DAOs. The Avana Hub's GHO rate would be flat, independent of utilization, and set by the Aave DAO at or above the Core Hub's GHO base rate, with each borrower's risk premium added (spec 2.1, SPEC-HUB-007). Avana Labs would earn an app fee charged outside the contracts and 20% of the oracle gain on each liquidation, described under Liquidation Design. Avana charges no fee on borrow interest, and no interest-fee parameter exists (spec 1.5, `avanaFeeShareBps`).

Initial borrowing would be funded through a capped GHO credit line on each chain, supplied by the Aave DAO to that chain's Avana Stable LP Hub through a supply-only Lend Spoke. Only Avana's CDP Spokes have GHO draw caps, and they sum to at most the credit line. Each draw cap also stays within the GHO flash liquidity of that chain's Aave V3 Pool, so every borrowed amount can be liquidated in one transaction. Borrower repayments return GHO to the Hub (spec 2.1, SPEC-HUB-003).

| Phase | Proposed capacity | Conditions for expansion |
|---|---|---|
| Launch | Proposed 2M GHO on Ethereum; Base line set in the funding ARFC, within the Base Pool's GHO flash liquidity | Audit and launch requirements satisfied, with observed oracle availability, borrowing activity and liquidation-route performance reported to governance |
| Initial target | Up to 10M GHO | Demonstrated borrowing demand, acceptable concentration and execution costs, and a recommendation from the designated risk reviewers |
| Expansion | 50M GHO or more | Continued operation within approved limits, satisfactory risk reporting and further governance approval |

The funding proposal will define the measurement periods and thresholds for these conditions, the authority to adjust capacity, repayment terms and interest allocation. At every phase, each chain's draw caps stay within its flash liquidity, and the funded first-loss reserve in the Avana Umbrella must satisfy `fundedBalance × 10⁴ ≥ coverageRatioBps × Σ drawCap` (spec 3.9, DEF-019). The funding ARFC sets `coverageRatioBps` and the reserve minimum with Aave's service providers. As an illustrative guide only, a 20% ratio would require one GHO of funded reserve for every five GHO of draw caps.

### Revenue Scenarios
The table below shows annual gross borrower interest at constant all-in rates of 4.5% and 9%. It assumes borrowing stays constant through the year, GHO is valued at $1, and outstanding debt equals 25% of deposited LP collateral value. That borrowing ratio is a scenario assumption, not a proposed Collateral Factor. It sits below the 28.4% opening loan-to-value that the 40% pool-risk-factor ceiling allows for two tokens with 78% Collateral Factors (spec 3.8, MKT-010).

| Outstanding borrowing | LP collateral at a 25% borrowing ratio | Annual interest at 4.5% | Annual interest at 9% |
|---|---|---|---|
| 2M GHO | $8M | $90,000 | $180,000 |
| 10M GHO | $40M | $450,000 | $900,000 |
| 50M GHO | $200M | $2.25M | $4.5M |
| 100M GHO | $400M | $4.5M | $9M |
| 300M GHO | $1.2B | $13.5M | $27M |
| 500M GHO | $2B | $22.5M | $45M |

At the scale Aave Labs projected in 2025 ($500M borrowed), the same arithmetic gives $22.5M–$45M a year. All of this interest accrues to the Aave DAO; Avana's revenue comes from its app fee and its share of liquidation gains.

## Specification

### LP Vault and Vault Tokens
Each AMM protocol has one immutable LP Vault per chain that holds the pledged positions, and Avana's Collateralization ledger records each position's depositor, market and credited liquidity. Each market has its own vault token, one per (CDP Spoke, pool, exact range), with decimals fixed at listing between 6 and 18 so that one whole token is worth at least $1 at listing prices ([spec 2.4](../spec/02-contracts/04-vault-tokens.md), SPEC-UNIT-001, REQ-VTOKEN-004).

One vault-token base unit represents one unit of the position's liquidity on Uniswap v3 and Aerodrome Slipstream. Collateralization calculates the amount, and the AaveAdapter mints it, only to the borrower's registered Position Proxy and independently of oracle prices (spec 2.4, REQ-VTOKEN-006, REQ-VTOKEN-014). Withdrawals and liquidations burn the tokens matching the collateral removed. These operations preserve the backing of existing vault tokens.

Vault tokens have no owner, admin or emissions. A vault token moves on three paths only: from a Position Proxy into the Hub when supplied, from the Hub back to that proxy on withdrawal, after which the AaveAdapter burns it, and from the Hub to LPVaultSwap on seizure. Every other transfer fails, and the Adapter never holds vault tokens (spec 2.4, REQ-VTOKEN-006, REQ-VTOKEN-008). They are collateral-only: the reserve is non-borrowable with a zero draw cap, the token is listed on no other Spoke, and `receiveSharesEnabled` is false (spec 2.1, REQ-HUB-094). For each market, Avana's Lens will report vault-token supply alongside the liquidity held in the LP Vault, so anyone can check that every outstanding vault token is backed 1:1 ([spec 2.17](../spec/02-contracts/17-lens.md), REQ-LENS-012). Borrowers in the same market still share exposure to its oracle, contracts and pool liquidity.

### Oracle and Pricing
LPOracle reports the value of the liquidity each vault token represents, with no haircut. Each token has a Chainlink primary route, an alternate Chainlink route with automatic failover, and a standby route approved at listing. A feed counts as fresh for its own heartbeat plus 1,800 seconds, and stablecoins are never valued above $1 (spec 1.1, REQ-ARCH-013, REQ-ARCH-188; spec 1.5, `heartbeatMargin`, `stableCeilingUsd`).

The price is the fair composition at the oracle prices: the token amounts the position would hold if the pool traded at the Chainlink prices, valued at those prices, for any number of tokens:

`VaultTokenPrice = Σᵢ qᵢ × Pᵢ`

Here qᵢ is the amount of token i that one vault token represents at the oracle prices, and Pᵢ is its Chainlink price. Because the amounts come from oracle prices, a trade in the pool cannot move the valuation (spec 2.4, SPEC-UNIT-003).

A 30-minute TWAP of the pool acts as a consistency check: it does not set the price, it decides whether the market may keep granting borrowing power. Borrowing, and any withdrawal that leaves debt, also requires each token's price to agree with an independent second source, such as a TWAP of another deep pool or a second oracle network. A guardian can switch a token to its standby second source at once. On Base, every price also reads the sequencer-uptime feed ([spec 2.10](../spec/02-contracts/10-lp-oracle.md), REQ-ORACLE-099, REQ-ORACLE-100; spec 1.5, `twapWindow`).

| Price condition | Market response |
|---|---|
| Live, second source agrees | Normal operation. |
| Live, second source disagrees or is unavailable | Borrowing and withdrawals that leave debt are blocked. Pledges, repayment and liquidation continue. |
| Drifting: TWAP consistency check fails | New pledges, borrowing and withdrawals that leave debt are blocked. Aave values the collateral at the lower of the fresh and last accepted price. Liquidation continues while the Chainlink inputs are fresh. |
| Drifting: primary and alternate Chainlink routes disagree | Borrowing is blocked and the collateral is valued at the lower route. Liquidation of this market waits until the routes agree, a guardian switches the faulty route to its standby, or a timelock fix executes. |
| Cached: both routes of a token stale or invalid, for up to 1 hour | Pledges, top-ups and borrowing are blocked. Aave values the collateral at the last accepted price. Liquidation of this market waits for a fresh price or a standby switch. |
| Expired: after 1 hour | The collateral counts as worthless in Aave's health factor. Liquidation of this market waits for a fresh price or the guardian's standby switch, so collateral is never seized at a price Avana cannot trust. |
| First 30 minutes after recovery from Expired | Only accounts below a health factor of 0.95 can be liquidated. |
| Base sequencer down, or within 1 hour of its restart | Borrowing is blocked. Liquidation pauses while the sequencer is down; for 1 hour after restart only accounts below a health factor of 0.95 can be liquidated. Price states do not change. |

In every row, repayment, fee collection and debt-free withdrawal stay open (spec 2.10, State effects; spec 3.5, LIQ-006, LIQ-007, LIQ-086; spec 1.5, `cachedWindow`, `graceDuration`, `graceHealthFactor`, `sequencer.gracePeriod`).

No pause, circuit breaker or freeze ever stops liquidation; only the price check of the market being seized does (spec 3.5, LIQ-002). A guardian ends a feed outage by switching to the standby route reviewed at listing, and the Aave governance executor can undo that switch at once (spec 2.15, REQ-ACCESS-159). To contain one market, the Aave Protocol Guardian can freeze its vault-token reserve and Avana's guardians can trip its circuit breaker; both stop new borrowing in that market only and leave repayment, withdrawal and liquidation open ([spec 3.6](../spec/03-operations/06-emergency-operations.md), EMG-009; spec 1.1, REQ-ARCH-181). Service providers will review the thresholds at each listing.

### Collateral and Health Factors
Valuation and borrowing limits are calculated separately. The reserve's Collateral Factor determines how much of a position's value can support debt. Aave V4 uses one Collateral Factor for both borrowing and liquidation, and calculates health per account. In Avana an account is one Position Proxy holding one market, so each market has its own health factor. Avana starts from the lowest Aave V4 Core Hub Collateral Factor among the pool's tokens and reduces it with a pool risk factor, rounding down:

`LP Collateral Factor = min(CF₁, …, CFₙ) × Pool Risk Factor`

`Borrowing Capacity = LP Position Value × LP Collateral Factor`

A GHO leg uses an explicit factor set at listing. The pool risk factor is at most 40%. The Aave DAO sets the reserve's factor at or below this value, and Avana's drift check stops new borrowing if it is set higher (spec 2.1, SPEC-HUB-001; spec 2.7, SPEC-CF-001, REQ-RISK-069).

The pool risk factor is applied once. It reflects the position's range, price sensitivity, pool depth and expected liquidation costs. Avana draws on Gauntlet's analysis of LP collateral, which recommends conservative starting factors; when the borrowed asset is not one of the pool's own tokens, such as GHO borrowed against WETH/USDC, it suggests starting as low as 0.25× the lower underlying factor. Final factors will be calibrated per market with service providers. An account's borrowing capacity also depends on its existing debt, exposure caps, available GHO liquidity and oracle checks.

Illustrative example. These figures are not proposed launch parameters. They assume GHO, USDC and USDT hold at $1, and use the Collateral Factor example of SPEC-HUB-001.

| Item | Illustrative result |
|---|---|
| USDC/USDT position value (exact range) | $100,000 |
| Vault tokens supplied | One base unit per unit of the position's liquidity, valued at $100,000 |
| Lower token Collateral Factor × pool risk factor | 75.00% × 37.50% = 28.12% (rounded down) |
| Collateral-based borrowing capacity | 28,120 GHO |
| Recommended borrow shown by the Lens, at health factor 1.10 | About 25,560 GHO |
| Actual borrowing and initial health factor | 20,000 GHO at 1.41 |
| Collateral value at health factor 1.00, debt unchanged | About $71,120 |

In this example, collateral value would need to fall about 29% to reach a health factor of 1, which for a stablecoin position takes a deep depeg of one token. Accrued interest and stablecoin price moves change that result. Aave's own rule is the only on-chain limit: an account may borrow up to health factor 1.00. Avana's Lens shows a recommended borrow at health factor 1.10 next to that protocol maximum, because a loan opened at full capacity has no buffer. With $100,000 of collateral at a 70% Collateral Factor, the Lens shows $63,636 recommended ($70,000 / 1.10, rounded down) and $70,000 maximum. A per-market hard floor exists as an optional parameter, off by default, and is set only if stress tests justify it ([spec 2.7](../spec/02-contracts/07-risk-module.md), REQ-ADAPTER-026, SPEC-CF-003; [spec 2.17](../spec/02-contracts/17-lens.md)).

### Borrowing and Repayment
To borrow, the depositor approves the transfer and deposits the position into the LP Vault, an action we call a Pledge. A Pledge changes custody of the NFT; it does not remove liquidity from the pool. Before accepting a position, the Risk Module checks that it matches a listed market's exact pool and range, the oracle state, the caps and a minimum pledge value of $10. An account holds at most 16 positions in one market. There is no borrower allowlist and no minimum debt (spec 1.1, REQ-ARCH-018, REQ-ARCH-019; spec 1.5, `minPledgeUsd`). The Risk Module also enforces exposure limits at the pool, underlying-token and depositor level for each Hub, and can cap Avana's share of a specific pool's liquidity where that pool's listing sets a cap (spec 1.5, `poolShareMaxBps`). By default there is no pool-share limit: removing liquidity has no price impact, and liquidation proceeds can be sold through any approved swap route (other pools, DEXs and aggregators), so liquidation safety comes from the route-depth checks and the draw caps, while token caps, market caps and listing review cover concentration risk. Avana's combined share of a pool above 25% raises a monitoring alert.

The borrowing rate combines the Hub's GHO base rate with the account's User Risk Premium:

`Borrowing Rate = Base Rate × (1 + User Risk Premium)`

A loan backed only by collateral with a 50% risk premium pays 6.75% at a 4.5% base rate. Because each account holds one market, the account's premium is that market's Collateral Risk. The rate is flat: it does not depend on utilization (spec 2.1, SPEC-HUB-004, SPEC-HUB-007). Collateral Risk sets this premium; it is not a haircut on collateral value.

Anyone can repay part or all of any account's debt through the AaveAdapter at any time. No Avana pause, circuit breaker or address freeze can block repayment, fee collection or a debt-free withdrawal; only an Aave-side pause of the debt reserve or a Hub halt of the Spoke can ([spec 2.15](../spec/02-contracts/15-governance-and-timelock.md), REQ-ACCESS-068). Borrowers can also call the contracts directly, without Avana's frontend.

Borrowers can also repay with collateral: LPVaultSwap flash-borrows the debt asset, the account repays, and only the chosen share of the position is unwound and sold to repay the loan. No bonus or Avana fee applies, and the account's health factor cannot fall (spec 1.1, REQ-ARCH-185).

On withdrawal, the Adapter withdraws and burns the matching vault tokens, and the LP Vault releases the NFT with any uncollected fees. A withdrawal that leaves debt must keep the account's health factor at or above 1.00 under Aave's rule and pass every price check; the Lens warns when it would leave less than 1.10. A debt-free withdrawal reads no price and is never paused (spec 1.1, REQ-ARCH-153, REQ-ARCH-186).

### Liquidation Design
An account becomes liquidatable when its health factor falls below 1, whether from falling collateral value, a rise in the debt asset's price or accrued interest. Each account holds one market, so a price move in one market never liquidates a position in another.

Every liquidation runs through LPVaultSwap on its chain, in one atomic transaction, and `LPVaultSwap.liquidate` is its only entry point ([spec 3.5](../spec/03-operations/05-liquidation.md); [spec 2.11](../spec/02-contracts/11-lpvaultswap.md)):

1. **Funding.** Any address can call `liquidate` once Aave allows the liquidation, choosing the primary-then-backup routes or the backup route only. LPVaultSwap pulls up to `debtToCover` of the debt asset from the caller and takes no flash loan itself (LIQ-001, LIQ-035, LIQ-061). A caller without the debt asset uses Avana's public flash liquidation helper, an immutable periphery contract anyone can use: it flash-borrows the debt asset from the Aave V3 Pool with `flashLoan` (no premium once Aave grants it `FLASH_BORROWER`, otherwise the Pool's premium), calls `liquidate`, and repays the Pool from the caller's payout. Operators may run their own helper (LIQ-036 to LIQ-040).
2. **Standard liquidation.** LPVaultSwap calls the CDP Spoke's standard `liquidationCall` with `receiveShares = false`. Aave sizes the repayment toward the Spoke's target health factor (Avana recommends 1.10), applying its dynamic bonus and dust rule, pulls the repayment from the caller's funding and sends the seized vault tokens to LPVaultSwap (LIQ-017).
3. **Burn and unwind.** The AaveAdapter burns exactly the seized vault tokens (`burnSeized`), Collateralization checks that the account's supply shares and the token supply both fell by exactly that amount and debits the account's records, and the LP Vault removes exactly that liquidity from the position, collecting only principal. The borrower keeps the rest of the position and all of its fees (LIQ-020, LIQ-023, LIQ-072).
4. **Swap.** Each unwound token is swapped into the debt asset over the market's primary or backup route, each leg with a minimum output derived from oracle prices. Routes never trade through the pool being unwound, and every swap settles inside the transaction. The proceeds must reach a recovery floor: the seized collateral's oracle value, less the slippage the bonus can absorb (at most 1%). The caller may top up a small shortfall from its own funds, buying at most 10% more slippage; otherwise the transaction fails and nothing changes (LIQ-027, LIQ-030, LIQ-075; REQ-SWAP-022, REQ-SWAP-100).
5. **Pay out in the debt asset.** Avana's fee is 20% of the oracle gain (the seized collateral's oracle value minus the debt repaid), capped by the realized gain. Any recovery above the seized collateral's oracle value goes to the borrower. Everything else goes to the caller: the funding Aave did not use, the recovered principal and the caller's reward, paid directly, or the whole transaction reverts. A fee or borrower payout that cannot be delivered, for example to a blocklisted address, goes to Avana's payout escrow (the `PayoutEscrow` contract), where its owner claims it, and the liquidation still completes. Holding refused payouts is the escrow's only job (LIQ-031, LIQ-032; REQ-SWAP-076; [spec 2.18](../spec/02-contracts/18-payout-escrow.md)). In a market whose slippage allowance reaches the limit the bonus sets, a caller that routes the recovery down to the floor can reduce Avana's fee to about zero, so the fee there is best-effort; the floor still protects the debt repaid and the borrower.
6. **Flash repayment, through the helper only.** When `liquidate` returns, the helper repays the Pool's principal and premium from the caller's payout and only then pays the operator. A payout too small to repay the loan reverts the whole transaction (LIQ-039, LIQ-040).

Liquidation is always partial; there is no full-position settlement (spec 3.5, intro, Q-060). Aave V4's built-in liquidation fee is set to 0. The pool's spot price gates nothing: removing liquidity at any pool price returns tokens worth at least their fair value at oracle prices, and the per-leg minimums and recovery floor bound what they convert to (LIQ-082, REQ-SWAP-025).

**Worked example: Ethereum, GHO debt (spec 3.5, LIQ-068).** A USDC/USDT Uniswap v3 market on Ethereum, vault token priced at $2.00, Collateral Factor 28.12%, maximum bonus 5%, target health factor 1.10, GHO debt. Alice's account holds 141,232 vault tokens ($282,464) and owes 79,452.85 GHO.

| Step | Result |
|---|---|
| Trigger | A USDT price move takes her health factor to 0.9997. Aave's bonus at that point is 2%. |
| Funding and liquidation | Avana's keeper calls the public helper, which flash-borrows 9,800 GHO with no premium and calls `liquidate`. LPVaultSwap pulls the 9,800 GHO; Aave repays 9,800 GHO of debt and seizes 4,998 vault tokens, worth 9,996 GHO at oracle prices. |
| Unwind and swap | The LP Vault unwinds about 4,998 USDC and 4,998 USDT, which swap to 9,950 GHO, above the recovery floor of 9,895.04 GHO. |
| Payout | The oracle gain is 196 GHO and the realized gain 150 GHO. Avana's fee is 39.2 GHO (20% of 196) and the borrower surplus is 0. The helper receives 9,910.8 GHO (the 9,800 GHO it funded plus a 110.8 GHO reward), repays the Pool 9,800 GHO and pays the keeper 110.8 GHO. Had the swaps returned more than the oracle value, the excess would have gone to Alice. |
| After | Alice keeps 136,234 vault tokens ($272,468), about 96.5% of her position, and all of its fees, against 69,652.85 GHO of debt, at a health factor of 1.09999. |

Had the keeper called `liquidationCall` directly, the Hub's transfer of seized vault tokens to the keeper would have failed on the vault token's transfer rule.

**Variant: Aerodrome Slipstream on Base (spec 3.5, LIQ-089).** The same flow runs on Base for a USDC/USDT Slipstream market (tick spacing 1, exact range, unstaked position) on "Aerodrome Slipstream Stable", vault token at $2.00. The example uses a USDC debt reserve to show settlement in a non-GHO debt asset; at launch GHO is the only debt reserve on each CDP Spoke (spec 1.5, `approvedDebtReserves`). The public helper's `FLASH_BORROWER` role on the Base Pool is still pending, so its loan carries the Pool's 5 bps premium, which comes out of the keeper's share.

| Step | Result |
|---|---|
| Sequencer grace | The Base sequencer restarts at 10:00. At 10:20 Carol's account is at health factor 0.9997 and owes 20,000 USDC; a keeper call fails because 0.9997 is above the grace threshold of 0.95. |
| Liquidation | At 11:00:02, the first Base block after the 1-hour grace window, a keeper calls the helper, which flash-borrows 2,000 USDC with a 1 USDC premium and calls `liquidate`. Aave repays 2,000 USDC and seizes 1,020 vault tokens ($2,040). |
| Unwind and swap | The Slipstream LP Vault unwinds about 1,020 USDC and 1,020 USDT; the USDT leg swaps to 1,018.5 USDC, so proceeds are 2,038.5 USDC against a recovery floor of 2,018.6 USDC. |
| Payout | The oracle gain is 40 USDC and the realized gain 38.5 USDC: Avana's fee is 8 USDC and the borrower surplus is 0. The helper receives 2,030.5 USDC, repays the Pool 2,001 USDC and pays the keeper 29.5 USDC. |

**Rounding and route failures.** Aave V4's dust rule can raise the repayment needed to finish a liquidation. The caller sizes `debtToCover` for that amount up front; Aave pulls only what it needs, and the rest returns in the caller's payout. A recovery a few units below the debt repaid reduces only the caller's payout, and Avana's keeper accepts that loss. Avana has no settlement budget and no in-kind settlement path: every liquidation settles in the debt asset or reverts with nothing changed ([spec 2.13](../spec/02-contracts/13-settlement-budget.md); spec 3.5, LIQ-041, LIQ-076). If both swap routes of a token fail, monitoring alerts, and a guardian freezes new borrowing in the market once the approved routes are confirmed unable to settle valid liquidations at the required size (see Circuit Breakers). If a liquidation empties the account's collateral while debt remains, Aave records the remainder as a deficit (see Shortfalls and Deficit Coverage).

**Committed operators and gas.** Any address can liquidate through `liquidate`, with both route modes and every check: the health factor, the price and grace gates, the Hub share check, the recovery floor, Avana's fee, the borrower surplus, the deadline, the caller's minimum payout and the address freeze (spec 3.5, LIQ-061, LIQ-066). LPVaultSwap's keeper list is a registry of committed operators, each of which commits to liquidate every account below a health factor of 1, whatever its size and whether or not the bonus covers the gas. At launch Avana's keeper is the committed operator on each chain: Avana funds it, pays its gas, and it repays as much as Aave allows per call, so no liquidation depends on a keeper's profit. Others, such as Aave Labs or a risk provider, can be added through the timelock at the normal delay, up to 32 per chain. The registry gates no call. The keeper floor is one per chain: new borrowing on a chain halts when no active committed operator remains there, and liquidation itself never halts (spec 3.5, LIQ-063, LIQ-065, LIQ-087; spec 1.5, `keeperFloor`, `MAX_KEEPERS`). A one-record liquidation uses about 1.55M gas, which is about $3 at today's gas price of about 1 gwei. The 16-record cap keeps the largest account's liquidation at 5.15M gas, within one transaction (spec 1.5, SPEC-CHAIN-001). The Aave DAO can liquidate through `liquidate` from any address at any time, or have a committed operator of its choice registered (LIQ-067). An address freeze stops a frozen address from calling LPVaultSwap directly but not through the public helper, because LPVaultSwap then sees the helper as its caller (LIQ-080). A direct `liquidationCall` from any other address fails, because the vault token accepts seized collateral only to LPVaultSwap (LIQ-064).

**What can stop it.** No Avana pause, circuit breaker, configuration drift or address freeze stops liquidation, and an Aave freeze of a reserve does not either. Liquidation waits only for a fresh price of the market being seized and of the debt being repaid, for the Base sequencer check, and for Aave-side halts: a Hub halt of the Spoke or an Aave pause of the reserve. The listing payload commits the Aave DAO to contain a Spoke with a reserve freeze and a zero draw cap, which leave liquidation open, and to halt or pause only a faulty Spoke (spec 3.5, LIQ-002, LIQ-006, LIQ-073, LIQ-086, LIQ-088).

## Risk Management

### Governance and Emergency Controls
The DAO would approve the deployment and initial parameters. Avana Labs would propose markets and parameter changes for assessment by a designated risk reviewer. Each new market is listed through the chain's AvanaTimelock at the normal delay, a five-day public review enforced on-chain, together with the Aave DAO's listing payload, which sets the Collateral Factor, bonus curve and caps (spec 1.1, REQ-ARCH-209; [spec 3.8](../spec/03-operations/08-market-lifecycle.md); spec 2.15, REQ-ACCESS-161).

Governance is per chain. Ethereum and Base each have their own AvanaTimelock, a 4-of-7 governance Safe and a 3-of-5 Emergency Guardian Safe, and no Avana role or operation on one chain can act on the other (spec 2.15, REQ-ACCESS-173).
- **Aave DAO ownership:** the Aave DAO owns and configures every Avana Hub and Spoke and holds every Aave-side control: caps, credit lines, reserve freeze and pause, and Hub halt. Avana owns no Aave contract (spec 1.1, REQ-ARCH-024).
- **AvanaTimelock:** every upgrade, parameter change, market listing and role change to Avana's contracts executes through the chain's timelock, which Avana Labs cannot bypass. The delay is 5 days, never less than 4, or 12 hours when every call only reduces risk or stops new activity. Anyone can execute a ready operation within a 14-day grace window. The governance Safe and the Aave governance executor can both propose. The governance Safe, the Emergency Guardian, the Aave Protocol Guardian and the Aave governance executor can all cancel, and only the Aave governance executor can cancel a role change or an operation that restores liquidation (spec 1.1, REQ-ARCH-154; spec 1.5, Change classes).
- **Guardians:** the Emergency Guardian and the Aave Protocol Guardian can each act at once to freeze or pause one Hub or every Hub on the chain, freeze an address, trip or reset a circuit breaker, switch a token to its pre-approved standby price route or standby second source, and cancel queued operations. They cannot upgrade contracts, change parameters, choose a new price source, unfreeze an address or move collateral. The Aave Protocol Guardian can also freeze or pause Avana reserves on the Aave side, so Avana's markets can be stopped without Avana Labs' cooperation.
- **Circuit breakers:** a short set of on-chain breakers per market and per debt reserve, with alert-only thresholds beside them, listed under Circuit Breakers below. The Base sequencer check, the coverage bound and the Aave configuration drift check also stop new borrowing under their own conditions (spec 1.1, REQ-ARCH-181).
- **Exits are never blocked:** pauses, freezes, circuit breakers and the address freeze stop new activity only. Repayment, fee collection, debt-free withdrawal and liquidation stay open in every state (spec 1.1, REQ-ARCH-153, REQ-ARCH-182; spec 2.15, REQ-ACCESS-068).
- **LPVaultSwap:** like every upgradeable Avana contract, it is upgraded only through the chain's AvanaTimelock, and its registry of committed operators changes only through timelock operations. There is no separate operations multisig (spec 2.15, REQ-ACCESS-104; spec 3.5, LIQ-065).

At most 3 of the 7 governance Safe signers come from Avana Labs, spanning at least three organisations and three jurisdictions. The signer sets of the governance Safe, the Emergency Guardian and the Aave Protocol Guardian do not overlap. Named signers will be agreed with service providers (spec 1.5, `governanceMultisigThreshold`; spec 2.15, REQ-ACCESS-104).

### Circuit Breakers
The v1 breakers stop new borrowing only where an on-chain check is reliable. Price drops, seizure surges and swap-route failures are monitored and alerted, not tripped on-chain: a reverted liquidation cannot persist a failure count, and an on-chain counter can be gamed ([spec 3.6](../spec/03-operations/06-emergency-operations.md); spec 1.5, Caps and risk).

| Trigger | Setting | Action |
|---|---|---|
| Oracle or stablecoin band breach | The oracle price-state checks and the $0.90–$1.02 stablecoin band | Block new borrowing and collateral withdrawals that leave debt |
| Price drop | 3% in 2 hours | Alert only |
| Avana's combined share of a pool | Above 25% across all borrowers and Spokes on the chain | Alert only; a per-pool cap applies only where its listing sets one, and above it new borrowing and pledges that increase pool exposure are blocked |
| Collateral seized | Above 20% of a market in 1 hour | Alert only |
| Swap-route failures | 3 in 1 hour | Alert. A guardian freezes new borrowing only when the approved routes are confirmed unable to settle valid liquidations at the required size |
| Outstanding GHO deficit | 10,000 GHO for the affected CDP Spoke; for other debt assets, a materiality level set at listing | Freeze new borrowing on that debt reserve automatically. Alert on every new deficit |
| Reopening | 30 minutes of healthy observations, for temporary price or depth breaches | Clear the temporary gate. A deficit or security freeze reopens only through the timelock or a guardian (spec 2.15) |

The 30-minute reopening window is a provisional launch setting, reviewed against live data. Repayment, debt-free exits and eligible liquidations stay open through every breaker. A liquidation still needs a valid price, Aave eligibility and executable settlement, and an Aave reserve pause can independently block repayment or liquidation.

### Shortfalls and Deficit Coverage
When a liquidation empties an account's collateral while debt remains, the CDP Spoke reports the remaining debt of each debt reserve as a deficit on that reserve's funding Hub, in that reserve's own asset (spec 3.5, LIQ-049). Recording the deficit and funding its coverage are separate operations. Each (Hub, debt asset) has its own Avana Umbrella (Coverage Spoke), controlled by the Aave DAO and funded by Avana Labs in that asset. Avana Umbrella is Avana's protocol safety module, named after Aave's Umbrella, whose design inspired it. It holds that pair's first-loss reserve and eliminates a recorded deficit within 72 hours. It is Avana's only on-chain loss layer at launch; committed revenues are not counted as coverage. A deficit is never covered with another asset's, Hub's or chain's reserve ([spec 2.14](../spec/02-contracts/14-first-loss-reserve.md), REQ-FLR-001; [spec 3.9](../spec/03-operations/09-deficit-coverage.md); spec 1.5, `deficitCoverageWindow`).

At launch each chain has one Avana Umbrella for GHO on its Stable LP Hub. The funded reserve must satisfy `fundedBalance × 10⁴ ≥ coverageRatioBps × Σ drawCap` on that (Hub, asset), checked when a debt reserve is enabled, on every draw-cap raise and on every borrow (spec 3.9, DEF-019). The funding ARFC sets `coverageRatioBps` and `firstLossReserveMinimum` with Aave's service providers; 20% serves only as an illustrative guide. An outstanding GHO deficit of 10,000 GHO on a CDP Spoke freezes new borrowing on that debt reserve, and every new deficit raises an alert. Rounding gaps in dust liquidations come out of the liquidator's own payout, never from the first-loss reserve. A deficit larger than the reserve is a loss to that Hub asset's suppliers; as soon as one appears, every drawing Spoke's draw cap on that asset is set to 0 through the Aave Guardian, and the Aave DAO realizes the loss (spec 2.14, REQ-FLR-027; spec 3.9, DEF-014). The funding proposal would define coverage amounts, replenishment and activation rules.

### Reporting and Offboarding
Avana Labs would publish weekly usage reports and monthly revenue reports, covering:
- figures per chain
- debt and collateral by market
- concentration levels
- the distribution of health factors
- successful, failed and retried liquidations
- Avana Umbrella usage
- bad debt
- oracle incidents
- pauses, freezes, circuit-breaker trips and monitoring alerts
- credit-line usage
- fees earned

Offboarding a market is a 12-hour timelock operation together with an Aave freeze of the market's vault-token reserve, which stops new pledges and borrowing at once. After a five-day public notice, anyone can step a 30-day linear ramp that lowers the market's liquidation threshold once a day, down to half its listed value, so each remaining borrower sees a predictable daily cut and can repay in time. Existing debt is never cancelled and there is no force-close power: repayment, withdrawal and liquidation stay open throughout, and the market's price feeds, swap routes and keepers stay in service. Once the market's total debt is 0, anyone can call `closeMarket`, and debt-free positions stay withdrawable with no time limit. A closed market cannot reopen; the same pool and range can return only as a new market on another CDP Spoke, through the full five-day review (spec 1.1, REQ-ARCH-023; spec 3.8, MKT-002, MKT-039, MKT-041, MKT-059; spec 1.5, `offboardNoticeSeconds`, `windDownRampSeconds`, `windDownFinalLtBps`).

## How we verified the design
The formulas and rules above are written in the specification, and the checks below test them before any contract code is written. The figures below were re-run or read from the run logs on 10 November 2026.

| Check | What it covers | Result |
|---|---|---|
| Traceability ([`trace.py`](../spec/05-verification/trace.py)) | Links every requirement to the checks that verify it. A lock file records each requirement's accepted text, so any edit must be re-verified before it is accepted again. | 3,454 requirements traced, 0 errors |
| Z3 ([`z3/`](../spec/05-verification/z3/README.md)) | Every formula in exact integers at Solidity bit widths: units, oracle math and price states, Aave V4 health factor and liquidation sizing ported from the pinned Aave V4 commit, recovery floor, waterfall, coverage, timelock timing, and LP pricing per AMM protocol. Every worked example is recomputed. | 45 scripts, 825 checks: 616 proved, 104 computed exactly, 105 counterexamples that the scripts search for on purpose (wrong readings and stated boundaries). Every result matches its recorded value. |
| SymPy ([`sympy/`](../spec/05-verification/sympy/README.md)) | Each formula equals the rule it implements, exactly and before rounding | 10 scripts, 240 checks: 239 consistent, 1 deliberate wrong reading |
| Hypothesis ([`hypothesis/`](../spec/05-verification/hypothesis/README.md)) | Generated action sequences against an executable integer model of Avana, Aave V4 and Uniswap v3, with solvency per debt asset checked after every step | 82 tests, 82 pass |
| Quint ([`quint/`](../spec/05-verification/quint/README.md)) | Cross-contract state machine with honest and hostile components, and a multi-Hub, multi-Spoke topology model | 70 deterministic scenarios pass (50 system, 20 topology); no violation of the 43 system and 15 topology invariants in the recorded simulator runs |
| Formal verification: custody ([`audit/formal-verification/custody`](../audit/formal-verification/custody/report.md)) | Collateralization, vault token and factory, LP Vault, the Adapter's mint and burn paths, Aave V4 Hub share math | Every check verified, 0 open findings (run FV-CUS-R6) |
| Formal verification: control ([`audit/formal-verification/control`](../audit/formal-verification/control/report.md)) | Access control, timelock, pause, gates, parameters, registry, oracle, upgrades, breakers | 180 checks: 168 verified, 6 verified under a bounded model, 6 Quint invariants with no violation in 10,000 samples; 0 open findings (run FV-CTL-R7) |
| Formal verification: liquidation ([`audit/formal-verification/liquidation`](../audit/formal-verification/liquidation/report.md)) | LPVaultSwap, settlement math, flash source, swap routes, Avana Umbrella (Coverage Spokes), payout escrow, Aave V4 liquidation sizing | 271 checks pass, 0 fail (run FV-LIQ-R8) |
| 1,000-user simulation ([`audit/user-simulation`](../audit/user-simulation/report.md)) | 1,000 users and bots over 90 days, including six stress episodes, at current mainnet gas prices | 572,608 invariant checks, 0 violations, 98 liquidations, $0 bad debt (run SIM-R12) |
| Adversarial design review ([`audit/design-review/amm-neutral`](../audit/design-review/amm-neutral/report.md)) | Red team, flow walkthroughs, integration assumptions checked against live chain data, gas and DoS, architecture options, state machine | The design as first written had 6 Critical, 13 High, 22 Medium and 14 Low findings, a score of 52/100. One Medium, an Aave-side halt stopping exits on a Spoke, is accepted with an operating playbook; all others are resolved in the specification. The [final re-check](../audit/design-review/amm-neutral/final-recheck.md) scored 96.5/100, and 99.0/100 after its fix pass, with no weak or open item. |

These checks verify the specification and the contract interfaces. They do not verify contract code, because the contract implementations are not written yet. The next steps are the implementations, the Foundry, fuzz, fork and invariant tests and prover runs the specification already lists ([spec 5.1](../spec/05-verification/01-test-requirements.md), [spec 5.2](../spec/05-verification/02-formal-properties.md)), and then independent audits of every contract. Findings and their resolutions are recorded in the [findings register](../audit/findings-register.md).

## Conclusion
Avana turns active AMM liquidity into a new source of collateral and borrowing demand for Aave V4. Liquidity providers can borrow GHO without withdrawing from their pools or giving up their trading fees, while the Aave DAO earns interest on the credit extended through the Avana Hubs.

Avana Labs is an independent team with experience building DeFi products. We have specified Avana end to end, covering the LP Vault, valuation, liquidation settlement and Aave V4 integration, verified its formulas with formal models and published contract interfaces that compile cleanly. The contract implementations follow, then independent audits. We also run a public sandbox that demonstrates the protocol flows, and we document our architecture and liquidation design at www.avana.cc. Avana Labs will share more details and accountable contacts with Aave's service providers during the review.

## Disclaimer
Avana Labs is the author of this proposal. We have not been compensated by any third party to publish it. This ARFC is intended to gather community feedback on Avana and discuss a potential GHO credit line request ahead of the planned mainnet launch. The information provided should not be construed as legal, financial, tax or professional advice.

## Next Steps
1. **Snapshot on this ARFC.** If feedback is positive, this ARFC goes to a Snapshot vote to confirm support for the assessment.
2. **Two follow-up ARFCs.** If the DAO approves, Avana Labs publishes one ARFC for the Ethereum and Base deployment and one for the GHO funding arrangement on both chains. Each includes risk parameters, audit reports and launch configuration, and each has its own Snapshot. Neither activates borrowing on its own: launch requires both, plus all security and risk prerequisites.
   - The deployment ARFC would ask the Aave DAO to list each CDP Spoke as a standard Aave V4 Spoke with `receiveSharesEnabled = false`, `liquidationFee = 0` and no reinvestment controller on every Avana collateral reserve; to grant Avana's public flash liquidation helper and its flash source the `FLASH_BORROWER` role on the Aave V3 Pool on Ethereum and on Base; to set each CDP Spoke's liquidation settings, for which Avana recommends a target health factor of 1.10 and a minimum bonus of at least 2%; to register an Avana Umbrella for GHO on each chain's Stable LP Hub and name its role holders; and to add the Aave governance executor of each chain as proposer and canceller on that chain's AvanaTimelock, and the Aave Protocol Guardian as guardian and canceller (spec 2.1, REQ-HUB-044; spec 3.9, DEF-016; spec 2.15).
   - The funding ARFC would set a GHO credit line and draw caps per chain (a proposed 2M GHO on Ethereum; the Base line), each within that chain's flash liquidity, route depth and coverage bound; the coverage ratio and first-loss reserve minimum of each Avana Umbrella; and a flat GHO rate at or above the Core Hub GHO base rate (spec 2.1, SPEC-HUB-003, SPEC-HUB-007; spec 3.9, DEF-019).
3. **AIPs.** If both Snapshots pass, the proposals go onchain as AIPs. Each chain beyond Ethereum and Base would get its own ARFC. Aave-side actions on Base go through the Aave DAO's Base executor over Aave's cross-chain governance (spec 1.1, REQ-CHAIN-001).

We are excited to hear the community's thoughts on this proposal and believe that it will enhance Aave V4 and GHO.

## References
This section contains governance discussions, historical implementations, research links, prior LP collateral proposals and extended market-sizing material.
- https://medium.com/aave/the-uniswap-market-is-live-on-aave-protocol-12b5a4cc5e2
- https://governance.aave.com/t/gauntlet-analysis-market-risks-of-listing-lp-tokens-as-collateral/10573
- https://governance.aave.com/t/renew-the-amm-market-assets/4918
- https://governance.aave.com/t/arc-add-support-for-defi-pulse-index-dpi/3576/22?
- https://governance.aave.com/t/limitations-of-a-market-for-uni-v2-collateral-be-created/545/2?u
- https://governance.aave.com/t/limitations-of-a-market-for-uni-v2-collateral-be-created/545/9?u
- https://governance.aave.com/t/arc-add-gelato-s-g-uni-erc20-uniswap-v3-positions-as-collateral-to-aave-s-amm-market/5687
- https://twitter.com/haydenzadams/status/1440461089133645835?s=20
- https://governance.aave.com/t/arc-implement-a-uni-v2-liquidity-pool-token-market-initial-discussion/645
- https://governance.aave.com/t/adding-uniswap-v3-nfts-as-collateral/11569
- https://governance.aave.com/t/arc-uniswap-v3-nft-as-collateral-for-minting-gho/10708
- https://governance.aave.com/t/arc-onboard-gamma-strategies-usdc-gho-uni-v3-collateral-to-mint-gho/10733
- https://governance.aave.com/t/arc-staked-atokens-a-new-aave-primitive-exploring-vote-escrow-economies/10406
- https://governance.aave.com/t/arc-erc4626-strategies-as-productive-collateral/10337
- https://governance.aave.com/t/arfc-strategic-opportunity-framework-for-friendly-forks-and-whitelabel-instances/21961
- https://governance.aave.com/t/direct-to-aip-onboard-usde-september-expiry-pt-tokens-on-aave-v3-core-instance/22620
- https://x.com/aave/status/1371761919682617347
- https://governance.aave.com/t/gauntlet-s-market-risk-assessment/3814
- https://www.comp.xyz/t/add-market-g-uni-erc20-uniswap-v3-positions/2324
- https://forum.sky.money/tags/c/collateral-onboarding/domain-work/28/uni-lp

## Copyright
Copyright and related rights waived via CC0.
