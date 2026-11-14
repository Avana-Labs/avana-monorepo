import { describe, expect, it } from "vitest"
import { buildSiweMessage } from "@/app/lib/siwe/message"
import { SIWE_CLOCK_SKEW_MS, SIWE_MAX_AGE_MS, checkSiweMessage } from "@/app/lib/siwe/verify-message"

const ADDRESS = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
const HOST = "localhost:3000"
const ISSUED = "2026-06-29T00:00:00.000Z"
const NOW = new Date("2026-06-29T00:01:00.000Z")
const CHECK = { host: HOST, nonce: "abc123def456", chainId: 1, now: NOW }

function message(overrides: Partial<Parameters<typeof buildSiweMessage>[0]> = {}) {
  return buildSiweMessage({
    address: ADDRESS,
    domain: HOST,
    uri: `http://${HOST}`,
    nonce: "abc123def456",
    issuedAt: ISSUED,
    chainId: 1,
    ...overrides,
  })
}

describe("buildSiweMessage", () => {
  it("builds an EIP-4361 message with the address on line 2 and required fields", () => {
    const lines = message().split("\n")
    expect(lines[0]).toBe(`${HOST} wants you to sign in with your Ethereum account:`)
    expect(lines[1]).toBe(ADDRESS)
    expect(lines).toContain(`URI: http://${HOST}`)
    expect(lines).toContain("Chain ID: 1")
    expect(lines).toContain("Nonce: abc123def456")
    expect(lines).toContain(`Issued At: ${ISSUED}`)
  })
})

describe("checkSiweMessage", () => {
  it("accepts the message the app builds", () => {
    expect(checkSiweMessage(message(), CHECK)).toEqual({ ok: true, address: ADDRESS })
  })

  it("rejects messages that do not rebuild exactly", () => {
    const base = message()
    for (const bad of [
      `${base}\nNonce: other`,
      base.replaceAll("\n", "\r\n"),
      `${base}\n`,
      `${base}\nIssued At: ${ISSUED}`,
      base.replace("Version: 1", "Version: 2"),
      base.replace(`Issued At: ${ISSUED}`, "Issued At: yesterday"),
      base.replace(`\nIssued At: ${ISSUED}`, ""),
      base.replace(ADDRESS, "0xnotanaddress"),
      "not a siwe message",
    ]) {
      expect(checkSiweMessage(bad, CHECK)).toMatchObject({ ok: false, status: 400 })
    }
  })

  it("binds the message to this origin, nonce and chain", () => {
    expect(checkSiweMessage(message({ domain: "evil.example" }), CHECK)).toMatchObject({ ok: false, status: 401 })
    expect(checkSiweMessage(message({ uri: "https://evil.example" }), CHECK)).toMatchObject({ ok: false, status: 401 })
    expect(checkSiweMessage(message({ nonce: "other123other" }), CHECK)).toMatchObject({ ok: false, status: 401 })
    expect(checkSiweMessage(message({ chainId: 8453 }), CHECK)).toMatchObject({ ok: false, status: 401 })
  })

  it("checks Issued At against the clock skew and the nonce lifetime", () => {
    const at = (ms: number) => new Date(NOW.getTime() + ms).toISOString()
    expect(checkSiweMessage(message({ issuedAt: at(SIWE_CLOCK_SKEW_MS) }), CHECK).ok).toBe(true)
    expect(checkSiweMessage(message({ issuedAt: at(SIWE_CLOCK_SKEW_MS + 1000) }), CHECK)).toMatchObject({
      ok: false,
      status: 401,
    })
    expect(checkSiweMessage(message({ issuedAt: at(-SIWE_MAX_AGE_MS) }), CHECK).ok).toBe(true)
    expect(checkSiweMessage(message({ issuedAt: at(-SIWE_MAX_AGE_MS - 1000) }), CHECK)).toMatchObject({
      ok: false,
      status: 401,
    })
  })

  it("checks Expiration Time and Not Before when present", () => {
    const base = message()
    const withLines = (...lines: string[]) => `${base}\n${lines.join("\n")}`
    expect(checkSiweMessage(withLines("Expiration Time: 2026-06-29T00:05:00.000Z"), CHECK).ok).toBe(true)
    expect(checkSiweMessage(withLines("Expiration Time: 2026-06-29T00:00:30.000Z"), CHECK)).toMatchObject({
      ok: false,
      status: 401,
    })
    expect(checkSiweMessage(withLines("Expiration Time: 2026-06-28T23:59:00.000Z"), CHECK)).toMatchObject({ ok: false })
    expect(checkSiweMessage(withLines("Not Before: 2026-06-29T00:02:00.000Z"), CHECK)).toMatchObject({
      ok: false,
      status: 401,
    })
  })
})
