Executive Summary
The deepest liquidity in DeFi is useful, but it is still locked away from credit.
Liquidity providers keep markets alive. They put assets into pools, support swaps, reduce slippage, and earn fees. But once capital is inside an AMM pool, it is hard to use that same capital as collateral. If a user needs to borrow, the normal path is still to remove liquidity, exit the pool, and give up the fees and market position they already built.
Avana changes this.
Avana lets users deposit supported LP positions and borrow against them through Aave v4. The LP position stays in place as the real collateral, while Avana turns it into an internal ERC-20 accounting asset that Aave can use on the borrow side. Avana starts with curated LP markets, so a LINK-ETH position maps to vaultLINKETH, an ETH-DAI position maps to vaultETHDAI, a WETH-USDC position maps to vaultWETHUSDC, and a WBTC-ETH position maps to vaultWBTCETH. Each market is priced, checked, and managed on its own, which keeps the experience simple. The vault token is just the bridge: Avana tracks and values the LP position, the Aave Adapter mints the right token, and Aave uses that token for collateral accounting so the user can borrow without closing the pool position. The LP stays live, the collateral stays organized, and the user gets credit against the value already in the market.
Protocol Motivation
The idea of using LP positions as borrowable collateral is not new. Previous attempts proved demand but failed to fully solve valuation, liquidation, and risk isolation. Avana exists because those three constraints can now be addressed directly.
In 2021, Aave launched its AMM market with Uniswap v2 and Balancer LP tokens as collateral. The model arrived before the surrounding infrastructure was ready. DEX liquidity was thinner, pool design was less mature, and risk frameworks were still too blunt to capture what LP positions actually were.
Additionally, Gelato's G-UNI wrapped Uniswap v3 NFT positions into fungible ERC-20 tokens, restoring composability across DeFi. Later, MakerDAO's DAI pool reached over $1B in TVL but ultimately declined, citing oracle fragility, liquidation complexity, and insufficient risk isolation.
Years later, in 2026, Aave returned with a new proposal to Uniswap: CDPs for Uniswap v4 Positions. The proposal ended up stalling, and adoption remained constrained by the same unresolved challenges.
LP collateral is easier to support now than it was a few years ago. AMMs are more mature, liquidity is deeper, oracles and liquidation systems are better, and there is a lot more data on how LP positions behave across different pairs. Aave v4 fits that setup because its hub-and-spoke design lets LP valuation, risk, and liquidation live inside separate spoke markets instead of forcing everything into one shared model.
Protocol Overview
Avana is a lending protocol built for LP collateral.
Liquidity providers on Uniswap, Balancer, Curve, or Aerodrome can deposit supported positions, keep them active in the pool, and borrow against them through market-specific risk settings.
Fluid is the closest comparison, but it takes a different path. Fluid turns debt and collateral into its own liquidity layer. Avana works the other way around: it takes LP positions that already exist across AMMs and makes them usable as collateral without replacing the underlying rails. Avana starts with Borrow Markets, then adds Lend Markets and Multiply Markets later. Each market keeps its own risk settings, so the first version stays focused and the risk model stays easy to tune.
Protocol Specification
At a high level, Avana works through three steps.
First, a user deposits an LP position into Avana. This can be any pool position from supported AMMs such as Uniswap, Balancer, Curve Finance, or Aerodrome Finance, depending on the phase and supported markets.
Second, Avana evaluates the LP position to determine its risk-adjusted collateral value. The protocol checks the value of the underlying pool assets, the structure of the liquidity pool, asset volatility, correlation between the assets in the pair, and overall liquidation risk. Avana relies on LP valuation models, conservative borrowing limits, oracle-based pricing, and automated liquidation mechanisms to ensure that LP positions can function safely as collateral.
Third, once the position has been evaluated, the user can borrow assets against it. The liquidity remains active inside the AMM and continues earning trading fees and incentives while also serving as collateral. This allows LPs to access liquidity without withdrawing liquidity from the AMM; the LP position itself becomes the collateral inside Avana.
Protocol Architecture
Avana is built on Aave v4's hub-and-spoke architecture because LP collateral needs both shared liquidity and isolated logic. The hub handles the common monetary layer: reserves, accounting, interest rate models, and global credit coordination. The spokes handle everything LP-specific: AMM pool collateral registration, LP position valuation, pool risk enforcement, and AMM pool liquidation execution.
Avana is built around five parts, and each one has a narrow job.
The LP Position Manager holds the real position and keeps the book on it. For a Uniswap v3 LP, that means the NFT ID, owner, pool, pair, fee tier, tick range, liquidity, current value, fees still sitting in the position, and whether it is already posted as collateral.
The Risk Module is the gatekeeper. It checks whether the pool is approved, whether the assets are supported, whether the position is deep enough, whether the range is still usable, and whether the market is still inside its caps.
The Collateralization Module sits between approval and action. It checks the oracle setup, pulls in the latest pricing, values the position, decides how much collateral it can support, and mints the vault token when the position is cleared for borrowing. It also updates or removes that collateral when the market changes or the position leaves the system.
The Aave Adapter handles the Aave-facing side of the system. Once the other modules approve a position, it supplies the vault token to Aave v4, withdraws it when collateral is removed, and keeps the integration isolated from the LP-specific logic.
Those vault collateral tokens are internal ERC-20 assets like vaultLINKETH, vaultETHDAI, vaultWETHUSDC, and vaultWBTCETH. Each market gets its own token, so the accounting stays simple on the Aave side while Avana keeps the real LP position and market logic behind the scenes.
Spoke Configuration
For Borrowers
Avana splits borrowing into separate spokes so each LP market gets its own setup. That way, stable pools, correlated pairs, weighted pools, and concentrated liquidity each get the rules they actually need instead of being forced into one generic template.
LP positions do not all behave the same. Some are calm and predictable, some move with each other, and some can swing hard when the range gets tight. Keeping them in separate spokes makes the pricing, liquidation, and borrowing rules easier to tune, and it lets Avana support more LP markets without turning everything into the same product. It starts with a focused set of borrow spokes across stable, correlated, volatile, and governance-token LP markets so launch sequencing stays manageable.
For Lenders
The Lend Spoke is where capital enters the system. Lenders deposit assets like ETH, BTC, and major stablecoins, and that liquidity gets routed through the Hub to support borrowing across the LP markets. They are not managing LP positions or ranges themselves, they are just putting clean capital to work.
Early on, Avana may lean on Aave Hub credit lines to bootstrap depth and make sure borrow markets feel liquid from day one. As the protocol grows, lender deposits should carry more of the load, which keeps the system simpler, reduces dependence on outside credit, and lets borrowing grow from its own base.
Risk Management
Liquidity provider (LP) collateral behaves fundamentally differently from traditional lending collateral. Its value is not static. Instead, it evolves continuously with pool composition, price divergence between paired assets, and impermanent loss dynamics that can accelerate faster than conventional volatility models anticipate. Any lending framework that treats an LP position as a simple token balance is structurally incomplete. Avana addresses this by assigning risk at the market level rather than the asset level. Each supported LP type is configured with collateral parameters derived from the structure of the pool and the historical behavior of its underlying assets. Pools composed of stable or highly correlated assets may support higher borrowing capacity, while volatile or thinly traded pairs require stricter limits. Concentrated liquidity positions are generally treated more conservatively than fungible or wide-range liquidity exposure because of the additional directional risk introduced by narrow tick ranges.
When a user deposits an LP position, the corresponding Borrow Spoke determines borrowing capacity by valuing the position in USD using a dual-oracle pricing framework. Chainlink price feeds provide the primary price reference for the underlying assets, while AMM-derived time-weighted average prices (TWAPs) act as an independent verification layer sourced directly from on-chain liquidity. Borrowing power is granted only when both pricing sources stay within a defined tolerance band, which keeps external oracle data and AMM-derived pricing in agreement and reduces exposure to flash-loan manipulation, transient price distortions, or stale updates that could otherwise lead to bad collateral valuation.
Once the vault token is supplied to Aave, its market settings add another layer of control by setting the LTV, liquidation threshold, liquidation bonus, caps, and health-factor checks for that reserve.
Avana's oracle architecture spans multiple layers to ensure redundancy, price integrity, and resilience under market stress.
Oracle Layer
Provider
Coverage
Update Frequency
Primary asset prices
Chainlink
50+ assets
0.5–2% deviation
Secondary verification
Chainlink Data Streams
100+ assets
Real-time
Pool-specific pricing
Uniswap v3 TWAP
All v3 pools
30-min rolling
Multi-asset pools
Balancer / Curve native
Pool-specific
1-hour exponential

Beyond price verification, Borrow Spokes continuously monitor pool composition, volatility, liquidity depth, and oracle reliability so the market can stay aligned with the position instead of relying on a fixed setting that never changes.
The system is designed with failure assumptions in mind. Dual-oracle verification prevents toxic pricing events, adaptive liquidation mechanisms minimize capital loss without abruptly removing liquidity from pools, and continuous monitoring allows the protocol to respond to evolving market conditions.
Position Valuation
Position Valuation has two sides.
First, Avana values the LP collateral itself, applies pool risk, and mints the vault token against that approved value. Then Aave v4 applies its reserve rules and risk premium to the vault token to decide how much the user can borrow.
For each LP position, Avana reads the position data and derives the token amounts from the liquidity and tick range. Those balances are priced in USD using Chainlink feeds and verified against AMM TWAPs, then Avana applies a pool risk factor so the collateral value reflects the actual market conditions inside that LP market.
That approved value becomes the backing for an internal ERC-20 vault token. Each market gets its own token, such as vaultLINKETH, vaultETHDAI, vaultWETHUSDC, or vaultWBTCETH, and the supply moves with the value of the collateral behind it instead of sitting on a fixed 1:1 peg.
Once the vault token is supplied, Aave v4 handles the borrow side. It applies that market's LTV, liquidation threshold, liquidation bonus, caps, health-factor checks, and risk premium to the ERC-20 reserve inside the Spoke.
Liquidation Mechanism
Liquidation starts when the account's health factor falls below the liquidation threshold. A liquidator repays the allowed debt amount, and Aave v4's liquidation engine uses that repayment to reduce or clear the borrow balance on the reserve side.
Once that happens, the vault collateral is released from the reserve side of Aave v4's market. The Avana Adapter burns the vault token, and the Liquidation Module marks the backing LP position as liquidated so the original collateral is no longer active.
From there, the Liquidation Module takes over the LP side. It unwinds, sells, or transfers the backing position depending on what makes the most sense for that market and route. The debt gets covered, the liquidator gets paid, and any surplus is returned by the final design.
Interest Rate
Borrow rates in Avana start with the Aave v4 Hub base rate, then add a spoke-level premium for the LP market itself. That keeps the pricing tied to the shared liquidity base while still letting each market carry its own risk cost.
As an example, an ETH/USDC LP position may carry a total borrow rate of 3.0%, built from a 2.0% Hub base rate and a 1.0% spoke premium. A more volatile pair such as UNI/ETH would carry a higher spoke premium, so the user sees a higher total borrow rate under the same Hub conditions. Rates stay predictable, but they still move with risk.
The initial set of collateral pools is intentionally narrow so the first markets are the ones with the deepest liquidity and the cleanest pricing. That keeps launch risk contained without losing the path to broader coverage later.
Revenue Model
Avana earns from two sources.
The first is a share of liquidation penalties on the LP positions it enables. Unwinding these positions properly with oracle validation, controlled execution, and slippage management requires purpose-built infrastructure, and the protocol is compensated for providing it. This also means Avana's economic incentives are aligned with conservative risk management: the better it protects positions, the fewer liquidations occur, and the more borrowers trust the system over time.
The second source is optional frontend fees through Avana's official interfaces, structured identically to Uniswap's frontend fee model. These fees are entirely separate from Aave's lending economics, have no effect on borrow or supply rates, and can be bypassed entirely by anyone building or using a self-hosted interface. The protocol is open and permissionless.
Market Opportunity
LP collateral already sits onchain as productive capital. The opportunity is to let that capital back borrowing instead of forcing users to exit their positions first. Across Ethereum, Arbitrum, and Base, that creates a large LP-collateral surface area that can grow as more AMM liquidity moves into organized borrowing markets.
The table below is directional. It uses simple assumptions to show how borrow demand, collateral depth, and protocol revenue can scale together as LP markets mature.
Scenario
LP Collateral
Outstanding Borrows
Aave Hub Revenue
Avana
Low
$100M
$50M
$4.5M / year
$2M
Average
$500M
$250M
$22.5M / year
$20M
Medium
$1B
$500M
$45M / year
$40
High
$2.5B
$1.25B
$112.5M / year
$100

The point is simple: borrow demand follows liquidity, and LP liquidity becomes more useful when it can support credit without leaving the pool. Aave captures the borrow side, and Avana captures the LP-collateral layer that makes that borrowing possible.
Conclusion
Avana directly executes on the strategic vision outlined by Aave Labs' "CDP for AMM Positions" proposal, extending it beyond a single DEX or pool design to encompass the entire multi-billion-dollar AMM ecosystem.
By connecting DEXs and lending markets, Avana transforms the deepest liquidity pools in DeFi into collateralized debt positions, turning AMMs from passive trading venues into active credit engines.
The infrastructure is now mature enough. The demand has been validated across multiple cycles. The risk models exist to do this safely at scale. Avana's vision expands over time through pool borrowing and structured leverage, but it begins with a simpler and more important first step. Phase 1 proves that LP positions can be valued, risk-managed, and liquidated safely enough to serve as real collateral. Once that foundation is established, AMM-backed credit will become a meaningful new layer of DeFi lending.


