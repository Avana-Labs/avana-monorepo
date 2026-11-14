import { execFileSync } from "node:child_process"
import fs from "node:fs"
import process from "node:process"

const failures = []

function fail(message) {
  failures.push(message)
}

function trackedFiles() {
  return execFileSync("git", ["ls-files"], { encoding: "utf8" })
    .split("\n")
    .map((file) => file.trim())
    .filter(Boolean)
}

const files = trackedFiles()

for (const file of files) {
  const isEnvironmentTemplate = /(?:^|\/)\.env\.example$/.test(file)
  if (!isEnvironmentTemplate && (/^\.env(?:\.|$)/.test(file) || /\/\.env(?:\.|$)/.test(file))) {
    fail(`Tracked environment file is not allowed: ${file}`)
  }
}

const secretRules = [
  {
    name: "Convex deploy key",
    pattern: /prod:[a-z0-9-]+\|[A-Za-z0-9_-]{20,}/,
  },
  {
    name: "Vercel OIDC token assignment",
    pattern: /VERCEL_OIDC_TOKEN\s*=\s*["']?eyJ[A-Za-z0-9_-]+\./,
  },
  {
    name: "Private key PEM",
    pattern: /-----BEGIN [A-Z ]*PRIVATE KEY-----/,
  },
  {
    name: "Private JWK assignment",
    pattern: /SIWE_JWT_PRIVATE_JWK\s*=\s*\{[^}\n]*"d"\s*:/,
  },
]

for (const file of files) {
  if (file === "package-lock.json") continue
  let source
  try {
    source = fs.readFileSync(file, "utf8")
  } catch {
    continue
  }

  for (const rule of secretRules) {
    if (rule.pattern.test(source)) {
      fail(`${rule.name} appears in tracked file: ${file}`)
    }
  }
}

if (process.env.VERCEL_ENV === "production" || process.env.AVANA_DEPLOYMENT_ENV === "production") {
  for (const key of ["AVANA_E2E_SESSION_SECRET", "AVANA_E2E_PRIVATE_JWK", "AVANA_E2E_STAGING"]) {
    if (process.env[key]) fail(`${key} must not be configured on production`)
  }
}

const publicBypassFlags = [
  "NEXT_PUBLIC_DEV_OPEN_GATE",
  "NEXT_PUBLIC_PLAYWRIGHT_TEST_MODE",
  "NEXT_PUBLIC_LIGHTHOUSE_AUDIT_MODE",
  // Sandbox dev-controls (umbrella time-warp / deficit / slash). Both the server
  // flag and its client mirror must stay off in CI/deploy builds.
  "SANDBOX_DEV_CONTROLS",
  "NEXT_PUBLIC_SANDBOX_DEV_CONTROLS",
]

if (process.env.VERCEL || process.env.CI) {
  for (const key of publicBypassFlags) {
    // Flags are enabled with "1" (open-gate/playwright/lighthouse) or "true"
    // (sandbox dev-controls). Either value is a failure in CI/deploy builds.
    if (process.env[key] === "1" || process.env[key] === "true") {
      fail(`Public bypass flag must not be enabled in CI/deploy builds: ${key}`)
    }
  }
}

if (failures.length > 0) {
  process.stderr.write("Security check failed:\n")
  for (const failure of failures) {
    process.stderr.write(`- ${failure}\n`)
  }
  process.exit(1)
}

process.stdout.write("Security check passed.\n")
