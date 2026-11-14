import { describe, expect, it } from "vitest"
import { readFileSync } from "node:fs"
import path from "node:path"

const multiplyActionSurfaces = [
  "app/components/action-page/multiply-action-page-client.tsx",
  "app/multiply/_detail/sidebars/MarketSidebar.tsx",
  "app/dashboard/_rewards-components/multiply-account-section.tsx",
]

describe("multiply architecture final gate", () => {
  it("keeps requirements matrix and session tests present", () => {
    expect(
      readFileSync(path.join(process.cwd(), "app/lib/multiply-engine/__tests__/validation.test.ts"), "utf8"),
    ).toContain("validateMultiplyAction")
    expect(
      readFileSync(path.join(process.cwd(), "app/lib/multiply-system/__tests__/use-multiply-session.test.tsx"), "utf8"),
    ).toContain("useMultiplySession")
    expect(
      readFileSync(path.join(process.cwd(), "app/lib/multiply-engine/__tests__/requirements-matrix.test.ts"), "utf8"),
    ).not.toContain("it.todo")
  })

  it("routes multiply UI through shared avana session context", () => {
    const offenders = multiplyActionSurfaces.filter((file) => {
      const source = readFileSync(path.join(process.cwd(), file), "utf8")
      return source.includes("useMultiplySession({")
    })

    expect(offenders).toEqual([])
    const multiplySection = readFileSync(
      path.join(process.cwd(), "app/dashboard/_rewards-components/multiply-account-section.tsx"),
      "utf8",
    )
    expect(multiplySection).toContain("useMultiplySessionContext")
    // The multiply UI must draw its session from the shared avana context rather
    // than instantiating its own, so unrelated product updates don't force a rerender.
    expect(multiplySection).toContain("const multiplySession = useMultiplySessionContext()")
    expect(readFileSync(path.join(process.cwd(), "app/components/avana-session-providers.tsx"), "utf8")).toContain(
      "AvanaSessionsProvider",
    )
  })

  it("keeps production multiply adapters behind explicit source guards", () => {
    const readAdapter = readFileSync(
      path.join(process.cwd(), "app/lib/multiply-system/production-read-adapter.ts"),
      "utf8",
    )
    const txAdapter = readFileSync(
      path.join(process.cwd(), "app/lib/multiply-system/production-transaction-adapter.ts"),
      "utf8",
    )

    expect(readAdapter).toContain("not implemented")
    expect(txAdapter).toContain("not implemented")
    expect(readAdapter).toContain("ProductionMultiplyReadSource")
    expect(txAdapter).toContain("ProductionMultiplyTransactionSource")
  })
})
