import { describe, expect, it, vi } from "vitest"
import { runActionSubmitFlow } from "@/app/lib/action-system/action-submit-runtime"

describe("runActionSubmitFlow", () => {
  it("advances through allowance, wallet sign, and processing stages", async () => {
    vi.useFakeTimers()
    const stages: string[] = []
    const onStage = (stage: string) => stages.push(stage)

    const promise = runActionSubmitFlow({
      simulated: true,
      needsAllowance: true,
      onStage,
      execute: async () => ({
        receipt: { status: "success", hash: "sim-test" },
      }),
    })

    await vi.runAllTimersAsync()
    const result = await promise

    expect(stages).toEqual([
      "approve_allowance",
      "wallet_sign",
      "processing",
      "submitted",
      "confirmed",
      "refreshing_position",
      "reconciled",
    ])
    expect(result.receipt.hash).toBe("sim-test")
    vi.useRealTimers()
  })

  it("rejects when execute() never settles instead of hanging on 'processing' (regression: M-8)", async () => {
    vi.useFakeTimers()
    const stages: string[] = []
    const promise = runActionSubmitFlow({
      simulated: false,
      timeoutMs: 50,
      onStage: (stage: string) => stages.push(stage),
      // Simulates a stalled Convex socket / dropped connection mid-submit.
      execute: () => new Promise<{ receipt: { status: string } }>(() => {}),
    })
    const expectation = expect(promise).rejects.toThrow(/timed out/i)
    await vi.advanceTimersByTimeAsync(60)
    await expectation
    // It reached processing (so the caller can move that stage to error), not hung silently.
    expect(stages).toContain("processing")
    vi.useRealTimers()
  })
})
