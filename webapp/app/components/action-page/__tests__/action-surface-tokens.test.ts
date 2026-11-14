import { describe, expect, it } from "vitest"
import {
  ACTION_FIELD_RADIUS_CLASS,
  ACTION_FIELD_STACK_CLASS,
  ACTION_FIELD_SURFACE_CLASS,
} from "@/app/components/action-page/action-surface-tokens"

describe("action surface tokens", () => {
  it("keeps action fields on one radius and density scale", () => {
    expect(ACTION_FIELD_SURFACE_CLASS).toBe("rounded-radius-lg px-4 py-3")
    expect(ACTION_FIELD_RADIUS_CLASS).toBe("rounded-radius-lg")
    expect(ACTION_FIELD_STACK_CLASS).toBe("flex flex-col gap-2")
  })
})
