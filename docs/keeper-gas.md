# Keeper gas

How Avana pays for its own keepers' gas on each chain: the fee rules, the AvanaGasVault, its deployment and funding,
the alerts and what to do on each, and the testnet drills that rehearse the vault. The rules are in the spec:
`EMG-114` (fee classes and budgets) and `EMG-115` (playbook P-22) in
[3.6](spec/03-operations/06-emergency-operations.md), and the vault in [2.23](spec/02-contracts/23-gas-vault.md).

## What runs where

| Part | Where | What it does |
|---|---|---|
| Fee classes | keeper, `chain/gas.ts` | `urgent` (liquidations, pokes that record something, the vault top-up), `scheduled` (checkpoint and feed-round oracle pokes), `lazy` (`settlePending`) each pay their own tip ([keeper/DESIGN.md](../services/keeper/DESIGN.md#fees)) |
| Daily budgets | keeper, `runtime/budget.ts` | `scheduled` and `lazy` stop at their rolling 24-hour budget and page `M-32`; `urgent` is never budget-limited |
| Checkpoint poke | keeper | the hourly checkpoint poke stays; every other poke is checked every block and sent on change |
| Vault top-up | keeper, `jobs/gasTopUp.ts` | `topUpAll()` when the vault lists the keeper's signer, it is below its `minBalance` and the vault would send something |
| AvanaGasVault | chain, `contracts/src/periphery/gas-vault/` | holds the chain's native gas token and refills the listed signers, each at most `periodCap` in any 24 hours; withdraws only to the treasury |
| Alerts | keeper and monitor | `M-17` signer runway, `M-31` spend anomaly, `M-32` budget reached, `M-33` standby unfunded, `M-34` poke overdue, `M-35` vault runway, `M-36` top-up capped ([services/README.md](../services/README.md#monitoring-and-alerting)) |

## Values

Every value comes from the measured daily spend `D` of the chain's keeper signer and the burst reserve `B` (the gas
of liquidating every account the listing's stress shock makes liquidatable, at twice the 99th-percentile base fee).

| Value | Rule | Where it is set |
|---|---|---|
| `minBalance` per signer | 3 × `D` (the top-up falls due when `M-17` would first warn) | `gasVault.signers[].minBalanceWei`, then the timelock's `addSigner` |
| `targetBalance` per signer | 7 × `D` + `B` | `gasVault.signers[].targetBalanceWei` |
| `periodCap` per signer | = `targetBalance` (one full refill a day after a burst; a stolen key costs at most 2 × target) | `gasVault.signers[].periodCapWei` |
| Vault lump sum | 30 × `D` per signer + `B` | `gasVault.fundWei` |
| Expected daily spend | `D` | keeper `KEEPER_GAS_DAILY_SPEND_WEI_<CHAIN>`, monitor `MONITOR_GAS_VAULT_DAILY_WEI` (`chain:wei`) |

Re-derive the values before each `activateMarket` that adds markets: the spend grows with the market count.

## Deployment, per chain

From `contracts/`, after `03-avana` and `05-execute-access-operations`, with the chain's config naming `gasVault`
(`maxSigners`, `fundWei`, and the primary and standby signers with their three values):

```bash
script/deploy/step.sh 12-gas-vault
```

```bash
script/deploy/step.sh 12-gas-vault-signers
```

```bash
script/deploy/step.sh 12-execute-gas-vault-signers
```

```bash
script/deploy/step.sh 12-fund-gas-vault
```

1. `12-gas-vault` deploys the vault with `TREASURY` = the config's `feeRecipient` treasury Safe, `TIMELOCK` = the
   chain's AvanaTimelock and `GUARDIAN` = the Emergency Guardian Safe. It first checks that the treasury is the
   ParameterStore's `feeRecipient` on chain and no operator helper's `FUNDING_SAFE`. No role is granted.
2. `12-gas-vault-signers` writes the timelock operation `gas-vault-signers` (one `addSigner` per configured signer not
   yet listed) for the governance Safe, at the normal delay. On anvil it also schedules it.
3. `12-execute-gas-vault-signers` executes it once the delay has passed. Anyone may.
4. `12-fund-gas-vault` brings the vault to `fundWei` from the treasury. On Ethereum and Base it only prints the treasury
   Safe's transaction (`fund()`, the amount), which the Safe's signers execute.

Then `npm run manifest -- produce` records the vault under `avana.gasVault`, and `verify` checks its code and its three
addresses. The local rehearsal (`script/e2e/e2e-local.sh`) runs these steps after the listing and checks that a drained
signer is refilled by `topUpAll`.

## Funding

- The vault and the signers are funded only by lump sums from the `feeRecipient` treasury Safe, never from
  `FUNDING_SAFE`. A stream is considered only if refills become routine.
- Keeper liquidation profits stay in `FUNDING_SAFE` as float. Turning them into gas is a manual treasury decision; no
  path does it automatically.
- On a second chain the treasury bridges the native token by hand through the canonical bridge, then funds that
  chain's vault.
- Guardian Safe owners pay their own Safe executions: each keeps at least 0.05 ETH (or the native equivalent) on each
  chain.

## Alerts and what to do

The steps are in the services README's [gas funding runbook](../services/README.md#gas-funding-runbook) and in P-22.
In short:

| Signal | First look | Then |
|---|---|---|
| `M-17` signer runway | `M-31`: is spend normal? | Normal spend: the keeper's top-up should have run; find out why it did not (vault paused, cap used, vault empty, signer not listed). Anyone may call `topUp(signer)` |
| `M-31` spend anomaly | spend per class and per Hub | A poke or breaker loop is a griefing case: raise no budget until the cause is known. A liquidation burst is expected in a crash |
| `M-32` budget reached | the spend log | Urgent jobs continue. Raise `KEEPER_DAILY_BUDGET_WEI_<CLASS>_<CHAIN>` only once the cause is known |
| `M-34` poke overdue | keeper heartbeat, balance, `M-32` | Anyone may `poke()`; send one by hand while the keeper is fixed |
| `M-35` vault runway | `M-31` | The treasury Safe sends the vault a lump sum (`fund()`) |
| `M-36` top-up capped | which signer, how much was asked | After a burst, wait for the 24-hour window or raise the cap (`setSignerConfig`, timelock, normal delay). `TopUpFailed`: the signer could not receive |
| Stolen signer key | — | Guardian `removeSigner` on the vault and `freezeAddress` on the operator helper at once; the standby takes over; a new signer through the timelock; rotate the KMS key |

## Testnet drills

To run on Sepolia and Base Sepolia before mainnet. Nothing here has been broadcast to a testnet. The script is
`contracts/script/drills/gas-vault/drill.sh` (header: usage); it deploys a stand-alone vault whose
timelock role is a drill account, so `addSigner` runs without the 4-day delay. The delay itself, and the deploy steps
above, are rehearsed on anvil.

**Before.** Each role signs from its own encrypted Foundry keystore held outside the repository, and the deployer,
treasury, timelock and guardian are funded with test ETH; the signer starts empty.

**Run**, per network (`sepolia`, then `base-sepolia`), from `contracts/`:

```bash
DRILL_PASSWORD_FILE=/path/outside/repo/password script/drills/gas-vault/drill.sh sepolia all --broadcast
```

| Step | Role | Expected |
|---|---|---|
| `deploy` | deployer | vault deployed; `gas-vault-drill.json` written; its three addresses are the drill's |
| `fund` | treasury | the vault holds `DRILL_FUND_WEI` (0.02 ETH by default) |
| `add-signer` | timelock | the signer is listed (min 0.002, target 0.005, cap 0.006 ETH) |
| `top-up` | deployer | the empty signer is filled to 0.005 ETH; the deployer receives nothing |
| `drain` | signer | the signer sends all but 0.0005 ETH back to the treasury |
| `top-up` | deployer | cut to the 0.001 ETH left of the cap: `ToppedUp.amount < requested`, which `M-36` pages on |
| `drain` | signer | as before |
| `check-cap` | — | 0.006 ETH sent in 24 hours; a third top-up is quoted at 0 (it would revert `NothingToSend`) |
| `pause` | guardian | paused; every top-up quoted at 0 |
| `unpause` | timelock | top-ups allowed again |
| `remove-signer` | guardian | the signer is no longer listed |
| `withdraw` | timelock | the vault's whole balance goes to the treasury, the only possible destination |

**Record**, per network: each transaction hash and its gas, the monitor's `M-36` page for the capped top-up and its
`M-35` reading (run the monitor against the drill vault with a manifest naming it), and anything that differed from
the table. A single action can be rerun on its own (`drill.sh sepolia pause --broadcast`), and any action can be
simulated first without `--broadcast`.

## Not done yet

- The 90-day fork replay of feed rounds and base fees (measures `D` per chain and checks the spend anomaly for false
  warns) and the burst fork test (checks `B`) need an archive RPC endpoint.
- The 7-day inclusion-delay measurement by tip on Sepolia and Base Sepolia, which sets the scheduled and lazy tips.
- The testnet drills above, and 14 days of keeper operation on both testnets with the measured `D` within 25 % of the
  model.
