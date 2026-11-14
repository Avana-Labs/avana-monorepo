import "./globals.css"
import type { Metadata } from "next"
import { cookies, headers } from "next/headers"
import localFont from "next/font/local"
import type React from "react"
import { Suspense } from "react"
import { Analytics } from "@vercel/analytics/next"
import { SpeedInsights } from "@vercel/speed-insights/next"
import { AnalyticsErrorSuppressor } from "./components/analytics-error-boundary"
import { InpReporter } from "./components/inp-reporter"
import { ThemeProvider } from "./components/theme-provider"
import { DisplayPreferencesProvider } from "./components/display-preferences"
import { WalletGateProvider } from "./lib/web3/wallet-gate"
import { SiweServerSessionProvider } from "./lib/siwe/use-siwe-auth"
import { verifySiweSessionJwt } from "./lib/siwe/jwt"
import { Web3ProviderBoundary } from "./lib/web3/web3-provider-boundary"
import { PageLoadingBar } from "./components/page-loading-bar"
import { ScrollResetOnNavigate } from "./components/scroll-reset-on-navigate"
import { ConditionalSiteChrome } from "./components/conditional-site-chrome"
import { SandboxGate } from "./components/sandbox/sandbox-gate"
import { ONBOARDED_COOKIE } from "./components/sandbox/onboarded-cookie"
import { CurrencyDisplayBoundary } from "./components/currency-display-boundary"
import { ProductRuntimeProviders } from "./components/product-runtime-providers"
import { isLighthouseAuditMode } from "./lib/test-mode"
import { SITE_URL } from "./lib/site-url"
import { SchemaMarkup, buildOrganizationSchema, buildWebSiteSchema } from "./components/seo/schema"
import { loadServerTokenPrices } from "./lib/prices/server-hydrate"
// Only load Vercel Analytics / Speed Insights when actually running on Vercel — their
// scripts are served by Vercel's edge (/_vercel/*), so a local `next start` build 404s
// on them and logs console errors (a Lighthouse best-practices failure). On Vercel the
// VERCEL env var is set and the scripts resolve normally.
const enableProductionAnalytics = process.env.NODE_ENV === "production" && Boolean(process.env.VERCEL)
const enableInpReporter = process.env.NODE_ENV !== "production" || process.env.ENABLE_WEB_VITALS_LOGS === "1"
const enableWebVitalsBeacon = process.env.ENABLE_WEB_VITALS_LOGS === "1"

const diatypeSans = localFont({
  src: [
    {
      path: "../public/fonts/diatype/core/ABCDiatype-Regular-Trial.woff2",
      weight: "400",
      style: "normal",
    },
  ],
  variable: "--font-diatype-sans",
  // preload puts the font on the critical path so it is fetched well before first paint (~170ms
  // vs ~800ms when it was off the critical path). With the font already available when text paints,
  // `swap` renders directly in Diatype — no fallback→Diatype swap flash. preload (not `optional`) is
  // what fixes the flash; `swap` keeps the preload "used" so there is no "preloaded but not used"
  // console warning (which `optional` produced whenever the font missed its short block window) and
  // guarantees the brand font always applies. CLS stays 0 via the metric-matched fallback.
  display: "swap",
  preload: true,
  // Metric-matched fallback so the preload+swap path does not double-paint the hero
  // (fallback glyphs and Diatype occupy the same boxes; CLS stays 0).
  adjustFontFallback: "Arial",
})

const themeBootstrapScript = `(()=>{const storageKey="avana-theme";const root=document.documentElement;const storedTheme=window.localStorage.getItem(storageKey);const theme=storedTheme==="light"||storedTheme==="dark"||storedTheme==="system"?storedTheme:"light";const systemTheme=window.matchMedia("(prefers-color-scheme: dark)").matches?"dark":"light";const resolvedTheme=theme==="system"?systemTheme:theme;root.classList.toggle("dark",resolvedTheme==="dark");root.style.colorScheme=resolvedTheme})()`

export const metadata: Metadata = {
  metadataBase: new URL(SITE_URL),
  title: {
    default: "Avana - Borrow Against LP Positions on Aave v4",
    template: "%s | Avana",
  },
  description:
    "Unlock liquidity from your LP tokens. Borrow up to 80% against Uniswap, Curve, and Balancer positions while continuing to earn trading fees on Aave v4.",
  applicationName: "Avana",
  authors: [{ name: "Avana Team" }],
  creator: "Avana",
  publisher: "Avana",
  keywords: [
    "DeFi",
    "Liquidity Provider",
    "LP tokens",
    "Collateral",
    "Borrowing",
    "Aave v4",
    "Uniswap",
    "Curve",
    "Balancer",
    "AMM",
    "Lending",
    "Yield Farming",
  ],
  alternates: {
    canonical: "/",
  },
  // Default every app route to noindex: the wallet gate serves crawlers the onboarding shell, and
  // the marketing host (www.avana.cc) owns brand SEO. Routes with real public content opt back in
  // via buildSeoMetadata({ index: true }) — currently only / and /ask.
  robots: { index: false, follow: true },
  openGraph: {
    type: "website",
    url: SITE_URL,
    siteName: "Avana",
    title: "Avana - Borrow Against LP Positions on Aave v4",
    description: "Unlock liquidity from your LP tokens while continuing to earn trading fees.",
    // og:image is supplied by app/opengraph-image.tsx (auto-resolved to the serving
    // origin, so the X share card works on whichever domain hosts the app).
  },
  twitter: {
    card: "summary_large_image",
    title: "Avana - Borrow Against LP Positions",
    description: "Unlock liquidity from your LP tokens on Aave v4",
  },
  icons: {
    icon: [
      {
        url: "/Avana Favicon.png",
        type: "image/png",
      },
    ],
    shortcut: [
      {
        url: "/Avana Favicon.png",
      },
    ],
    apple: [
      {
        url: "/Avana Favicon.png",
      },
    ],
  },
}

export default async function RootLayout({ children }: { children: React.ReactNode }) {
  const isAuditMode = isLighthouseAuditMode()

  if (isAuditMode) {
    return (
      <html lang="en" data-lighthouse-audit="true" suppressHydrationWarning>
        <body className="min-h-screen bg-background">{children}</body>
      </html>
    )
  }

  // Fetch the live oracle prices once on the server: this hydrates the server-side canonical
  // store (server-computed price surfaces render live) AND yields the seed handed to the client
  // TokenPricesContext, so CLIENT-rendered prices are live from SSR. FX is intentionally not
  // fetched here: DisplayPreferencesProvider applies its local cache and refreshes in the browser,
  // while the server always renders USD. A root-level FX request only delayed every route.
  // Awaited here rather than behind a Suspense boundary: streaming the page body after the shell
  // turns notFound()/redirect() into soft 200s. The seed's 250ms cold-cache cap bounds the wait.
  const initialTokenPrices = await loadServerTokenPrices()
  // Per-request CSP nonce (set by middleware) for the inline theme-bootstrap script below.
  const nonce = (await headers()).get("x-nonce") ?? undefined
  // Server-owned HttpOnly SIWE session. Re-verifying it here (signature + expiry, no network)
  // tells us whether this visitor is signed in; only the wallet metadata is handed to the client.
  const jar = await cookies()
  const sessionJwt = jar.get("avana_siwe")?.value
  const verified = sessionJwt ? verifySiweSessionJwt(sessionJwt) : null
  const serverSession = verified ? { wallet: verified.wallet } : null
  // Wallet that last finished onboarding on this browser (set by the gate checker). Only honoured
  // when it names the verified session wallet, so the product is server-rendered for returning
  // users while a different/new wallet still waits for Convex behind the skeleton.
  const onboardedCookie = jar.get(ONBOARDED_COOKIE)?.value?.toLowerCase()
  const onboardedWallet = serverSession && onboardedCookie === serverSession.wallet ? onboardedCookie : undefined

  return (
    <html
      lang="en"
      className={diatypeSans.variable}
      data-lighthouse-audit={isAuditMode ? "true" : undefined}
      suppressHydrationWarning
    >
      <head>
        <link
          rel="preload"
          as="image"
          href="/avana-wordmark-220.png"
          imageSrcSet="/avana-wordmark-220.png 220w, /avana-wordmark-440.png 440w"
          imageSizes="220px"
          fetchPriority="high"
          media="(min-width: 1280px)"
        />
        <link rel="preload" as="image" href="/avana-icon-64.png" />
        {/* Inline so theme/color-scheme apply before first paint — external src added a
            network hop and could shift scrollbar-gutter when overlays open. */}
        <script nonce={nonce} dangerouslySetInnerHTML={{ __html: themeBootstrapScript }} suppressHydrationWarning />
        {/* Site-wide JSON-LD in <head> so it lands in the served HTML shell (static/AI crawlers
            read it) on every route, independent of the wallet gate that intercepts page bodies. */}
        <SchemaMarkup data={[buildWebSiteSchema(), buildOrganizationSchema()]} />
      </head>
      <body className="min-h-screen bg-background">
        <ThemeProvider attribute="class" defaultTheme="light" enableSystem disableTransitionOnChange>
          <DisplayPreferencesProvider>
            <SiweServerSessionProvider session={serverSession}>
              <WalletGateProvider>
                <Web3ProviderBoundary>
                  {/* Site chrome (header + action-route suppression) is hoisted ABOVE the
                    session/auth gates so the header stays painted through every loading
                    state — the gates only ever swap the content region below it. Header's
                    subtree reads no gated context (currency/token-price/convex/session). */}
                  <ConditionalSiteChrome>
                    <Suspense fallback={null}>
                      <PageLoadingBar />
                    </Suspense>
                    <ScrollResetOnNavigate />
                    <SandboxGate onboardedWallet={onboardedWallet}>
                      <ProductRuntimeProviders initialTokenPrices={initialTokenPrices}>
                        <CurrencyDisplayBoundary>{children}</CurrencyDisplayBoundary>
                      </ProductRuntimeProviders>
                    </SandboxGate>
                  </ConditionalSiteChrome>
                </Web3ProviderBoundary>
              </WalletGateProvider>
            </SiweServerSessionProvider>
          </DisplayPreferencesProvider>
        </ThemeProvider>
        {/* In production, don't load or call the custom collector unless it is explicitly enabled. */}
        {enableInpReporter ? <InpReporter enableBeacon={enableWebVitalsBeacon} /> : null}
        {enableProductionAnalytics ? <AnalyticsErrorSuppressor /> : null}
        {enableProductionAnalytics ? <Analytics /> : null}
        {enableProductionAnalytics ? <SpeedInsights /> : null}
      </body>
    </html>
  )
}
