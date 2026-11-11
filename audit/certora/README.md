# Certora Prover

## What it proves

The CVL rules and invariants in `contracts/certora/specs/`, one conf per contract in `contracts/certora/conf/`, prove the implementation-stage properties (`PROP-001`…`PROP-097`, 86 rows) of [5.2](../../spec/05-verification/02-formal-properties.md) over unbounded integers and all call sequences. Every rule carries a `PROP-NNN verifies:` tag; a rule counts only after the prover passes it with sanity checks (no vacuous rule). Before the prover, `check-methods.py` checks every `methods` entry of every spec against the compiled interface ABIs.

## How to run

From `contracts/` (certora-cli 8.20.3 in `.venv`, Java 21 in `tools/jdk-21/`, key in `CERTORAKEY`):

```bash
python3 certora/check-methods.py --out out-security/build/src      # methods check (fast tier step `cvl`)
script/security-fast.sh cvl
.venv/bin/certoraRun certora/conf/Lock.conf --compilation_steps_only   # compile and type-check, no cloud job
.venv/bin/certoraRun certora/conf/Lock.conf                            # one contract, every rule
for conf in certora/conf/*.conf; do .venv/bin/certoraRun "$conf" --wait_for_results all; done
```

Rules, shared models and the property map: [`contracts/certora/README.md`](../../contracts/certora/README.md); run log: [`contracts/certora/RUNS.md`](../../contracts/certora/RUNS.md). Prover results are filed per property under [`audit/formal/`](../formal/).

## Scope

27 confs and 25 spec files plus 5 setup models, covering every Avana contract. Confs with a merged implementation on 2026-11-10: Lock, AvanaTimelock, ParameterStore, MarketRegistry, VaultToken, VaultTokenFactory, Collateralization, FlashSource, PositionProxy, ProxyManager, ProxyManagerIsolation, PayoutEscrow, CoverageSpoke, DexPathRoute, PegModuleRoute, WrapperThenDexRoute.

## How often it runs

The methods check runs in the fast tier on every push. The prover runs at the contract gate once `CERTORAKEY` is set (compile-only until then), in the `Certora` CI job, and `certoraMutate` runs at each layer gate on every contract whose rules verify ([mutation](../mutation/)).

## Latest result

| Date | Check | Result |
|---|---|---|
| 2026-11-10 21:33 | Methods check (fast tier) | 694 methods entries in 30 spec files, 0 errors |
| 2026-11-10 22:25 | Local type check of `Lock.conf` | CVL error at `Lock.spec:117`: `lastReverted` read after a call made without `@withrevert` |
| 2026-11-10 22:25 onward | Prover pass over every conf with a merged implementation | In progress: CVL fixes, then prover jobs with sanity checks; the first cloud job was submitted for `Lock.conf`. Results are logged in `contracts/certora/RUNS.md` |

No `PROP` row has a prover pass recorded yet (`- **Prover passed**:` lines in `RUNS.md`).

## Results folder

- [`RUNS-2026-11-10.md`](results/RUNS-2026-11-10.md): copy of `contracts/certora/RUNS.md` on 2026-11-10.
- [`cvl-methods.txt`](results/cvl-methods.txt): the methods check of the latest fast tier.
- [`certora-typecheck-lock-2026-11-10.log`](results/certora-typecheck-lock-2026-11-10.log): the local type check of `Lock.conf`.
