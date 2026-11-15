import { afterEach, describe, expect, it, vi } from "vitest"
import { resolveActionCloseHref } from "@/app/lib/action-system/contracts"
import { isSafeExternalUrl, openExternal, safeInternalHref } from "@/app/lib/safe-links"

const OPEN_REDIRECTS = [
  "//evil.example",
  "/\\evil.example",
  "/\\/evil.example",
  "/%09/evil.example",
  "/%0a/evil.example",
  "/%5Cevil.example",
  "/%2F/evil.example",
  "/\t/evil.example",
  "https://evil.example",
  "javascript:alert(1)",
  "evil.example",
  "/%E0%A4%A",
]

describe("safeInternalHref", () => {
  it.each(OPEN_REDIRECTS)("rejects %s", (value) => {
    expect(safeInternalHref(value)).toBeNull()
  })

  it("keeps same-origin paths with query and hash", () => {
    expect(safeInternalHref("/borrow/markets/eth-usdc?tab=risk#about")).toBe("/borrow/markets/eth-usdc?tab=risk#about")
    expect(safeInternalHref("/")).toBe("/")
  })

  it("rejects empty values", () => {
    expect(safeInternalHref(undefined)).toBeNull()
    expect(safeInternalHref("")).toBeNull()
  })
})

describe("resolveActionCloseHref", () => {
  it.each(OPEN_REDIRECTS)("falls back for %s", (value) => {
    expect(resolveActionCloseHref("borrow", value)).toBe("/borrow")
    expect(resolveActionCloseHref("lend", value)).toBe("/lend")
  })

  it("keeps and normalizes a same-origin return path", () => {
    expect(resolveActionCloseHref("borrow", "/borrow/pool/eth-usdc")).toBe("/borrow/markets/eth-usdc")
    expect(resolveActionCloseHref("lend", "/lend/markets/usdc")).toBe("/lend/markets/usdc")
  })
})

describe("isSafeExternalUrl", () => {
  it("allows only https with a host and no credentials", () => {
    expect(isSafeExternalUrl("https://etherscan.io/address/0x1")).toBe(true)
    expect(isSafeExternalUrl("http://etherscan.io")).toBe(false)
    expect(isSafeExternalUrl("javascript:alert(1)")).toBe(false)
    expect(isSafeExternalUrl("data:text/html,<script>")).toBe(false)
    expect(isSafeExternalUrl("https://user:pass@evil.example")).toBe(false)
    expect(isSafeExternalUrl("/relative")).toBe(false)
    expect(isSafeExternalUrl(undefined)).toBe(false)
  })
})

describe("openExternal", () => {
  afterEach(() => vi.unstubAllGlobals())

  function stubOpen() {
    const open = vi.fn()
    vi.stubGlobal("window", { open })
    return open
  }

  it("opens https links with noopener and noreferrer", () => {
    const open = stubOpen()
    openExternal("https://x.com/search?q=USDC")
    expect(open).toHaveBeenCalledWith("https://x.com/search?q=USDC", "_blank", "noopener,noreferrer")
  })

  it("ignores unsafe links", () => {
    const open = stubOpen()
    openExternal("javascript:alert(1)")
    openExternal("http://evil.example")
    expect(open).not.toHaveBeenCalled()
  })
})
