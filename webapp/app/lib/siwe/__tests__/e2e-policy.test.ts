import crypto from "node:crypto"
import { afterEach, expect, it, vi } from "vitest"
import { allowsLocalE2E, isIsolatedE2EStaging } from "../e2e-policy"
import { mintSiweSessionJwt, verifySiweSessionJwt } from "../jwt"

const key = () =>
  JSON.stringify(crypto.generateKeyPairSync("rsa", { modulusLength: 2048 }).privateKey.export({ format: "jwk" }))
const env = () => ({
  NODE_ENV: "production",
  VERCEL_ENV: "preview",
  AVANA_DEPLOYMENT_ENV: "staging",
  AVANA_E2E_STAGING: "1",
  NEXT_PUBLIC_CONVEX_URL: "https://stage.convex.cloud",
  AVANA_E2E_CONVEX_URL: "https://stage.convex.cloud",
  AVANA_PRODUCTION_CONVEX_URL: "https://prod.convex.cloud",
  NEXT_PUBLIC_SIWE_ISSUER: "https://stage.example.com",
  AVANA_PRODUCTION_SIWE_ISSUER: "https://example.com",
  SIWE_JWT_PRIVATE_JWK: key(),
  AVANA_E2E_PRIVATE_JWK: key(),
})
afterEach(() => vi.unstubAllEnvs())
it("refuses production and incomplete staging even with bypass flags", () => {
  const staging = env()
  expect(isIsolatedE2EStaging(staging)).toBe(true)
  expect(isIsolatedE2EStaging({ ...staging, VERCEL_ENV: "production" })).toBe(false)
  expect(isIsolatedE2EStaging({ ...staging, AVANA_DEPLOYMENT_ENV: "production" })).toBe(false)
  expect(isIsolatedE2EStaging({ ...staging, AVANA_E2E_PRIVATE_JWK: staging.SIWE_JWT_PRIVATE_JWK })).toBe(false)
  expect(isIsolatedE2EStaging({ ...staging, AVANA_PRODUCTION_CONVEX_URL: staging.NEXT_PUBLIC_CONVEX_URL })).toBe(false)
  expect(allowsLocalE2E({ NODE_ENV: "production", NEXT_PUBLIC_PLAYWRIGHT_TEST_MODE: "1" })).toBe(false)
  expect(allowsLocalE2E({ NODE_ENV: "development", NEXT_PUBLIC_PLAYWRIGHT_TEST_MODE: "1" })).toBe(true)
})
it("staging sessions cannot verify with the normal signing key", () => {
  const staging = env()
  for (const [name, value] of Object.entries(staging)) vi.stubEnv(name, value)
  const token = mintSiweSessionJwt("0x1111111111111111111111111111111111111111", staging.NEXT_PUBLIC_SIWE_ISSUER)
  expect(verifySiweSessionJwt(token)).not.toBeNull()
  vi.stubEnv("AVANA_E2E_STAGING", "")
  expect(verifySiweSessionJwt(token)).toBeNull()
})

it("production endpoint returns 404 even with the correct secret and test flag", async () => {
  vi.stubEnv("NODE_ENV", "production")
  vi.stubEnv("VERCEL_ENV", "production")
  vi.stubEnv("AVANA_E2E_SESSION_SECRET", "test-secret")
  vi.stubEnv("NEXT_PUBLIC_PLAYWRIGHT_TEST_MODE", "1")
  const { POST } = await import("@/app/api/siwe/e2e-session/route")
  const response = await POST(
    new Request("https://example.com/api/siwe/e2e-session", {
      method: "POST",
      headers: { "x-avana-e2e-secret": "test-secret" },
      body: JSON.stringify({ wallet: "0x1111111111111111111111111111111111111111" }),
    }),
  )
  expect(response.status).toBe(404)
})
