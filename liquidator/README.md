# liquidator

Avana's own liquidation bot, outside the protocol and its audit. It is the first committed operator: it liquidates every Avana account below health factor 1, whether or not the bonus pays.

## How it works

Every pass, the bot:

1. Reads every account the AaveAdapter has deployed, from its `AccountCreated` events.
2. Reads each account's health factor on its Spoke.
3. For an account below 1, picks the debt reserve with the largest debt and funds the liquidation one of two ways ([`decide.ts`](bot/src/decide.ts)):
   - **Flash** ([`FlashLiquidator`](src/FlashLiquidator.sol)): borrows the debt asset from the chain's Aave V3 Pool, calls `LiquidationModule.liquidate` with itself as receiver, sells both pool tokens through Uniswap's SwapRouter02, repays the loan and sends the profit to the bot. Used first while the Aave DAO has granted the contract `FLASH_BORROWER` (no premium, as the ARFC asks). Otherwise used only when the bot's own funds do not cover the debt. A sale that falls short is topped up from the bot, up to `LIQUIDATOR_MAX_TOP_UP`.
   - **Direct**: the bot repays from its own balance through `LiquidationModule.liquidate` and keeps both pool tokens (liquidation in kind). It sells them on its own schedule.
4. Simulates every transaction before sending it. The flash path's `minProfit` is the simulated profit less `LIQUIDATOR_PROFIT_SLIPPAGE_BPS`.

An account the bot cannot fund (no balance and no flash path) is logged as an `ALERT`.

## Signer

The bot signs only from an **encrypted Foundry keystore**:

```sh
cast wallet new ~/.foundry/keystores avana-liquidator    # or: cast wallet import avana-liquidator --interactive
```

`LIQUIDATOR_KEYSTORE` points to the keystore. The password comes from the file at `LIQUIDATOR_PASSWORD_FILE` (kept outside the repository, mode 600), or from a hidden prompt on the terminal when that variable is unset.

The bot refuses to start if the environment holds anything named like a private key, mnemonic, seed phrase or password. No key is in the source, tests, `.env` files, CI or command lines; the tests generate their keys at run time.

The `FlashLiquidator` contract accepts calls only from its `OPERATOR`, the keystore's address, which is set at deployment.

## Settings

| Variable | Meaning |
|---|---|
| `LIQUIDATOR_RPC_URL`, `LIQUIDATOR_CHAIN_ID` | The chain |
| `LIQUIDATOR_ADAPTER`, `LIQUIDATOR_LIQUIDATION_MODULE` | Avana's AaveAdapter and LiquidationModule; the RiskModule and LPVault are read from the module |
| `LIQUIDATOR_DEBT_RESERVES` | Debt reserve ids to check, comma-separated |
| `LIQUIDATOR_FLASH_LIQUIDATOR`, `LIQUIDATOR_SWAP_ROUTER`, `LIQUIDATOR_SWAP_LEGS` | Optional flash path: the contract, SwapRouter02, and `token:feeTier` per pool token (`0x4200…0006:500`) |
| `LIQUIDATOR_MAX_TOP_UP` | Most debt asset added to a flash liquidation that sells at a loss (default 0) |
| `LIQUIDATOR_PROFIT_SLIPPAGE_BPS` | Share of the simulated profit the sent transaction may lose (default 50) |
| `LIQUIDATOR_FROM_BLOCK`, `LIQUIDATOR_POLL_MS` | Where discovery starts, and the pause between passes |
| `LIQUIDATOR_KEYSTORE`, `LIQUIDATOR_PASSWORD_FILE` | The signer (see above) |

```sh
npm start --workspace liquidator
```

## Layout and tests

- `src/`, `test/`: Foundry contracts. They compile against `../contracts/src` (remapped as `avana/`) and its dependencies, so run `forge soldeer install` in `contracts/` first. The swap step reuses the periphery's `SwapCalls`. Run `forge test -j 2` here (CI: the `liquidator` job in `contracts.yml`).
- `bot/`: the TypeScript runner and its vitest suite. Run `npm test --workspace liquidator` (CI: `services.yml`).

The services step moves discovery to the Ponder indexer's account stream and registers the bot as the first keeper in the RiskModule's registry.
