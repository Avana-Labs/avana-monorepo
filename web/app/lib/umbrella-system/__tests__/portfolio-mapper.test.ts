import { describe, expect, it } from "vitest"
import { derivePersistedUmbrellaPositionStatus } from "../portfolio-mapper"

describe("persisted Umbrella position status", () => {
  it("uses the shared Umbrella lifecycle rules for Convex positions", () => {
    expect(
      derivePersistedUmbrellaPositionStatus({
        status: "open",
        suppliedUsd6: "100000000",
        cooldownAmountUsd6: "25000000",
        cooldownEndsAt: 2_000,
        withdrawalWindowEndsAt: 3_000,
        now: 1_000,
      }),
    ).toBe("partiallyCooling")
    expect(
      derivePersistedUmbrellaPositionStatus({
        status: "closed",
        suppliedUsd6: "0",
        slashedAmountUsd6: "1000000",
        now: 1_000,
      }),
    ).toBe("slashed")
  })
})
