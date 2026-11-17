# services/faucet

Test funds for a connected wallet on the local fork chains (Ethereum 31337, Base 31338) and on the public test networks (Sepolia 11155111 as the app's Ethereum, Base Sepolia 84532 as its Base). The webapp calls it once per wallet when the wallet onboards.

## What a wallet gets

Per chain, in this order (each step must succeed before the next runs; a failed step stops the grant and is named in the answer):

1. **Chain check.** The chain id must be one of `FAUCET_CHAIN_IDS` and the node must be anvil. On any other chain the faucet does nothing.
2. **Gas.** The native ETH balance is set with `anvil_setBalance`.
3. **Wallet tokens.** Each token balance is set with `anvil_dealERC20`, or with a write to the token's balance slot on an anvil without it. The amounts are the wallet part of the reference app's starting grant ([src/grants.ts](src/grants.ts)).
4. **Starting positions** (LP positions, pledges and debt, lend supplies). These are not built yet.

No step charges the Q-409 front-end fee: the faucet is not an app action. On a fork the faucet holds no key: every step is a cheatcode.

A grant is given once per (chain, wallet) and recorded in `FAUCET_DATA_DIR/grants.json`. A second request returns the recorded grant.

## On the test networks

`FAUCET_CHAIN_KIND=testnet` serves Sepolia and Base Sepolia (`FAUCET_CHAIN_IDS`, default `11155111,84532`; no other chain is accepted). Cheatcodes do not exist there, so:

1. **Chain check.** The chain id must be one of `FAUCET_CHAIN_IDS` and a test network.
2. **Gas** (only with `FAUCET_GAS_ETH` above 0, the default 0 gives none). The wallet is topped up to that much test ETH from the signer.
3. **Wallet tokens.** Each token of the grant is minted to the wallet with `TestToken.mint`, signed by the tokens' minter, the deployer of the network's test world. A token the signer cannot mint fails its line only. The mints go out with consecutive nonces and are confirmed after.

The signer is an encrypted Foundry keystore, `FAUCET_SIGNER_KEYSTORE`, with its password in `FAUCET_SIGNER_PASSWORD_FILE` (both outside the repository); it is decrypted in memory at start and never written. No starting positions are opened there. `contracts/script/testnet/app.ts` starts the faucet this way with the deployer keystore of the private test-network config.

## API (127.0.0.1 only)

| Request | Answer |
|---|---|
| `POST /v1/grant` `{ "chain": "ethereum" \| "base", "wallet": "0x…" }` | 201 with the grant and its steps; 200 with the recorded grant if already given; 400 bad input; 409 not a local fork (or not an allowed test network); 500 a step failed (`failedStep`) |
| `GET /v1/grant?chain=…&wallet=…` | the recorded grant, or 404 |
| `GET /healthz` | 200 |

## Run

```sh
npm run start --workspace @avana/faucet
```

Configuration: [.env.example](.env.example).
