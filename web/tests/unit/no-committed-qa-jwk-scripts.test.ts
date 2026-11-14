import { execSync } from "node:child_process"
import { existsSync } from "node:fs"
import path from "node:path"
import { describe, expect, it } from "vitest"

const repoRoot = path.resolve(__dirname, "..", "..")

// These helpers read the private SIWE JWK to self-mint valid sandbox tokens; they
// must never be committed. Guard against reintroduction (#138).
const bannedScripts = ["_qa-mint.mjs", "_qa-seed.mjs"]

describe("no committed QA token-minting scripts (#138)", () => {
  it("does not track any _qa-*.mjs helper that could mint tokens from the JWK", () => {
    const tracked = execSync("git ls-files", { cwd: repoRoot, encoding: "utf8" }).split("\n").filter(Boolean)
    const offenders = tracked.filter((f) => /(^|\/)_qa-.*\.mjs$/.test(f))
    expect(offenders).toEqual([])
  })

  it("does not leave the known scripts on disk in the repo root", () => {
    for (const script of bannedScripts) {
      expect(existsSync(path.join(repoRoot, script))).toBe(false)
    }
  })
})
