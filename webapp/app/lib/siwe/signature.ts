import { createPublicClient, http, recoverMessageAddress, type Address, type Hex } from "viem"
import { mainnet } from "viem/chains"

type VerifySmartAccountSignature = (input: { address: Address; message: string; signature: Hex }) => Promise<boolean>

const mainnetClient = createPublicClient({
  chain: mainnet,
  transport: http(),
})

async function verifySmartAccountSignature(input: { address: Address; message: string; signature: Hex }) {
  return mainnetClient.verifyMessage(input)
}

/**
 * Verify both ordinary EOA signatures and ERC-1271/ERC-6492 smart-account signatures.
 * Keep the recovery-only path first so injected wallets do not depend on an RPC request.
 */
export async function verifySiweSignature(
  input: {
    address: Address
    message: string
    signature: Hex
  },
  verifySmartAccount: VerifySmartAccountSignature = verifySmartAccountSignature,
): Promise<boolean> {
  try {
    const recovered = await recoverMessageAddress({
      message: input.message,
      signature: input.signature,
    })
    if (recovered.toLowerCase() === input.address.toLowerCase()) return true
  } catch {
    // Contract-account signatures are not recoverable as an EOA; verify them on-chain.
  }

  try {
    return await verifySmartAccount(input)
  } catch {
    return false
  }
}
