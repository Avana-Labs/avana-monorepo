import { expect, it } from "vitest"
import { assertNonProductionTarget, assertSeedDeployment } from "../../lib/deployment-safety.mjs"
it("rejects unknown/production targets before any seed client is constructed", () => {
  const env = {
    AVANA_DEPLOYMENT_ENV: "development",
    NEXT_PUBLIC_CONVEX_URL: "https://dev.convex.cloud",
    AVANA_DEVELOPMENT_CONVEX_URL: "https://dev.convex.cloud",
  }
  expect(() => assertNonProductionTarget(env)).not.toThrow()
  for (const bad of [
    { CONVEX_DEPLOY_KEY: "prod:example|redacted" },
    { AVANA_DEPLOYMENT_ENV: "production" },
    { AVANA_DEVELOPMENT_CONVEX_URL: "https://other.convex.cloud" },
    { AVANA_PRODUCTION_CONVEX_URL: env.NEXT_PUBLIC_CONVEX_URL },
  ])
    expect(() => assertNonProductionTarget({ ...env, ...bad })).toThrow(/Refusing/)
  expect(() => assertSeedDeployment({ AVANA_DEPLOYMENT_ENV: "production" })).toThrow(/disabled/)
  expect(() => assertSeedDeployment({})).toThrow(/disabled/)
  expect(() => assertSeedDeployment({ AVANA_DEPLOYMENT_ENV: "staging" })).not.toThrow()
})
