import { renderToStaticMarkup } from "react-dom/server"
import { describe, expect, it, vi } from "vitest"

// SchemaMarkup reads the per-request CSP nonce from next/headers; stub it for the render.
vi.mock("next/headers", () => ({
  headers: async () => new Headers({ "x-nonce": "test-nonce" }),
}))

import { SchemaMarkup } from "../schema"

describe("SchemaMarkup — JSON-LD escaping (P3-7)", () => {
  it("escapes </script> and other HTML-significant characters so the tag can't be broken out of", async () => {
    const html = renderToStaticMarkup(
      await SchemaMarkup({ data: { name: "</script><img src=x onerror=alert(1)>", note: "a & b" } }),
    )
    // No raw sequence that a parser would treat as markup.
    expect(html).not.toContain("</script><img")
    expect(html).not.toContain("<img")
    // The value survives as escaped JSON.
    expect(html).toContain("\\u003c/script\\u003e")
    expect(html).toContain("a \\u0026 b")
  })

  it("still emits valid JSON that round-trips to the original data", async () => {
    const data = { "@type": "WebPage", name: "A <b> & c > d" }
    const html = renderToStaticMarkup(await SchemaMarkup({ data }))
    const json = html.replace(/^<script[^>]*>/, "").replace(/<\/script>$/, "")
    expect(JSON.parse(json)).toEqual(data)
  })
})
