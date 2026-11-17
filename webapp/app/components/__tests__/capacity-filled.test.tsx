import { cleanup, render } from "@testing-library/react"
import { afterEach, describe, expect, it } from "vitest"
import { CapacityFilled, formatCapacityFilled } from "../capacity-filled"

describe("CapacityFilled", () => {
  afterEach(() => {
    cleanup()
  })

  it("keeps two decimals under 1% so a lightly used market never reads as 0%", () => {
    expect(formatCapacityFilled(0.13)).toBe("0.13%")
    expect(formatCapacityFilled(0.004)).toBe("<0.01%")
    expect(formatCapacityFilled(0)).toBe("0%")
    expect(formatCapacityFilled(62.4)).toBe("62%")
  })

  it("shows the same label in the text and the accessible name", () => {
    const { getByRole } = render(<CapacityFilled value={0.13} />)
    const gauge = getByRole("img")
    expect(gauge.getAttribute("aria-label")).toBe("Capacity filled 0.13%")
    expect(gauge.textContent).toBe("0.13%")
  })
})
