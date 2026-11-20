# Keeper gas

How Avana pays for its own keepers' gas on each chain: the keeper top-up wallet, its band and funding, the alerts and
what to do on each. The AvanaGasVault of [2.24](spec/02-contracts/24-gas-vault.md) was removed in the refactor; the
top-up wallet applies the same refill rule from an ordinary account. The fee rules are in the spec: `EMG-114` (fee
classes and budgets) and `EMG-115` (playbook P-22) in [3.6](spec/03-operations/06-emergency-operations.md).

## What runs where

| Part | Where | What it does |
|---|---|---|
| Fee classes | keeper, `chain/gas.ts` | `urgent` (liquidations), `scheduled` and `lazy` each pay their own tip ([keeper/DESIGN.md](../services/keeper/DESIGN.md#fees)) |
| Daily budgets | keeper, `runtime/budget.ts` | `scheduled` and `lazy` stop at their rolling 24-hour budget and page `M-32`; `urgent` is never budget-limited |
| Keeper top-up wallet | chain, an account with its encrypted Foundry keystore | holds the chain's keeper gas; `KEEPER_TOPUP_WALLET` or the deploy config's `keeperTopUp.wallet`, required on test networks and mainnet |
| Refill | `contracts/script/deploy/11_FundKeepers.s.sol` (`step.sh 11-fund-keepers`) | every keeper signer below `minBalanceWei` is sent back to `targetBalanceWei`, signed by the wallet; safe to rerun |
| Alerts | keeper and monitor | `M-17` signer runway, `M-31` spend anomaly, `M-32` budget reached, `M-33` standby unfunded ([services/README.md](../services/README.md#monitoring-and-alerting)) |

Since the refactor the keepers send only liquidations: the oracles are stateless (no pokes), nothing is left to
settle, the bands are fixed at listing and a depeg is an alert the risk steward answers with a freeze.

## Values

Every value comes from the measured daily spend `D` of the chain's keeper signer and the burst reserve `B` (the gas
of liquidating every account the listing's stress shock makes liquidatable, at twice the 99th-percentile base fee).

| Value | Rule | Where it is set |
|---|---|---|
| `minBalanceWei` | 3 × `D` (the refill falls due when `M-17` would first warn) | `keeperTopUp.minBalanceWei` |
| `targetBalanceWei` | 7 × `D` + `B` | `keeperTopUp.targetBalanceWei` |
| Wallet balance | a first fill to the target per signer, plus 30 × `D` per signer and `B` | the wallet itself |
| Expected daily spend | `D` | keeper `KEEPER_GAS_DAILY_SPEND_WEI_<CHAIN>` |

The test networks' figures (gas per deploy step, `D`, the band and the recommended wallet balance: 1.0 ETH on Sepolia,
0.01 ETH on Base Sepolia) are in [contracts/script/README.md](../contracts/script/README.md#keeper-gas). Re-derive the
values before each `activateMarket` that adds markets: the spend grows with the market count.

## Funding

- The wallet is funded by lump sums from the `feeRecipient` treasury Safe, never from `FUNDING_SAFE`. On a test
  network it is funded with test ETH like the deployer.
- `11-fund-keepers` runs after `09-execute-listing-activate`, then whenever `M-17` warns. It stops before sending
  anything when the wallet holds less than the refill.
- Keeper liquidation profits stay in `FUNDING_SAFE` as float. Turning them into gas is a manual treasury decision; no
  path does it automatically.
- On a second chain the treasury bridges the native token by hand through the canonical bridge, then funds that
  chain's wallet.
- Guardian Safe owners pay their own Safe executions: each keeps at least 0.05 ETH (or the native equivalent) on each
  chain.

## Alerts and what to do

The steps are in the services README's [gas funding runbook](../services/README.md#gas-funding-runbook) and in P-22.
In short:

| Signal | First look | Then |
|---|---|---|
| `M-17` signer runway | `M-31`: is spend normal? | Normal spend: run `11-fund-keepers`; if the wallet is short, the treasury Safe funds it first |
| `M-31` spend anomaly | spend per class and per Hub | A liquidation burst is expected in a crash; anything else is a griefing case: raise no budget until the cause is known |
| `M-32` budget reached | the spend log | Urgent jobs continue. Raise `KEEPER_DAILY_BUDGET_WEI_<CLASS>_<CHAIN>` only once the cause is known |
| `M-33` standby unfunded | the standby's balance | Run `11-fund-keepers` (the standby is one of the config's keepers) |
| Stolen signer key | — | `freezeAddress` on the operator helper at once and remove the keeper; the standby takes over; a new signer through governance; rotate the key |
| Stolen wallet key | — | The loss is at most the wallet's balance, which holds no role: name a new wallet in the config and fund that one |

## Not done yet

- The 90-day fork replay of base fees (measures `D` per chain) and the burst fork test (checks `B`) need an archive RPC
  endpoint.
- 14 days of keeper operation on both test networks with the measured `D` within 25 % of the model.
