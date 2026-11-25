// @vitest-environment jsdom

import { beforeEach, describe, expect, it } from "vitest"
import { getAskAIGuestToken, setAskAIGuestToken } from "../guest-auth-store"

function token(expSeconds: number) {
  const payload = btoa(JSON.stringify({ exp: expSeconds }))
  return `header.${payload}.signature`
}

describe("Ask AI guest auth store", () => {
  beforeEach(() => {
    window.sessionStorage.clear()
    setAskAIGuestToken(null)
  })

  it("persists a scoped guest token for the tab", () => {
    const value = { jwt: token(Math.floor(Date.now() / 1000) + 3_600), subject: "ask-guest:test" }
    setAskAIGuestToken(value)
    expect(getAskAIGuestToken()).toEqual(value)
  })

  it("rejects expired and non-guest identities", () => {
    setAskAIGuestToken({ jwt: token(1), subject: "ask-guest:expired" })
    expect(getAskAIGuestToken()).toBeNull()
    setAskAIGuestToken({ jwt: token(Math.floor(Date.now() / 1000) + 3_600), subject: "0xwallet" })
    expect(getAskAIGuestToken()).toBeNull()
  })
})
