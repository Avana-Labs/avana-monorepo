# Evidence of a local run, 2026-11-12

Output of `contract_checklist.py --all --check --results <run> --summary` on the wave 1 tree of 2026-11-12, with the results of one local `forge test --json` run: `FOUNDRY_PROFILE=lite` (optimizer off), fuzz 32 runs, invariant 8 runs at depth 16, fork and differential suites excluded by the profile, Halmos checks not run by forge (the recorded logs in `docs/audit/halmos/results/` are read), 3,010 tests: 3,008 passed, 2 failed. Both failures come from the lite profile, not the code: `Lens.Surface` `test_TEST_247_everyFunctionIsView` reads `out/`, which the lite profile does not write, and `Lock` `test_TEST_060_exactCycleCost` asserts gas of the optimized build. CI's evidence job runs the same check on the ci profile's results.

| Contract | Verified | Failed | Not run | Unlinked | Out of scope | --check |
|---|---:|---:|---:|---:|---:|---|
| AvanaRoles | 191 | 0 | 0 | 0 | 10 | pass |
| Lock | 33 | 2 | 0 | 0 | 0 | FAIL (2) |
| AvanaTimelock | 215 | 0 | 1 | 2 | 12 | FAIL (3) |
| LPPriceMath | 15 | 0 | 0 | 0 | 0 | pass |
| SettlementMath | 23 | 0 | 0 | 1 | 0 | FAIL (1) |
| ParameterStore | 81 | 0 | 0 | 8 | 0 | FAIL (8) |
| MarketRegistry | 138 | 0 | 1 | 14 | 1 | FAIL (15) |
| LPOracle | 129 | 0 | 4 | 48 | 3 | FAIL (52) |
| DebtOracle | 138 | 0 | 1 | 5 | 2 | FAIL (6) |
| VaultToken | 78 | 0 | 0 | 2 | 0 | FAIL (2) |
| VaultTokenFactory | 59 | 0 | 1 | 0 | 0 | FAIL (1) |
| Collateralization | 227 | 1 | 15 | 8 | 0 | FAIL (24) |
| ClPricing | 133 | 0 | 0 | 25 | 2 | FAIL (25) |
| UniswapV3Integration | 103 | 1 | 4 | 49 | 1 | FAIL (54) |
| SlipstreamIntegration | 65 | 1 | 4 | 23 | 2 | FAIL (28) |
| AaveV3FlashSource | 16 | 0 | 1 | 1 | 0 | FAIL (2) |
| PositionProxy | 86 | 0 | 0 | 0 | 0 | pass |
| ProxyManager | 64 | 0 | 0 | 0 | 0 | pass |
| RiskModule | 193 | 0 | 8 | 35 | 3 | FAIL (43) |
| AaveAdapter | 212 | 0 | 9 | 11 | 0 | FAIL (20) |
| SwapRoutes | 52 | 0 | 1 | 8 | 2 | FAIL (9) |
| PayoutEscrow | 28 | 0 | 0 | 1 | 0 | FAIL (1) |
| LPVaultSwap | 252 | 0 | 24 | 25 | 0 | FAIL (49) |
| CoverageSpoke | 54 | 0 | 0 | 12 | 3 | FAIL (12) |
| Lens | 54 | 2 | 0 | 13 | 0 | FAIL (15) |
| FlashLiquidator | 21 | 0 | 1 | 0 | 0 | FAIL (1) |

### TEST rows on no contract checklist (52; 18 block --check)

- [ ] `TEST-001` [environment] All contracts — outside contracts/
- [x] `TEST-002` [environment] Aave V4 Hubs, Spokes
- [~] `TEST-003` [environment] External dependencies
- [x] `TEST-004` [environment] Deploy scripts, `packages/protocol`
- [ ] `TEST-005` [environment] Test harness
- [ ] `TEST-007` [environment] Test harness — outside contracts/
- [ ] `TEST-008` [environment] Test harness
- [ ] `TEST-009` [environment] All flows
- [ ] `TEST-207` [environment] `contracts/src`, CI — outside contracts/
- [x] `TEST-032` [access-control] All Avana contracts
- [x] `TEST-061` [unit] All Avana contracts
- [x] `TEST-177` [unit] All Avana contracts
- [ ] `TEST-076` [unit] Avana-deployed Spoke
- [x] `TEST-080` [fuzz] All Avana contracts
- [ ] `TEST-082` [environment] Test harness
- [x] `TEST-092` [invariant] All Avana contracts
- [ ] `TEST-103` [invariant] Aave Hub, Borrow Spoke
- [ ] `TEST-110` [fork] Deployment, upgrades
- [ ] `TEST-111` [fork] Borrow Spoke, Hub · FLOW-003, FLOW-005
- [ ] `TEST-121` [fork] All contracts · FLOW-001…FLOW-009
- [ ] `TEST-126` [fork] All contracts · FLOW-006
- [ ] `TEST-127` [fork] Whole system
- [ ] `TEST-184` [fork] Borrow Spoke · FLOW-005
- [ ] `TEST-134` [deployment-check] Deploy scripts, `deployments/`
- [ ] `TEST-135` [deployment-check] Deploy scripts, `deployments/`
- [ ] `TEST-136` [deployment-check] Monitoring — outside contracts/
- [ ] `TEST-137` [deployment-check] Upgradeable contracts — outside contracts/
- [ ] `TEST-183` [deployment-check] Deploy scripts, `deployments/`
- [ ] `TEST-140` [keeper] Keeper — outside contracts/
- [ ] `TEST-141` [keeper] Keeper — outside contracts/
- [ ] `TEST-142` [keeper] Keeper · FLOW-005 — outside contracts/
- [ ] `TEST-178` [keeper] Keeper — outside contracts/
- [ ] `TEST-143` [off-chain] Ponder, Convex — outside contracts/
- [ ] `TEST-144` [off-chain] Ponder, web — outside contracts/
- [ ] `TEST-145` [off-chain] Convex — outside contracts/
- [ ] `TEST-146` [off-chain] `packages/protocol`, web — outside contracts/
- [ ] `TEST-147` [off-chain] Web — outside contracts/
- [ ] `TEST-148` [off-chain] Convex, web — outside contracts/
- [ ] `TEST-149` [off-chain] Web, Ponder, keeper — outside contracts/
- [ ] `TEST-297` [off-chain] `packages/protocol`, web — outside contracts/
- [ ] `TEST-253` [static-analysis] `contracts/`, CI — outside contracts/
- [ ] `TEST-254` [static-analysis] `contracts/src`, CI — outside contracts/
- [ ] `TEST-255` [static-analysis] `contracts/src`, CI — outside contracts/
- [ ] `TEST-256` [static-analysis] `contracts/src`, CI — outside contracts/
- [ ] `TEST-257` [static-analysis] `contracts/src`, CI — outside contracts/
- [ ] `TEST-258` [fuzz] `contracts/test/invariant/echidna/`, CI — outside contracts/
- [ ] `TEST-259` [fuzz] `contracts/test/invariant/`, CI — outside contracts/
- [ ] `TEST-260` [formal] `contracts/test/halmos/`, `contracts/test/symbolic/`, `contracts/test/invariant/` — outside contracts/
- [ ] `TEST-261` [static-analysis] `contracts/src`, CI — outside contracts/
- [ ] `TEST-262` [formal] `contracts/src`, CI — outside contracts/
- [ ] `TEST-263` [environment] CI, `contracts/security/`, `docs/audit/findings-register.md`
- [ ] `TEST-282` [unit] Deficit coverage and liquidation worked examples
