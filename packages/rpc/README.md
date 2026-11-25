# @avana/rpc

`AvanaRPCManager`, Avana's shared RPC layer. A caller gives provider credentials once; the manager builds each chain's endpoints, picks a healthy one, fails over to the backup provider on infrastructure failures and comes back when the primary is healthy again.

```ts
import { AvanaRPCManager } from "@avana/rpc";

const rpc = AvanaRPCManager.fromEnv();                     // reads the variables below
const client = rpc.getClient(11155111);                    // viem PublicClient: failover, multicall batching
const ws = rpc.getWebSocketClient(84532);                  // WebSocket: reconnects, subscriptions
const wallet = createWalletClient({ account, chain: sepolia, transport: rpc.transport(11155111) });
const ep = await rpc.selectHealthy(84532);                 // one endpoint for a child process (forge, cast)
childEnv.AVANA_RPC_URL = ep.secretUrl();                   // environment only: never argv, never a log
```

## Environment

| Variable | Effect |
|---|---|
| `ALCHEMY_API_KEY` | Alchemy, the primary provider |
| `QUICKNODE_ENDPOINT_NAME`, `QUICKNODE_TOKEN` | QuickNode, the backup (both required) |
| `AVANA_RPC_PROVIDERS` | Provider order for every chain, default `alchemy,quicknode` |
| `AVANA_RPC_PROVIDERS_<SYM>` | Provider order for one chain |
| `RPC_<SYM>`, `RPC_WS_<SYM>` | An explicit endpoint: when set it is the chain's only endpoint (escape hatch; the same `RPC_<SYM>` as the Aave toolbox and `contracts/foundry.toml`) |

`<SYM>` is `MAINNET` (1), `SEPOLIA` (11155111), `BASE` (8453) or `BASE_SEPOLIA` (84532). A provider is used only when all its credentials are set. Options of the constructor set the same things in code, per chain, plus freshness limits.

## Behaviour

- **Transport**: Aave's values, `timeout` 30 s, JSON-RPC batching, `retryCount` 5, `retryDelay` 500 ms, multicall batching. One change: the retries are counted across providers, not per URL (Aave's 5 retries on one URL become 5 retries where the first moves to the backup at once), and each provider's own viem transport has its retries off.
- **Failover**: only infrastructure failures move a request: a timeout, a connection error, HTTP 429 or JSON-RPC 429/-32005/-32007, HTTP 5xx or -32603, HTTP 401/403/404 (a refused key or a network not enabled), a malformed answer (not JSON-RPC, the wrong type, another chain) and a stale head. A revert or an invalid request (HTTP 400/413, -32602, -32601, `execution reverted`, `nonce too low`, …) is returned to the caller at once, never retried.
- **Backoff**: retry `n` waits `500 ms × 2^n`, or the `Retry-After` the provider sent (60 s at most), except a move to a provider in use, which is immediate.
- **Health**: a probe reads `eth_chainId` and the latest block. It is good when it answers within 5 s, on the right chain, at most `maxLagBlocks` behind the best head seen (3 on Ethereum, 15 on Base) and at most `maxHeadAgeMs` old (90 s, 30 s). Every 10 s while requests flow, the providers are probed in the background.
- **Hysteresis**: a provider goes out of use on its first infrastructure failure (`failoverAfter`) and comes back after 3 consecutive good probes (`recoverAfter`), the first at least 30 s after it went out (`recoverCooldownMs`) and the next 10 s apart. A failed probe restarts the count and the cool-down.
- **Transactions**: `eth_sendRawTransaction` is tracked by hash, sender and nonce. After a send with an unknown outcome (timeout, dropped connection, server error), the next provider is asked for the hash, then the sender's mined and pending nonces; only a transaction found nowhere whose nonce is free is sent again, as the same signed bytes. A nonce used by another transaction throws `NonceConsumedError`; anything unsettled throws `TransactionOutcomeUnknownError` without sending. A hash the caller sends again after it was accepted is answered without a request. `eth_sendTransaction` (the node assigns the nonce) is sent once.
- **WebSocket**: viem's `webSocket` transport per provider, reconnecting (5 attempts, 2 s apart) with a 30 s keep-alive; requests fail over as over HTTP, subscriptions go to the provider in use and viem re-subscribes after a reconnect.
- **Secrets**: an `Endpoint` prints as `provider:chain:kind`; its URL is read only with `secretUrl()`. Every log line and every error the manager lets out has the credentials and authenticated URLs replaced by their names (viem names the full URL in its errors). Errors are scrubbed in place, so viem still decodes a revert from them.

## Files

| File | Contents |
|---|---|
| `src/chains.ts` | The four chains: viem chain, `RPC_<SYM>` symbol, freshness limits |
| `src/providers.ts` | The provider registry: credentials, network slugs, HTTP and WebSocket URL builders. A new provider is one entry |
| `src/config.ts` | Transport defaults (Aave's), health policy, `configFromEnv` |
| `src/errors.ts` | Failure classification (`classifyError` for viem errors, `classifyText` for forge and cast output) and the errors the manager throws |
| `src/health.ts` | `Endpoint`, `HealthTracker` |
| `src/transport.ts` | `FailoverRpc`: retries, failover, probes, the transaction-send guard; `failoverTransport` |
| `src/manager.ts` | `AvanaRPCManager` |

The operator test-network deploy uses it (a healthy provider per forge step, a resume on the backup after an RPC failure).

## Test

```bash
npm run typecheck
npm run test
```

`test/manager.test.ts` runs against mocked providers, plus a local HTTP server (a real timeout, an HTML answer) and a local WebSocket server (a dropped socket). `test/integration.test.ts` runs against the real providers only when their credentials are in the environment, and is skipped otherwise.
