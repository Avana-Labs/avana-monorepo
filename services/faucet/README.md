# services/faucet

Test funds for a connected wallet on the local fork chains (Ethereum 31337, Base 31338). The webapp calls it once per wallet when the wallet onboards.

## What a wallet gets

Per chain, in this order (each step must succeed before the next runs; a failed step stops the grant and is named in the answer):

1. **Chain check.** The chain id must be one of `FAUCET_CHAIN_IDS` and the node must be anvil. On any other chain the faucet does nothing.
2. **Gas.** The native ETH balance is set with `anvil_setBalance`.
3. **Wallet tokens.** Each token balance is set with `anvil_dealERC20`, or with a write to the token's balance slot on an anvil without it. The amounts are the wallet part of the reference app's starting grant ([src/grants.ts](src/grants.ts)).
4. **Starting positions** (LP positions, pledges and debt, lend supplies). These are not built yet.

No step charges the Q-409 front-end fee: the faucet is not an app action. The faucet holds no key: on a fork, every step is a cheatcode.

A grant is given once per (chain, wallet) and recorded in `FAUCET_DATA_DIR/grants.json`. A second request returns the recorded grant.

`FAUCET_CHAIN_KIND=testnet` (Sepolia) refuses every grant for now: impersonation and cheatcodes do not exist there, and how test funds are given is not decided yet.

## API (127.0.0.1 only)

| Request | Answer |
|---|---|
| `POST /v1/grant` `{ "chain": "ethereum" \| "base", "wallet": "0x…" }` | 201 with the grant and its steps; 200 with the recorded grant if already given; 400 bad input; 409 not a local fork; 500 a step failed (`failedStep`) |
| `GET /v1/grant?chain=…&wallet=…` | the recorded grant, or 404 |
| `GET /healthz` | 200 |

## Run

```sh
npm run start --workspace @avana/faucet
```

Configuration: [.env.example](.env.example).
