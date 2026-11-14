import { render } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { ActionTokenIcon } from "../action-token-icon"

describe("ActionTokenIcon", () => {
  it("renders a neutral placeholder (not the clipped 'Ass') when no asset is selected", () => {
    const { container } = render(<ActionTokenIcon symbol="Asset" />)
    expect(container.textContent).not.toContain("Ass")
    expect(container.textContent).toBe("?")
  })

  it("treats an empty symbol as a placeholder", () => {
    const { container } = render(<ActionTokenIcon symbol="" />)
    expect(container.textContent).toBe("?")
  })

  it("still shows a short fallback for a real icon-less token symbol", () => {
    const { container } = render(<ActionTokenIcon symbol="FOOBAR" />)
    expect(container.textContent).toBe("FOO")
  })
})
