# Keeper gas

How Avana pays for its own keepers' gas on each chain: the keeper top-up wallet, its band and funding, the alert and
what to do on it. There is no gas contract: the top-up wallet is an ordinary account, and the refill is a deploy step.

## What runs where

| Part | Where | What it does |
|---|---|---|
| Keeper signers | the config's `keepers` and each operator FlashLiquidator's `OPERATOR` | send liquidations and pay their own gas ([bot runner design](../services/keeper/DESIGN.md)) |
| Keeper top-up wallet | chain, an account with its encrypted Foundry keystore | holds the chain's keeper gas; `KEEPER_TOPUP_WALLET` or the deploy config's `keeperTopUp.wallet`, required on test networks and mainnet |
| Refill | `contracts/script/deploy/11_FundKeepers.s.sol` (`step.sh 11-fund-keepers`) | every keeper signer below `minBalanceWei` is sent back to `targetBalanceWei`, signed by the wallet; safe to rerun |
| Alert | monitor, `M-35` | a keeper signer below `minBalanceWei` warns (run the step), below a third of it pages; the top-up wallet below one full refill of every signer warns ([services/README.md](../services/README.md#monitoring-and-alerting)) |

The keepers send only liquidations: the oracles are stateless (no pokes), nothing is left to settle, the bands are
fixed at listing and a depeg is an alert answered with an Aave reserve freeze.

## Values

Every value comes from the measured daily spend `D` of the chain's keeper signer and the burst reserve `B` (the gas
of liquidating every account the listing's stress shock makes liquidatable, at twice the 99th-percentile base fee).

| Value | Rule | Where it is set |
|---|---|---|
| `minBalanceWei` | 3 × `D` | `keeperTopUp.minBalanceWei` |
| `targetBalanceWei` | 7 × `D` + `B` | `keeperTopUp.targetBalanceWei` |
| Wallet balance | a first fill to the target per signer, plus 30 × `D` per signer and `B` | the wallet itself |

The test networks' figures (gas per deploy step, `D`, the band and the recommended wallet balance: 1.0 ETH on Sepolia,
0.01 ETH on Base Sepolia) are in [contracts/script/README.md](../contracts/script/README.md#keeper-gas). Re-derive the
values before each `activateMarket` that adds markets: the spend grows with the market count.

## Funding

- The wallet is funded by lump sums from the treasury (the RiskModules' `feeRecipient`). On a test network it is funded
  with test ETH like the deployer.
- `11-fund-keepers` runs after `09-execute-listing-activate`, then whenever `M-35` warns. It stops before sending
  anything when the wallet holds less than the refill.
- The LiquidationBot keeps the pool tokens of a direct liquidation and the profit of a flash liquidation in its own
  wallet; turning them into gas is a manual treasury decision.
- On a second chain the treasury bridges the native token by hand through the canonical bridge, then funds that
  chain's wallet.
- Safe owners pay their own Safe executions: each keeps at least 0.05 ETH (or the native equivalent) on each chain.

## Alerts and what to do

The steps are in the services README's [gas funding runbook](../services/README.md#gas-funding-runbook). In short:

| Signal | Then |
|---|---|
| `M-35` keeper signer below `minBalanceWei` | Run `11-fund-keepers`; if the wallet is short, the treasury funds it first |
| `M-35` page (below a third of the minimum) | Run it now and find out why the warn was not acted on |
| `M-35` top-up wallet below one full refill | The treasury refills the wallet |
| Stolen signer key | `removeKeeper` by the Joint Configuration Safe at once; a new signer is added by `addKeeper` at the governance delay, with a new operator FlashLiquidator (its `OPERATOR` is fixed at deployment) and its `FLASH_BORROWER` grant; rotate the key. Liquidation stays open to anyone meanwhile |
| Stolen wallet key | The loss is at most the wallet's balance, which holds no role: name a new wallet in the config and fund that one |

## Not done yet

- The 90-day fork replay of base fees (measures `D` per chain) and the burst fork test (checks `B`) need an archive RPC
  endpoint.
- 14 days of keeper operation on both test networks with the measured `D` within 25 % of the model.
