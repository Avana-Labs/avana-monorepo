import { encodeFunctionData, parseAbi, type Address, type Hex } from "viem"
import { DIRECTION, type FeeAction, type FeeQuote } from "@/convex/lib/fees"
import { trackEvent } from "@/app/lib/analytics/track-event"

/**
 * The batch every app action is sent in (Q-409, docs/spec/04-security/04-design-decisions.md): the action's calls
 * and one transfer of the front-end fee to the ParameterStore's `feeRecipient`, read on chain when the batch is built
 * (never from env, Convex or a keeper's config). The fee amount is `quoteFee`'s (services/convex/convex/lib/fees.ts),
 * the same figure the "Avana Platform Fee" row shows.
 *
 * - Order: the fee goes first for actions the user pays with (supply, repay, pledge, swap…), last for actions that
 *   pay the user (withdraw, borrow…), whose tokens only reach the wallet during the action.
 * - Q-409 (6): if the simulation shows the fee transfer would revert, the fee leg is dropped and the action goes alone.
 * - A wallet without atomic batches (EIP-5792 `wallet_sendCalls`) sends the action alone, without the fee, so a fee is
 *   never paid for an action that failed. Each such action is counted (`fee_free_action`) for the quarterly
 *   front-end-fee report (Q-409 (7)).
 * - Native ETH: Q-409's ERC-20 transfer rule applied to ETH, a plain value transfer to `feeRecipient`.
 * - Not used by the faucet or by keepers: they are not app actions.
 */

export type Call = { to: Address; data?: Hex; value?: bigint }

export const PARAMETER_STORE_ABI = parseAbi(["function feeRecipient() view returns (address)"])
const ERC20_TRANSFER_ABI = parseAbi(["function transfer(address to, uint256 amount) returns (bool)"])

/** The fee leg: an ERC-20 transfer of `amount` to the recipient, or for native ETH a value transfer. */
export function feeTransferCall(fee: { token: Address | "native"; amount: bigint; recipient: Address }): Call {
  if (fee.token === "native") return { to: fee.recipient, value: fee.amount }
  return {
    to: fee.token,
    data: encodeFunctionData({ abi: ERC20_TRANSFER_ABI, functionName: "transfer", args: [fee.recipient, fee.amount] }),
  }
}

/** What the batch needs from the chain. `simulate` answers null when the node cannot simulate a batch. */
export type BatchChain = {
  readFeeRecipient(): Promise<Address>
  simulate(account: Address, calls: readonly Call[]): Promise<readonly boolean[] | null>
  /** Whether one call alone succeeds from `account` at the current state. */
  callSucceeds(account: Address, call: Call): Promise<boolean>
}

export type ActionBatch = {
  calls: Call[]
  /** The fee leg, when it is in the batch. */
  fee: { recipient: Address; amount: bigint; index: number } | null
  /** Why the fee is not in the batch, when it is not. */
  feeDropped: "zero" | "simulation" | null
}

export async function buildActionBatch(args: {
  action: FeeAction
  account: Address
  calls: readonly Call[]
  quote: Pick<FeeQuote, "feeAmount">
  feeToken: Address | "native"
  chain: BatchChain
}): Promise<ActionBatch> {
  const { action, account, calls, quote, feeToken, chain } = args
  if (quote.feeAmount <= 0n) return { calls: [...calls], fee: null, feeDropped: "zero" }

  const recipient = await chain.readFeeRecipient()
  const feeCall = feeTransferCall({ token: feeToken, amount: quote.feeAmount, recipient })
  const feeFirst = DIRECTION[action] === "pay"
  const withFee = feeFirst ? [feeCall, ...calls] : [...calls, feeCall]
  const feeIndex = feeFirst ? 0 : calls.length

  const results = await chain.simulate(account, withFee)
  let feeReverts: boolean
  if (results) {
    // The fee leg is the cause only when it fails and the action's own calls succeed.
    const actionOk = results.every((ok, index) => index === feeIndex || ok)
    feeReverts = actionOk && results[feeIndex] === false
  } else {
    // No batch simulation on this node: a fee paid first can still be checked alone; one paid last cannot, and stays.
    feeReverts = feeFirst ? !(await chain.callSucceeds(account, feeCall)) : false
  }
  if (feeReverts) return { calls: [...calls], fee: null, feeDropped: "simulation" }
  return { calls: withFee, fee: { recipient, amount: quote.feeAmount, index: feeIndex }, feeDropped: null }
}

/** What sending needs from the wallet. */
export type BatchWallet = {
  /** Whether the wallet sends atomic batches on this chain (EIP-5792 `atomic` capability). */
  supportsAtomicBatch(): Promise<boolean>
  sendCalls(calls: readonly Call[]): Promise<{ id: string }>
  sendTransaction(call: Call): Promise<Hex>
}

export type SentBatch =
  { kind: "batch"; id: string; feeIncluded: boolean } | { kind: "transactions"; hashes: Hex[]; feeIncluded: false }

/**
 * Sends the batch: atomically when the wallet can; otherwise the action's calls one by one without the fee leg.
 * Every action sent without its fee is counted, never with an address or amount.
 */
export async function sendActionBatch(
  action: FeeAction,
  batch: ActionBatch,
  wallet: BatchWallet,
  count: (reason: "no_atomic_batch" | "fee_reverts") => void = (reason) =>
    trackEvent("fee_free_action", { action, reason }),
): Promise<SentBatch> {
  if (batch.feeDropped === "simulation") count("fee_reverts")
  if (await wallet.supportsAtomicBatch()) {
    const { id } = await wallet.sendCalls(batch.calls)
    return { kind: "batch", id, feeIncluded: batch.fee !== null }
  }
  const actionCalls = batch.fee ? batch.calls.filter((_, index) => index !== batch.fee!.index) : batch.calls
  if (batch.fee) count("no_atomic_batch")
  const hashes: Hex[] = []
  for (const call of actionCalls) hashes.push(await wallet.sendTransaction(call))
  return { kind: "transactions", hashes, feeIncluded: false }
}
