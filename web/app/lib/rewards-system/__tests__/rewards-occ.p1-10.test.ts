import { describe, expect, it } from "vitest"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"

describe("rewards saveState client OCC", () => {
  it("p1-10: convex session provider passes expectedRevision to saveState", () => {
    const source = readFileSync(resolve(__dirname, "../../avana-session/convex-avana-sessions-provider.tsx"), "utf8")
    expect(source).toMatch(/expectedRevision:\s*args\.expectedRevision/)
    expect(source).toMatch(/remoteRewardsRevision/)
    expect(source).toMatch(/rewardsState\.revision \?\? 0/)
    expect(source).toMatch(/persistRewardsState=\{scope\.rewards \? persistRewardsState : undefined\}/)
  })

  it("p1-10: useRewardsSession seeds revision inside the persistence lock", () => {
    const source = readFileSync(resolve(__dirname, "../use-rewards-session.ts"), "utf8")
    expect(source).toMatch(/withRewardsPersistenceLock\(walletId, async \(\) => \{/)
    expect(source).toMatch(/rewardsRevisionRef\.current = revision/)
    expect(source).toMatch(/remoteState \? \(remoteRevision \?\? 0\) : undefined/)
    expect(source).toMatch(/if \(remoteState === undefined \|\| !persistRemoteState\) return/)
    expect(source).toMatch(/remoteState !== null && rewardsRevisionRef\.current == null/)
  })
})
