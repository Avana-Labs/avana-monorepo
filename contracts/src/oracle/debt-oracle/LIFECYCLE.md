Implementation pending: links point to interfaces; update to implementation functions once the hand-written contracts exist.

# DebtOracle lifecycle

A DebtOracle is the Aave price source of one debt asset with a market price (USDC, USDT, WETH; GHO uses Aave's fixed $1 source): it serves the USD price with 8 decimals, keeps a cached price through outages, and reports whether borrowing and liquidation of that reserve may use it.

## Walkthrough

Setup (Base, `r_USDC` on the "Aerodrome Slipstream Stable" CDP Spoke, from 3.2 `BOR-022`): Chainlink USDC/USD with an 86,400 s heartbeat (fresh until 88,200 s), reading $0.9999, and a second source that agrees.

1. **Listing → [`initialize`](IDebtOracle.sol#L42)** fixes [`ASSET`](IDebtOracle.sol#L138) = USDC and seeds the accepted price. Event: [`DebtPriceSeeded`](IDebtOracleEvents.sol#L15). Error: [`NotDebtAsset`](IDebtOracleErrors.sol#L24).
2. **Aave reads [`latestAnswer`](IDebtOracle.sol#L53) / [`latestRoundData`](IDebtOracle.sol#L75)**: 99,990,000 ($0.9999). Carol's 5,000 USDC debt is valued at $4,999.50.
3. **RiskModule `preBorrowCheck` → [`poke`](IDebtOracle.sol#L119)** before Carol's borrow: round 30,000 s old ≤ 88,200 s, Live. Events: [`DebtPriceAccepted`](IDebtOracleEvents.sol#L22). Error: [`InsufficientGas`](IDebtOracleErrors.sol#L12).
4. **Borrow age limit.** [`borrowPriceMaxAge`](IDebtOracle.sol#L99) bounds the borrow side: a round 88,300 s old makes Carol's borrow revert `DebtPriceTooOld`. On an L2 a borrow also needs the served round newer than the sequencer's last restart: after a restart at 1,010,000 with a 3,600 s grace period, a round published at 1,009,000 keeps `borrowAllowed` false at 1,013,600 while liquidation and repayment run on it.
5. **LPVaultSwap → [`poke`](IDebtOracle.sol#L119)** before a liquidation repaying USDC; [`liquidationPriceMaxAge`](IDebtOracle.sol#L107) bounds the liquidation side. A failing price reverts LPVaultSwap with `DebtPriceStale(r)`.
6. **Disagreement.** Primary and alternate both fresh and apart beyond `feedAgreementToleranceBps`: the oracle records the start and serves `max(primary, alternate, accepted)`, so debt is never undervalued; `latestRoundData().updatedAt`, the age limits and the reported legs are those of the route whose value is served, or the accepted price's timestamp with no legs when the accepted price is served. Events: [`DebtDisagreementRecorded`](IDebtOracleEvents.sol#L54), [`DebtDisagreementCleared`](IDebtOracleEvents.sol#L60).
7. **Outage and expiry.** Both routes stale: Cached (serves the accepted $0.9999), then after 1 h Expired (serves `ceil(accepted × (10^4 + debtStressRiseBps) / 10^4)`, never below the accepted price and never above 1.5 × it: the oracle reads the stress rise into [100, 5,000] bps and, if the read fails, keeps the value the last `poke` read). Borrowing and liquidation of the reserve stop; repay continues. Events: [`DebtFailureRecorded`](IDebtOracleEvents.sol#L41), [`DebtOutageExpiredLatched`](IDebtOracleEvents.sol#L66), [`DebtPriceStateChanged`](IDebtOracleEvents.sol#L29).
8. **Recovery.** The first fresh round starts a 30-minute grace. Events: [`DebtGraceStarted`](IDebtOracleEvents.sol#L73), [`DebtFailureCleared`](IDebtOracleEvents.sol#L47). A standby switch in the MarketRegistry shows up as [`DebtRouteVersionObserved`](IDebtOracleEvents.sol#L79).
9. **AvanaTimelock → [`setPokeMinGas`](IDebtOracle.sol#L126)** at the normal delay. Event: [`PokeMinGasUpdated`](IDebtOracleEvents.sol#L85). Error: [`PokeMinGasOutOfBounds`](IDebtOracleErrors.sol#L29).

## What the UI reads and calls

- Lens: [`getDebtPriceState`](../../lens/lens/ILensLiquidation.sol#L32)`(spoke, debtReserveId)`; direct [`getPriceState`](IDebtOracle.sol#L85).
- Events to index: `DebtPriceStateChanged`, `DebtPriceAccepted`, `DebtFailureRecorded`, `DebtFailureCleared`, `DebtDisagreementRecorded`, `DebtOutageExpiredLatched`, `DebtGraceStarted` ([IDebtOracleEvents.sol](IDebtOracleEvents.sol)).
- User calls: [`poke`](IDebtOracle.sol#L119) (anyone).

## Spec

- [2.10 LPOracle, LPPriceMath and DebtOracle](../../../../spec/02-contracts/10-lp-oracle.md): `REQ-ORACLE-089`–`REQ-ORACLE-098`, `SPEC-ORC-015`, `SPEC-ORC-018`.
- Flows: [3.2](../../../../spec/03-operations/02-borrow.md) `BOR-006`, `BOR-022`; [3.5](../../../../spec/03-operations/05-liquidation.md) `LIQ-073`; [3.6](../../../../spec/03-operations/06-emergency-operations.md) `EMG-020`.
