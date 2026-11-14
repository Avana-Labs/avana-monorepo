import fs from "node:fs/promises"
import path from "node:path"
import process from "node:process"

const reportDirectory = process.argv[2]

if (!reportDirectory) {
  process.stderr.write("Usage: npm run lighthouse:analyze -- <lighthouse-report-directory>\n")
  process.exit(1)
}

const files = (await fs.readdir(reportDirectory)).filter((file) => file.endsWith(".json"))
const bundles = new Map()

for (const file of files) {
  const report = JSON.parse(await fs.readFile(path.join(reportDirectory, file), "utf8"))
  const items = report.audits["unused-javascript"]?.details?.items ?? []

  for (const item of items) {
    const current = bundles.get(item.url) ?? { routes: 0, transferredBytes: 0, unusedBytes: 0 }
    current.routes += 1
    current.transferredBytes = Math.max(current.transferredBytes, item.totalBytes ?? 0)
    current.unusedBytes += item.wastedBytes ?? 0
    bundles.set(item.url, current)
  }
}

const rows = [...bundles.entries()]
  .map(([url, bundle]) => ({
    bundle: url.split("/").pop(),
    routes: bundle.routes,
    transferredKiB: Math.round(bundle.transferredBytes / 1024),
    unusedKiB: Math.round(bundle.unusedBytes / 1024),
  }))
  .sort((left, right) => right.unusedKiB - left.unusedKiB)

process.stdout.write(`${JSON.stringify(rows, null, 2)}\n`)
