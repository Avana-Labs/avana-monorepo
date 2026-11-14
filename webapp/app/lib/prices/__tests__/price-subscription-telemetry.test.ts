// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest"
import { getActivePriceSubscriptionCount, registerPriceSubscription } from "../price-subscription-telemetry"

describe("price subscription telemetry", () => {
  const disposers: Array<() => void> = []
  function register(route: string) {
    const dispose = registerPriceSubscription(route)
    disposers.push(dispose)
    return dispose
  }

  afterEach(() => {
    for (const dispose of disposers.splice(0)) dispose()
    vi.restoreAllMocks()
    expect(getActivePriceSubscriptionCount()).toBe(0)
  })

  it("tracks mounted instances and emits route/query details", () => {
    const dispatchEvent = vi.spyOn(window, "dispatchEvent")
    const disposeA = register("/borrow")
    const disposeB = register("/lend")

    expect(getActivePriceSubscriptionCount()).toBe(2)
    expect(dispatchEvent).toHaveBeenCalledWith(
      expect.objectContaining({
        type: "avana:price-subscription",
        detail: expect.objectContaining({
          route: "/lend",
          activeInstances: 2,
          event: "mount",
          queries: ["prices.getPriceSnapshot", "prices.getPriceStatus"],
        }),
      }),
    )

    disposeA()
    disposeA()
    expect(getActivePriceSubscriptionCount()).toBe(1)
    disposeB()
    expect(getActivePriceSubscriptionCount()).toBe(0)
  })

  it("cleans up registrations even when a test leaves before manual disposal", () => {
    register("/early-exit")
    expect(getActivePriceSubscriptionCount()).toBe(1)
    // afterEach must dispose the existing instance and verify zero active instances.
  })
})
