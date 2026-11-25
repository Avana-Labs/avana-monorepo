# test/invariant/echidna

Property harnesses that both Echidna and Medusa run (`script/security-slow.sh echidna` and `medusa`). Each harness is one contract named `<Subject>Properties` in a file of the same name, with one harness per Avana contract or library; the runners find every `*Properties` contract in this folder through the build, so a new harness runs on the next run with nothing else to register.

## How a harness is written

- **Properties.** `property_<behavior>()` returns `bool` and must hold after every transaction of every sequence. Echidna runs them in property mode (`prefix: "property_"` in `echidna.yaml`) and Medusa in property testing (`testPrefixes` in `medusa.json`).
- **Assertions.** Every other state-changing function is an assertion entry point: the fuzzers call it with random arguments and fail on any reachable `assert`. hevm then proves each entry point symbolically (`hevm symbolic --sig` against a local chain on which the harness is deployed, so the constructor has run and the contracts it deploys execute from their deployed code and storage), and the run fails unless every one reaches QED, so an assertion function keeps its branching finite: a symbolic index selects among concrete cases with `if` branches rather than a memory-array lookup.
- **Arithmetic hevm can decide.** hevm hands z3 256-bit bit-vector queries. z3 decides an exact formula written in the shape the code computes it, and arithmetic where one factor of every product and every divisor is a literal; it does not finish within `HEVM_SMT_TIMEOUT` when an exponent is symbolic (`10 ** decimals`: hevm cannot encode it at all), when two symbolic values are multiplied (a `mulDiv` or a checked `x * y`), or when an inequality between 128-bit sums or a floor-division bound must be derived (a linear top-up query takes 4 s at 32 bits, 24 s at 64 bits and more than 150 s at 128 bits). So a math harness gives each parameter that makes the arithmetic nonlinear (decimals, tolerances, block times, fee shares, slippages, rises) a concrete case: one entry point per value, or a `which` selector over a few literals, with the amounts symbolic and bounded by masks or `%` by a power of two (a `%` by any other number is a division). Its assertions there are the spec formulas; the bounds that follow from them (rounding direction, conservation, minimality) are checked over the whole input range by `property_` functions on the inputs a `fuzz<Formula>` entry point records, so Echidna's property mode and Medusa keep the full range. A `fuzz` entry point holds no assertion.
- **State.** The harness deploys or holds the subject the way production does (constructor arguments, roles granted through the timelock path). Handlers bound their inputs to the listing bounds of the spec, as the Foundry invariant handlers in `test/invariant/handlers/` do.
- **Time.** `maxTimeDelay` (Echidna) and `blockTimestampDelayMax` (Medusa) allow jumps of up to 14 days per call, so one sequence crosses the 12-hour short delay, the 5-day normal delay and the 14-day grace period.

## Harnesses

| Harness | Subject | Properties | Assertion entry points |
|---|---|---|---|
| `AvanaRolesProperties` | `src/AvanaRoles.sol` | each role is the keccak256 of its name; no role is `DEFAULT_ADMIN_ROLE`; the four Avana roles and the three `TimelockController` roles are pairwise distinct | `checkRolePair(i, j)`: identifiers equal exactly when the indexes are |

The core contracts are fuzzed by the Foundry invariant suites in `test/invariant/` and checked symbolically by Halmos (`test/halmos/`), hevm (every `src/` contract) and Certora. A new harness here joins the slow tier on its next run.

## Commands

From `contracts/`:

```bash
script/security-slow.sh build echidna          # every harness, property and assertion mode
ECHIDNA_TEST_LIMIT=100000 ECHIDNA_TIMEOUT=600 script/security-slow.sh build echidna     # nightly budget
script/security-slow.sh build medusa           # the same harnesses under Medusa
```

Corpora and coverage reports are kept in `out-security/corpus/echidna/<Harness>-<mode>/` and `out-security/corpus/medusa/<Harness>/`, so each run starts from every sequence that reached new coverage before (the nightly job restores them from the Actions cache); logs are in `out-security/echidna/` and `out-security/medusa/`.
