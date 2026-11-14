type Environment = Record<string, string | undefined>

/** A test secret alone must never turn a deploy into an impersonation endpoint. */
export function isIsolatedE2EStaging(env: Environment = process.env): boolean {
  if (env.VERCEL_ENV === "production" || env.AVANA_DEPLOYMENT_ENV !== "staging" || env.AVANA_E2E_STAGING !== "1")
    return false
  const target = env.AVANA_E2E_CONVEX_URL?.replace(/\/$/, "")
  const production = env.AVANA_PRODUCTION_CONVEX_URL?.replace(/\/$/, "")
  const issuer = env.NEXT_PUBLIC_SIWE_ISSUER?.replace(/\/$/, "")
  const productionIssuer = env.AVANA_PRODUCTION_SIWE_ISSUER?.replace(/\/$/, "")
  if (!target || !production || target === production || target !== env.NEXT_PUBLIC_CONVEX_URL?.replace(/\/$/, ""))
    return false
  if (!issuer || !productionIssuer || issuer === productionIssuer) return false
  try {
    const testKey = JSON.parse(env.AVANA_E2E_PRIVATE_JWK ?? "{}") as { n?: string; d?: string }
    const normalKey = JSON.parse(env.SIWE_JWT_PRIVATE_JWK ?? "{}") as { n?: string }
    return Boolean(testKey.n && testKey.d && testKey.n !== normalKey.n)
  } catch {
    return false
  }
}

export function allowsLocalE2E(env: Environment = process.env): boolean {
  return (
    env.NODE_ENV === "development" &&
    env.VERCEL_ENV !== "production" &&
    env.AVANA_DEPLOYMENT_ENV !== "production" &&
    env.NEXT_PUBLIC_PLAYWRIGHT_TEST_MODE === "1"
  )
}
