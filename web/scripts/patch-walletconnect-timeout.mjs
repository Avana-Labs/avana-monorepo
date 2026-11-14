import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

// Backport the createDelayedPromise timeout fix from WalletConnect's utils/src/misc.ts:
// https://github.com/WalletConnect/walletconnect-monorepo/blob/master/packages/utils/src/misc.ts
// 2.21.0/2.21.1 reject the awaited promise AND create an orphan Promise.reject(err).
// Remove only the orphan; callers still receive the original timeout error normally.
// Apply to every locked copy and distribution, including Reown's nested dependencies.
// The npm workspace installs into the repository root, next to its package-lock.json. CI installs with
// --ignore-scripts, so `pretest` and `prebuild` run this too; it is idempotent.
const root = fileURLToPath(new URL("../../", import.meta.url))
const lock = JSON.parse(fs.readFileSync(path.join(root, "package-lock.json"), "utf8"))
const marker = "/* avana-walletconnect-timeout-fix */"
const orphan = /[\w$]+=Promise\.reject\(([\w$]+)\),([\w$]+)\(\1\)/g
const edits = []

for (const [packagePath, locked] of Object.entries(lock.packages)) {
  if (!packagePath.endsWith("node_modules/@walletconnect/utils")) continue
  const directory = path.resolve(root, packagePath)
  if (!directory.startsWith(path.join(root, "node_modules") + path.sep)) {
    throw new Error(`Unexpected WalletConnect package path: ${packagePath}`)
  }
  const installed = JSON.parse(fs.readFileSync(path.join(directory, "package.json"), "utf8"))
  if (installed.version !== locked.version) throw new Error(`Install dependencies first: ${packagePath}`)
  const entries = ["main", "module", "unpkg"].filter((entry) => installed[entry])
  if (!["2.21.0", "2.21.1"].includes(locked.version)) {
    // Later releases dropped the orphan rejection upstream; fail only if one still carries it.
    for (const entry of entries) {
      if ([...fs.readFileSync(path.join(directory, installed[entry]), "utf8").matchAll(orphan)].length) {
        throw new Error(`Review the WalletConnect timeout patch for utils ${locked.version}`)
      }
    }
    continue
  }
  for (const entry of entries) {
    const filename = path.join(directory, installed[entry])
    const source = fs.readFileSync(filename, "utf8")
    if (source.includes(marker)) continue
    if ([...source.matchAll(orphan)].length !== 1) {
      throw new Error(`WalletConnect timeout implementation changed: ${filename}`)
    }
    // Keep the replacement the same length so the package's source-map columns stay valid.
    const patched = source.replace(orphan, (match, error, reject) => `${reject}(${error})`.padEnd(match.length))
    edits.push([filename, `${patched}\n${marker}\n`])
  }
}

// Validate every target before writing any of them. Re-running is a no-op.
for (const [filename, source] of edits) fs.writeFileSync(filename, source)
console.log(`WalletConnect timeout patch: ${edits.length} distributions updated`)
