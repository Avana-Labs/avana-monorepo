# Quint recorded results

Copied from docs/spec/05-verification/quint/README.md (Results and Findings) as of 2026-11-10.

## Results

Run on 2026-11-10 with Quint 0.22.4 on 8 cores, in quick mode: 500 traces × 20 steps per check, 96 checks, about 14 minutes. The 10,000 × 20 full run is the next nightly run's job: `QUINT_FULL=1 ./run.sh`. In full mode a missed witness fails the run, so the four quick-mode warnings below must be reached there.

| Check | Result |
|---|---|
| `quint typecheck avana.qnt`, `quint typecheck avana_tests.qnt` | Both pass |
| `quint test avana_tests.qnt` | 50 of 50 scenarios pass (`QNT-T01` … `QNT-T44`) |
| `quint test avana.qnt` | No `run` tests in this module; passes |
| 58 properties `QNT-01` … `QNT-58` | 58 hold, 0 violated |
| 8 combined runs | 8 hold, 0 violated |
| 30 witnesses | 26 reached, 4 not reached in quick mode (warnings) |

**Combined runs**

| ID | Invariant | Init | Steps | Result | Time |
|---|---|---|---|---|---|
| QNT-ALL-H | `honestInvariants` | `init` | step | Holds | 395 s |
| QNT-ALL-HS | `honestInvariants` | `initStressed` | step | Holds | 574 s |
| QNT-ALL-HR | `honestInvariants` | `initRouteOutage` | step | Holds | 460 s |
| QNT-ALL-HC | `honestInvariants` | `initCrash` | step | Holds | 809 s |
| QNT-ALL-X | `hostileInvariants` | `init` | stepAll | Holds | 250 s |
| QNT-ALL-XH | `hostileInvariants` | `initHostileSwap` | stepAll | Holds | 249 s |
| QNT-ALL-XS | `hostileInvariants` | `initStressedHostileSwap` | stepAll | Holds | 302 s |
| QNT-ALL-A | `adapterInvariants` | `initStressedHostileAdapter` | stepHostileAdapter | Holds | 192 s |

**Single properties.** Each of `QNT-01` … `QNT-58` holds on the step relation in the Properties table (92 s to 186 s per run). No new counterexample was found.

**Witnesses**

| ID | State the traces must reach | Init | Steps | Result |
|---|---|---|---|---|
| W-SEIZE | a liquidation call moves vault tokens | `init` | step | Not reached in quick mode (warning) |
| W-SURPLUS | the Avana fee recipient receives a fee | `init` | step | Reached |
| W-ZEROREC | a record at 0 credited units | `init` | step | Reached |
| W-DEFICIT | a deficit is reported | `initStressed` | step | Reached |
| W-COVER | a Coverage Spoke covers a deficit | `initStressed` | step | Reached |
| W-WITHDRAW | a record is closed | `init` | step | Reached |
| W-TWOMKT | one proxy holds two markets | `init` | step | Reached |
| W-GRACE | a market recovers Expired → Live | `init` | step | Reached |
| W-DISAGREE | a disagreement pause expires for liquidation | `init` | step | Reached |
| W-STRAY | a stray NFT's owner is proven | `init` | step | Reached |
| W-KEEP | a hostile LPVaultSwap keeps seized tokens | `initStressedHostileSwap` | stepHostileSwap | Reached |
| W-PERM | a permissionless liquidation | `init` | step | Not reached in quick mode (warning) |
| W-INKIND | a debt token starts refusing a holder's payout (in-kind removed, `Q-401`) | `init` | step | Reached |
| W-ESCROW | the PayoutEscrow credits a refused payout | `initStressed` | step | Reached |
| W-3PREPAY | a third party repays a borrower's debt | `init` | step | Reached |
| W-PENDING | a pending-settlement balance | `initStressedHostileSwap` | stepHostileSwap | Reached |
| W-ORPHAN | an exit after an orphan burn | `initStressedHostileSwap` | stepHostileSwap | Reached |
| W-RESCUE | a rescue top-up | `initStressed` | step | Reached |
| W-REMOVE | a partial removal | `initStressed` | step | Reached |
| W-RECREDIT | a re-credit | `initStressed` | step | Not reached in quick mode (warning) |
| W-RWC | a repay with collateral | `initStressed` | step | Reached |
| W-USDTLIQ | a liquidation repaying USDT | `initStressed` | step | Reached |
| W-SHORTFALL | a caller's shortfall top-up | `initCrash` | step | Reached |
| W-AUTOINKIND | a floor-failure report (an alert only) | `initCrash` | step | Reached |
| W-SURGE | a seizure-surge alert (no latch) | `initStressed` | step | Reached |
| W-STANDBY | a standby switch | `init` | step | Reached |
| W-FROZENEXIT | a frozen address withdraws or repays | `initStressed` | step | Reached |
| W-TLEXEC | a timelock operation executes | `init` | step | Reached |
| W-DAOPROP | an operation proposed by the Aave executor executes | `init` | step | Reached |
| W-DAOCANCEL | the DAO canceller cancels a DAO-only operation | `init` | step | Not reached in quick mode (warning) |

The four warnings are coverage gaps of the 500-trace sample, not property failures. The random states they ask for are reachable: the W-SURPLUS trace from `init` ends in a permissionless liquidation that moves vault tokens, so the states of W-SEIZE and W-PERM occur in this run's traces, only not inside their own samples (from `init` a seizure needs a pledge, a borrow and a price fall before the liquidation, inside 20 steps). Each state is also reached by a deterministic scenario that passes: a keeper seizure by `QNT-T05` (and from the seeded states by W-USDTLIQ, W-KEEP, W-INKIND and W-SHORTFALL), a permissionless liquidation by `QNT-T29`, a re-credit by `QNT-T36`; for W-DAOCANCEL, `QNT-T23`, `QNT-T33` and `QNT-T40` show the DAO canceller allowed and every other canceller refused on restoring and role-change operations.

### Findings

No property was violated in this run. The model records one finding from its scenarios:

| ID | Finding | Evidence | Status |
|---|---|---|---|
| QNT-F1 | A hostile LPVaultSwap can seize an Expired market in full for one unit of debt. Aave values an Expired market at its minimum price (modelled as 0), so a liquidation sized at that price seizes the whole supply of the market. Trace: alice holds mA and mB on S1 with debt; mA falls to price 1; mB's feeds fail; after two ticks mB is Expired. The reviewed LPVaultSwap seizes the fresh mA and refuses every amount on mB; a hostile one seizes all 600 units of mB for 1 GHO. | `QNT-T24` (`hostileSwapStaleTest`), `QNT-T42`; QNT-22 holds for the reviewed LPVaultSwap | Bounded by the timelock: a hostile LPVaultSwap must wait the normal delay and can be cancelled (QNT-52, QNT-53); the reviewed implementation never seizes a market whose own price is Cached, Expired or disagreeing (QNT-22, `Q-247`) |

