import { describe, it, expect } from "vitest"
import { GET } from "@/app/llms.txt/route"
import { SITE_URL } from "@/app/lib/site-url"

describe("/llms.txt", () => {
  it("serves a text/plain agent guide with a 'when to use' section and canonical links", async () => {
    const res = GET()
    expect(res.status).toBe(200)
    expect(res.headers.get("content-type")).toMatch(/text\/plain/)
    const body = await res.text()
    expect(body).toContain("# Avana")
    expect(body).toMatch(/When to use/i)
    expect(body).toContain(`${SITE_URL}/ask`)
    // Must self-reference the app host, never the marketing host.
    expect(body).not.toContain("https://avana.cc")
  })
})
