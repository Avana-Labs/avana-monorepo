/** @param {Record<string, string | undefined>} env */
export function assertNonProductionTarget(env, target = env.NEXT_PUBLIC_CONVEX_URL) {
  if (
    !["development", "staging"].includes(env.AVANA_DEPLOYMENT_ENV ?? "") ||
    env.VERCEL_ENV === "production" ||
    env.CONVEX_DEPLOY_KEY?.startsWith("prod:") ||
    env.CONVEX_DEPLOYMENT?.startsWith("prod:") ||
    !target ||
    target === env.AVANA_PRODUCTION_CONVEX_URL ||
    target !== env.AVANA_DEVELOPMENT_CONVEX_URL
  )
    throw new Error("Refusing production or unverified development target; configure an isolated deployment")
}

/** Deployment-owned gate; never accept a target or bypass from an action argument. */
export function assertSeedDeployment(env = process.env) {
  if (!["development", "staging"].includes(env.AVANA_DEPLOYMENT_ENV ?? "") || env.VERCEL_ENV === "production")
    throw new Error("Seed administration is disabled on this deployment")
}
