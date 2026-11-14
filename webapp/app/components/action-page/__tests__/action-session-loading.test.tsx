import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import {
  ActionSessionLoading,
  shouldShowActionSessionLoading,
} from "@/app/components/action-page/action-session-loading"

describe("ActionSessionLoading", () => {
  it("announces wallet hydration without rendering seeded position values", () => {
    render(<ActionSessionLoading />)
    expect(screen.getByRole("status")).toHaveTextContent("Loading wallet position")
  })

  it("never bypasses authoritative hydration for an open-gate action", () => {
    expect(shouldShowActionSessionLoading(false)).toBe(true)
    expect(shouldShowActionSessionLoading(true)).toBe(false)
    expect(shouldShowActionSessionLoading(undefined)).toBe(false)
  })
})
