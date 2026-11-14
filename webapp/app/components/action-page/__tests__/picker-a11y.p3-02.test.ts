import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { describe, expect, it } from "vitest"

describe("swap and borrow picker polish", () => {
  it("P3-02: swap picker options expose accessible names and borrow picker uses token icons", () => {
    const swapPicker = readFileSync(resolve(__dirname, "../../../swap/swap-asset-picker-dialog.tsx"), "utf8")
    const amountCard = readFileSync(resolve(__dirname, "../action-amount-card.tsx"), "utf8")
    expect(swapPicker).toMatch(/aria-label=\{`\$\{asset\.name\} \(\$\{asset\.symbol\}\)`\}/)
    expect(amountCard).toMatch(/ActionTokenIcon symbol=\{option\.symbol\}/)
  })
})
