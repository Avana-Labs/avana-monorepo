# Design risk review: run log

One entry per design review pass. Each new pass appends an entry; earlier entries are never edited. Findings are tracked in the [findings register](../findings-register.md); the review itself is [risk-review.md](risk-review.md).

## DR-R1 — 2026-11-09 — adversarial design review

| Item | Value |
|---|---|
| Date | 2026-11-09 |
| What ran | A manual adversarial review of the protocol design: invariants that must hold, failure modes (50 % price shock, liquidity withdrawal, oracle lag and manipulation), a per-function transition analysis, parameter drift, MEV, token handling, OpSec and the risk-parameter process, circuit breakers and monitoring, and a critique of test coverage |
| Command | None. The review is a reading of the inputs below; each scenario's numbers are worked in the review text and can be recomputed from the reference values in its opening table. |
| Inputs | `spec/` as rewritten for decisions `Q-223`…`Q-240`; [1.5 Protocol Parameters](../../spec/01-architecture/05-parameters.md); [4.4 Design Decisions](../../spec/04-security/04-design-decisions.md); the interface tree under `contracts/src` (interfaces and types only); user decisions U1–U4 of 2026-11-09 |
| Tools | None beyond the spec text; no model or solver was run in this pass |
| Seeds and bounds | Not applicable. Reference values: `CF_LP` 3,120 bps, `minOpeningHealthFactor` 1.10, `PROXY_HEALTH_FACTOR_FLOOR` 1.05, bonus 10,200–10,500 bps, `slippageAllowanceBps` 100, `buySlippageAllowanceBps` 1–300, SettlementBudget 25 / 500 GHO, `firstLossReserveMinimum[GHO]` 100,000, `minPledgeUsd` $10. |
| Results | 20 findings: 4 High, 11 Medium, 4 Low, 1 Informational. 11 required tests specified (`DR-T-01`…`DR-T-11`). |
| Exit code | Not applicable |
| Findings produced | `DR-01`…`DR-20` |
| Spec state | Decisions `Q-001`…`Q-240` |
