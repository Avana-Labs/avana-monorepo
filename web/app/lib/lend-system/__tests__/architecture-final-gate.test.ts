import { describe, expect, it } from "vitest"
import { readFileSync } from "node:fs"
import path from "node:path"

const lendActionSurfaces = ["app/lend/lend-client.tsx", "app/dashboard/_rewards-components/lend-account-section.tsx"]

describe("lend architecture final gate", () => {
  it("routes lend UI through shared avana session context", () => {
    const offenders = lendActionSurfaces.filter((file) => {
      const source = readFileSync(path.join(process.cwd(), file), "utf8")
      return source.includes("useLendSession({")
    })

    expect(offenders).toEqual([])
    expect(
      readFileSync(path.join(process.cwd(), "app/lib/avana-session/avana-sessions-provider.tsx"), "utf8"),
    ).toContain("lend:")
  })

  it("keeps production lend adapters injectable for live integration", () => {
    const readAdapter = readFileSync(path.join(process.cwd(), "app/lib/lend-system/production-read-adapter.ts"), "utf8")
    const txAdapter = readFileSync(
      path.join(process.cwd(), "app/lib/lend-system/production-transaction-adapter.ts"),
      "utf8",
    )

    expect(readAdapter).toContain("constructor(private readonly source")
    expect(readAdapter).toContain("this.source.readWalletSnapshot")
    expect(txAdapter).toContain("createIntent(action: LendAction)")
    expect(txAdapter).toContain("this.source.previewTransaction")
  })
})
