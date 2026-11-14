import { SITE_URL } from "@/app/lib/site-url"

type JsonValue = string | number | boolean | null | JsonValue[] | { [key: string]: JsonValue }

/**
 * Escape the characters that could break out of the `<script>` element when a
 * JSON-LD payload is injected via `dangerouslySetInnerHTML`. `<`, `>` and `&`
 * are rewritten to their `\uXXXX` escapes — still valid JSON, but inert as HTML,
 * so a string value like `</script>` cannot close the tag or inject markup.
 */
function escapeJsonLd(json: string): string {
  return json.replace(/</g, "\\u003c").replace(/>/g, "\\u003e").replace(/&/g, "\\u0026")
}

export function SchemaMarkup({ data }: { data: JsonValue | JsonValue[] }) {
  // Synchronous on purpose: JSON-LD is a non-executable data block, so CSP script-src does not
  // gate it and no per-request nonce is needed. Staying sync (no `await headers()`) renders the
  // tag into the initial HTML shell that static/AI crawlers read, instead of only the streamed
  // RSC flight payload.
  return <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: escapeJsonLd(JSON.stringify(data)) }} />
}

export function buildWebPageSchema(input: { name: string; description: string; url: string }) {
  return {
    "@context": "https://schema.org",
    "@type": "WebPage",
    name: input.name,
    description: input.description,
    url: input.url,
    isPartOf: {
      "@type": "WebSite",
      name: "Avana",
      url: SITE_URL,
    },
  }
}

export function buildBreadcrumbSchema(items: Array<{ name: string; url: string }>) {
  return {
    "@context": "https://schema.org",
    "@type": "BreadcrumbList",
    itemListElement: items.map((item, index) => ({
      "@type": "ListItem",
      position: index + 1,
      name: item.name,
      item: item.url,
    })),
  }
}

export function buildWebSiteSchema() {
  return {
    "@context": "https://schema.org",
    "@type": "WebSite",
    name: "Avana",
    url: SITE_URL,
    description: "Borrow against LP positions and lend on Avana.",
  }
}

export function buildOrganizationSchema() {
  return {
    "@context": "https://schema.org",
    "@type": "Organization",
    name: "Avana",
    url: SITE_URL,
    logo: `${SITE_URL}/Avana%20Favicon.png`,
    sameAs: ["https://x.com/avana", "https://github.com/Avana-Labs"],
  }
}

export function buildFaqSchema(items: Array<{ question: string; answer: string }>) {
  return {
    "@context": "https://schema.org",
    "@type": "FAQPage",
    mainEntity: items.map((item) => ({
      "@type": "Question",
      name: item.question,
      acceptedAnswer: {
        "@type": "Answer",
        text: item.answer,
      },
    })),
  }
}
