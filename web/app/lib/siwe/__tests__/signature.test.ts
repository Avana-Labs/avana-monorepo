import { privateKeyToAccount } from "viem/accounts"
import { describe, expect, it, vi } from "vitest"
import { verifySiweSignature } from "../signature"

describe("verifySiweSignature", () => {
  it("verifies an EOA signature without an RPC request", async () => {
    const account = privateKeyToAccount(`0x${"11".repeat(32)}`)
    const message = "Sign in to Avana"
    const signature = await account.signMessage({ message })
    const verifySmartAccount = vi.fn()

    await expect(
      verifySiweSignature(
        {
          address: account.address,
          message,
          signature,
        },
        verifySmartAccount,
      ),
    ).resolves.toBe(true)
    expect(verifySmartAccount).not.toHaveBeenCalled()
  })

  it("falls back to smart-account verification when EOA recovery does not match", async () => {
    const signer = privateKeyToAccount(`0x${"22".repeat(32)}`)
    const smartAccount = privateKeyToAccount(`0x${"33".repeat(32)}`).address
    const message = "Sign in to Avana"
    const signature = await signer.signMessage({ message })
    const verifySmartAccount = vi.fn().mockResolvedValue(true)

    await expect(
      verifySiweSignature(
        {
          address: smartAccount,
          message,
          signature,
        },
        verifySmartAccount,
      ),
    ).resolves.toBe(true)
    expect(verifySmartAccount).toHaveBeenCalledWith({
      address: smartAccount,
      message,
      signature,
    })
  })

  it("rejects a signature when both verification paths fail", async () => {
    const signer = privateKeyToAccount(`0x${"44".repeat(32)}`)
    const claimedAddress = privateKeyToAccount(`0x${"55".repeat(32)}`).address
    const message = "Sign in to Avana"
    const signature = await signer.signMessage({ message })

    await expect(
      verifySiweSignature(
        {
          address: claimedAddress,
          message,
          signature,
        },
        vi.fn().mockResolvedValue(false),
      ),
    ).resolves.toBe(false)
  })
})
