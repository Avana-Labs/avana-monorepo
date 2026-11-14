import { describe, expect, it } from "vitest"
import { buildSiweMessage, extractSiweAddress, extractSiweChainId, extractSiweNonce } from "@/app/lib/siwe/message"

const ADDRESS = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"

describe("SIWE message", () => {
  it("builds an EIP-4361 message with the address on line 2 and required fields", () => {
    const msg = buildSiweMessage({
      address: ADDRESS,
      domain: "localhost:3000",
      uri: "http://localhost:3000",
      nonce: "abc123",
      issuedAt: "2026-06-29T00:00:00.000Z",
      chainId: 1,
    })
    const lines = msg.split("\n")
    expect(lines[0]).toBe("localhost:3000 wants you to sign in with your Ethereum account:")
    expect(lines[1]).toBe(ADDRESS)
    expect(msg).toContain("URI: http://localhost:3000")
    expect(msg).toContain("Chain ID: 1")
    expect(msg).toContain("Nonce: abc123")
    expect(msg).toContain("Issued At: 2026-06-29T00:00:00.000Z")
  })

  it("round-trips the address and nonce out of a built message", () => {
    const msg = buildSiweMessage({
      address: ADDRESS,
      domain: "localhost:3000",
      uri: "http://localhost:3000",
      nonce: "deadbeef",
      issuedAt: "2026-06-29T00:00:00.000Z",
      chainId: 1,
    })
    expect(extractSiweAddress(msg)).toBe(ADDRESS)
    expect(extractSiweNonce(msg)).toBe("deadbeef")
  })

  it("rejects a malformed address line", () => {
    expect(extractSiweAddress("not a siwe message\n0xnotanaddress\n")).toBeNull()
    expect(extractSiweNonce("no nonce here")).toBeNull()
  })

  it("extracts the chain id, and returns null when absent or malformed", () => {
    const msg = buildSiweMessage({
      address: ADDRESS,
      domain: "localhost:3000",
      uri: "http://localhost:3000",
      nonce: "abc123",
      issuedAt: "2026-06-29T00:00:00.000Z",
      chainId: 1,
    })
    expect(extractSiweChainId(msg)).toBe(1)
    expect(extractSiweChainId("no chain here")).toBeNull()
    expect(extractSiweChainId("Chain ID: not-a-number")).toBeNull()
  })
})
