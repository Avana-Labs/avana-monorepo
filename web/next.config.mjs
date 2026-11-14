import path from "node:path"
import process from "node:process"
import bundleAnalyzer from "@next/bundle-analyzer"
import { withSentryConfig } from "@sentry/nextjs"
import { sentryDeploymentFlag } from "./app/lib/monitoring/sentry-deployment-flag.mjs"

const isDev = process.env.NODE_ENV === "development"

// Opt-in bundle analysis: `npm run analyze` (ANALYZE=1) opens the treemap after a build so the
// first-load JS impact of optimizePackageImports / demand-loading changes is measurable.
const withBundleAnalyzer = bundleAnalyzer({ enabled: process.env.ANALYZE === "1" })

// NOTE: Content-Security-Policy is set per-request in proxy.ts so it can carry a nonce and
// drop `script-src 'unsafe-inline'` in production. The remaining static security headers stay here.
const securityHeaders = [
  {
    key: "Strict-Transport-Security",
    value: "max-age=63072000; includeSubDomains; preload",
  },
  {
    key: "X-Frame-Options",
    value: "DENY",
  },
  {
    key: "Referrer-Policy",
    value: "strict-origin-when-cross-origin",
  },
  {
    // Wallet flows (Coinbase Smart Wallet, WalletConnect, social logins) open auth
    // popups and post back via window.opener. "same-origin-allow-popups" keeps the
    // opener reference reachable for those popups while still isolating cross-origin
    // documents — a stricter "same-origin" would null window.opener and break them.
    key: "Cross-Origin-Opener-Policy",
    value: "same-origin-allow-popups",
  },
  {
    key: "Permissions-Policy",
    value:
      "accelerometer=(), autoplay=(), camera=(), display-capture=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), midi=(), payment=(), publickey-credentials-get=(), usb=()",
  },
  {
    key: "X-Content-Type-Options",
    value: "nosniff",
  },
]

// Vercel preview deployment (a feature-branch push), as opposed to production or local.
const isVercelPreview = process.env.VERCEL_ENV === "preview"

/** @type {import('next').NextConfig} */
const nextConfig = {
  poweredByHeader: false,
  // Inlined for server, edge and client: Sentry reports only from a Vercel deployment.
  env: {
    NEXT_PUBLIC_AVANA_SENTRY_DEPLOYED: sentryDeploymentFlag(process.env),
  },
  typescript: {
    // Same duplication for `tsc`, but a type error CAN change behaviour, so this is only
    // skipped on preview builds — the feature-branch pushes that make up most of the build
    // volume and ship to nobody. Production builds still typecheck, and CI runs
    // `npx tsc --noEmit` on every PR to main and every push to main.
    ignoreBuildErrors: isVercelPreview,
  },
  // Playwright and local mobile-device testing use the loopback host while the
  // dev server may bind as localhost. Next otherwise blocks the client chunks/HMR
  // request and leaves client-only session hydration at its server skeleton.
  allowedDevOrigins: isDev ? ["127.0.0.1"] : undefined,
  experimental: {
    // NOT inlining CSS: with `inlineCss: true` the ~127KB global stylesheet was embedded
    // three times in every HTML document (once as <style>, twice inside the RSC payload),
    // turning a ~20KB page into a 450KB one that the browser must download and parse before
    // hydration. A single cached <link> stylesheet is cheaper on every visit after the first
    // and removes ~60KB (gzipped) from the critical path on the first.
    inlineCss: false,
    // Tree-shake heavy barrel packages so a 2-icon import doesn't pull the whole library.
    // @fluentui/react-icons especially ships thousands of icons behind one barrel.
    optimizePackageImports: ["framer-motion", "@hugeicons/react", "@hugeicons/core-free-icons"],
  },
  async redirects() {
    return [
      // The old Portfolio and Rewards pages were folded into the dashboard, which is now the
      // only account entry point. Redirect the retired routes (and any old bookmarks) there at
      // the edge rather than dead-ending on a 404. Guarded by the portfolio-routing e2e smoke.
      { source: "/portfolio", destination: "/dashboard", permanent: true },
      { source: "/rewards", destination: "/dashboard", permanent: true },
    ]
  },
  async rewrites() {
    return [
      // SIWE → JWT bridge: Convex fetches the OIDC discovery doc + JWKS at these
      // well-known paths to verify the app's JWTs. Served by /api route handlers.
      { source: "/.well-known/openid-configuration", destination: "/api/siwe/openid-configuration" },
      { source: "/.well-known/jwks.json", destination: "/api/siwe/jwks" },
    ]
  },
  async headers() {
    return [
      {
        source: "/:path*",
        headers: securityHeaders,
      },
    ]
  },
  distDir: process.env.AVANA_NEXT_DIST_DIR || ".next",
  // Local perf builds (`AVANA_PERF_SOURCEMAPS=1`) emit browser source maps so chunk
  // fingerprinting names real modules instead of minified guesswork. Production
  // deploys leave this off (Sentry uploads maps separately).
  productionBrowserSourceMaps: process.env.AVANA_PERF_SOURCEMAPS === "1",
  images: {
    remotePatterns: [
      { protocol: "https", hostname: "cryptologos.cc" },
      { protocol: "https", hostname: "token-logos.family.co" },
      { protocol: "https", hostname: "raw.githubusercontent.com" },
      { protocol: "https", hostname: "cdn.prod.website-files.com" },
      { protocol: "https", hostname: "avatars.githubusercontent.com" },
    ],
  },
  // The monorepo root: web/ imports the Convex API and Ask AI library from services/convex.
  turbopack: {
    root: path.resolve(process.cwd(), ".."),
  },
}

export default withSentryConfig(withBundleAnalyzer(nextConfig), {
  // For all available options, see:
  // https://www.npmjs.com/package/@sentry/webpack-plugin#options
  org: "avana",
  project: "sentry-byzantine-book",

  // Only print logs for uploading source maps in CI
  silent: !process.env.CI,

  // For all available options, see:
  // https://docs.sentry.io/platforms/javascript/guides/nextjs/manual-setup/

  // Upload a larger set of source maps for prettier stack traces (increases build time)
  widenClientFileUpload: true,

  // Route browser requests to Sentry through a Next.js rewrite to circumvent ad-blockers.
  // Note: Check that the configured route will not match with your Next.js middleware/proxy,
  // otherwise reporting of client-side errors will fail.
  tunnelRoute: "/monitoring",

  webpack: {
    // Enables automatic instrumentation of Vercel Cron Monitors. (Does not yet work with App Router route handlers.)
    // See the following for more information:
    // https://docs.sentry.io/product/crons/
    // https://vercel.com/docs/cron-jobs
    automaticVercelMonitors: true,

    // Tree-shaking options for reducing bundle size
    treeshake: {
      // Automatically tree-shake Sentry logger statements to reduce bundle size
      removeDebugLogging: true,
    },
  },
})
