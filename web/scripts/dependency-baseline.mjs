import fs from "node:fs"
import { execFileSync } from "node:child_process"
import { pathToFileURL } from "node:url"

export function baselineFailures(report, exceptions = [], now = Date.now()) {
  if (!report?.metadata?.vulnerabilities || !report.vulnerabilities || report.error)
    throw new Error("Dependency audit did not return a valid advisory report")
  for (const exception of exceptions) {
    if (
      !exception.package ||
      !exception.advisory ||
      !exception.reason ||
      !Number.isFinite(Date.parse(exception.expires)) ||
      Date.parse(exception.expires) <= now
    )
      throw new Error("Dependency exception is incomplete or expired")
  }
  return Object.values(report.vulnerabilities)
    .filter((entry) => {
      if (!["high", "critical"].includes(entry.severity)) return false
      const advisories = entry.via.filter((item) => typeof item === "object")
      // An inherited advisory cannot be waived indirectly through a package name.
      return (
        !advisories.length ||
        advisories.some((advisory) => !exceptions.some((e) => e.package === entry.name && e.advisory === advisory.url))
      )
    })
    .map((entry) => `${entry.name}: ${entry.severity}`)
}

function main() {
  let raw
  try {
    raw = execFileSync("npm", ["audit", "--omit=dev", "--json"], { encoding: "utf8", timeout: 60_000 })
  } catch (error) {
    if (error.status !== 1 || !error.stdout)
      throw new Error("Dependency audit unavailable; refusing an unchecked baseline", { cause: error })
    raw = error.stdout
  }
  const failures = baselineFailures(
    JSON.parse(raw),
    JSON.parse(fs.readFileSync("config/dependency-exceptions.json", "utf8")),
  )
  if (failures.length) throw new Error(`Dependency baseline failed:\n${failures.join("\n")}`)
  console.log("Dependency baseline passed: no unexcepted high/critical production advisories")
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main()
