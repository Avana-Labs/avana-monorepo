---
title: <Title>
chain: <Ethereum | Base>
delay: <normal | short>
proposer: <governance Safe | DAO governance executor>
cancel: <any canceller | DAO canceller only>
spec: [<REQ-…>, <Q-…>]
fork_block: <block the fork test pins>
---

# <Title>

## Why

What the operation changes and the reason, with the numbers: the current value, the new value and the rule in
[1.5 Protocol Parameters](../../../spec/01-architecture/05-parameters.md) or the decision in
[4.4 Design Decisions](../../../spec/04-security/04-design-decisions.md) that sets it.

## Calls

| # | Target | Function | Arguments | Delay class |
|---|---|---|---|---|
| 1 | `<Contract>` (`AvanaEthereum.<CONSTANT>`) | `<function>` | `<values>` | `<normal or short>` |

`operation.json` holds the exact batch scheduled on the AvanaTimelock: `targets`, `values`, `payloads`,
`predecessor`, `salt` and `delay`.

## Effect

`diff.md` lists every value the operation changes, read on a fork before and after execution. Expected changes:

- `<path>`: `<before>` → `<after>`

## Checks

```bash
cd contracts
FOUNDRY_PROFILE=governance forge test --match-path test/governance/<Title>.fork.t.sol
python3 script/governance-diff.py ../governance/operations/<YYYYMMDD_Chain_Title>
```

The fork test schedules the batch through the real AvanaTimelock, waits the delay, executes it, writes
`before.json` and `after.json`, and asserts the expected changes and the invariants the operation touches.
