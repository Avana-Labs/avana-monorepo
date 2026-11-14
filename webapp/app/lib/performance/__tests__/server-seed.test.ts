import { afterEach, describe, expect, it, vi } from "vitest"
import { SERVER_SEED_WAIT_MS, waitForServerSeed } from "../server-seed"

afterEach(() => vi.useRealTimers())

describe("server display seed deadline", () => {
  it("returns a ready seed and clears its timer", async () => {
    vi.useFakeTimers()
    await expect(waitForServerSeed(Promise.resolve({ usd: 1 }), {})).resolves.toEqual({ usd: 1 })
    expect(vi.getTimerCount()).toBe(0)
  })

  it("releases rendering when an upstream never settles", async () => {
    vi.useFakeTimers()
    const seed = waitForServerSeed(new Promise<null>(() => {}), null)
    await vi.advanceTimersByTimeAsync(SERVER_SEED_WAIT_MS)
    await expect(seed).resolves.toBeNull()
    expect(vi.getTimerCount()).toBe(0)
  })

  it("propagates upstream failures to the caller's existing fallback", async () => {
    vi.useFakeTimers()
    await expect(waitForServerSeed(Promise.reject(new Error("offline")), {})).rejects.toThrow("offline")
    expect(vi.getTimerCount()).toBe(0)
  })

  it("handles a rejection after the deadline without changing the returned seed", async () => {
    vi.useFakeTimers()
    let reject!: (error: Error) => void
    const seed = waitForServerSeed(new Promise<null>((_resolve, fail) => (reject = fail)), null)
    await vi.advanceTimersByTimeAsync(SERVER_SEED_WAIT_MS)
    await expect(seed).resolves.toBeNull()
    reject(new Error("late failure"))
    await Promise.resolve()
  })
})
