import { describe, it, expect } from "vitest"
import { ASK_AI_GUEST_COOKIE, readAskGuestId, readClientIp, signGuestId } from "../session/route-utils"

const SECRET = "unit-test-secret"
const UUID = "11111111-1111-4111-8111-111111111111"

describe("Ask AI guest cookie is unforgeable", () => {
  it("rejects a forged valid-format UUID cookie (the mint-throttle bypass)", () => {
    // Pre-fix, any valid-format UUID was accepted as an existing guest and skipped the throttle,
    // letting one client mint unlimited guest quotas and drain the global Ask AI budget.
    expect(readAskGuestId(`${ASK_AI_GUEST_COOKIE}=${UUID}`, SECRET)).toBeNull()
  })

  it("accepts a server-signed guest cookie and returns the raw id", () => {
    const signed = `${ASK_AI_GUEST_COOKIE}=${signGuestId(UUID, SECRET)}`
    expect(readAskGuestId(signed, SECRET)).toBe(UUID)
  })

  it("rejects a signed cookie whose signature was tampered", () => {
    const signed = signGuestId(UUID, SECRET)
    const flipped = signed.slice(0, -1) + (signed.endsWith("A") ? "B" : "A")
    expect(readAskGuestId(`${ASK_AI_GUEST_COOKIE}=${flipped}`, SECRET)).toBeNull()
  })
})

describe("client IP prefers the trusted platform header", () => {
  it("ignores a spoofed leftmost X-Forwarded-For when the trusted header is present", () => {
    const req = new Request("https://app.avana.cc/api/ask-ai/session", {
      headers: { "x-forwarded-for": "1.2.3.4", "x-vercel-forwarded-for": "9.9.9.9" },
    })
    expect(readClientIp(req)).toBe("9.9.9.9")
  })
})
