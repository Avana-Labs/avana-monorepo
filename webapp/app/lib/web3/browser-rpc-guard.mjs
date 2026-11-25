// The browser's RPC URLs (NEXT_PUBLIC_RPC_ETHEREUM, NEXT_PUBLIC_RPC_BASE) are inlined into the page code, where anyone
// can read them. Each must use a provider key of its own, restricted at the provider to the app's domains and capped
// in requests, never the services' key: a build whose browser URL carries a server credential found in the build's
// environment is refused (next.config.mjs). Messages name the variables only, never a value.

/** Server credentials of the RPC providers (packages/rpc, contracts/.env.example). */
const SERVER_KEYS = ["ALCHEMY_API_KEY", "QUICKNODE_TOKEN"]
/** The services' RPC URLs (RPC_<CHAIN>, RPC_<CHAIN>_FALLBACK). */
const SERVER_URLS = ["MAINNET", "BASE", "SEPOLIA", "BASE_SEPOLIA"].flatMap((c) => [`RPC_${c}`, `RPC_${c}_FALLBACK`])
const BROWSER_URLS = ["NEXT_PUBLIC_RPC_ETHEREUM", "NEXT_PUBLIC_RPC_BASE"]

const value = (env, name) => (typeof env[name] === "string" ? env[name].trim() : "")
const loopback = (url) => /^https?:\/\/(127\.0\.0\.1|localhost|\[::1\])(:\d+)?(\/|$)/i.test(url)

/** Each browser RPC variable that carries a server credential, with the server variable it repeats. */
export function browserRpcProblems(env) {
  const problems = []
  for (const browser of BROWSER_URLS) {
    const url = value(env, browser)
    if (!url) continue
    for (const key of SERVER_KEYS) {
      const secret = value(env, key)
      if (secret.length >= 8 && url.includes(secret)) problems.push(`${browser} contains ${key}`)
    }
    // A local node (the local stack, a rehearsal) has no credential to leak.
    if (loopback(url)) continue
    for (const server of SERVER_URLS) {
      if (value(env, server) === url) problems.push(`${browser} is the same URL as ${server}`)
    }
  }
  return problems
}

/** Stops the build when a browser RPC URL carries a server credential. */
export function assertBrowserRpc(env) {
  const problems = browserRpcProblems(env)
  if (problems.length > 0) {
    throw new Error(
      `Refusing to build: ${problems.join("; ")}. The browser RPC URLs ship in the page code; give them a separate provider key restricted to the app's domains.`,
    )
  }
}
