import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { describe, expect, it } from "vitest"
import { formatActionUsd } from "@/app/lib/action-system/formatters"

describe("pledge success receipt copy", () => {
  it("P3-03: formats tiny USD amounts with cents so receipts never show a bare $0. fragment", () => {
    expect(formatActionUsd(0, { exact: true })).toBe("$0.00")
    expect(formatActionUsd(0.004, { exact: true })).toBe("$0.00")
    expect(formatActionUsd(0, { exact: true })).not.toBe("$0.")

    const client = readFileSync(resolve(__dirname, "../borrow-action-page-client.tsx"), "utf8")
    expect(client).toMatch(/formatActionUsd\(executedAmountUsd, \{ exact: true \}\)/)
    expect(client).toMatch(/processed\./)
  })
})
