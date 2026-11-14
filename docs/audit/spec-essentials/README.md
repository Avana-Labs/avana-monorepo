# Spec essentials

The parts of the specification that every check in this folder tests against, on one page. Each row links to the spec text that binds; the spec wins where this page is shorter.

## The protocol

Avana lets a liquidity provider borrow approved debt assets, GHO first, against a liquidity position in a listed AMM pool, without taking the liquidity out of the pool. Aave V4 does the lending: an unmodified Aave V4 Hub and, as CDP Spoke, an unmodified standard Aave V4 Spoke hold the collateral reserves, the debt, interest, health factor and liquidation sizing. Avana separates custody from collateral accounting. One immutable LPVault per AMM protocol per chain holds the positions; one immutable Collateralization ledger per chain records how many liquidity units each position backs; a transfer-restricted vault token per market stands for those units one for one. The AaveAdapter mints vault tokens to the borrower's own PositionProxy for that CDP Spoke and market, which supplies them to the Spoke. Liquidation goes through one entry point, `LPVaultSwap.liquidate`, which calls Aave's `liquidationCall`, burns the seized vault tokens, debits the matching units from the ledger, unwinds that liquidity and swaps it into the debt asset over reviewed routes, with a recovery floor taken from the oracle value. Launch: Ethereum (Uniswap v3) and Base (Aerodrome Slipstream), each with an Avana Stable LP Hub. Source: [1.1 Protocol Overview](../../spec/01-architecture/01-protocol-overview.md), [1.2 Contract Relationships](../../spec/01-architecture/02-contract-relationships.md).

## Trust model and roles

| Topic | Rule | Spec |
|---|---|---|
| Who holds which power | Aave DAO, AvanaTimelock, Governance Safe (4-of-7), Emergency Guardian (3-of-5), Aave Protocol Guardian, Joint Configuration Safe (2-of-3), keepers, treasury Safe, risk service providers | [docs/governance/roles-and-responsibilities.md](../../governance/roles-and-responsibilities.md), [1.4 Permissions and Roles](../../spec/01-architecture/04-permissions-and-roles.md), [2.15 Governance and Timelock](../../spec/02-contracts/15-governance-and-timelock.md) |
| Immutable and upgradeable contracts | Immutable: vault tokens, VaultTokenFactory, every LPVault, Collateralization, Lock, PayoutEscrow, every PositionProxy, ProxyManager, swap routes, flash source. Upgradeable (UUPS, `APPLICATION_ADMIN` held only by the timelock): AaveAdapter, RiskModule, MarketRegistry, ParameterStore, LPVaultSwap, LPOracle, DebtOracle | `INV-052`, `INV-065`, `Q-226`, [1.3 Trust Boundaries](../../spec/01-architecture/03-trust-boundaries.md) |
| Blast radius | A faulty or hostile upgradeable contract is bounded by what the immutable contracts enforce: the LPVault returns a position only to its depositor of record, Collateralization rejects a seizure without the matching share and supply drop, borrowing stays within Aave's health factor and each `drawCap`. The AaveAdapter is trusted for custody of proxy positions and its radius is stated per Hub | `INV-018`, `Q-223`, [1.3 Custody trust and blast radius](../../spec/01-architecture/03-trust-boundaries.md#custody-trust-and-blast-radius) |
| Every privileged change through the timelock | Scheduled by the Governance Safe or the Aave governance executor (the two proposers), 5-day normal delay, 12-hour short delay for an immutable allowlist of tightenings, any canceller can cancel while it waits, 14-day grace | `INV-051`, `INV-068`, `INV-090`, `Q-228`, `Q-262` |
| Admin roles only for the timelock | A grant of `DEFAULT_ADMIN_ROLE` or `APPLICATION_ADMIN` to anyone else reverts | `INV-084`, `Q-259` |
| Stops never reach exits | Pause states, breakers and the address freeze never block repay, debt-free withdrawal, fee collection or liquidation | `INV-067`, `INV-081` |

## Critical invariants

Full list: [4.1 Global Invariants](../../spec/04-security/01-global-invariants.md) (99 `INV` rows).

| Area | Invariant | What it says | Checks that prove or test it |
|---|---|---|---|
| Backing | `INV-001` | A market's vault-token supply never exceeds the credited units of its open records plus its pending-settlement units, for any LPVaultSwap implementation | `FV-CUS-01`, `FV-CUS-26`, `FV-CUS-33`, `HYP-01`, `HYP-89`, `QNT-03`, `PROP-001`, `PROP-045`, `TEST-010`, `TEST-186` |
| Backing | `INV-002` | Every open record's position holds at least its credited units | `FV-CUS-02`, `PROP-002`, `TEST-016`, `QNT-TOPO-01` |
| Backing | `INV-008`, `INV-066`, `INV-080` | Per proxy, supplied shares equal credited units; mint equals credit in every pledge and re-credit; supply ≤ credited + pending after every transaction (one-sided check, `Q-257`) | `INV-008`: `FV-CUS-26`, `QNT-07`, `PROP-045`, `TEST-150`; `INV-066`: `FV-CUS-34`, `MATH-AR-42`, `HYP-89`, `HYP-93`, `PROP-054`, `PROP-065`; `INV-080`: `FV-CUS-01`, `FV-CUS-07`, `FV-CUS-19`, `MATH-AR-61`, `QNT-03`, `QNT-48`, `HYP-89`, `TEST-241` |
| Exclusive liquidation path | `INV-062` | `LPVaultSwap.liquidate` is the only liquidation entry point; any caller that is not frozen may use it (`Q-404`) | `FV-LIQ-01`, `FV-LIQ-03`, `HYP-67`, `PROP-022`, `PROP-053` |
| Exclusive liquidation path | `INV-011`, `INV-013`, `INV-014` | Vault tokens move only on the allowlisted paths, so a third party cannot take them through `liquidationCall` on a standard Spoke; every LPVaultSwap seizure debits exactly the measured share and supply drop (`Q-352`, `Q-281`) | `INV-011`: `FV-CUS-10`, `QNT-04`, `PROP-008`, `PROP-055`, `TEST-022`, `TEST-189`; `INV-013`: `QNT-09`, `TEST-150`; `INV-014`: `FV-CUS-15`, `FV-LIQ-03`, `MATH-ST-37`, `QNT-10`, `PROP-004`, `PROP-011`, `TEST-056`, `TEST-208` |
| Solvency | `INV-074` | Per debt asset, realizable collateral plus pending value plus funded coverage covers the debt after every transaction | `HYP-70`, `HYP-92` |
| Solvency | `INV-057`, `INV-076`, `INV-079` | Draw gate per debt asset; liquidation deficit bound; settlement-asset conservation across sequences | `INV-057`: `FV-CTL-99`, `QNT-TOPO-04`, `QNT-TOPO-T04`, `QNT-TOPO-T05`; `INV-076`: `HYP-72`; `INV-079`: `HYP-74`, `HYP-91` |
| Oracle conservatism | `INV-078` | The LPOracle values units at the fair composition at the oracle prices, the cheapest holding the position can reach | `MATH-AMM-V3-PRICE-01`, `MATH-AMM-SLIP-PRICE-01`, `HYP-71`, `HYP-AMM-V3-MANIP-01`, `HYP-AMM-SLIP-MANIP-01` |
| Oracle conservatism | `INV-087`, `INV-055` | Outside Live the served price is at most the accepted price and stress valuation is monotone; `latestAnswer()` never reverts and returns at least 1 | `MATH-UO-59`, `MATH-UO-65`, `FV-CTL-63`, `HYP-11`, `HYP-90`, `PROP-074`, `PROP-023`, `TEST-037`, `TEST-230` |
| Oracle conservatism | `INV-031`, `INV-059` | An outage is recorded only from read source timestamps; the first disagreement time is stored and bounds the liquidation pause | `INV-031`: `FV-CTL-65`, `FV-CTL-66`, `FV-CTL-70`, `FV-CTL-115`, `FV-CTL-129`; `INV-059`: `FV-CTL-67`, `FV-CTL-112`, `FV-CTL-123`, `PROP-049` |
| Lock | `INV-091`, `INV-054` | The Lock has exactly two members (AaveAdapter, LPVaultSwap); every external state-changing entry point of those two acquires it, and every value move of Collateralization and the LPVaults requires it held by the named caller (`Q-318`) | `PROP-037`, `PROP-075`, `TEST-060`, `TEST-270`, `HYP-91`, `FV-CTL-85`, `LockProperties` harness (Medusa, hevm QED) |

## Key formulas

Settlement formulas are in [2.11 Settlement math](../../spec/02-contracts/11-lpvaultswap.md#settlement-math); pricing in [2.10 Composition and the vault-token price](../../spec/02-contracts/10-lp-oracle.md#composition-and-the-vault-token-price).

| Formula | Spec | Statement | Z3 and SymPy checks |
|---|---|---|---|
| Recovery floor | `SPEC-LIQ-005` | `minRec = max(0, ⌈V × (10⁴ − s) / 10⁴⌉ − U − ε)`, with `V` the seized oracle value (`SPEC-LIQ-004`), `s` the effective slippage (`SPEC-LIQ-003`), `U` one raw unit of each released token in debt units, `ε` the per-reserve rounding allowance. Tested on `R + shortfall`; depends on no caller input | `MATH-ST-01`, `-06`, `-07`, `-09`, `-21`, `-27`, `-55`, `-56`, `-64`, `-81`, `-92`, `-94`, `-101`, `-105`, `-111`; `SYM-40`, `SYM-48` |
| Per-leg minimum | `SPEC-LIQ-018` | `minOutᵢ = max(1, ⌈Vlegᵢ × (10⁴ − sLeg) / 10⁴⌉ …)` on every route call, so each leg is bounded by its oracle value (`INV-083`) | `MATH-ST-63`, `-64`, `-66`, `-67`, `-73`, `-86`, `-101`, `-111`, `-123`; `SYM-48`; `HYP-85` |
| Avana fee share | `SPEC-LIQ-009` | `A = min(⌊G × avanaFeeShareBps / 10⁴⌋, S)`, `G = max(0, V − D)`, `S = max(0, R_f − D)`, `R_f = max(R, minRec)`; `avanaFeeShareBps` 2,000 (20 %), bounded 0–5,000 | `MATH-ST-04`, `-14`, `-16`, `-20`, `-26`, `-82`, `-92`, `-94`, `-101`, `-104`; `SYM-46`, `SYM-49` |
| Settlement gap | `SPEC-SET-001`, `SPEC-LIQ-019` | `g = max(0, D + A + B − Kf − R)` and `shortfall = max(0, minRec − R, g)`, paid by the caller up to `maxShortfall`; no Avana balance closes a gap (`INV-037`, `Q-397`) | `MATH-ST-14`, `-17`…`-25`, `-52`…`-60`, `-88`, `-92`, `-99`, `-100`, `-101`, `-104`, `-109`, `-121`, `-122`; `SYM-45`, `SYM-46`, `SYM-47`, `SYM-180` |
| Fair composition | `SPEC-ORC-007`, `SPEC-AMM-CORE-001` | The composition at the oracle price is the cheapest holding of the position over every reachable pool state; concentrated liquidity in range: excess `L·(s − s_O)²/s` | `MATH-UO-09`, `MATH-UO-52`, `MATH-ST-106`, `MATH-AMM-V3-PRICE-01`, `MATH-AMM-SLIP-PRICE-01`; `SYM-22`, `SYM-23`, `SYM-26`, `SYM-33`, `SYM-66`, `SYM-126` |
| Vault-token price | `SPEC-ORC-008` | `price8 = max(1, Σᵢ mulDiv(a'ᵢ, vᵢ, 10^dᵢ))` with `a'ᵢ = aᵢ − 1` (one raw unit off each floored amount) | `MATH-UO-02`, `-14`…`-18`, `-42`, `-51`, `-64`; `SYM-31`, `SYM-32`, `SYM-102`, `SYM-127` |

Each ID is a tag in [`docs/spec/05-verification/z3/`](../../spec/05-verification/z3/) or [`sympy/`](../../spec/05-verification/sympy/); results are in [z3](../z3/) and [sympy](../sympy/).

## Main design decisions

All 401 decisions: [4.4 Design Decisions](../../spec/04-security/04-design-decisions.md).

| Decision | Resolution |
|---|---|
| `Q-223` | Every borrower action goes wallet → AaveAdapter → PositionProxy → CDP Spoke; the proxy accepts calls only from the Adapter |
| `Q-306`, `Q-307` | The PositionProxy is a logic-free immutable account, one per (wallet, CDP Spoke, market), created by CREATE2 |
| `Q-226`, `Q-228`, `Q-259` | Which contracts are immutable and which upgradeable; one timelock holds every admin role; admin grants to anyone else revert |
| `Q-281`, `Q-352` | Every CDP Spoke is a standard Aave V4 Spoke with three required settings; liquidation exclusivity comes from the vault token's transfer rule |
| `Q-291`, `Q-321` | AMM-neutral core: one immutable LPVault per AMM protocol per chain; LPOracle as price-state core plus one pricing module per AMM protocol |
| `Q-318` | The Lock has exactly two members, one Lock per chain |
| `Q-257` | One-sided backing check (supply ≤ credited + pending) |
| `Q-397` | No settlement budget: no Avana balance funds a settlement gap |
| `Q-401` | No in-kind settlement; a refused payout goes to the PayoutEscrow |
| `Q-404` | Caller-funded liquidation through one entry point; flash funding lives in a periphery helper, outside the core |
| `Q-284` | One Coverage Spoke per (Hub, debt asset), funded by Avana and controlled by the Aave DAO |
| `Q-381` | No minimum debt; Avana's keepers pay liquidation gas |
| `Q-399` | Final circuit-breaker table: oracle and peg breaches block new debt; price-drop and seizure-surge signals are alerts only |
| `Q-240` | Implementation files ≤ 500 lines of code, interfaces ≤ 300 lines |

## Attack scenarios with the highest severity

All 197 scenarios: [4.2 Attack Scenarios](../../spec/04-security/02-attack-scenarios.md). Listed here: the scenarios whose impact, unblocked, is loss of collateral, unbacked debt or a protocol-wide halt (Critical or High in the severity scale of [docs/audit/README.md](../README.md#findings)).

| Scenario | Impact if unblocked | Protection |
|---|---|---|
| [`ATTACK-001`](../../spec/04-security/02-attack-scenarios.md#attack-001-duplicate-lp-collateral-registration) Duplicate LP collateral registration | Unbacked vault tokens; borrowing against nothing | `INV-005` custody keyed by (integrationId, positionKey); checks `FV-CUS-02`, `QNT-01`, `QNT-02`, `PROP-003` |
| [`ATTACK-002`](../../spec/04-security/02-attack-scenarios.md#attack-002-liquidation-outside-the-authorized-route) Liquidation outside the authorized route | Seized collateral detached from its records | `INV-011`, `INV-013`, `INV-062` |
| [`ATTACK-003`](../../spec/04-security/02-attack-scenarios.md#attack-003-pledge-of-a-third-partys-nft) Pledge of a third party's NFT | Theft of the victim's position | Depositor of record is the wallet that transferred the position (`INV-007`) |
| [`ATTACK-009`](../../spec/04-security/02-attack-scenarios.md#attack-009-unbacked-mint-through-a-position-modification-flow), [`ATTACK-011`](../../spec/04-security/02-attack-scenarios.md#attack-011-unbacked-mint-through-the-minters-upgrade-path) Unbacked mint | Unbacked vault tokens up to each `drawCap` | `INV-009`, `INV-066`, `INV-080`, Hub `addCap` |
| [`ATTACK-019`](../../spec/04-security/02-attack-scenarios.md#attack-019-detaching-vault-tokens-from-their-nft-records), [`ATTACK-020`](../../spec/04-security/02-attack-scenarios.md#attack-020-vault-token-liquidity-leaving-through-hub-share-transfers-draws-or-sweep) Vault tokens detached from records or leaving the Hub | Unliquidatable debt; stranded positions | `INV-003`, `INV-011` |
| [`ATTACK-023`](../../spec/04-security/02-attack-scenarios.md#attack-023-hostile-aaveadapter-calls-liquidationcall-as-an-allowed-holder), [`ATTACK-122`](../../spec/04-security/02-attack-scenarios.md#attack-122-hostile-aaveadapter-upgrade) Hostile AaveAdapter | Borrowing up to each `drawCap`; per-proxy backing broken | `INV-018` blast radius, 5-day delay, cancellers, exits inside the delay (`TEST-130`, `TEST-210`) |
| [`ATTACK-025`](../../spec/04-security/02-attack-scenarios.md#attack-025-hostile-lpvaultswap-debits-a-healthy-accounts-records), [`ATTACK-026`](../../spec/04-security/02-attack-scenarios.md#attack-026-hostile-lpvaultswap-seizes-and-keeps-vault-tokens) Hostile LPVaultSwap | Debit of healthy accounts; seized tokens kept | Collateralization's own snapshots (`INV-014`), reconcile on exit (`INV-058`), `TEST-131`, `TEST-154` |
| [`ATTACK-032`](../../spec/04-security/02-attack-scenarios.md#attack-032-credit-line-drain-through-a-malicious-aaveadapter-or-proxy-upgrade) Credit-line drain through an upgrade | Every credit line drained up to each `drawCap` | Timelock, `drawCap`s, `INV-057` |
| [`ATTACK-040`](../../spec/04-security/02-attack-scenarios.md#attack-040-flash-loan-manipulation-of-the-vault-token-price), [`ATTACK-051`](../../spec/04-security/02-attack-scenarios.md#attack-051-common-mode-feed-error-passes-the-agreement-and-twap-checks) Price manipulation or common-mode feed error | Overvalued borrowing | Fair composition at oracle prices (`INV-078`), feed agreement, TWAP consistency, second source |
| [`ATTACK-076`](../../spec/04-security/02-attack-scenarios.md#attack-076-one-wei-donation-dos-on-zero-balance-checks) One-wei donation on zero-balance checks | Protocol-wide liquidation halt | Measured deltas instead of zero-balance checks; the flash source forwards only what the Pool delivered |
| [`ATTACK-092`](../../spec/04-security/02-attack-scenarios.md#attack-092-cross-contract-reentrancy-during-settlement) Cross-contract reentrancy during settlement | Fees or liquidity taken twice; mint without a record | The Lock (`INV-054`, `INV-091`) |
| [`ATTACK-120`](../../spec/04-security/02-attack-scenarios.md#attack-120-cdp-spoke-upgrade-or-configuration-change-that-reopens-third-party-seizure), [`ATTACK-155`](../../spec/04-security/02-attack-scenarios.md#attack-155-third-party-seizure-through-spoke-configuration-on-a-standard-spoke) Spoke change that reopens third-party seizure | Seizure with no ledger debit | Transfer rule refuses the move; drift check on every Avana entry (`CONFIG_DRIFT`) |
