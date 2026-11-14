import { cleanup, fireEvent, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { LendMarketDetail } from "@/app/lib/lend-detail"
import { LendSidebar } from "../LendSidebar"

// A stateful stand-in for the action form: it only needs to show whether switching tabs mounts a
// fresh form or reuses the previous one (and its stage/amount state).
vi.mock("@/app/components/action-page/responsive-lend-action", async () => {
  const React = await import("react")
  return {
    ResponsiveLendAction: ({ kind }: { kind: string }) => {
      const [typed, setTyped] = React.useState("")
      return <input aria-label={`${kind} amount`} value={typed} onChange={(event) => setTyped(event.target.value)} />
    },
  }
})

const detail = { id: "eth", row: { marketId: "eth" }, hero: { name: "Ether" } } as unknown as LendMarketDetail

describe("LendSidebar", () => {
  afterEach(() => cleanup())

  it("mounts a fresh Withdraw form instead of inheriting the Deposit form's state", () => {
    render(<LendSidebar detail={detail} />)
    fireEvent.change(screen.getByLabelText("deposit amount"), { target: { value: "5" } })

    fireEvent.click(screen.getByRole("tab", { name: "Withdraw" }))

    // Reusing the Deposit instance carried over its state; after a failed deposit that included
    // the "error" stage, whose in-place retry submitted the withdraw without a review step.
    expect(screen.getByLabelText("withdraw amount")).toHaveValue("")
  })
})
