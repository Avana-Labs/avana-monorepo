import { render, cleanup } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { AnalyticsErrorSuppressor } from "../analytics-error-boundary"

afterEach(cleanup)

function dispatchRejection(reason: unknown) {
  const event = new Event("unhandledrejection") as PromiseRejectionEvent
  Object.defineProperty(event, "reason", { value: reason, configurable: true })
  const preventDefault = vi.spyOn(event, "preventDefault")
  window.dispatchEvent(event)
  return preventDefault
}

describe("AnalyticsErrorSuppressor", () => {
  it("suppresses analytics beacon rejections", () => {
    render(<AnalyticsErrorSuppressor />)
    const preventDefault = dispatchRejection(new TypeError("Analytics SDK: Failed to fetch"))
    expect(preventDefault).toHaveBeenCalled()
  })

  it("leaves unrelated rejections untouched", () => {
    render(<AnalyticsErrorSuppressor />)
    const preventDefault = dispatchRejection(new Error("Convex mutation failed"))
    expect(preventDefault).not.toHaveBeenCalled()
  })
})
