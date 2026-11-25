import { ConvexHttpClient } from "convex/browser"
import { DataSourceError } from "@/app/lib/data/core/source-runtime"
import { fetchSiweAccessToken, getSiweSession } from "@/app/lib/siwe/auth-store"

export function getAuthenticatedWallet(sourceId: string, operation: string) {
  if (typeof window === "undefined") {
    throw new DataSourceError({
      code: "auth",
      sourceId,
      operation,
      message: "Authenticated live data is loaded on the client after SIWE.",
    })
  }
  const url = process.env.NEXT_PUBLIC_CONVEX_URL
  if (!url) {
    throw new DataSourceError({
      code: "unavailable",
      sourceId,
      operation,
      message: "NEXT_PUBLIC_CONVEX_URL is not configured.",
      retryable: true,
    })
  }
  const session = getSiweSession()
  if (!session?.wallet) {
    throw new DataSourceError({
      code: "auth",
      sourceId,
      operation,
      message: "Sign in with Ethereum to load wallet data.",
    })
  }
  return { url, wallet: session.wallet.toLowerCase() }
}

export async function getAuthenticatedConvexClient(sourceId: string, operation: string) {
  const { url, wallet } = getAuthenticatedWallet(sourceId, operation)
  const token = await fetchSiweAccessToken()
  if (!token) {
    throw new DataSourceError({
      code: "auth",
      sourceId,
      operation,
      message: "Sign in with Ethereum to load wallet data.",
    })
  }
  const client = new ConvexHttpClient(url)
  client.setAuth(token)
  return { client, wallet }
}
