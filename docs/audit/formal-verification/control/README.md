# Control area formal verification (FV-C)

Avana's internal formal verification of the control area: access control and `AdminRoleOnlyTimelock`, the standard-Spoke drift settings and liquidation exclusivity, the `IFlashSource`, Hub-keyed caps, credit lines and SettlementBudget windows, the application pause state and its reasons, the AvanaTimelock (delay floor, short-delay allowlist, DAO-only cancel), circuit breakers and the address freeze, RiskModule opening checks and rescue top-ups, the LPOracle and DebtOracle price-state machines with backup routes and the standby switch, LPPriceMath, upgrade paths, the immutable PositionProxy per wallet × CDP Spoke × market, the two-member Lock and the Lens. Targets `T-53`…`T-80` of the [methodology](../methodology.md), plus properties added from the spec reading. The models encode the AMM-neutral spec (decisions `Q-001`…`Q-380`); report section 13 lists what changed.

## Run

```
docs/audit/formal-verification/control/run.sh
```

It runs every model with `docs/spec/05-verification/.venv/bin/python` (Z3 4.13.0), type-checks `governance.qnt` and runs its six invariants with `quint run` (10,000 samples × 12 steps, seed `0x1`), then checks that every cited spec ID is defined (`check_ids.py`, using `trace.py`'s rules). It exits non-zero while any property is Violated or Unknown, except a violation registered with `open_finding` in `common.py`: such a check prints `[OPN]` with its counterexample, is listed at the end of the run, and is an open finding in [report.md](report.md) section 13.3 with the exact spec change that restores the property. Results land in `results/` (`<model>.json`, `quint.txt`, `run.log`); each run is logged in [RUNS.md](RUNS.md). The `models` CI workflow (`.github/workflows/models.yml`) runs `run.sh` on every pull request and push to `main`, and the job fails when `run.sh` exits non-zero.

## Files

| File | Contents |
|---|---|
| `common.py` | Harness: `prove` (unsat of the negation), `witness`, `exhaustive`, `bounded_prove`, `expect`, `open_finding`; JSON results |
| `fv_ctl_access.py` | Admin-role rule (`AdminRoleOnlyTimelock`), timelock-only privileged paths, restricted-function matrix across pages, guardian powers, PositionProxy surface (`execute` only), hostile-component containment, reachability from the two Lock members only |
| `fv_ctl_timelock.py` | Required delay, execution window and expiry, the normal-delay floor, cancel rights for role-change and restoring operations, the `SHORT_ELIGIBLE` allowlist, exit window |
| `fv_ctl_pause.py` | Pause transitions with reasons, caller bounds, the pause matrix on every page against the Adapter's decision procedure, rescue and exit liveness |
| `fv_ctl_gates.py` | Health floor with rescue units excluded, oracle, DebtOracle, breaker and freshness gates, reserve flags, nonce, repay liveness and sizing, exits that never read the registry, rescue top-up rule, account isolation |
| `fv_ctl_params.py` | Pledge and rescue minimum, charge and rescue units, cap counters, pledge price-state rule, tighten predicates and loosening steps, buy-slippage floor and two-leg inequality, breaker tighteners, delay classes across pages, `SHORT_ELIGIBLE`, SettlementBudget caps and per-market sub-cap, the single-leg liquidation-liveness inequality, the short-selector set against the owning pages, parameter drift, drawCap |
| `fv_ctl_registry.py` | Market lifecycle, in-kind window, relisting after cancel, duplicate keys, active-market count, debt-reserve list, route records, the standby switch and route versions, Lock |
| `fv_ctl_oracle.py` | LPOracle and DebtOracle state machines (served price by state, lower-route price, Expired valuation, cache, latch, idempotency, disagreement, Cached window, grace start, phase rollover, standby switch, checkpoint), heartbeat margins and age limits, USD band, leg behaviours, LPPriceMath |
| `fv_ctl_upgrade_lens.py` | Initializers of the UUPS contracts, the immutable proxy's selector inventory, layout rule, CREATE2 binding per (wallet, spoke, marketId), `proxyOf` and `predictProxy`, Lens paging, the flash-premium ceiling (exact form on every page, `SettlementMath.flashPremiumWithinCap`, no flash loan in liquidation), read-only reentrancy |
| `fv_ctl_breakers.py` | Circuit-breaker math, latching and read scope; address freeze (protected set read from 2.8 and `MarketRegistrySafetyLogic._isProtected`, no keeper floor, 20 freezes per 24 one-hour buckets, lifting); exits and liquidation under every combination of controls |
| `fv_ctl_amm.py` | Standard-Spoke liquidation exclusivity and its mutation witness, `CONFIG_DRIFT` effects, flash-source pre-loan and callback checks, flash-source replacement and caller-funded fallback, Hub-keyed caps, credit lines per (funding Hub, asset, Spoke), SettlementBudget market windows, transfer-rule wording across pages |
| `governance.qnt` | Quint governance state machine (module `gov`): timelock operations, cancel rights, `AdminRoleOnlyTimelock`, delay floor, pause reasons, address freeze |
| `check_ids.py` | Fails on any cited spec ID that the spec does not define |
| `report.md` | Report: scope, method, assumptions (including OpSec), findings with counterexamples and exact spec changes, bug-class sweep, property tables |
| `audit-mapping.md` | Avana internal audit mapping: prover rules (CVL) and `PROP-NNN` per property |

Check IDs are `FV-CTL-NN` (with `-W` witness and `-EX` example variants); each is tagged in its source as `FV-CTL-NN verifies: <spec IDs>`, which `docs/spec/05-verification/trace.py` collects.
