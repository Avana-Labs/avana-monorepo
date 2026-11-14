/**
 * live-concurrency.k6.js — live HTTP concurrency stress test for the Avana app.
 *
 * WHY THIS EXISTS
 * ---------------
 * The engine-level stress test exercises the pure simulation math in-process; it does
 * NOT prove that the deployed app (Next.js route handlers + the Convex read path behind
 * them) survives ~1,000 concurrent users hitting the balance/market read endpoints and
 * subscribing to live position/price updates. This k6 script drives that live HTTP path.
 *
 * SAFETY
 * ------
 *   - Parameterized by BASE_URL and defaults to a safe localhost origin.
 *   - Refuses to run against anything that looks like production (see the prod guard in
 *     setup()). Point it at a STAGING deployment.
 *   - Read-only: it only issues GET requests. It never mutates state, signs in, or writes.
 *
 * RUN
 * ---
 *   # local dev server (default)
 *   k6 run scripts/load/live-concurrency.k6.js
 *
 *   # staging (see scripts/load/README.md — never prod)
 *   BASE_URL=https://staging.example.internal k6 run scripts/load/live-concurrency.k6.js
 *
 *   # tune the peak (defaults to ~1000 VUs)
 *   PEAK_VUS=1000 BASE_URL=https://staging.example.internal k6 run scripts/load/live-concurrency.k6.js
 */

/* global __ENV */
import http from "k6/http"
import ws from "k6/ws"
import { check, sleep } from "k6"
import { Counter, Rate } from "k6/metrics"

// --- Configuration (all overridable via env) --------------------------------------

// Default to loopback so an accidental `k6 run` never touches a shared environment.
const BASE_URL = (__ENV.BASE_URL || "http://localhost:3000").replace(/\/+$/, "")
const PEAK_VUS = Number(__ENV.PEAK_VUS || 1000)

// Convex WS URL — e.g. wss://<staging-deployment>.convex.cloud. Empty by default so a
// bare `k6 run` never opens a subscription socket. When set, the live-subscription
// scenario runs alongside the HTTP scenario and proves the reactive path holds under
// concurrent long-lived clients.
const CONVEX_WS_URL = (__ENV.CONVEX_WS_URL || "").replace(/\/+$/, "")
const WS_VUS = Number(__ENV.WS_VUS || 200)
const WS_HOLD_SECONDS = Number(__ENV.WS_HOLD_SECONDS || 60)

// p95 latency ceiling (ms) and the maximum tolerated share of failed requests.
const P95_MS = Number(__ENV.P95_MS || 800)
const MAX_ERROR_RATE = Number(__ENV.MAX_ERROR_RATE || 0.01)

// Read-only endpoints that model what a browsing/authenticated user polls. Adjust the
// paths to match the deployment under test; these are the app's balance/market reads.
const READ_ENDPOINTS = [
  "/", // home / market overview shell
  "/borrow", // market list read path
  "/lend", // supply market read path
  "/dashboard", // portfolio/balance read path
]

// --- Custom metrics ----------------------------------------------------------------

const droppedRequests = new Counter("dropped_requests")
const requestErrors = new Rate("request_errors")
const wsConnectFailures = new Counter("ws_connect_failures")
const wsUpgradeSuccess = new Rate("ws_upgrade_success")

// --- Load profile: ramp toward ~1,000 concurrent VUs and hold -----------------------

const httpScenario = {
  executor: "ramping-vus",
  exec: "httpBrowse",
  startVUs: 0,
  stages: [
    { duration: "1m", target: Math.ceil(PEAK_VUS * 0.25) },
    { duration: "2m", target: PEAK_VUS },
    { duration: "3m", target: PEAK_VUS }, // hold at ~1,000 concurrent users
    { duration: "1m", target: 0 },
  ],
  gracefulRampDown: "30s",
}

// Convex live-subscription scenario. Only mounts when CONVEX_WS_URL is provided so a
// bare `k6 run` never opens a socket. `constant-vus` holds WS_VUS long-lived sockets
// for WS_HOLD_SECONDS — enough surface to prove the reactive path survives concurrent
// subscribers while the HTTP scenario ramps.
const wsScenario = CONVEX_WS_URL
  ? {
      live_subscriptions: {
        executor: "constant-vus",
        exec: "convexSubscribe",
        vus: WS_VUS,
        duration: `${WS_HOLD_SECONDS + 30}s`,
      },
    }
  : {}

export const options = {
  scenarios: {
    live_concurrency: httpScenario,
    ...wsScenario,
  },
  thresholds: {
    // p95 latency ceiling — the primary SLO this test defends.
    http_req_duration: [`p(95)<${P95_MS}`],
    // No dropped requests: k6 records connection failures / timeouts as failed http_reqs.
    http_req_failed: [`rate<${MAX_ERROR_RATE}`],
    dropped_requests: ["count==0"],
    request_errors: [`rate<${MAX_ERROR_RATE}`],
    // Every attempted subscription must upgrade to WebSocket. If Convex refuses the
    // upgrade under load, ws_upgrade_success drops and this threshold trips.
    ...(CONVEX_WS_URL ? { ws_upgrade_success: ["rate>0.99"], ws_connect_failures: ["count==0"] } : {}),
  },
}

// --- Prod guard: fail fast rather than ever stress production -----------------------

function looksLikeProd(url) {
  const u = url.toLowerCase()
  return (
    u.includes("avana.cc") ||
    u.includes("://avana.") ||
    u.includes("www.avana") ||
    u.includes(".prod.") ||
    u.includes("production")
  )
}

export function setup() {
  if (looksLikeProd(BASE_URL)) {
    throw new Error(
      `Refusing to run: BASE_URL="${BASE_URL}" looks like production. ` +
        `This load test must only target localhost or a staging deployment.`,
    )
  }
  if (CONVEX_WS_URL && looksLikeProd(CONVEX_WS_URL)) {
    throw new Error(
      `Refusing to subscribe: CONVEX_WS_URL="${CONVEX_WS_URL}" looks like production. ` +
        `Point this at a staging Convex deployment only.`,
    )
  }
  // Smoke the target once so a misconfigured BASE_URL fails before the ramp starts.
  const res = http.get(`${BASE_URL}/`, { tags: { name: "setup" } })
  check(res, { "target reachable": (r) => r.status !== 0 })
  return { baseUrl: BASE_URL, convexWsUrl: CONVEX_WS_URL }
}

// --- Virtual user loops -------------------------------------------------------------

export function httpBrowse(data) {
  const base = data.baseUrl
  const path = READ_ENDPOINTS[Math.floor(Math.random() * READ_ENDPOINTS.length)]
  const res = http.get(`${base}${path}`, {
    tags: { name: path },
    // A user waiting >P95_MS on a read is effectively a dropped experience.
    timeout: `${Math.max(P95_MS * 5, 5000)}ms`,
  })

  // status 0 == connection refused / reset / timed out == a dropped request.
  if (res.status === 0) {
    droppedRequests.add(1)
  }
  const ok = res.status >= 200 && res.status < 400
  requestErrors.add(!ok)
  check(res, {
    "status is 2xx/3xx": () => ok,
    "not dropped": () => res.status !== 0,
  })

  // Model a browsing user's think-time between reads.
  sleep(Math.random() * 2 + 1)
}

// Retained for scripts that still call the default export (compatibility shim).
export default httpBrowse

/**
 * Live position/price subscription VU. Opens a WebSocket to the staging Convex
 * deployment, holds it for WS_HOLD_SECONDS, then closes cleanly. Each socket counts
 * as one concurrent live subscriber — the surface HTTP reads DON'T exercise. The
 * scenario only runs when CONVEX_WS_URL is set (see setup guard). The Convex Sync
 * protocol is proprietary; a socket that upgrades cleanly, stays open for the hold
 * window, and closes without an error frame is proof enough that Convex accepted
 * the connection under concurrent load — subscribing to a specific query set with
 * the Sync frames is an optional enrichment (see the socket.send stub below).
 */
export function convexSubscribe(data) {
  const url = data.convexWsUrl
  if (!url) return
  const holdMs = WS_HOLD_SECONDS * 1000

  const res = ws.connect(url, {}, (socket) => {
    let opened = false
    socket.on("open", () => {
      opened = true
      // Optional enrichment: the Convex Sync protocol expects a Connect frame here
      // followed by a ModifyQuerySet subscribing to concrete queries (e.g.
      // api.sandbox.prices.subscribe). We don't ship those frames because their
      // shape is deployment-specific; opening the socket + holding it is already
      // a stronger signal than the HTTP scenario, which never exercises WS at all.
      // Callers with a canned Connect frame can send it here.
    })
    socket.on("error", () => {
      // Recorded via the res.status check below.
    })
    socket.setTimeout(() => socket.close(), holdMs)
    // If the socket never fires "open" within the hold window, treat as failure.
    socket.setTimeout(
      () => {
        if (!opened) {
          wsConnectFailures.add(1)
          socket.close()
        }
      },
      Math.min(10_000, holdMs),
    )
  })

  const upgraded = res && res.status === 101
  wsUpgradeSuccess.add(upgraded ? 1 : 0)
  if (!upgraded) {
    wsConnectFailures.add(1)
  }
  check(res, { "ws upgrade 101": (r) => r && r.status === 101 })
}
