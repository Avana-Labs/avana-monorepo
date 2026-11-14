/**
 * EIP-4361 (Sign-In With Ethereum) message build for the browser sign-in flow. The server
 * verify route checks the message strictly with `checkSiweMessage` (viem/siwe).
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
