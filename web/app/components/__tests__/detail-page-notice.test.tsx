import { cleanup, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it } from "vitest"
import { DetailPageNotice } from "@/app/components/detail-page-primitives"

describe("DetailPageNotice", () => {
  afterEach(() => {
    cleanup()
  })

  it("p0-05: borrow variant keeps LP liquidation risk copy", () => {
    render(<DetailPageNotice product="borrow" />)
    expect(screen.getByRole("note")).toHaveTextContent(/Borrowing against LP tokens/)
  })

  it("p0-05: lend variant uses the same full disclaimer shape without borrow-LP copy", () => {
    render(<DetailPageNotice product="lend" />)
    const note = screen.getByRole("note")
    expect(note).not.toHaveTextContent(/Borrowing against LP tokens/)
    expect(note).toHaveTextContent(/Supplying assets involves risk/)
    expect(note).toHaveTextContent(/does not custody your funds/)
    expect(note).toHaveTextContent(/enforced on-chain/)
    expect(note).toHaveTextContent(/full control of your position/)
  })
})
