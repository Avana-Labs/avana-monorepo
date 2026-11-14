import { describe, expect, it } from "vitest"
import {
  ASK_AI_ERROR_COPY,
  FALLBACK_ASK_AI_ERROR,
  resolveAskAIErrorDetail,
  toFriendlyAskAIError,
} from "../components/ask-ai-thread"

describe("Ask AI client error mapping", () => {
  it("reads the ConvexError payload code and message", () => {
    const friendly = toFriendlyAskAIError({
      data: { code: "ASK_AI_RATE_LIMITED", message: "Slow down there." },
    })
    expect(friendly).toEqual({ code: "ASK_AI_RATE_LIMITED", message: "Slow down there." })
  })

  it("falls back to code copy when the payload has no message", () => {
    const friendly = toFriendlyAskAIError({ data: { code: "ASK_AI_UNAVAILABLE" } })
    expect(friendly.code).toBe("ASK_AI_UNAVAILABLE")
    expect(friendly.message).toBe(ASK_AI_ERROR_COPY.ASK_AI_UNAVAILABLE)
  })

  it("never leaks a raw Error message (no function path / request id)", () => {
    const friendly = toFriendlyAskAIError(new Error("[Request ID: abc] Server Error at askAIAgent:generateTurn"))
    expect(friendly.message).toBe(FALLBACK_ASK_AI_ERROR)
    expect(friendly.message).not.toContain("generateTurn")
    expect(friendly.message).not.toContain("Request ID")
  })

  it("resolves a detail line from a friendly error object, a bare code, or nothing", () => {
    expect(resolveAskAIErrorDetail({ message: "Custom detail" })).toBe("Custom detail")
    expect(resolveAskAIErrorDetail({ code: "ASK_AI_GENERATION_FAILED" })).toBe(
      ASK_AI_ERROR_COPY.ASK_AI_GENERATION_FAILED,
    )
    expect(resolveAskAIErrorDetail(undefined)).toBe(FALLBACK_ASK_AI_ERROR)
    expect(resolveAskAIErrorDetail("Server Error at askAIAgent:generateTurn")).toBe(FALLBACK_ASK_AI_ERROR)
  })
})
