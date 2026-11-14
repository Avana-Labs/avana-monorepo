import { describe, expect, it } from "vitest"
import { withRewardsPersistenceLock } from "../persistence-lock"

describe("rewards persistence lock", () => {
  it("serializes writes for the same wallet", async () => {
    const events: string[] = []
    let releaseFirst!: () => void
    let markFirstStarted!: () => void
    const firstGate = new Promise<void>((resolve) => {
      releaseFirst = resolve
    })
    const firstStarted = new Promise<void>((resolve) => {
      markFirstStarted = resolve
    })
    const first = withRewardsPersistenceLock("0xabc", async () => {
      events.push("first:start")
      markFirstStarted()
      await firstGate
      events.push("first:end")
      return 1
    })
    const second = withRewardsPersistenceLock("0xabc", async () => {
      events.push("second:start")
      events.push("second:end")
      return 2
    })

    await firstStarted
    expect(events).toEqual(["first:start"])
    releaseFirst()
    await expect(Promise.all([first, second])).resolves.toEqual([1, 2])
    expect(events).toEqual(["first:start", "first:end", "second:start", "second:end"])
  })

  it("does not serialize different wallets", async () => {
    const events: string[] = []
    await Promise.all([
      withRewardsPersistenceLock("0xaaa", async () => void events.push("a")),
      withRewardsPersistenceLock("0xbbb", async () => void events.push("b")),
    ])
    expect(events.sort()).toEqual(["a", "b"])
  })
})
