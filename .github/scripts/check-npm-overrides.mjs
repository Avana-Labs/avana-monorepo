// Fails when package-lock.json does not resolve a package the way the root package.json
// `overrides` pin it. npm ci installs the lock file as written, so an override the lock does not
// reflect (a lock not regenerated after the override was added) never takes effect.
//
// A top-level override `"name": "x.y.z"` must hold for every locked copy of `name`. A nested
// override `"parent": { "child": "x.y.z" }` must hold for the copy of `child` each locked
// `parent` resolves through Node's lookup; `"."` inside it pins `parent` itself.
//
// Usage: node .github/scripts/check-npm-overrides.mjs [repository root]
import fs from "node:fs"
import path from "node:path"

const root = path.resolve(process.argv[2] ?? ".")
const manifest = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"))
const lock = JSON.parse(fs.readFileSync(path.join(root, "package-lock.json"), "utf8"))
const packages = lock.packages ?? {}
const failures = []

const nameOf = (lockPath) => lockPath.slice(lockPath.lastIndexOf("node_modules/") + "node_modules/".length)

function lockedCopies(name) {
  return Object.entries(packages).filter(([lockPath, entry]) => !entry.link && lockPath && nameOf(lockPath) === name)
}

// Node's lookup from a package's folder: its own node_modules, then each enclosing node_modules.
function resolveFrom(lockPath, name) {
  let base = lockPath
  for (;;) {
    const candidate = base ? `${base}/node_modules/${name}` : `node_modules/${name}`
    if (packages[candidate]) return [candidate, packages[candidate]]
    if (!base) return null
    const cut = base.lastIndexOf("/node_modules/")
    base = cut === -1 ? "" : base.slice(0, cut)
  }
}

function expect(lockPath, entry, want, rule) {
  if (entry.version !== want) failures.push(`${lockPath}: locked ${entry.version}, override ${rule} wants ${want}`)
}

for (const [name, spec] of Object.entries(manifest.overrides ?? {})) {
  if (typeof spec === "string") {
    for (const [lockPath, entry] of lockedCopies(name)) expect(lockPath, entry, spec, name)
    continue
  }
  for (const [child, want] of Object.entries(spec)) {
    if (typeof want !== "string") {
      failures.push(`override ${name} > ${child}: nesting deeper than one level is not checked`)
      continue
    }
    if (child === ".") {
      for (const [lockPath, entry] of lockedCopies(name)) expect(lockPath, entry, want, name)
      continue
    }
    for (const [parentPath, parent] of lockedCopies(name)) {
      const declared = { ...parent.dependencies, ...parent.optionalDependencies, ...parent.peerDependencies }
      if (!(child in declared)) continue
      const resolved = resolveFrom(parentPath, child)
      if (!resolved) {
        if (parent.peerDependencies?.[child] === undefined) failures.push(`${parentPath}: ${child} is not in the lock file`)
        continue
      }
      expect(resolved[0], resolved[1], want, `${name} > ${child}`)
    }
  }
}

if (failures.length) {
  console.error("package-lock.json does not apply every override in package.json; regenerate it with npm install:")
  for (const failure of failures) console.error(`  ${failure}`)
  process.exit(1)
}
console.log(`npm overrides: ${Object.keys(manifest.overrides ?? {}).length} rules applied by package-lock.json`)
