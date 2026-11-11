# Contracts build to-do (josue-todo.md section 2)

Working list for writing the 25 hand-written contracts, test first, one at a time. Temporary: deleted when section 2 closes. Handoff at the end: section 2.7 of `josue-todo.md` (LIFECYCLE links), then section 3.

## Decisions for this build

| Topic | Decision |
|---|---|
| Coverage Spoke | Avana writes it (`src/coverage/coverage-spoke/CoverageSpoke.sol`); `ICoverageSpoke` moved to the same folder; `CoverageSpoke.conf` added. |
| "0 issues" | Zero untriaged findings. Real findings are fixed. A false positive goes into `security/*-triage.json` with a reason and `"approval": "pending (Josue)"`, and is listed in [Josue triage review](#josue-triage-review). Josue decides on the whole list once, after all 25 contracts; until then a pending entry lets the gate pass. |
| Triage approval | Decided 2026-11-10: Josue approved every triage entry and inline suppression recorded so far (218 entries, 151 suppressions) by pattern. A future entry in an approved pattern (unused error or import for `@inheritdoc` or a later contract, view-only calls before writes, bounded loops, returns measured by balance delta, assembly for ERC-7201 or transient slots, specified timestamps, analysis artefacts of abstract facets, divide-before-multiply and cyclomatic complexity in ported AMM math with a differential test) is accepted with `"approval": "approved by pattern"` once the independent review agrees; a new pattern or a higher-severity detector comes to Josue individually; unused-error entries are removed when their contract lands. |
| Testing additions | Decided 2026-11-10: fast tier adds Semgrep (smart-contract rules) and 4naly3er under the same triage gate; CI adds a per-contract branch-coverage minimum (`forge coverage`) and a storage-layout check for every UUPS contract (OpenZeppelin Upgrades validation plus a layout diff against the last release); each layer gate adds Foundry-suite mutation testing (`slither-mutate`) and Necessist; before audit, properties move into one Chimera harness (Echidna, Medusa, Foundry invariants, Halmos) and each layer gets a 24-hour Echidna and Medusa campaign with the corpus kept and replayed in CI. |
| Option C follow-ups | Decided 2026-11-11: the public flash liquidation helper is freeze-protected (REQ-MREG-020 set); the SPEC-LIQ-020 deleverage example uses the premium the Pool charges (φ = 1,037,962, assetOut = 19,237,965); LPVaultSwap `POST_CALL_GAS` is 10,000; the 2.11 rewrite's design calls stand as written (keeper selector names kept for the committed-operator registry, listing check unchanged, helper reads `maxFlashFeeBps` and checks the recorded Hub, residues count zero toward recovery, `settlePending` dust to `feeRecipient`, sub-share carry, `minAmounts` kept). |
| Tooling decisions | Decided 2026-11-11: the Decurity Semgrep smart-contract rules are used locally and in CI (licence handled by Josue); the new Semgrep and 4naly3er findings and excluded detectors go to an independent review agent first, which approves those in approved patterns and brings new patterns to Josue; the ParameterStore logic contracts get a delegated-only guard like MarketRegistry's, with `abi.encodeCall` at `ParameterStoreOracle.sol:93`, in the ParameterStore fix batch. |
| Later decisions (2026-11-11) | The Aave V3 Pool behind the flash source is freeze-protected: MarketRegistry reads it from `IFlashSource(flashSource).LENDER()` (MarketRegistry fix batch). ParameterStore refuses a `PoolTwap` second source or standby for a debt asset with a DebtOracle (ParameterStore fix batch). The unused registry error `KeeperFloor` is deleted and its four LIFECYCLE anchors updated (MarketRegistry fix batch). VaultToken naming: symbol `avLP-<marketId>`, name carries the full description (chain, AMM, pair, fee tier, range, market ID), enforced in the listing checklist and spec 2.4. CL LPVault review: all fixes applied (CL-01 exact sqrt above 2^64 with SPEC-ORC-009 and its Z3 model first, CL-02 generation check, CL-03 spacing ≤ 6,931, CL-04 AaveAdapter as Lock holder for `collectFees`, spec points S1–S9), Slipstream compiled at 1,000 optimizer runs in its own profile with matching Certora confs. LPOracle evaluation gas (~460k measured with the real ParameterStore) is re-measured and compared with reference oracles before any design change. |
| Oracle gas (2026-11-11) | Measured: a cold LPOracle `latestAnswer` (what Aave reads) costs 576k gas against Aave V4's 22k for a Chainlink reserve. Josue chose to optimize the whole price-read path now, as launch work, keeping every pricing and safety rule: remove repeated work (duplicate feed and config reads, repeated normalisation and calculations), precompute immutable market data (token decimals, pool identity, range bounds, scaling constants), keep valuation independent of depositor count, and use an assembly decoder and fewer hops. No stored-price caching and no weakened freshness, deviation or rounding check for gas; a version-guarded cache of governance config that falls back to a live read on any mismatch is allowed only if it is exact, and is reviewed separately. Acceptance: benchmarks of the real Aave flows (borrow, withdraw, liquidation) at the maximum supported collateral and debt reserves, fallback oracle paths included, judged on the full worst-case transaction; a CI gas-budget test guards the result. Done before contract 13. |
| Helper and DebtOracle review (2026-11-11) | All fixes approved. Helper: FL-01 the helper also pulls up to the caller's `maxShortfall`, approves X plus the shortfall and returns the unused part; FL-02 everything leaving the operator Safe per call (top-up, premium, shortfall) is capped by `MAX_TOP_UP_BPS` of the debt actually repaid, and the loan never exceeds what the liquidation needs; FL-03 a permissionless claim on the public helper sends escrowed credits to `feeRecipient`, and the REQ-HELPER-010 reasoning is corrected; 3.5 LIQ-037/039/040/084 aligned with REQ-HELPER-004…008. GHO-debt liquidations borrow from the GHO flash minter (ERC-3156, fee read live and capped by `maxFlashFeeBps`); other assets use the Aave V3 Pool; confirmed on a fork once archive RPCs exist. DebtOracle: INV-098 corrected to the Aave sentinel behaviour (repayment paused while the sequencer is down, per REQ-ORACLE-099); stress rise capped at 5,000 bps in code (DO-03); served timestamps follow the served route (DO-01); last good `debtStressRiseBps` kept on a failed read; the other 2.10 contradictions fixed (REQ-ORACLE-096 vs INV-030, INV-030 vs REQ-ORACLE-093, REQ-ORACLE-091/080/081). |
| Repo setup and licence (2026-11-11) | All 17 setup changes from the conventions research are adopted (fork-block pins in code, `.env.example`, CI supply-chain hardening, fork tests skipped on outside PRs, size margin check, `SECURITY.md`, CODEOWNERS, changelog and tag policy, gas snapshots, a folder per governance operation, deploy Makefile, audit-report folder, tool version files, pre-commit hook, PR template, address library, keeper env naming). The six interface files copied from Aave V4 are rewritten in house as minimal interfaces with the same ABI. Licence: Avana source files carry BUSL-1.1 headers (`LICENSE`: Licensor Avana Labs; Change Date the earlier of three years after the Ethereum mainnet launch or four years after first public distribution; Change License MIT; no Additional Use Grant). A governance-set earlier date, the Additional Use Grants and the third-party licence questions go to counsel (`LICENSING.md`; questions kept outside the repo). |
| Step 2 decisions (2026-11-11, after the restart) | **Triage:** every entry pending Josue (230: groups A–Y and the reviewed CL math, LPOracle and excluded-detector entries) approved; each group is now an approved pattern, so a future finding of the same kind gets "approved by pattern". **LPOracle second source:** an out-of-range second-source word marks that token's second source unconfirmed (bit 16) instead of failing the read; it blocks new borrowing and withdraw-with-debt only; the primary price is computed and served as normal and its freshness, Cached and Expired rules apply unchanged; a second-source error alone never starts, resets or extends a primary failure or grace timer; repay and liquidation are not blocked by it. `latestAnswer()`, `getPriceState()` and `poke()` share one primary-price computation, and the confirmation flag is a separate permission that every borrow path enforces on-chain. The ParameterStore setters also reject invalid second-source configuration; the LPOracle keeps its own check for upgrades. Tests: the kept failing test, plus an invalid second source with a stale primary, repeated pokes and recovery, comparing prices at the same state. No second-source reads on the served views. **Token decimals:** stored at listing; every `poke()` re-reads `decimals()` of each token (and feed decimals wherever they are stored); a mismatch or failed read marks the configuration invalid, which blocks new borrowing, withdraw-with-debt and liquidation at that valuation, while repay and debt-free exits stay open; changed decimals are never adopted automatically (governance review, then recovery); risk-increasing actions require a successful verification within a maximum age, so a stopped keeper cannot leave the window open. This is delayed detection: a transaction between a token upgrade and the next poke can still use the old decimals. **Poke floor:** `POKE_MIN_GAS_FLOOR = 900,000` provisionally; calibration on a fork benchmark is a launch requirement; the floor is the gas remaining at its enforcement point, gas starvation must never commit an oracle-failure transition, and transaction gas limits must also cover the work before that point. **PROP-066:** the `getAccountGateStatus` exclusion stays and a second rule proves the status view changes no state and that its pause read reaches only `pauseState`/`pauseReason`, never `borrowAllowed` or another gate result; the PROP-066 text names it. **PositionManagerApproved:** proved by construction and removed from the runtime drift reasons (REQ-RISK-088, `DriftReason`) once verified: every approval route of the pinned Spoke, direct and by signature, is checked so that no signature can authorize a manager for a proxy (the missing ERC-1271 alone is not the proof); the proxy has no arbitrary call, delegatecall, batching or upgrade path that could approve one; tests and formal invariants show an unapproved manager stays unapproved across every permitted Avana action; upgrade detection binds the actual implementation behind an upgradeable Spoke, not the proxy's code, and the same applies to upgradeable Avana components that control the proxy; an implementation change needs revalidation. **Status fallback:** every reserve field is `NO_RESERVE`, a `statusUnavailable` flag is set, `borrowAllowed` and `withdrawWithDebtAllowed` stay false; the app shows "Risk status unavailable. Refresh and try again."; the spec lists the full fallback; a regression test forces it and checks every field. **`_loadSeed` duplicate check:** kept; the branch is recorded as unreachable through today's call paths (checkConfig and initialize enforce it first) with its reason, tests keep the entry-point rejections, and the justification is revisited whenever the initialization or upgrade flow changes. |
| Step 3 decisions (2026-11-11) | **Market-count bound:** the MarketRegistry caps the count the chain-wide `checkConfig` re-run actually traverses (today `1..marketCount`, so the cap limits lifetime listings, closed markets included; document this). The cap is enforced at registration, before a market can enter the loop, with no listing path that bypasses it. N is not chosen before measuring: it is sized on a fork from the most expensive ParameterStore setter, the worst supported market configuration and cold reads, with substantial headroom below the target chain's transaction gas limit; calibration is a launch requirement and is re-validated whenever an upgrade raises `checkConfig` cost. When the lifetime limit becomes a practical constraint, move to a registry-kept list of configured markets plus the cap, so retired markets leave the validation set. **Slither low-level-calls in ParameterStoreAdminRiskLogic (`_reportsAvana` 8d8edc33708b1612, `_word` 6ad16bee58e4f4b8):** approved for these two call sites only, with no new approved pattern, and recorded only after review confirms: the intended targets and selectors; failed calls and short responses cannot yield a valid configuration; returned words are type- and range-checked (length alone is not validation); an oversized response cannot cause excessive return-data copying; and tests cover revert, short, long and oversized responses. The approval names the reviewed file hash. **AMM integration contracts (MarketRegistry):** the governance record `recordIntegrationContracts` stays for launch, with: an explicit finalize step, and no settlement route accepted for an integration until its set is recorded and finalized; the record keyed to the chain, the integration address and version, and pool identity, so a replacement integration needs a fresh record and validation; an addition applies at once, re-checking existing routes so a newly protected address cannot leave an approved unsafe route usable; mandatory release checks (deploy and fork tests) comparing the record with the integration's actual position manager, factory, singleton and every other required protected address, run against the exact governance payload (non-zero with code is not enough). Residual trust: an incomplete record weakens the route and freeze protections. `ammContracts()` on `IAmmIntegration` is reconsidered at the next integration-interface revision, not committed now. **USDT GSM backup:** refused; a GSM route whose input token has a fee switch is never listed, so the USDT→GHO backup is a Curve route. **`DEBT_MARK_GAS_FLOOR` = 50,000 is provisional** (a post-failure detection threshold, not the read's budget; EIP-150 keeps about 1/64 at each call boundary, so nested calls can run out while the caller still has gas). It is final only after fork evidence: a benchmark of the maximum supported account (every active collateral and debt reserve, cold oracle reads, expensive fallback paths); a sweep of transaction gas limits that starves the Spoke and the nested oracle calls, where no case leaves a stale debt-free mark usable for authorization; genuine oracle reverts tested apart from gas exhaustion; repeated after any change to oracle cost or supported reserve counts. The 576k LP read and 3.15M account read figures are not confirmed bounds until then. Launch requirement. **Slither `ef24f14ff0f0c97f` (`markDebtFree`)** re-confirmed after the `InsufficientGas` change. |
| Test depth target (2026-11-11) | Avana matches Aave V4's test depth: at least 6 lines of test code per line of contract code (Aave V4 at `a3ef63e`: 62,723 test / 10,435 src code lines = 6.0×; Avana today: 43,615 / 20,378 = 2.1×). Counted as non-comment, non-blank Solidity lines, measured per contract folder and for the whole repo. Lines are the measure, not the goal: every added test checks a spec rule, an invariant, a boundary or an attack scenario; mutation survivors (slither-mutate, Gambit) and Necessist findings at the layer gate show that tests catch faults instead of padding the count. Applies to the remaining contracts as they are written and to the final spec-conformance phase for the merged ones. |
| Launch configuration (2026-11-11, from `deployments/proposed/launch-config-notes.md`) | These choices set Avana's own testnet and fork runs and the proposal Avana brings; the production pools, ranges, debt assets, caps and routes are set by LlamaRisk (risk service provider) and the Aave DAO in the listing and funding payloads. Allowed-route GHO depth is about $1.0M on Ethereum and about $55k on Base (no backup route possible on Base). **Base launches with USDC as its debt asset** (GHO later); this changes the launch shape in the ARFC and spec ("GHO as the first debt reserve on each chain"): Base needs a USDC DebtOracle, a USDC credit line, a USDC Coverage Spoke and routes into USDC. **Ethereum keeps GHO** with draw caps sized to measured route depth at listing (below the 2M line); the USDC GSM's capacity is measured on the fork and considered as the primary route; no new route families. **Ethereum launch market:** Uniswap v3 USDC/USDT 0.01% only (`0x3416cF6C708Da44DB2624D63ea0AAef7113527C6`). **Range: full range** on both chains (Josue: reach as many LPs as possible). **GHO listing:** a fixed-price debt asset that is not a pool token of any market is exempt from REQ-CONFIG-021's three routes; its feed is used for monitoring. **USDT probe:** a combined probe kind checks `basisPointsRate() == 0` and `paused() == false`. **SVR proxies** are accepted as alternate and standby routes (they cover proxy or aggregator failure; independence comes from the second source). **Second source for USDC and USDT:** an oracle-network source (read allowlisting arranged before launch) with a pool TWAP as standby; the spec names the TWAP's quote token. **Base launch pool:** the Initial-generation Slipstream USDC/USDT pool (`0xa41Bc0AF…fcD1`) now; the Aero pool is added once Aerodrome publishes its addresses. **Slipstream generations:** keep four (Aero addresses filled in and fork-checked once published). **Curve routes:** legacy (non-NG) Curve pools are allowed, which needs new route code, pinned per-pool checks and added audit scope (settlement routes, 2.12). **Spec examples** in REQ-CONFIG-021/023 are aligned to the registry (82,800 s Ethereum USDC heartbeat, 1,800 s margin), with any model using them re-run. **Base USDT probe** is set per chain from the fork check: the combined probe only for the functions the bridged token has, `None` if it has neither. |
| Slow tools | Changed 2026-11-10: the slow tier (Echidna, Medusa, hevm, Mythril, SMTChecker, plus Certora mutation testing with `certoraMutate` on every contract whose rules verify) runs once at the end of each layer (2.1 … 2.6), over every contract of the layer, at full budget. Per contract the gate is unit/fuzz/invariant tests, Halmos, the fast tier and an independent review. Contracts 1–3 also ran the slow tier per contract. |
| Checkpoints | No git until the GitHub repository exists. Each contract ends with a gate report in the progress log below. |
| Parallel work | Since 2026-11-10: contracts with no unfinished dependency are written in parallel, up to four at a time, each by an agent in its own copy of `contracts/`; the results are merged, checked and reviewed here one by one. The independent review starts as soon as a contract compiles. |

## What exists already

- Every interface, event, error and type under `contracts/src/` (194 files); `forge build` is clean.
- `AvanaRoles.sol` and `LockSlot.sol` (constants), with Echidna harnesses.
- 26 Certora confs and 27 CVL specs, already bound to the interface ABIs (`check-methods.py`).
- Spec-stage models: Z3, SymPy, Hypothesis, Quint, the simulation, and the three `audit/formal-verification/*` suites.
- Spec IDs to cover: 287 `TEST`, 86 `PROP`, 99 `INV`, 197 `ATTACK`.
- `out-aave/` built from the pinned Aave V4 commit.
- Toolchain: forge 1.9.0, solc 0.8.28, Slither, Aderyn, solhint, Mythril (`.venv-mythril`), Halmos, Echidna, Medusa, hevm, certoraRun, z3, Java.

Missing: `test/utils/` (base test, fixtures, mocks, harnesses), every implementation, and `CERTORAKEY` (Certora runs only type-check, `--compilation_steps_only`, until the key is set).

## Phase 0: before contract 1

- [x] **Per-contract checklist** `spec/05-verification/contract_checklist.py`: `--list` shows the counts for every contract; `<Contract>` prints its REQ/SPEC IDs, TEST rows, cross-cutting TEST rows, PROP rows (with tool), INV and ATTACK rows, each ticked when a tag in `contracts/test` or `contracts/certora` links it; `--check` exits 1 while a REQ/SPEC, TEST or PROP is unlinked (gate step).
- [x] **Test base** `test/utils/AvanaTest.sol`: actors, the 1.5 and 5.1 fixture values, bound helpers.
- [x] **Aave V4 fixture** `test/utils/fixtures/AaveV4Fixture.sol`: Aave's batches from `out-aave/` in the orchestration's order, the Safe Singleton Factory, `LiquidationLogic` CREATE2-deployed and linked into `SpokeInstance`, the AccessManager, both configurators, the TreasurySpoke, the Stable LP Hub, the "Uniswap v3 Stable" CDP Spoke and the Lend Spoke with their own AaveOracles; every Aave role ends with `aaveDao`. Aave's role procedures run unchanged through `aave-deploy/AvanaAaveV4Roles.sol` (built only by the `aave` profile; the release bytecode hashes are unchanged).
- [x] **Manifest** `test/utils/Deployments.sol`: writes and reads the Aave section of `deployments-local/<chainId>-<label>.json`.
- [x] **Differential harness** `test/differential/`: exact Python reference (stdlib integers and fractions), the FFI base, and a harness check against OpenZeppelin `mulDiv`.
- [x] **Coverage Spoke** interface moved to `src/coverage/coverage-spoke/`; `CoverageSpoke.conf` added; smt profile, `certora/README.md`, `contracts/README.md` and the CVL spec header updated.
- [x] `certora/README.md`: `IDebtBuyRoute` and routes 4–5 removed.
- [ ] `foundry.toml` `[profile.smt]` and `certora/conf/LPVault.conf` name `src/custody/lp-vault/LPVault.sol`; settled at contract 14 (shared abstract base or not).
- [ ] **Added with the contract that first needs it:**
  - [ ] Mocks (Chainlink feed and sequencer feed, the Uniswap v3 and Slipstream factory/pool/position manager, GHO, Aave V3 Pool and ACLManager, GSM, LitePSM, swap pool, hostile tokens).
  - [ ] `InvariantChecks`, `PriceStateDriver`, `AvanaFixture`, `MarketFixture`.
  - [ ] GHO debt reserve, Lend Spoke credit line and Coverage Spoke in the Aave fixture; TEST-002 and TEST-004 are linked for the parts that exist (Hub, Spokes, oracles, library link, roles, manifest) and gain the rest then.
  - [ ] `mpmath==1.3.0` in `contracts/.venv` for the CL pricing reference (contract 13). It is not in the local cache, so installing it downloads it from PyPI (about 0.5 MB); Josue approves the download at that step.

Phase 0 gate (2026-11-10): `forge build --force -D warnings` clean; `forge test` 6/6; differential profile 1/1 (256 runs); size check pass; `trace.py` 0 errors; `security-fast.sh` every step passed (Slither 0 findings; Aderyn 292 `unused-error` findings, all already triaged for interfaces whose implementations are not written yet; they clear as each contract lands).

## The per-contract loop (test first)

Each contract goes through these steps in order. A step that fails sends the contract back to the step that caused it.

1. **Read and extract.** Run the checklist generator on the contract's spec page. Read the page, its interface pieces, its LIFECYCLE walkthrough, the flows in spec section 3 that call it, and the Z3/SymPy/Hypothesis models of its math.
2. **Design check before code.** Estimate the size and split it along the interface pieces when it would pass 450 lines. List the storage layout (ERC-7201 namespaces for UUPS contracts), every external call, reentrancy entry, rounding direction and failure mode. Check the design against the `ATTACK` rows for this contract. A gap or contradiction in the spec stops the loop: the spec and its Z3 model are fixed first, then the code.
3. **Write the tests (red).**
   - Unit tests: one `test_TEST_NNN_…` per `TEST` row, with `// TEST-NNN verifies:` tags.
   - Fuzz tests for every formula, rounding direction and bound.
   - A Halmos `check_PROP_NNN_…` for each Halmos `PROP`.
   - An Echidna/Medusa `<Contract>Properties` harness with one property per `INV` on the page.
   - The Certora conf compiles against a stub.
   - For the math libraries, golden vectors taken from the Z3/SymPy models.
4. **Implement (green).** Write exactly the spec page, with `/// @custom:spec <IDs>` on every function, checks-effects-interactions, and errors and events from the interface. Use OpenZeppelin 5.1.0 and Solady as pinned. Aave V4 is used unmodified and never copied. Upgradeable contracts use UUPS with `_disableInitializers` and `_authorizeUpgrade` gated by `APPLICATION_ADMIN`.
5. **Gate (all must pass):**
   - [ ] `forge build --force -D warnings`, and `forge test` green (unit and fuzz at 1,000 runs; the 10,000-run CI fuzz on the contract's math)
   - [ ] `check-file-size.sh` (≤ 500 lines per contract, ≤ 300 per interface)
   - [ ] `trace.py`: 0 errors, and every ID from step 1 linked to a test or `PROP`
   - [ ] `security-fast.sh`: fmt, lint, solhint, Slither, upgradeability, Aderyn and cvl, with zero untriaged findings
   - [ ] Halmos: every `check_` passes
   - [ ] Echidna/Medusa harness and Halmos checks written (the slow tier runs them at the layer gate)
   - [ ] Certora conf: `--compilation_steps_only` without a key, and a full run once `CERTORAKEY` is set
   - [ ] Differential run against the Python models (math contracts)
   - [ ] Adversarial review by a fresh subagent that gets only the spec page and the code, not my reasoning; every finding is fixed or answered in the log
6. **Record.** Tick the contract, add a row to the progress log (tests, properties, findings, triage entries waiting for approval), and stop for Josue's review before the next contract.

**Layer gate**, after each of 2.1 … 2.6: full-budget slow tier over everything written so far (Echidna, Medusa, hevm, Mythril, SMTChecker); integration tests across the layer's contracts on the local Aave V4 fixture; `run_all.sh` and the three `audit/formal-verification/*/run.sh` still pass; size check over everything.

## Josue triage review

Every triage entry added during this build, for one decision at the end of section 2. Each entry is in the named file with `"approval": "pending (Josue)"`. Approve, or reject and the contract is reworked.

| # | Tool | Contract | Finding | Location | Why it stays | Decision |
|---|---|---|---|---|---|---|
| 1 | Slither | Lock | `assembly` (informational) | `Lock._holder()`, `security/slither-triage.json` | One `TLOAD` of the fixed ERC-7201 slot `HOLDER_SLOT` (`REQ-LOCK-002`); Solidity 0.8.28 cannot place a transient variable at a chosen slot. Covered by TEST-060, PROP-037 (Halmos), LockProperties (Echidna, Medusa, hevm QED). | approved |
| 2 | Slither | Lock | `assembly` (informational) | `Lock._setHolder(address)`, `security/slither-triage.json` | One `TSTORE` of the same slot; same reason and coverage. | approved |
| 3 | Slither | AvanaTimelock | `timestamp` (low) | `isOperationExpired`, `security/slither-triage.json` | Expiry is defined on `block.timestamp` (SPEC-GOV-013, a 14-day window); validator drift of seconds cannot matter. Covered by TEST-194, TEST-212, PROP-058. | approved |
| 4 | Aderyn | AvanaTimelock | `eth-send-unchecked-address` (high) | `execute`, `security/aderyn-triage.json` | OpenZeppelin timelock execution: target and value were fixed at scheduling and waited their delay in public; forwarding them is the timelock's job. | approved |
| 5 | Aderyn | AvanaTimelock | `eth-send-unchecked-address` (high) | `executeBatch` | Same as 4. | approved |
| 6 | Aderyn | AvanaTimelock | `unchecked-return` (low) | constructor `CANCELLER_ROLE` grants | `_grantRole` returns false only for a holder that already has the role (a proposer listed again as canceller); nothing to act on. | approved |
| 7 | Aderyn | AvanaTimelock | `unchecked-return` (low) | constructor `DAO_CANCELLER_ROLE` grants | Same as 6. | approved |
| 8 | Aderyn | AvanaTimelock | `unused-import` (low) | `IAvanaTimelockGovernance` | Used by `@inheritdoc`, which must name the declaring interface; Aderyn ignores NatSpec. | approved |
| 9 | Aderyn | AvanaTimelock | `unused-import` (low) | `IAvanaTimelockViews` | Same as 8. | approved |
| 10 | forge lint | AvanaTimelock | `costly-loop` (note), 3 inline suppressions | constructor, writes of `SHORT_ELIGIBLE`, the short list and the DAO-only set | Filling the two immutable sets is one storage write per pair, once, at construction. | approved |
| 11 | forge lint | AvanaTimelock | `require-revert-in-loop` (warning), 2 inline suppressions | `_grantRole` (`AdminRoleOnlyTimelock`, `PublicExecutionOnlyByToggle`) | The constructor's role loops reach `_grantRole`, whose checks must revert there too (REQ-ACCESS-153, REQ-ACCESS-144). | approved |

Not in this list: the 288 Aderyn `unused-error` entries accepted before the build. They are errors declared in interfaces whose implementation is not written yet, and they disappear as each contract lands.

## The 25 contracts

Paths are under `contracts/src/`. "Split" lists the planned implementation files for contracts expected to pass 450 lines; the final split is set in step 2 of the loop.

### 2.1 Shared core: foundations

| # | Contract | Implementation | Spec | Depends on (mock until written) | Formal targets |
|---|---|---|---|---|---|
| [x] 1 | AvanaRoles | `governance/roles/AvanaRoles.sol` (exists: constants) | 2.15 | — | Echidna harness exists; role-ID uniqueness tests |
| [x] 2 | Lock | `lock/lock/Lock.sol` | 2.16 | `LockSlot` | Certora `Lock.conf`, SMT, Echidna `LockSlotProperties` |
| [x] 3 | AvanaTimelock | `governance/timelock/AvanaTimelock.sol` (extends OZ `TimelockController`) | 2.15 | AvanaRoles | Certora `AvanaTimelock.conf`, SMT, Hypothesis `test_hyp_timelock`, Z3 `governance/` |
| [x] 4 | LPPriceMath | `oracle/lp-oracle/LPPriceMath.sol` (library) | 2.10 | — | Z3 `units-oracle/`, `amm-pricing/`; SymPy sym03/04/08; differential |
| [x] 5 | SettlementMath | `liquidation/lp-vault-swap/SettlementMath.sol` (library) | 2.11 | — | Z3 `settlement/`; SymPy sym05; formal-verification `fv_liq_01`; differential |
| [x] 6 | ParameterStore | `policy/parameter-store/ParameterStore.sol`; split: chain values, tighten, loosen, listing/initial, views | 2.9 | Timelock, AvanaRoles | Certora `ParameterStore.conf`, SMT, `fv_ctl_params` |
| [x] 7 | MarketRegistry | `policy/market-registry/MarketRegistry.sol`; split: hubs and listing, routes and standby, pause/freeze/breakers, wind-down and credit lines | 2.8 | ParameterStore, VaultTokenFactory (mock), integration (mock) | Certora `MarketRegistry.conf`, SMT, `fv_ctl_registry`, `fv_ctl_pause`, `fv_ctl_breakers` |
| [x] 8 | LPOracle base | `oracle/lp-oracle/LPOracle.sol` (abstract base: states, failover, second source, sequencer, grace, poke) | 2.10 | LPPriceMath, ParameterStore, MarketRegistry, mock feeds | Certora `LPOracle.conf`, SMT, `fv_ctl_oracle`, Hypothesis state machine |
| [x] 9 | DebtOracle | `oracle/debt-oracle/DebtOracle.sol` | 2.10 | same as 8 | Certora `DebtOracle.conf`, SMT |
| [x] 10 | VaultToken | `vault-token/vault-token/VaultToken.sol` | 2.4 | addresses of Adapter, LPVaultSwap, Collateralization (predicted) | Certora `VaultToken.conf`, SMT, `fv_token` |
| [x] 11 | VaultTokenFactory | `vault-token/vault-token-factory/VaultTokenFactory.sol` (Solady CREATE3) | 2.4 | VaultToken (the factory calls no integration) | Certora `VaultTokenFactory.conf`, SMT |
| [x] 12 | Collateralization | `custody/collateralization/Collateralization.sol`; split: adapter path, seizure, pending, debt mark, views | 2.3 | Lock, LPVault (mock), ParameterStore | Certora `Collateralization.conf`, SMT, `fv_backing`, `fv_list`, `fv_pending`, `fv_exposure`, `custody.qnt` |

### 2.2 AMM integrations

| # | Contract | Implementation | Spec | Depends on | Formal targets |
|---|---|---|---|---|---|
| [ ] 13 | CL pricing library and CL LPOracle | `oracle/lp-oracle/ClPriceMath.sol` (library) and `oracle/lp-oracle/LPOracleCL.sol` | 2.10, 2.20 | LPOracle base, LPPriceMath | Z3 `amm-pricing/`, Hypothesis `test_hyp_amm_pricing`, differential vs the mpmath reference (`TEST-037`), `fv_lpvalue` |
| [x] 14 | Uniswap v3 integration (LPVault) | `amm/uniswap-v3/UniswapV3Integration.sol` (plus a shared abstract base if chosen) | 2.2, 2.19, 2.20 | Collateralization, Lock, mock NFPM/factory/pool | Certora `UniswapV3Integration.conf` and `LPVault.conf`, SMT, `fv_lpvault`, `fv_amm`; fork tests |
| [x] 15 | Aerodrome Slipstream integration (LPVault) | `amm/slipstream/SlipstreamIntegration.sol` | 2.19, 2.21 | same as 14, four generations, gauge mock | Certora `SlipstreamIntegration.conf`, SMT; Base fork tests for every generation |

### 2.3 Flash source

| # | Contract | Implementation | Spec | Depends on | Formal targets |
|---|---|---|---|---|---|
| [x] 16 | Aave V3 flash source | `flash/AaveV3FlashSource.sol` | 2.11 | mock Aave V3 Pool and ACLManager, ParameterStore | Certora `FlashSource.conf`, SMT; `TEST-118` on fork |

### 2.4 Proxies

| # | Contract | Implementation | Spec | Depends on | Formal targets |
|---|---|---|---|---|---|
| [x] 17 | PositionProxy | `proxy/position-proxy/PositionProxy.sol` | 2.5 | — | Certora `PositionProxy.conf`, SMT |
| [x] 18 | ProxyManager | `proxy/proxy-manager/ProxyManager.sol` | 2.5 | PositionProxy | Certora `ProxyManager.conf`, `ProxyManagerIsolation.conf`, SMT |

### 2.5 Shared core: contracts that use the above

| # | Contract | Implementation | Spec | Depends on | Formal targets |
|---|---|---|---|---|---|
| [x] 19 | RiskModule | `policy/risk-module/RiskModule.sol`; split: pledge checks, borrow/withdraw checks, drift, views | 2.7 | ParameterStore, MarketRegistry, oracles, Collateralization, Aave V4 fixture | Certora `RiskModule.conf`, `RiskModuleDrift.conf`, SMT, `fv_ctl_gates`, Z3 `aave-risk/` |
| [ ] 20 | AaveAdapter | `policy/aave-adapter/AaveAdapter.sol`; split: user ops, collateral ops, settlement hooks, admin, views | 2.6 | everything above plus Aave V4 fixture | Certora `AaveAdapter.conf`, `AaveAdapterGates.conf`; `fv_solvency`, `fv_hub` |
| [x] 21 | Swap routes | `liquidation/settlement-routes/DexPathRoute.sol`, `WrapperThenDexRoute.sol`, `PegModuleRoute.sol` | 2.12 | mock pools, Curve, LitePSM | Certora `DexPathRoute.conf`, `WrapperThenDexRoute.conf`, `PegModuleRoute.conf`, SMT; `TEST-119`, `TEST-120` on fork |
| [x] 22 | PayoutEscrow (payout escrow) | `liquidation/payout-escrow/PayoutEscrow.sol` | 2.18 | hostile tokens | Certora `PayoutEscrow.conf`, SMT, `fv_liq_05` |
| [ ] 23 | LPVaultSwap | `liquidation/lp-vault-swap/LPVaultSwap.sol`; split: keeper path, permissionless, deleverage, pending, admin/keepers, views | 2.11 | SettlementMath, flash source, routes, escrow, Collateralization, Adapter, Aave V4 fixture | Certora `LPVaultSwap.conf`, SMT, `fv_liq_02` … `fv_liq_07`, `liquidation.qnt` |
| [x] 24 | Avana Umbrella (Coverage Spoke) | `coverage/coverage-spoke/CoverageSpoke.sol` | 2.14 | Aave V4 Hub (`eliminateDeficit`), DAO AccessManager | `CoverageSpoke.spec` (new conf), SMT, `fv_liq_05`. Also add its deployment step to `script/README.md`, which still lists Coverage Spokes as Aave's deployment |

### 2.6 Periphery

| # | Contract | Implementation | Spec | Depends on | Formal targets |
|---|---|---|---|---|---|
| [ ] 25 | Lens | `lens/lens/Lens.sol`; split by `ILensAccount`, `ILensPreview`, `ILensMarket`, `ILensRisk`, `ILensLiquidation` | 2.17 | everything | `fv_ctl_upgrade_lens`; previews equal Z3/SymPy worked examples |

Order notes:
- A contract is unit-tested against mocks of the neighbours it calls that are not written yet. Its integration tests are added at the layer gate where those neighbours exist.
- The Aave V4 Hub and Spokes are never mocked: contracts 12 and 19 to 25 run on `AaveV4Fixture`.
- 2.2 fork tests (Ethereum fork for Uniswap v3, Base fork for Slipstream) need archive RPCs from section 0 of `josue-todo.md`. Without them, only local tests run, and the fork tests stay open on this list.

## Open items carried by finished contracts

State as of 2026-11-11: main plus the unmerged branches w2oracle, w2risk, depthcoll, depthpstore and depthmreg. Done items were removed; decisions are in the Decisions table.

### Code fixes (decided, not yet done)

- Market-count cap in the MarketRegistry (Step 3 decision): enforced at registration before a market enters the `1..marketCount` loop, with no listing path that bypasses it; it limits lifetime listings, closed markets included (document this). Today `listCollateralMarket` sets `marketCount` with no bound (`MarketRegistryListingLogic.sol:102-131`), and the ParameterStore re-checks loop over it unbounded (`ParameterStoreOracle.sol:145,302`). N is sized on a fork later (see Fork work).
- AMM integration contract record (Step 3 decision): `recordIntegrationContracts` (`MarketRegistryHubsLogic.sol:186-208`) only appends. Add an explicit finalize step, with no settlement route accepted for an integration until its set is recorded and finalized; key the record to the chain, integration address and version, and pool identity, so a replacement integration needs a fresh record; an addition applies at once and re-checks existing routes. Release checks are under Deploy scripts.
- Bounded return-data reads: `_word` and `_reportsAvana` (`ParameterStoreAdminRiskLogic.sol:313,346`) and VaultTokenFactory `_readCapabilities` and `_readWord` (`VaultTokenFactory.sol:370,400`) reuse the bounded STATICCALL of `RouteReads.sol` (no full copy of a candidate's response). Tests for reverting, short, long and oversized responses on both contracts (depthpstore covers revert, short and long for the fee recipient only; no oversized case; nothing for the factory). Then record Slither `8d8edc33708b1612`, `6ad16bee58e4f4b8` (ParameterStore) and `f193056336ee06ef`, `250a89330c14ea04` (VaultTokenFactory) as approved (Josue, 2026-11-11) against the reviewed file hash, after the review confirms targets and selectors, failed or short calls give no valid configuration, words are type- and range-checked, and oversized responses cause no excessive copying.
- Public flash helper (Q-S2): the operator path accepts `flashAmount = 0` and takes the whole repayment from the committed operator's Safe. Today `FlashLiquidatorBase.sol:112-114` reverts `InvalidFlashAmount`; update `IFlashLiquidator.sol:33` NatSpec, REQ-HELPER-003 (`0 < F ≤ X`) and REQ-HELPER-013 (`F outside (0, X]`) in 2.11, and the flash-liquidator unit and fuzz tests.
- ParameterStore enforces `sequencer.gracePeriod ≥ max(twapWindow, secondSource.twapWindow)` in `setSequencer`, `setTwapWindow` and the second-source setters, with a spec rule (REQ-PSTORE-023 area) and a Z3 model.
- Borrowing requires a Chainlink round newer than the sequencer restart (`updatedAt > startedAt` of the sequencer feed), added to SPEC-ORC-021 (today it gates only on `startedAt + gracePeriod`) and the LPOracle and DebtOracle borrow gates.
- NatSpec: `IMarketRegistryRoutes.sol:18` says `debtAsset` must be an enabled debt reserve's asset; the code also accepts a listed token or an asset covered by a Coverage Spoke on the home Hub. Line 10 still says a liquidation flash-borrows the debt asset (stale after option C).
- NatSpec: `src/types/DriftReason.sol:22-23` drops "not paid to Avana's fee receiver" (`liquidationFee` must be 0; a fee pays Hub shares with no token transfer).
- NatSpec: `src/custody/collateralization/types/CounterKind.sol:7` says `marketUsd` is keyed by market id; it is keyed by vault token.
- Test: ParameterStore fee-recipient check through the `ProxyManager.predictProxy` branch (only the `ADAPTER()` branch is tested, `ParameterStore.Access.unit.t.sol:213-232`).
- Test: the ParameterStore Echidna harness covers Tighten and Loosen only (initcode limit); cover Listing, AdminOracle and AdminRisk (split harness or another route).
- Test: CoverageSpoke Echidna property with real-Hub yield; `CoverageSpokeProperties.sol` uses `MockCoverageHub` and its header still says "no yield in this model" while the property adds `ghostYield`. If the pinned Hub cannot be loaded, record that unit tests (`CoverageSpoke.unit.t.sol:648,673`) cover real-Hub yield.
- Test: REQ-LOCK-017 has no test or rule citing it.
- Test (to confirm): the contract 14/15 donation tests (`UniswapV3Integration.Donations.unit.t.sol`, `SlipstreamIntegration.Donations.unit.t.sol`) assert records and amounts; decide whether cap, credit and mint must also be asserted.
- Test (to confirm): a dedicated test for `FlashSourceSet` emission and for each new protected-set member (flash source `LENDER()`, integration contracts).
- Test: a MarketRegistry listing test with a real integration and price `integrationData` (the fixture `_marketDef`, `MarketRegistryFixture.sol:309-320`, leaves it empty against a mock).

### Spec text edits

- Liquidation fee is 0 with no alternative (a fee pays Hub shares with no token transfer): remove "or paid to Avana's fee receiver" from 2.1 REQ-HUB-003 (`01-avana-hub-and-spokes.md:148`), REQ-HUB-029 (:189), REQ-HUB-092 (:289), INV-093 (`01-global-invariants.md:175`), INV-029 (:81, also "a second Spoke … other than the fee receiver"), ATTACK-014 (`02-attack-scenarios.md:202-212`), 1.1 (`01-protocol-overview.md:140`) and 4.3 (`03-external-dependencies.md:43`).
- Dust third-party liquidation (zero collateral seized) succeeds: state it in INV-013 (:44), INV-041 (:104) and ATTACK-028 (:423, which says the call reverts `Unauthorized()`).
- Seizure bound for a faulty Adapter: any non-reserved address the Adapter registers, up to `addCap` (REQ-PROXY-008), in INV-009 (:40) and ATTACK-022 (:340).
- Stale attack rows: ATTACK-021 (:326; cites `Unauthorized()`, `UnsupportedLiquidationCall()`, `APPROVED_DEBT_RESERVES`, `UnsupportedBorrowableCollateral()` of the dropped liquidation-manager design); ATTACK-023 (:354; says the hostile Adapter's `liquidationCall` reverts on the transfer, against PoC `test_poc_hostileAdapterEoaLiquidator`); ATTACK-027 (`returnStrayNft` → `returnStray`); INV-003 (:28), flagged stale by the VaultToken review without detail: re-check it against the fee-only and dust liquidation PoCs.
- Proxy binding map written one way (`proxyOf[wallet][marketId]`, `walletOf`, `accountOf`, fixed creation code) in INV-064 (:61), Q-307 (`04-design-decisions.md:153`) and REQ-PROXY-053; INV-016 (:55) says the proxy has only `execute` (drop `supplyCollateral`/`withdrawCollateral`); REQ-ROLE-095 (`04-permissions-and-roles.md:110`) drops `initialize(wallet, spoke)` and keys per wallet, Spoke and market.
- INV-017 (:56): no `pool()`/`tickLower()`/`tickUpper()` getters; describe the current validation (factory `isVaultToken`, `tokenOf(spoke, marketKey)`, `lpVaultOf`, `adapter()`, `lpVaultSwap()`, pool read from the LPVault's `marketOf`).
- REQ-ARCH-207 ("a market belongs to exactly one CDP Spoke for life", `01-protocol-overview.md:68`) reconciled with Q-355 relisting on a successor Spoke.
- REQ-ROLE-017 (`04-permissions-and-roles.md:105`): per (CDP Spoke, market key), `TokenExistsForMarket`.
- REQ-HUB-043 (`01-avana-hub-and-spokes.md:212`): the current `deployVaultToken` signature, not the 7-argument form.
- Escrow credit is the measured rise capped at the request in INV-039 (:102), INV-061 (:107, now "exactly the amount that transfer failed to deliver"), INV-079 (:168) and ATTACK-118 (:1704); INV-039, INV-061 and ATTACK-118 also list the `settlePending` residue to `feeRecipient`. `certora/specs/PayoutEscrow.spec:5` drops "keeper payouts" (`keeperOut` is never escrowed).
- Served LP price: INV-055 (:154) uses the SPEC-ORC-008 sum formula instead of `isqrt(4 × a0 × a1) − 1` and `min(lower, fresh, A)`; INV-087 (:114), PROP-074 (`02-formal-properties.md:218`) and TEST-230 (`01-test-requirements.md:442`) say `min(lower, fresh, A)`.
- PROP-026 (:216): bounds `[1, MAX_ROUTE_ANSWER]` and false outside, as the Halmos check uses, instead of `p, b < 2^128`.
- TEST-037 (:108): the reference is the stdlib `fractions.Fraction` model (mpmath arrives at contract 13); restate the error bound per SPEC-ORC-005/008 and drop "actual Uniswap holdings".
- Seizure-list order: INV-015 (:46) says partial changes keep insertion order and the order decides charge release and rescue caps, never units seized; "largest-first" becomes "in list order from the head" in INV-008 (:33), INV-058 (:34), 2.6 REQ-PROXY-038 (`06-aave-adapter.md:191`), 2.11 REQ-SWAP-020 (:247), 3.5 LIQ-057 (:296), 3.4 WDR-015 (:87), WDR-027 (:117), WDR-POST-002 (:357) and DEP-POST-006; 3.4 WDR-037 (:209) says a partial removal does not reorder (today "re-sorted largest-first").
- Lock exceptions: 2.7 line 43 says `getAccountRescueUnits` and `poolUnits` are readable while the Lock is free or held by the Adapter (REQ-COLL-018); 2.16 REQ-LOCK-016 (`16-lock.md:111`) adds `poolUnits` (read by the borrow-side market breaker); REQ-LOCK-017 (:112) states checks-effects-interactions per step (REQ-VAULT-089), resolving the REQ-VAULT-053/131 ordering.
- 2.8 REQ-CONFIG-039/040 (`08-market-registry.md:266-267`): no token of `route.exactAmountInputs()` may be a listed token with the `UsdtFeeRate` probe (REQ-ROUTE-008; code and 2.12 REQ-ROUTE-005 have it).
- 2.8 or 3.8: the listing passes the integration's listing prices as `integrationData` (`abi.encode(price0, price1)` for Uniswap v3, `(generation, price0, price1)` for Slipstream) in REQ-CONFIG-078 and MKT-018..020.
- MarketRegistry stale rows: TEST-185 (:168) and TEST-138 (:402) drop `approveSpoke` and `registerMarket`; REQ-ACCESS-133 (`15-governance-and-timelock.md:227`), REQ-ARCH-133 (`02-contract-relationships.md:453`) and MKT-055 (`08-market-lifecycle.md:131`) use `deployCdpSpoke(SpokeDef)` (MKT-055 also names `approveSpokeCodeHash` first); MKT-F-020 (:261) drops `SpokeNotOnHub` and `SpokeExists`.
- Collateralization stale rows: DEP-012 (`01-deposit.md:72`) and DEP-F-021 (:264) use `2^64`; DEP and WDR drop `accountRegularUsd`, `lastPledgeAt`, `accountUsd` (`01-deposit.md:72,95,188,295,303,326`; `04-withdraw.md:87,144,207`).
- Proxies stale rows: TEST-026 (:73) `NoProxy(wallet, marketId)`; TEST-242 (:454) and TEST-168 (:167) drop ProxyManager as an upgradeable AccessControl contract.
- LPVault stale rows: TEST-017 (:46) always one collect with max caps, called by Collateralization under the Adapter's Lock (REQ-VAULT-065); TEST-058 (:138) drops `LPVault.removeLiquidity`.
- TEST-109 (:347): `UnauthorizedTransfer(hub, caller)`, not `UnauthorizedRecipient`.
- EMG-108 step 5 (`06-emergency-operations.md:319`): with `receiveShares = true` and `receiveSharesEnabled = true` the liquidation moves Spoke shares with no token transfer, so the claimed revert does not happen; align with REQ-VTOKEN-006.
- COVERAGE breaker removed (2.14 Q-399, 2.7 SPEC-BRK-004): rewrite 3.9 DEF-012, DEF-018 (COVERAGE, COVERAGE_BOUND), DEF-019 and DEF-F-007 (`09-deficit-coverage.md:62,66,67,86,99,146`), EMG-028 (`06-emergency-operations.md:75`) and 3.6 lines 268 and 390.
- `fundingAssetId` → `hubAssetId` in `09-deficit-coverage.md:64`, `15-governance-and-timelock.md:230`, Q-282 (`04-design-decisions.md:381`).
- 1.5: `firstLossReserveAddCap` = `MAX_ALLOWED_SPOKE_CAP` (:156); `deficitCoverageWindow` not a proposed default (:158).
- MATH-ST-114 in the 5.2 st09 row (`02-formal-properties.md:50`).
- Joint Configuration Safe in 2.15: REQ-ACCESS-005..009 and the holders table (JCS, guardian seats, "no signer key shared"), REQ-ACCESS-026 (:159), REQ-ACCESS-027 (:160, guardian roles also to the JCS), REQ-ACCESS-104 (:436, four Safes, no signer key shared), and the tighten-setter rows REQ-ACCESS-037..041, 049, 131, 132, 138, 146, 165 and REQ-ACCESS-043 (`setAvanaFeeShareBps`) add `APPLICATION_RISK_STEWARD`.
- 4.1 INV-051 (:138) lists the risk steward's immediate tightenings, the fee share and `useStandbySecondSource`.
- 2.7 SPEC-CF-004 (`07-risk-module.md:275`): the check also runs in the ParameterStore (REQ-PSTORE-004).
- 2.9 REQ-CONFIG-056 (:264): a failed or malformed answer classifies the candidate as not Avana, so the check relies on every Avana contract answering its views; this is the refusal list's direction, not a fail-closed read.
- "rolling 24 hours" → "24 one-hour buckets" on live-rule pages: 1.2 REQ-ARCH-200 (`02-contract-relationships.md:459`), 2.15 REQ-ACCESS-157 (:237), REQ-ACCESS-169 (:521) and the `freezeAddress` row (:103), 3.6 EMG-090 (:174) and EMG-F-020 (:521), 4.1 INV-085 (:146), 4.4 Q-242 (:419), Quint (`avana.qnt:230,297`, `quint/README.md:60`) and Hypothesis comments (`model/params.py:71`, `model/avana.py:365`). Historical decision and finding records keep their wording.
- Keeper monitoring (Q-S3): EMG-053 (`06-emergency-operations.md:132`, also :308), `07-risk-module.md:86` and Q-382 say the keeper simulates `pokeConfig` and `pokeBreakers` every block and sends only when the result changes state.
- EMG text for M-16/M-17: EMG-082 (:254) maps M-17 to debt-asset balances, but M-17 is gas plus Aave V3 Pool idle liquidity and M-16 is the debt-asset float; EMG-098 (flash liquidity) cites M-17 (:263, 326-327).
- Hypothesis `model/swap.py:269`: the gap is `max(0, D + A + B − Kf − R)` (SPEC-SET-001), not `max(0, D + A − K − R)`.
- Run `trace.py` acceptance so REQ-ROLE-117 enters `traceability.lock.json`.

### Docs and READMEs

- `contracts/certora/README.md`: VaultTokenFactory under PROP-099, not PROP-034/055, with its Summaries line (:132, 324, 345); ProxyManager removed from the AccessControl list (:55) and the PROP-034 and PROP-070 maps (:324, 360); PROP-034 map and ParameterStore section name the `APPLICATION_RISK_STEWARD` and `useStandbySecondSource` exceptions (:222-225, 324).
- `contracts/test/README.md`: remove the `LPOracle.halmos.t.sol` row (functions do not exist) and the duplicated SettlementMath row (:219-222); fix the TEST-037 row (:304, nonexistent `LPOracle.differential.t.sol` and `testFuzz_TEST_037_matchesMpmathReference`); record the Halmos PROP-023/024-symmetry/026 timeouts and their 10,000-run fuzz twins.
- `contracts/README.md:194`: "mpmath reference" → the `fractions.Fraction` reference.
- Root `README.md`: add the Semgrep, 4naly3er, coverage-gate and storage-layout-check commands (:187, 197, 205; `contracts/README.md:242-259` has them).
- `test/hostile/` does not exist: write the hostile suite or drop it from `contracts.yml:271-272`, `README.md:407` and `contracts/README.md:198,210`.
- `spec/05-verification/z3/README.md` totals table (:26-33): aave-risk with ar12 (MATH-AR-70), units-oracle 15 scripts, settlement, an amm-pricing row, and the total; `z3/aave-risk/README.md:218` adds ar12.
- `spec/05-verification/z3/settlement/README.md:295`: st02 counts 120 / 96 / 24.
- `audit/hypothesis/README.md:18`: test count (80 functions, not 71).
- `audit/README.md:65`: review count and date (17 folders).
- `audit/reviews/AvanaTimelock/README.md:17`: itemize the five Lows (three named today).
- `audit/reviews/LPPriceMath/README.md`: rate finding #8 (`pokeMinGasFloor` vs MATH-UO-57c).
- `audit/reviews/SettlementMath` and `audit/reviews/VaultToken`: the "listed test gaps" are not recorded; record them and check each against the tests, or drop the item.
- `audit/echidna/README.md`: the 16:02 row still says Lock "Every property reported passing"; mark it invalid.
- `services/README.md`: M-13 (:212) drops "COVERAGE breaker trips" (monitoring alert only); M-22 (:221) drops "beacon change"; keeper duty 4 (:69) says simulate `pokeConfig` and `pokeBreakers` every block, send only on a state change (Q-S3); add an alert for liquidity leaving listed pools.
- `spec/05-verification/hypothesis/README.md`: until the rekey (contract 20/23 item below) the model does not test cross-market isolation; Foundry and Certora tests do.
- LIFECYCLE anchors (stale/total on main): amm 29/29, uniswap-v3 18/18, slipstream 23/23, flash 18/20, lp-oracle 60/62 (w2oracle 60/68), debt-oracle 26/26, lock 11/12, flash-liquidator 32/32, lp-vault-swap 61/64, payout-escrow 5/23, lens 26/29, timelock 35/35, lp-vault 43/43, risk-module 46/46 (w2risk 5/50), aave-adapter 69/77, market-registry 10/84, vault-token 1/34, coverage-spoke 1/47, settlement-routes 3/27.

### Formal verification and slow tier

- Certora prover pass over every conf with a merged implementation, CVL errors fixed, sanity checks, results in `certora/RUNS.md`. Waiting or never submitted: ParameterStore `tightenLowersScalars`, `adminRolesOnlyTimelock`, `tightenGateRecoverySecondsIsSafer`; MarketRegistry `freezeGuardianCannotLift`, `onlyUnfreezeAddressLiftsAFreeze`, `noCallFreezesAProtectedAddress`, `activateMarketRunsTheDriftCheck`, `roleAdminsNeverChange`, `adminRolesOnlyTimelock`, `freezeAddressGates`, `appAdminAdministeredByDefaultAdmin`, `pauseTransitions`, `reasonIsNoneExactlyWhenNotPaused` (`listCollateralMarket` vacuous); AvanaTimelock `executeBatchWindow`; `routeBindingsSet` on the three route confs; 31 Collateralization rules; five ParameterStore jobs and the listing probe whose results were not collected. Never run: LPOracle, DebtOracle, RiskModule, RiskModuleDrift, LPVault, LPVaultSlipstream, UniswapV3Integration, SlipstreamIntegration.
- Certora `MarketRegistry.spec` `isProtected` (:137-148) adds the flash source's `LENDER()` and the recorded integration contracts, as the code protects them.
- Echidna for Lock and AvanaTimelock re-runs at the layer 2.1 gate (the 2026-11-10 runs crashed at start).
- Halmos on SettlementMath (2/14 under load) re-runs at the layer gate on a quiet machine.

### Contract 13

- Replace `ClPriceMath.sol` (GPL-2.0-or-later, compiled into the BUSL-1.1 concentrated-liquidity LPVaults; an unresolved combination until replaced): tick conversions from Uniswap v4-core `TickMath.sol` (pinned, MIT, notices kept, each imported dependency's licence checked); the other four functions implemented independently from documented mathematics (not a rename or rearrangement of the GPL code); differential and Z3 checks over rounding, boundaries, overflow and reverts; then a dependency and licence review before distribution.

### Contract 20 (AaveAdapter)

- Router plus immutable delegatecall logic contracts (user ops, collateral ops, settlement) like the ParameterStore; reword REQ-ADAPTER-004's "link no external libraries" (`06-aave-adapter.md:139`).
- First pledge into a proxy requires zero collateral and zero debt on its Spoke account (REQ-PROXY-055, ~2^80 collision assumption); add the rule to 2.6 (REQ-ADAPTER-065/066 area).
- Permissionless `refreshDebtMark(address proxy)`: implement, and add the 2.6 row (anyone; Lock; `markDebtFree`; release; no asset moved; reads no registry, pause, freeze, breaker or price; works in Offboarding, Q-355).
- State in REQ-PROXY-035 and 2.6 (:188) that exits depend on Aave reading every reserve's price.
- Drop the duplicate end-of-call no-tokens check of REQ-ADAPTER-007 (:142) if per-step checks cover it.
- Consider moving the borrow receiver rule (:11) into a RiskModule or MarketRegistry view.
- The Adapter never sends a zero VaultToken amount (zero-amount transfers revert).
- Lock obligations and tests: REQ-LOCK-007 (acquire before external calls, release on every success path), REQ-LOCK-023 (`burnSeized` `NotLPVaultSwap`), REQ-LOCK-028 (fee collection and zero-credit release through the Adapter), REQ-LOCK-030 (release only last, never from an inner callee or hook, no foreign delegatecall); Adapter sides of TEST-060, TEST-270, TEST-062 and TEST-242.
- Real-Aave test list from the brief: two proxies per wallet, `borrowCount` debt-free, repay-all flags at 6/18 decimals, dynamic keys, stale risk premium after a partial repay, signature and collision cases, exits with a reverting registry or RiskModule, 16-record gas.
- Hypothesis model rekey (after contracts 20 and 23): the state machine keys accounts per (wallet, Spoke, market) instead of (wallet, Spoke), about 35 sites in `model/avana.py`, `swap.py`, `invariants.py` and the state machine, with an invariant that actions in one market never change another market's account.

### Contract 23 (LPVaultSwap) and the 2.11 option C rewrite

- Implement caller-funded `liquidate(params)` as the single entry point (any caller, `PrimaryThenBackup` or `BackupOnly`; HF, oracle poke and grace, Hub share check, recovery floor, fee, surplus, deadline, `minPayout`, address freeze on the caller); pull `debtToCover` by balance delta, measure Kf with 0 < Kf ≤ X.
- `deleverage` flash path: repay the flash source by balance delta with `MAX_REPAY_TRANSFERS = 4`, valid only under USDT's per-transfer fee cap (REQ-SWAP-122).
- `settlePending`: read `settlementReserve(marketId)` (REQ-MREG-033, REQ-SWAP-066); skip `fund` when R is below one share's value and carry it to the next settlement (REQ-SWAP-070); residue to `feeRecipient`.
- REQ-SWAP-076: a transfer that returns `true` but under-delivers is measured and the shortfall escrowed; update the REQ-SWAP-076 text (today step (3) counts `true` as delivered) and implement it.
- The aggregate recovery floor values residues paid to the caller at zero.
- Remove `flashPremium`, `transferCost` and `premiumOnDebt` from SettlementMath (`SettlementMath.sol:271-287`); they are 0 on the liquidation path.
- LPVaultSwap never sends a zero VaultToken amount.
- Lock obligations and tests: REQ-LOCK-007 (incl. the `settlePending` pre-acquire view read), REQ-LOCK-023 (`deleverageRepay`/`deleverageRelease` `NotLPVaultSwap`/`NoDeleverageSession`), REQ-LOCK-030; LPVaultSwap sides of TEST-060, TEST-270, TEST-062 and TEST-242.

### Contract 25 (Lens)

- Lens views revert `Locked()` while locked (REQ-LOCK-016); Lens sides of TEST-060 and TEST-270.
- The Lens reads `OracleConfig` from calldata or a split struct (decoding into memory hits "stack too deep" in the legacy pipeline).

### Fork work (needs RPCs)

- TEST-067: timelock cancellation on a fork (every canceller, `RoleChangeCancelRestricted`).
- TEST-118 (`FlashSource.fork.t.sol`, not written) and `maxFlashLoan` against Aave 3.1+ virtual accounting (`getVirtualUnderlyingBalance`).
- TEST-264 remaining assertions (custody of a live NFT, unwind at a moved spot, fees), TEST-116 and TEST-266 for the Uniswap v3 LPVault.
- TEST-265 on every Slipstream generation including Aero (written, skipped without `RPC_BASE`).
- TEST-275 (`SequencerGate.fork.t.sol`, not written).
- Fork test of the VaultToken liquidation-fee PoC (local real-Aave regression exists).
- TEST-269: worst-case gas of a 16-record seizure plus reconcile with real v3 unwinds (about 4–5M).
- GSM static-aToken deposit check and REQ-ROUTE-043 route fork tests (Curve NG `get_coin_indices` ABI from stableswap-ng 3332cd4).
- `DEBT_MARK_GAS_FLOOR` calibration (50,000 provisional): maximum supported account (every active collateral and debt reserve, cold oracle reads, expensive fallback paths); a gas-limit sweep that starves the Spoke and nested oracle calls with no case leaving a stale debt-free mark usable; genuine oracle reverts tested apart from gas exhaustion; repeated after any change to oracle cost or reserve counts. The 576k LP read and 3.15M account read are not confirmed bounds until then.
- Market-count cap N sized on a fork from the most expensive ParameterStore setter, the worst supported market configuration and cold reads, with headroom below the chain's transaction gas limit; re-validated when an upgrade raises `checkConfig` cost.

### Deploy scripts

None exist yet (`contracts/script` has no `*.s.sol`).
- Step 7 passes `marketRegistry` as the VaultTokenFactory's 5th constructor argument.
- Collateralization deployed with `deployCode("Collateralization.sol:Collateralization")` (via-IR profile).
- Reuse `test/utils/fixtures/TimelockLaunchLists.sol`; TEST-224 deployment simulation (forge script on both forks, Safe format, live-configuration check).
- Grants: `APPLICATION_RISK_STEWARD` and both MarketRegistry guardian roles to the Joint Configuration Safe (`script/README.md:15,54` steps 04_ConfigureAccess and 13 grant guardians only to the Emergency Guardian and Aave Protocol Guardian); the Aave DAO's listing payload grants `COVERAGE_ROLE` to both guardians.
- Listing batches in the REQ-PSTORE-004 order: `setFeedAgreementToleranceBps` before `setFeed`, `setTokenCollateralFactorBps` before `setInitialMarketParams`, `enableDebtReserve` before `setDebtAssetParams`, `tightenTopUpSliceUsd` before a cap below the slice; every debt asset, GHO included, `listToken`ed before `enableDebtReserve`; `approveSpokeCodeHash` before `deployCdpSpoke` (each Aave V4 Spoke implementation has its own hash).
- Listing payload passes the integration's listing prices as `integrationData`.
- `FeedDef.maxAnswerCap` and the `uint16` `FeedConfigured.heartbeatMargin` reach the deploy scripts and the app.
- `RouteConfig` takes the three pinned factories.
- `07_VerifyDeployment`: PayoutEscrow `ILock(lock).LP_VAULT_SWAP() == lpVaultSwap`; `route.poolFactories()` equals the address book; AMM integration record release check comparing the record with each integration's actual position manager, factory, singleton and every other protected address, run against the exact governance payload (non-zero with code is not enough).
- Deployment hardening: explicit gas for time-dependent calls, cross-block fork simulation, a runbook that replays only unexecuted calls, storage-fault negative tests for TEST-135.
- CI: the TEST-005 counterpart script fails when a Base counterpart is skipped; the fork job's RPC secret moves to a protected environment with a dedicated rate-limited key (`contracts.yml:223-234` has no `environment:`).

### Services

- `services/README.md` and `services/keeper/`: keeper duty 4 simulate-then-send (Q-S3); M-13, M-22 and the pool-liquidity alert (listed under Docs and READMEs); the keeper follows LPVaultSwap's final interface once contract 23 lands.

### Found in the 2026-11-11 audit, outside the old list

- Aerodrome Slipstream fourth generation: the code and 2.21 treat its position manager and factory as fork-checked, while the Launch configuration decision and `deployments/proposed/base-launch-draft.json` say Aerodrome has not published those addresses; settle which is right and align both.
- Legacy Curve pools are allowed by the Decisions table, but the route code has only one Curve hop kind (stableswap-ng); add the legacy hop kind or narrow the decision.
- REQ-SWAP-106 example says 19.237964; the SettlementMath fix gives 19.237965.
- REQ-LENS-029 still says "including for permissionless callers" (one liquidation path since option C).
- REQ-COLL-040 states the 3.15M gas bound as fact; it is provisional until the fork calibration (TEST-269).
- `contracts/certora/README.md:7` lists merged contracts as "not yet written".
- `contracts/certora/RUNS.md` says the ParameterStore logic contracts accept direct calls; `_onlyDelegated` now refuses them.
- `contracts/security/size-margins.json`: the Slipstream size-margin reason is stale.
- `contracts/foundry.toml`: the fork-block comment is stale.
- `contracts/script/security-slow.sh` header still says "nightly"; the slow tier now runs on demand.
- Not yet decidable from the records: the "listed test gaps" of the SettlementMath and VaultToken reviews (never written down; take them from `audit/reviews/`), and which clause of INV-003 is stale.

### Carried from the Decisions table

- Contract 20: the PositionManagerApproved proof (selector-allowlist test and a parametric Certora rule over every Adapter method; then remove the reserved `DriftReason`), with the pre-deploy CREATE2 bound (about 2^80) stated as accepted.
- Fork: `POKE_MIN_GAS_FLOOR` calibration (900,000 is provisional; a launch requirement), and the market-count cap calibration.

## Progress log

| Date | Contract | Result |
|---|---|---|
| 2026-11-10 | — | List created; four build decisions recorded. |
| 2026-11-10 | Phase 0 | Checklist generator, test base, Aave V4 fixture, manifest helper, differential harness, Coverage Spoke move and Certora fixes landed; gate passed. |
| 2026-11-10 | 1 AvanaRoles | Done. 6 unit/fuzz tests (identifier rows of TEST-062); Echidna/Medusa and hevm QED on the existing harness. |
| 2026-11-10 | 2 Lock | Done. Spec: REQ-LOCK-029 (constructor refuses zero or equal members), REQ-LOCK-030 (members release only at the end of an outer entry point), REQ-LOCK-002/003/005/008/009/018 reworded. Code fixes found by tests: getters refuse delegatecall; a free lock refuses every release. 24 unit tests, 6 Halmos checks (a swapped-check mutation is caught), Echidna and Medusa pass, hevm QED, Mythril 0, SMTChecker no counterexample, Slither 2 triaged (pending). Independent review: no critical/high/medium; all points applied. |
| 2026-11-10 | 3 AvanaTimelock | Code and tests done; slow tier and SMTChecker rerunning. Spec: storage of public execution and clean-up written as implemented, check order (REQ-ACCESS-117), exact selector allowlists (REQ-ACCESS-142, 181), REQ-ACCESS-182 (timelock keeps its admin role), REQ-ACCESS-183 (constructor role checks), overflow-free expiry (SPEC-GOV-013), buy-route names removed from INV-051, INV-090, ATTACK-097. Independent review found 2 medium (public execution switchable by a DAO-only role change; the timelock could drop its own admin role) and 5 low; all fixed with tests. 47 unit/fuzz tests, TEST-212 invariant suite, 7 Halmos checks, Hypothesis and Z3 governance models updated and passing, fast tier green with 9 triage rows (pending). |
| 2026-11-10 | 4 LPPriceMath, 5 SettlementMath, 10 VaultToken | Written in parallel and merged; tests, differential, Halmos and the fast tier pass. Independent reviews done: no code defect above Info in SettlementMath; LPPriceMath 2 medium (array lengths, signed answers) and 5 low; VaultToken code correct, with spec findings (liquidation fee must be 0, dust third-party liquidation, seizure bound). Fixes queued in open items. |
| 2026-11-10 | 6 ParameterStore | Written and merged as a router plus five logic contracts. 258 tests pass across the repo, 8 Halmos checks, control FV 175 checks, Z3 st02 new check proved, fast tier green with new triage rows (pending). 2.9 edits accepted in `trace.py`. Independent review not yet run. |
| 2026-11-10 | — | Research: Aave V4 health is one factor per account per Spoke over all collaterals, so the proxy stays per (wallet, CDP Spoke, market); the liquidation fee must be 0 on every vault-token reserve and the DAO's share comes from settlement proceeds. Note in `avana-internal-references/research/aave-v4-health-and-proxy-keying.md`. |

### 2026-11-11 (end of day, before laptop restart)
Merged into the real repo and gated (`forge build -D warnings`, `forge test -j 2` 1,054/1,054, `forge fmt --check`, licence check, file sizes): option C interfaces and decisions; DebtOracle (9); LPOracle (8) with the gas refactor (cold Aave LP read 692k to 376k gas; liquidationCall 1.85M to 1.11M; CI gas budgets in test/gas); Slipstream LPVault (15); CL LPVault review fixes CL-01..05 and S1..S9; flash liquidation helper with FL-01..03 and the GHO flash minter; DebtOracle review fixes; RiskModule (19, lint not yet clean); tooling (Semgrep, 4naly3er, coverage gate, layout check); the 17 repo-setup items; in-house Aave V4 interfaces (ABI-equal); BUSL-1.1 licensing headers and LICENSE; triage review (36 approved by pattern, 108 pending Josue in groups A-Q).
Not yet green: `script/security-fast.sh` has not completed on the merged repo (RiskModule forge-lint 32 findings; new Slither/Aderyn/Semgrep/4naly3er findings in RiskModule, LPOracle gas code and the helper not triaged). Coverage profile fails "stack too deep" on the 12-field positions() destructures.
Workspace handoff notes and backups: ~/Documents/avana-internal-references/tools/.

### 2026-11-11 (after the restart)
- RiskModule lint clean: each logic contract now checks its drift, breaker and borrow dependencies with `_requireLogic` (kind and immutables hash), tested in TEST-062; the remaining suppressions carry reasons; `_marketDrift` split into `_marketDrift` and `_reserveDrift`.
- Coverage: the "stack too deep" no longer occurs. Tests for every uncovered branch of LPOracle, LPOracleCalls, LPOracleConfig, the flash helper, ParameterStoreRouter and all RiskModule files (RiskModule files now 100 %).
- Security tier: the security build compiles `src/` only (a restricted test helper put ParameterStore in two compiler profiles, which broke slither-check-upgradeability and the layout check); the layout check accepts one contract in several profiles when the layouts match; RiskModule layout snapshot added; DebtOracle `lastStressRiseBps` appended.
- `trace.py`: a citation with a case suffix (`MATH-UO-53c`) cites its check.
- For Josue:
  - LPOracle second-source words: an out-of-range second-source word from `getOracleInputs` fails the read in `getPriceState`/`poke` (Cached, failure timer started) but not in the served views, which read without second sources; this breaks REQ-ORACLE-042 and REQ-ORACLE-100. Proposed fix: treat it as an unconfirmed second source for that token (bit 16, `borrowAllowed` false). Failing test kept in the session handoff folder (`LPOracle.SecondSourceWords.unit.t.sol`). Reachable only through a broken or upgraded ParameterStore.
  - `LPOracleConfig._loadSeed` token-count and market-id check is unreachable (checked earlier in `checkConfig` and `initialize`): keep as a defensive check or remove.
  - RiskModule `getAccountGateStatus` fallback (view body reverted) leaves reserve fields at 0, which is GHO's reserve id; set every reserve field to the no-reserve value instead.
  - `borrowAllowed` in the account status ignores debt breakers (a borrow checks only the borrowed reserve's breaker); state it in the spec.
- Step 1 closed (2026-11-11): `forge test -j 2` 1,116/1,116; `script/check-coverage.sh` pass (86 % branch total, minimums recorded for every file); `script/security-fast.sh` every step passes (Slither 591, Aderyn 320, Semgrep 26, 4naly3er 135 accepted); `trace.py` 0 errors after the spec models passed (`run_all.sh`; HYP-21 assertion now also accepts a token refusing delivery, per Q-118) and 429 changed requirements were accepted. Triage review triage3: 66 approved by pattern, 3 pending review (approved pattern), 81 pending Josue in new groups R–Y (downcasts after range checks; delegatecall view forwarding with assembly return; assembly reads of length-checked buffers; zero-initialised locals; zero address rejected by `_requireLogic`; empty variant hooks in the public flash helper; `block.number` for the same-block quote cap) and additions to B, E, F, G, H, J, L, M, O, P, Q. Stale entries kept for the next run: Slither 7, Aderyn 2, Semgrep 1, 4naly3er 4. ParameterStore batch: duplicated comment line in `ParameterStoreAdminOracleLogic` near line 278.
