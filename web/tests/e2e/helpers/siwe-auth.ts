import type { APIRequestContext, Page } from "@playwright/test"

/**
 * Install a real HttpOnly `avana_siwe` session for Playwright.
 * Replaces the legacy `sessionStorage` JWT helper that auth-store no longer reads.
 */
export function walletFromAuthToken(token: string) {
  const payload = JSON.parse(Buffer.from(token.split(".")[1] ?? "", "base64url").toString()) as {
    wallet?: string
    sub?: string
  }
  return (payload.wallet ?? payload.sub ?? "").toLowerCase()
}

export async function installSiweSession(
  page: Page,
  token: string,
  options?: { request?: APIRequestContext; origin?: string },
) {
  const wallet = walletFromAuthToken(token)
  const request = options?.request ?? page.request
  const origin =
    options?.origin ?? process.env.PLAYWRIGHT_BASE_URL ?? `http://127.0.0.1:${process.env.PLAYWRIGHT_PORT ?? "3000"}`
  const headers: Record<string, string> = {
    "content-type": "application/json",
    origin,
  }
  const secret = process.env.AVANA_E2E_SESSION_SECRET?.trim()
  if (secret) headers["x-avana-e2e-secret"] = secret

  const response = await request.post("/api/siwe/e2e-session", {
    data: { wallet, token },
    headers,
  })
  if (!response.ok()) {
    throw new Error(`Failed to install SIWE session (${response.status()}): ${await response.text()}`)
  }
  return wallet
}
