import { describe, it, expect } from "vitest"
import { renderToStaticMarkup } from "react-dom/server"
import { SchemaMarkup, buildOrganizationSchema } from "@/app/components/seo/schema"

// SchemaMarkup must be a synchronous server component so its JSON-LD renders into the initial
// HTML shell that static/AI crawlers read — not only the streamed RSC flight payload. An async
// component (awaiting headers() for a nonce) serializes to flight and leaves 0 real ld+json tags
// in the served HTML.
describe("SchemaMarkup renders JSON-LD into static HTML", () => {
  it("emits a real <script type=application/ld+json> tag", () => {
    const html = renderToStaticMarkup(<SchemaMarkup data={buildOrganizationSchema()} />)
    expect(html).toContain('<script type="application/ld+json">')
    expect(html).toContain("schema.org")
  })
})
