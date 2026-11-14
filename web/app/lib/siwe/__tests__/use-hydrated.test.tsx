import { render, renderHook, screen } from "@testing-library/react"
import { renderToStaticMarkup } from "react-dom/server"
import { describe, expect, it } from "vitest"
import { useHydrated } from "@/app/lib/siwe/use-siwe-auth"

// The onboarding-flash bug was: the SIWE session reads as signed-out on the server and
// the first hydration render, so the gate rendered the onboarding screen in that window.
// useHydrated is the guard — it must read `false` on the server (so the gate can hold a
// neutral placeholder there) and `true` on the client.
function Probe() {
  return <span data-testid="state">{useHydrated() ? "hydrated" : "pending"}</span>
}

describe("useHydrated", () => {
  it("reads false during server rendering (the pre-hydration window)", () => {
    // renderToStaticMarkup exercises the server snapshot path — the exact render whose
    // HTML previously contained the onboarding flow.
    expect(renderToStaticMarkup(<Probe />)).toContain("pending")
  })

  it("reads true on the client", () => {
    render(<Probe />)
    expect(screen.getByTestId("state").textContent).toBe("hydrated")
  })

  it("reads true immediately (client snapshot) — no placeholder flash on remount", () => {
    const { result } = renderHook(() => useHydrated())
    expect(result.current).toBe(true)
  })
})
