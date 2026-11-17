// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The webapp's dev server on the local stack (contracts/script/local/stack.ts starts it as its `webapp` process).
//
//   node scripts/local-stack.mjs <path to deployments-local/stack/stack.env>
//
// Reads the stack's endpoints from stack.env, sets the webapp's environment from them and runs `next dev` on the
// stack's webapp origin. The two values the webapp shares with the local Convex deployment (the rate-limit secret and
// the SIWE signing key) are random files in the stack's secrets folder, made on first use; no value is written here.

import { spawn } from "node:child_process"
import crypto from "node:crypto"
import fs from "node:fs"
import path from "node:path"
import process from "node:process"

const envFile = process.argv[2]
if (!envFile || !fs.existsSync(envFile)) {
  process.stderr.write("usage: node scripts/local-stack.mjs <deployments-local/stack/stack.env>\n")
  process.exit(1)
}

const stack = Object.fromEntries(
  fs
    .readFileSync(envFile, "utf8")
    .split(/\r?\n/)
    .filter((l) => /^[A-Z0-9_]+=/.test(l))
    .map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1).trim()]),
)

function need(key) {
  const v = stack[key]
  if (!v) {
    process.stderr.write(`${envFile} has no ${key}: run the stack's up command first\n`)
    process.exit(1)
  }
  return v
}

/** A random file in the stack's secrets folder, made on first use (stack.ts's secret() reads the same files). */
function secret(name, make) {
  const dir = path.join(path.dirname(envFile), "secrets")
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 })
  const p = path.join(dir, name)
  if (!fs.existsSync(p)) fs.writeFileSync(p, make(), { mode: 0o600 })
  return fs.readFileSync(p, "utf8").trim()
}

const sessionJwk = () => {
  const { privateKey } = crypto.generateKeyPairSync("rsa", { modulusLength: 2048 })
  return JSON.stringify({ ...privateKey.export({ format: "jwk" }), kid: crypto.randomUUID(), alg: "RS256" })
}

// The stack lists its chains Ethereum first, then Base.
const [ethereumId, baseId] = need("STACK_CHAIN_IDS").split(",")
const webapp = new URL(need("STACK_WEBAPP_URL"))
const env = {
  NEXT_PUBLIC_CONVEX_URL: need("STACK_CONVEX_URL"),
  NEXT_PUBLIC_CONVEX_SITE_URL: stack.STACK_CONVEX_SITE_URL ?? "",
  CONVEX_URL: need("STACK_CONVEX_URL"),
  CONVEX_RATE_LIMIT_SECRET: secret("convex-rate-limit-secret", () => crypto.randomBytes(32).toString("base64")),
  NEXT_PUBLIC_AVANA_ETHEREUM_CHAIN_ID: ethereumId,
  NEXT_PUBLIC_AVANA_BASE_CHAIN_ID: baseId,
  NEXT_PUBLIC_AVANA_CHAIN_ID: ethereumId,
  NEXT_PUBLIC_RPC_ETHEREUM: need(`STACK_RPC_${ethereumId}`),
  NEXT_PUBLIC_RPC_BASE: need(`STACK_RPC_${baseId}`),
  NEXT_PUBLIC_AVANA_NETWORK_LABEL: "Local",
  NEXT_PUBLIC_AVANA_SWAP_PROVIDER: "onchain-pools",
  FAUCET_URL: process.env.FAUCET_URL || need("STACK_FAUCET_URL"),
  NEXT_PUBLIC_SIWE_ISSUER: webapp.origin,
  SIWE_JWT_PRIVATE_JWK: secret("siwe-jwt-private-jwk", sessionJwk),
}

const child = spawn(
  process.execPath,
  [path.join("scripts", "run-next.mjs"), "dev", "--hostname", webapp.hostname, "--port", webapp.port || "3000"],
  { cwd: process.cwd(), env: { ...process.env, ...env }, stdio: "inherit" },
)
for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, () => child.kill(signal))
child.on("exit", (code, signal) => process.exit(code ?? (signal ? 1 : 0)))
