import { expect, it } from "vitest"
import { queueRetryDelay } from "../queue-backoff"
it("spreads capacity retries and bounds persistent overload", () => {
  expect(queueRetryDelay(0, "a")).toBeGreaterThanOrEqual(2500)
  expect(queueRetryDelay(1, "a")).toBeGreaterThan(queueRetryDelay(0, "a"))
  expect(queueRetryDelay(50, "a")).toBeLessThanOrEqual(30_000)
  expect(queueRetryDelay(0, "a")).not.toBe(queueRetryDelay(0, "b"))
})
