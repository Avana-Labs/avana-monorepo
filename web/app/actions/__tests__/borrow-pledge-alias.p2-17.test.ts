import { describe, expect, it } from "vitest"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { isValidAction, normalizeActionKind } from "@/app/lib/action-system/contracts"

describe("borrow pledge vocabulary", () => {
  it("P2-17: maps /actions/borrow/pledge to supply and adds borrow txn filters", () => {
    expect(normalizeActionKind("borrow", "pledge")).toBe("supply")
    expect(isValidAction("borrow", "pledge")).toBe(true)

    const history = readFileSync(
      resolve(__dirname, "../../components/detail-transaction-table/kind-configs.ts"),
      "utf8",
    )
    expect(history).toMatch(/borrow: "Borrow"/)
    expect(history).toMatch(/repay: "Repay"/)

    const client = readFileSync(
      resolve(__dirname, "../../components/action-page/borrow-action-page-client.tsx"),
      "utf8",
    )
    expect(client).toMatch(/Choose the asset to borrow/)
    expect(client).not.toMatch(/Pledge LP collateral before you can borrow against this market/)
    expect(client).not.toMatch(/blockedRedirectHref/)
  })
})
