/**
 * Remove Next.js output and tool caches that often corrupt on Windows
 * (ENOENT *.pack.gz, missing ./NNN.js, or stale chunk references).
 */
import fs from "node:fs"
import path from "node:path"
import process from "node:process"

const root = process.cwd()
const targets = [".next", ".next-dev", ".next-prod", path.join("node_modules", ".cache")]

for (const relativePath of targets) {
  const absolutePath = path.join(root, relativePath)

  try {
    if (fs.existsSync(absolutePath)) {
      fs.rmSync(absolutePath, { recursive: true, force: true })
      process.stdout.write(`removed ${relativePath}\n`)
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    process.stderr.write(`warning: could not remove ${relativePath}: ${message}\n`)
  }
}

process.stdout.write("clean-next: done.\n")
