# Necessist

## What it proves

Necessist removes statements and method calls from the tests one at a time and reports each removal after which the test still passes: a setup step or an assertion the test does not need, which usually means the test checks less than its name says.

## How to run

Necessist is added to `script/install-security-tools.sh` and runs over `contracts/test/` with the Foundry framework at each layer gate.

## Scope

Every test file of the layer's contracts.

## How often it runs

Layer gate (decided 2026-11-10).

## Latest result

`mutation-gate.yml` run 43492416937 on `main` at `aa340fb` (dispatched 2026-11-13): 176 Necessist jobs finished (layers 2.1 to 2.6; their logs dry-ran 343 test files), the run is stuck queued for the rest. Necessist is report-only in CI.

The jobs report 6,108 removals after which the tests still passed, in 320 test files. The `<layer>.txt` files list 6,004 distinct lines because `grep ' passed$'` keeps only the last line of a statement that spans several lines; the triage reads each job's `<layer>.log`. 1,816 of the removals are Necessist's method-call removals (`vm.prank(x)` reduced to `vm`), each the same removal as the statement removal reported at the same place; they share that statement's class.

Triage, at `fda9bed`: [contracts/security/necessist-triage.json](../../../contracts/security/necessist-triage.json), with the file, test function, line at `aa340fb` and at `fda9bed`, the statement, the class and the reason; `approval` is `pending`.

| Class | Removals |
|---|---|
| noise: calls to test helpers that only check (assertions, or prank + expectRevert + the refused call) | 1,093 |
| noise: hostile conditions set by tests that pin an action is not affected by them | 57 |
| equivalent or harmless: `vm.prank` before `vm.expectRevert` (the test contract is refused with the same data) | 284 |
| equivalent or harmless: `vm.assume` filters in fuzz tests | 134 |
| equivalent or harmless: two AaveAdapter rows read one by one (refused-receiver array, permissionless repay) | 26 |
| real test gap | 0 recorded |
| not triaged | 4,514 |

Not triaged: statements that change state (setup calls, assignments, pranks not followed by an expected revert, warps, mocks, snapshots, helpers that act), which need each test read. By test family: `LPOracle*` 628, `LPVaultSwap*` 498, `MarketRegistry*` 487, `Lens*` 486, `ParameterStore*` 404, `DebtOracle*` 379, `AaveAdapter*` 269, `Collateralization*` 245, `SlipstreamIntegration*` 126, `UniswapV3Integration*` 119, `FlashLiquidator*` 98, `VaultToken*` 84, `SettlementMath*` 79, `LPPriceMath*` 59, `RiskModule*` 59, `VaultTokenFactory*` 54, `CoverageSpoke*` 51, `PegModuleRoute*` 38, `AvanaTimelock*` 36, `DexHops*` 35, `Lock*` 35, `PayoutEscrow*` 32, `WrapperThenDexRoute*` 31, `DexPathRoute*` 29, `AaveV3FlashSource*` 28, `RouteReads*` 28, `SwapRoutes*` 26, `PositionProxy*` 23, `ProxyManager*` 20, `SwapRouteBase*` 19, `ClPriceMath*` 7, `RouteMath*` 2. The JSON lists the count per test file.
