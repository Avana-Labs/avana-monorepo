import { decodeFunctionData, parseAbi, type Address, type Hex } from "viem"
import { describe, expect, it, vi } from "vitest"
import {
  buildActionBatch,
  feeTransferCall,
  sendActionBatch,
  type BatchChain,
  type BatchWallet,
  type Call,
} from "@/app/lib/fees/fee-batch"

const ACCOUNT: Address = "0x00000000000000000000000000000000000a11ce"
const RECIPIENT: Address = "0x000000000000000000000000000000000000Fee5"
const USDC: Address = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
const SPOKE: Address = "0x0000000000000000000000000000000000005b0e"
const action: Call = { to: SPOKE, data: "0x1234" }
const approve: Call = { to: USDC, data: "0x095ea7b3" }

const transferAbi = parseAbi(["function transfer(address to, uint256 amount) returns (bool)"])

function chain(
  opts: { simulate?: readonly boolean[] | null | ((calls: readonly Call[]) => boolean[]); alone?: boolean } = {},
) {
  const read = vi.fn(async () => RECIPIENT)
  const fake: BatchChain = {
    readFeeRecipient: read,
    simulate: async (_account, calls) =>
      typeof opts.simulate === "function"
        ? opts.simulate(calls)
        : opts.simulate === undefined
          ? calls.map(() => true)
          : opts.simulate,
    callSucceeds: async () => opts.alone ?? true,
  }
  return { fake, read }
}

describe("fee leg", () => {
  it("is an ERC-20 transfer of the quoted amount to feeRecipient", () => {
    const call = feeTransferCall({ token: USDC, amount: 1_000_000n, recipient: RECIPIENT })
    expect(call.to).toBe(USDC)
    expect(decodeFunctionData({ abi: transferAbi, data: call.data as Hex }).args).toEqual([RECIPIENT, 1_000_000n])
  })

  it("is a plain value transfer for native ETH", () => {
    expect(feeTransferCall({ token: "native", amount: 5n, recipient: RECIPIENT })).toEqual({ to: RECIPIENT, value: 5n })
  })
})

describe("buildActionBatch", () => {
  it("puts the fee first for an action the user pays with, with the recipient read on chain", async () => {
    const { fake, read } = chain()
    const batch = await buildActionBatch({
      action: "supply",
      account: ACCOUNT,
      calls: [approve, action],
      quote: { feeAmount: 1_000_000n },
      feeToken: USDC,
      chain: fake,
    })
    expect(read).toHaveBeenCalledOnce()
    expect(batch.fee).toEqual({ recipient: RECIPIENT, amount: 1_000_000n, index: 0 })
    expect(batch.calls).toHaveLength(3)
    expect(batch.calls.slice(1)).toEqual([approve, action])
  })

  it("puts the fee last for an action that pays the user", async () => {
    const batch = await buildActionBatch({
      action: "borrow",
      account: ACCOUNT,
      calls: [action],
      quote: { feeAmount: 1_000_000n },
      feeToken: USDC,
      chain: chain().fake,
    })
    expect(batch.fee?.index).toBe(1)
    expect(batch.calls[0]).toEqual(action)
  })

  it("drops the fee leg when only the fee transfer would revert (Q-409 (6))", async () => {
    const batch = await buildActionBatch({
      action: "repay",
      account: ACCOUNT,
      calls: [approve, action],
      quote: { feeAmount: 1n },
      feeToken: USDC,
      chain: chain({ simulate: [false, true, true] }).fake,
    })
    expect(batch).toEqual({ calls: [approve, action], fee: null, feeDropped: "simulation" })
  })

  it("keeps the fee when the action itself would revert: that is the action's failure, not the fee's", async () => {
    const batch = await buildActionBatch({
      action: "repay",
      account: ACCOUNT,
      calls: [action],
      quote: { feeAmount: 1n },
      feeToken: USDC,
      chain: chain({ simulate: [false, false] }).fake,
    })
    expect(batch.fee).not.toBeNull()
  })

  it("checks a first-paid fee alone when the node cannot simulate a batch", async () => {
    const batch = await buildActionBatch({
      action: "swap",
      account: ACCOUNT,
      calls: [action],
      quote: { feeAmount: 1n },
      feeToken: "native",
      chain: chain({ simulate: null, alone: false }).fake,
    })
    expect(batch.feeDropped).toBe("simulation")
  })

  it("adds nothing for a zero fee", async () => {
    const { fake, read } = chain()
    const batch = await buildActionBatch({
      action: "withdraw",
      account: ACCOUNT,
      calls: [action],
      quote: { feeAmount: 0n },
      feeToken: USDC,
      chain: fake,
    })
    expect(batch).toEqual({ calls: [action], fee: null, feeDropped: "zero" })
    expect(read).not.toHaveBeenCalled()
  })
})

describe("sendActionBatch", () => {
  const feeBatch = {
    calls: [{ to: USDC, data: "0xa9" as Hex }, action],
    fee: { recipient: RECIPIENT, amount: 1n, index: 0 },
    feeDropped: null,
  }

  function wallet(atomic: boolean) {
    const sent: { batches: Call[][]; txs: Call[] } = { batches: [], txs: [] }
    const fake: BatchWallet = {
      supportsAtomicBatch: async () => atomic,
      sendCalls: async (calls) => {
        sent.batches.push([...calls])
        return { id: "0xbatch" }
      },
      sendTransaction: async (call) => {
        sent.txs.push(call)
        return "0xtx" as Hex
      },
    }
    return { fake, sent }
  }

  it("sends the fee and the action in one atomic batch", async () => {
    const { fake, sent } = wallet(true)
    const count = vi.fn()
    expect(await sendActionBatch("supply", feeBatch, fake, count)).toEqual({
      kind: "batch",
      id: "0xbatch",
      feeIncluded: true,
    })
    expect(sent.batches).toEqual([feeBatch.calls])
    expect(count).not.toHaveBeenCalled()
  })

  it("sends the action alone, without the fee, from a wallet without atomic batches, and counts it", async () => {
    const { fake, sent } = wallet(false)
    const count = vi.fn()
    const result = await sendActionBatch("supply", feeBatch, fake, count)
    expect(result).toEqual({ kind: "transactions", hashes: ["0xtx"], feeIncluded: false })
    expect(sent.txs).toEqual([action])
    expect(count).toHaveBeenCalledWith("no_atomic_batch")
  })

  it("counts an action whose fee leg was dropped by the simulation", async () => {
    const { fake } = wallet(true)
    const count = vi.fn()
    await sendActionBatch("supply", { calls: [action], fee: null, feeDropped: "simulation" }, fake, count)
    expect(count).toHaveBeenCalledWith("fee_reverts")
  })
})
