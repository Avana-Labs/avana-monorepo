/**
 * Vercel "Ignored Build Step".
 *
 * Build CPU is billed per minute and every push to every branch triggered a full Next
 * build, so doc/test-only commits were costing the same as a real deploy. This skips a
 * build only when EVERY changed path provably cannot alter the deployed output.
 *
 * Contract (Vercel): exit 1 => run the build, exit 0 => skip it.
 *
 * FAIL-SAFE BY DESIGN: the default is always to build. We skip only when the diff is
 * readable AND every path in it matches the allowlist below. A missing commit parent
 * (shallow clone), a git error, an unrecognised path, or the production branch all build.
 * Wrongly skipping a deploy is far more expensive than wrongly running one.
 */
import { execFileSync } from "node:child_process"
import process from "node:process"

/** Exit 1: run the build. */
function build(reason) {
  process.stdout.write(`BUILD: ${reason}\n`)
  process.exit(1)
}

/** Exit 0: skip the build. */
function skip(reason) {
  process.stdout.write(`SKIP: ${reason}\n`)
  process.exit(0)
}

/**
 * Paths that cannot change what Vercel serves.
 *
 * Deliberately NOT here — each of these can alter the build output or the deployed files:
 *   `convex/**`     — `convex/_generated/api` is imported for types at build time
 *   `public/**`     — shipped as static assets
 *   `scripts/**`    — `run-next.mjs` wraps the build itself
 *   lockfiles, configs, and anything under `app/` or `components/`
 */
const IGNORABLE = [
  /^docs\//,
  /^\.github\//,
  /^\.vscode\//,
  /^\.idea\//,
  /\.md$/,
  /(^|\/)__tests__\//,
  /\.test\.[cm]?[jt]sx?$/,
  /\.spec\.[cm]?[jt]sx?$/,
  /^e2e\//,
  /^\.gitignore$/,
  /^\.prettierignore$/,
  /^LICENSE$/,
]

const branch = process.env.VERCEL_GIT_COMMIT_REF ?? ""

// Never gamble on the production deployment.
if (process.env.VERCEL_ENV === "production") build("production deployment")
if (branch === "main") build("production branch")

let changed
try {
  // Vercel clones with enough depth for the parent in normal operation; if it is not
  // there this throws and we build.
  const out = execFileSync("git", ["diff", "--name-only", "HEAD^", "HEAD"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  })
  changed = out.split("\n").filter(Boolean)
} catch {
  build("could not read the commit diff (shallow clone or first commit)")
}

if (changed.length === 0) build("empty diff")

const relevant = changed.filter((file) => !IGNORABLE.some((pattern) => pattern.test(file)))
if (relevant.length > 0) {
  build(`${relevant.length} build-relevant file(s), e.g. ${relevant.slice(0, 3).join(", ")}`)
}

skip(`${changed.length} file(s) changed, all docs/tests/editor config`)
