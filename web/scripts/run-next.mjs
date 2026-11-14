import { execSync, spawn } from "node:child_process"
import fs from "node:fs"
import path from "node:path"
import process from "node:process"
import { createRequire } from "node:module"
import nextEnv from "@next/env"

const root = process.cwd()
const [mode = "dev", ...forwardArgs] = process.argv.slice(2)
const supportedModes = new Set(["dev", "build", "start"])

if (!supportedModes.has(mode)) {
  process.stderr.write(`Unsupported next mode: ${mode}\n`)
  process.exit(1)
}

// Load the same local configuration Next will use before checking its target.
nextEnv.loadEnvConfig(root, mode === "dev", { info() {}, error() {} })
if (
  (process.env.VERCEL_ENV === "production" || process.env.AVANA_DEPLOYMENT_ENV === "production") &&
  ["AVANA_E2E_SESSION_SECRET", "AVANA_E2E_PRIVATE_JWK", "AVANA_E2E_STAGING"].some((key) => process.env[key])
)
  throw new Error("E2E credentials are forbidden on the production deployment")

// Deploy hygiene: never bake the open-gate test mode into a production build.
// A `build` with NEXT_PUBLIC_PLAYWRIGHT_TEST_MODE=1 inlines IS_OPEN_GATE_TEST_MODE=true
// — a full SIWE/onboarding bypass authenticating every visitor as the test wallet.
// Refuse it so a poisoned artifact can never be produced or shipped.
const isLocalLighthouseAuditBuild =
  process.env.NEXT_PUBLIC_LIGHTHOUSE_AUDIT_MODE === "1" &&
  process.env.AVANA_NEXT_DIST_DIR === ".next-lighthouse" &&
  process.env.NEXT_PUBLIC_LIGHTHOUSE_AUDIT_ARTIFACT === "1" &&
  !process.env.VERCEL &&
  !process.env.CI

if (mode === "build" && process.env.NEXT_PUBLIC_PLAYWRIGHT_TEST_MODE === "1") {
  process.stderr.write(
    "Refusing to build with an open-gate test mode: that bakes the open auth gate\n" +
      "(and the test wallet) into the production artifact. Unset it for production builds.\n",
  )
  process.exit(1)
}

if (mode === "build" && process.env.NEXT_PUBLIC_LIGHTHOUSE_AUDIT_MODE === "1" && !isLocalLighthouseAuditBuild) {
  process.stderr.write("Refusing to build Lighthouse audit mode outside the local .next-lighthouse artifact.\n")
  process.exit(1)
}

const isCI = !!(process.env.VERCEL || process.env.CI)

const modeConfig = isCI
  ? {
      dev: { distDir: ".next", cleanTargets: [] },
      build: { distDir: ".next", cleanTargets: [] },
      start: { distDir: ".next", cleanTargets: [] },
    }
  : {
      dev: {
        distDir: ".next-dev",
        lockFile: ".next-dev.lock.json",
        // Keep .next-dev so Turbopack's persistent filesystem cache survives restarts —
        // wiping it forced a full cold recompile (15-28s per route) on every `npm run dev`.
        // Only clear the stray default `.next` dir a non-scripted `next` invocation may leave.
        // Need a truly clean slate (branch switch, upgrade)? `rm -rf .next-dev` by hand.
        cleanTargets: [".next"],
      },
      build: {
        distDir: ".next-prod",
        guardLockFile: ".next-prod.lock.json",
        cleanTargets: [".next-prod", ".next"],
      },
      start: {
        distDir: ".next-prod",
        lockFile: ".next-prod.lock.json",
        cleanTargets: [],
      },
    }

const config = modeConfig[mode]
// next is hoisted to the monorepo root by the npm workspace; resolve it from here.
const nextBin = path.join(path.dirname(createRequire(import.meta.url).resolve("next/package.json")), "dist", "bin", "next")

function processExists(pid) {
  if (!pid || typeof pid !== "number") {
    return false
  }

  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

function readLock(lockName) {
  if (!lockName) {
    return null
  }

  const lockPath = path.join(root, lockName)

  if (!fs.existsSync(lockPath)) {
    return null
  }

  try {
    const lock = JSON.parse(fs.readFileSync(lockPath, "utf8"))

    if (processExists(lock.pid)) {
      return { ...lock, path: lockPath }
    }
  } catch {
    // ignore malformed lock files and remove them below
  }

  fs.rmSync(lockPath, { force: true })
  return null
}

function writeLock(lockName) {
  if (!lockName) {
    return null
  }

  const lockPath = path.join(root, lockName)
  const payload = {
    pid: process.pid,
    mode,
    cwd: root,
    createdAt: new Date().toISOString(),
  }

  fs.writeFileSync(lockPath, JSON.stringify(payload, null, 2))
  return lockPath
}

function removePath(relativePath) {
  const absolutePath = path.join(root, relativePath)

  if (!fs.existsSync(absolutePath)) {
    return
  }

  fs.rmSync(absolutePath, { recursive: true, force: true })
  process.stdout.write(`removed ${relativePath}\n`)
}

/** Turbopack's persistent cache grows without bound and slows every dev compile once it bloats. */
const TURBOPACK_CACHE_MAX_KB = 2 * 1024 * 1024 // 2 GiB

function directorySizeKb(absolutePath) {
  if (!fs.existsSync(absolutePath)) {
    return 0
  }

  try {
    const out = execSync(`du -sk ${JSON.stringify(absolutePath)}`, { encoding: "utf8" })
    return Number.parseInt(out.split(/\s/)[0] ?? "0", 10)
  } catch {
    return 0
  }
}

function maybePruneTurbopackCache(distDir) {
  if (process.env.AVANA_SKIP_TURBOPACK_CACHE_PRUNE === "1") {
    return
  }

  const cacheDir = path.join(root, distDir, "dev", "cache", "turbopack")
  const sizeKb = directorySizeKb(cacheDir)
  if (sizeKb <= TURBOPACK_CACHE_MAX_KB) {
    return
  }

  const sizeGb = (sizeKb / (1024 * 1024)).toFixed(1)
  process.stdout.write(
    `Pruning turbopack cache (${sizeGb}GB > 2GB) — the next compile will be slower once, then dev should feel responsive again.\n`,
  )
  fs.rmSync(cacheDir, { recursive: true, force: true })
}

const activeLock = readLock(config.lockFile || config.guardLockFile)

if (activeLock) {
  const action =
    mode === "build"
      ? "Builds cannot rewrite .next-prod while a start server is running"
      : mode === "start"
        ? "A production server is already running for this workspace"
        : "A dev server is already running for this workspace"

  process.stderr.write(`${action} (pid ${activeLock.pid}). Stop it first.\n`)
  process.exit(1)
}

if (!fs.existsSync(nextBin)) {
  process.stderr.write("Could not find Next.js binary under node_modules.\n")
  process.exit(1)
}

for (const target of config.cleanTargets) {
  removePath(target)
}

if (mode === "dev") {
  maybePruneTurbopackCache(config.distDir)
}

let lockPath = null
if (config.lockFile) {
  lockPath = writeLock(config.lockFile)
}

function clearLock() {
  if (!lockPath) {
    return
  }

  try {
    fs.rmSync(lockPath, { force: true })
  } catch {
    // ignore lock cleanup failures
  }
}

let child

function forwardSignal(signal) {
  if (child && !child.killed) {
    child.kill(signal)
  }
}

function suppressSlowFilesystemAdvisory(stream, writer) {
  let pending = ""
  let skipping = false

  stream.on("data", (chunk) => {
    pending += chunk.toString()
    const lines = pending.split(/\r?\n/)
    pending = lines.pop() ?? ""

    for (const line of lines) {
      if (line.includes("Slow filesystem detected.")) {
        skipping = true
        continue
      }

      if (skipping) {
        if (line.includes("See more: https://nextjs.org/docs/app/guides/local-development")) {
          skipping = false
        }
        continue
      }

      writer.write(`${line}\n`)
    }
  })

  stream.on("end", () => {
    if (pending && !pending.includes("Slow filesystem detected.") && !skipping) {
      writer.write(pending)
    }
  })
}

process.on("SIGINT", () => forwardSignal("SIGINT"))
process.on("SIGTERM", () => forwardSignal("SIGTERM"))
process.on("exit", clearLock)

child = spawn(process.execPath, [nextBin, mode, ...forwardArgs], {
  cwd: root,
  stdio: mode === "dev" ? ["inherit", "pipe", "pipe"] : "inherit",
  env: {
    ...process.env,
    AVANA_NEXT_DIST_DIR: config.distDir,
  },
})

if (mode === "dev") {
  suppressSlowFilesystemAdvisory(child.stdout, process.stdout)
  suppressSlowFilesystemAdvisory(child.stderr, process.stderr)
}

child.on("exit", (code, signal) => {
  clearLock()

  if (signal) {
    process.kill(process.pid, signal)
    return
  }

  process.exit(code ?? 0)
})
