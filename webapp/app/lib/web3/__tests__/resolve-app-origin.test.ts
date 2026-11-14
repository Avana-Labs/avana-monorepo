import { afterEach, describe, expect, it, vi } from "vitest"

import { resolveAppOrigin } from "../web3-provider"

describe("resolveAppOrigin", () => {
  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it("returns the runtime page origin in the browser so metadata.url matches the page", () => {
    vi.stubGlobal("window", { location: { origin: "http://localhost:3000" } })
    expect(resolveAppOrigin()).toBe("http://localhost:3000")

    vi.stubGlobal("window", { location: { origin: "https://preview.avana.cc" } })
    expect(resolveAppOrigin()).toBe("https://preview.avana.cc")
  })

  it("falls back to the canonical production origin during SSR (no window)", () => {
    vi.stubGlobal("window", undefined)
    expect(resolveAppOrigin()).toBe("https://avana.cc")
  })
})
