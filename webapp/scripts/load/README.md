# Load tests

Live HTTP concurrency stress tests for the deployed Avana app. These complement the
in-process engine stress test: the engine test proves the simulation math scales, while
these prove the **live Convex/HTTP path** (Next.js route handlers + the Convex read path
behind them) survives ~1,000 concurrent users.

## Prerequisites

Install [k6](https://k6.io/docs/get-started/installation/):

```sh
brew install k6          # macOS
# or see https://k6.io/docs/get-started/installation/ for other platforms
```

## `live-concurrency.k6.js`

Ramps to ~1,000 concurrent virtual users hitting the balance/market **read** endpoints,
asserting a p95 latency threshold and zero dropped requests. It is **read-only** (GET
only — no sign-in, no writes) and includes a commented WebSocket scenario for
subscribing to live position/price updates against staging.

### Run it

```sh
# Against a local dev server (the safe default when BASE_URL is unset)
k6 run scripts/load/live-concurrency.k6.js

# Against STAGING (never prod — see below)
BASE_URL=https://staging.example.internal k6 run scripts/load/live-concurrency.k6.js

# Tune the peak concurrency and thresholds
PEAK_VUS=1000 P95_MS=800 MAX_ERROR_RATE=0.01 \
  BASE_URL=https://staging.example.internal k6 run scripts/load/live-concurrency.k6.js
```

### Environment variables

| Var              | Default                 | Meaning                                                                   |
| ---------------- | ----------------------- | ------------------------------------------------------------------------- |
| `BASE_URL`       | `http://localhost:3000` | Target origin. Localhost or **staging** only.                             |
| `PEAK_VUS`       | `1000`                  | Peak concurrent virtual users.                                            |
| `P95_MS`         | `800`                   | p95 latency ceiling (ms). Test fails if exceeded.                         |
| `MAX_ERROR_RATE` | `0.01`                  | Max tolerated failed-request rate (1%).                                   |
| `CONVEX_WS_URL`  | _(unset)_               | Staging Convex `wss://…` URL for the optional live-subscription scenario. |

The run fails the thresholds if p95 latency exceeds `P95_MS`, if the failed-request rate
exceeds `MAX_ERROR_RATE`, or if any request is dropped (connection refused / reset /
timed out).

## ⚠️ Never target production

These scripts generate ~1,000 concurrent users of sustained traffic. **Only ever run
them against a local dev server or a dedicated staging deployment.** Running them against
production would degrade or take down the live app for real users.

As a safety net, `live-concurrency.k6.js` has a prod guard in `setup()` that throws and
aborts the run if `BASE_URL` (or `CONVEX_WS_URL`) looks like a production origin. Do not
weaken or remove that guard.
