/**
 * Minimal EIP-4361 (Sign-In With Ethereum) message build + parse. Kept dependency-free
 * (viem verifies the signature) so it runs in both the browser sign-in flow and the
 * server verify route.
 */

type SiweMessageParams = {
  address: string
  domain: string
  uri: string
  nonce: string
  issuedAt: string
  chainId: number
  statement?: string
}

const DEFAULT_STATEMENT = "Sign in to Avana. This request will not trigger a transaction or cost gas."

/** Build the canonical EIP-4361 message string a wallet signs. */
export function buildSiweMessage(p: SiweMessageParams): string {
  const statement = p.statement ?? DEFAULT_STATEMENT
  return [
    `${p.domain} wants you to sign in with your Ethereum account:`,
    p.address,
    "",
    statement,
    "",
    `URI: ${p.uri}`,
    "Version: 1",
    `Chain ID: ${p.chainId}`,
    `Nonce: ${p.nonce}`,
    `Issued At: ${p.issuedAt}`,
  ].join("\n")
}

/** Extract the address line (line 2) from a SIWE message. */
export function extractSiweAddress(message: string): string | null {
  const line = message.split("\n")[1]?.trim()
  return line && /^0x[a-fA-F0-9]{40}$/.test(line) ? line : null
}

/** Extract the `Nonce:` field from a SIWE message. */
export function extractSiweNonce(message: string): string | null {
  const match = message.match(/^Nonce: (.+)$/m)
  return match ? match[1]!.trim() : null
}

/** Extract the domain from line 1 (`<domain> wants you to sign in...`). */
export function extractSiweDomain(message: string): string | null {
  const match = message.match(/^(.+) wants you to sign in with your Ethereum account:$/m)
  return match ? match[1]!.trim() : null
}

/** Extract the `URI:` field from a SIWE message. */
export function extractSiweUri(message: string): string | null {
  const match = message.match(/^URI: (.+)$/m)
  return match ? match[1]!.trim() : null
}

/** Extract the `Chain ID:` field (a positive integer) from a SIWE message. */
export function extractSiweChainId(message: string): number | null {
  const match = message.match(/^Chain ID: (\d+)$/m)
  if (!match) return null
  const chainId = Number(match[1])
  return Number.isInteger(chainId) && chainId > 0 ? chainId : null
}
