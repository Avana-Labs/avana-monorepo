import crypto from "node:crypto"
import { afterAll, beforeAll, describe, expect, it } from "vitest"
import { mintAskGuestJwt, mintConvexJwt, mintSiweSessionJwt, verifyConvexJwt, verifySiweSessionJwt } from "../jwt"

const WALLET = "0x1111111111111111111111111111111111111111"
const previous = process.env.SIWE_JWT_PRIVATE_JWK

beforeAll(() => {
  const { privateKey } = crypto.generateKeyPairSync("rsa", { modulusLength: 2048 })
  process.env.SIWE_JWT_PRIVATE_JWK = JSON.stringify({ ...privateKey.export({ format: "jwk" }), kid: "test" })
})
afterAll(() => {
  if (previous === undefined) delete process.env.SIWE_JWT_PRIVATE_JWK
  else process.env.SIWE_JWT_PRIVATE_JWK = previous
})

describe("SIWE JWT purposes", () => {
  it("accepts a wallet token we minted and returns its wallet", () => {
    const token = mintConvexJwt(WALLET, "https://avana.test")
    expect(verifyConvexJwt(token)?.wallet).toBe(WALLET)
  })

  it("rejects a tampered payload", () => {
    const [h, p, s] = mintConvexJwt(WALLET, "https://avana.test").split(".") as [string, string, string]
    const claims = JSON.parse(Buffer.from(p, "base64url").toString("utf8")) as Record<string, unknown>
    claims.wallet = "0x2222222222222222222222222222222222222222"
    const forged = `${h}.${Buffer.from(JSON.stringify(claims)).toString("base64url")}.${s}`
    expect(verifyConvexJwt(forged)).toBeNull()
  })

  it("rejects Ask-AI guest tokens (no wallet scope) and garbage", () => {
    expect(verifyConvexJwt(mintAskGuestJwt(crypto.randomUUID(), "https://avana.test"))).toBeNull()
    expect(verifyConvexJwt("not.a.jwt")).toBeNull()
    expect(verifyConvexJwt("")).toBeNull()
  })

  it("keeps browser sessions and Convex bearer tokens purpose-bound", () => {
    const session = mintSiweSessionJwt(WALLET, "https://avana.test")
    const access = mintConvexJwt(WALLET, "https://avana.test")

    expect(verifySiweSessionJwt(session)?.wallet).toBe(WALLET)
    expect(verifyConvexJwt(session)).toBeNull()
    expect(verifySiweSessionJwt(access)).toBeNull()
  })

  it("rejects a token signed by a different key", () => {
    const token = mintConvexJwt(WALLET, "https://avana.test")
    const { privateKey } = crypto.generateKeyPairSync("rsa", { modulusLength: 2048 })
    process.env.SIWE_JWT_PRIVATE_JWK = JSON.stringify({ ...privateKey.export({ format: "jwk" }), kid: "other" })
    expect(verifyConvexJwt(token)).toBeNull()
  })
})
