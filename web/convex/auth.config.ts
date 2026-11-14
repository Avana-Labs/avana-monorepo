/**
 * Registers the SIWE → JWT issuer so `ctx.auth.getUserIdentity()` is populated from
 * the sandbox JWTs minted by the app's /api/siwe/verify route. Convex fetches
 * `${domain}/.well-known/openid-configuration` → JWKS to verify each token.
 *
 * `domain` MUST equal the token `iss` (app/lib/siwe/jwt.ts resolveIssuer) and be
 * reachable by the Convex backend. Local dev defaults to the Next dev origin; set the
 * `SIWE_JWT_ISSUER` Convex env var in deployed environments (e.g. the Vercel URL).
 */
// Strip any trailing slash so this EXACTLY matches the token `iss` minted by the app
// (app/lib/siwe/jwt.ts also strips it) — Convex compares issuer to `domain` by exact string.
const issuer = (process.env.SIWE_JWT_ISSUER ?? "http://localhost:3000").replace(/\/+$/, "")

export default {
  providers: [
    {
      domain: issuer,
      applicationID: "convex",
    },
  ],
}
