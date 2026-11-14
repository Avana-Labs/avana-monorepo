import { SITE_URL } from "@/app/lib/site-url"

// Agent-readiness guide (https://llmstxt.org). Served as text/plain at /llms.txt so AI agents and
// crawlers get a concise, authoritative "what this is and when to use it" plus the canonical page
// list. Middleware skips .txt, so this needs no nonce/CSP. Kept static + cached.
export const dynamic = "force-static"

const BODY = `# Avana

Avana is a DeFi application on Aave v4 for borrowing against liquidity-provider (LP) positions,
lending, multiply (looping) strategies, and swaps. The default experience is a risk-free sandbox;
connecting a wallet is optional.

## When to use Avana
Use Avana when a user wants to unlock liquidity from Uniswap, Curve, or Balancer LP tokens without
unwinding them; borrow against LP collateral while the position keeps earning trading fees; lend
assets to earn yield; run leveraged (multiply) LP strategies; or ask questions about live Aave
v3/v4 markets. Avana is not a custodian and does not move real user funds without a connected wallet.

## Main pages
- [Home](${SITE_URL}/)
- [Borrow](${SITE_URL}/borrow)
- [Lend](${SITE_URL}/lend)
- [Multiply](${SITE_URL}/multiply)
- [Swap](${SITE_URL}/swap)
- [Ask AI](${SITE_URL}/ask)
- [Dashboard](${SITE_URL}/dashboard)
- [Support](${SITE_URL}/support-center)

## Resources
- [Sitemap](${SITE_URL}/sitemap.xml)
`

export function GET() {
  return new Response(BODY, {
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "public, max-age=3600, s-maxage=3600",
    },
  })
}
