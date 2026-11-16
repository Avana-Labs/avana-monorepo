// The swap's front-end fee on the local Ethereum fork, end to end: the swap contracts from the local Convex, a quote
// on the fork's pools, the batch the app builds (fee leg to the ParameterStore's feeRecipient read through the Lens,
// exact approval, exactInput), each call sent in order by a Foundry keystore signer, then the balances read back.
//
// The signer must hold at least 1,000 USDC and 1.1 ETH on the fork. Its keystore and the file with its password come
// from env; the password reaches cast through CAST_PASSWORD, never a command line.
//
// Run: AVANA_FORK_RPC_ETHEREUM=http://127.0.0.1:8545 AVANA_LOCAL_CONVEX_URL=http://127.0.0.1:3210 \
//      AVANA_FORK_KEYSTORE=<keystore file> AVANA_FORK_PASSWORD_FILE=<password file> npm run test:local-fork
import { execFileSync } from "node:child_process"
import { readFileSync } from "node:fs"
import { ConvexHttpClient } from "convex/browser"
import { createPublicClient, getAddress, http, parseAbi, type Address, type Hex, type PublicClient } from "viem"
import { beforeAll, describe, expect, it } from "vitest"
import { api } from "@/convex/_generated/api"
import { DEFAULT_FEE_RULES } from "@/convex/lib/fees"
import { buildActionBatch } from "@/app/lib/fees/fee-batch"
import { viemBatchChain } from "@/app/lib/fees/fee-batch-viem"
import { SWAP_ASSETS } from "@/app/lib/swap-system/catalog"
import { onchainPoolsConfig, quoteWithFrontendFee, type SwapContracts } from "@/app/lib/swap-system/onchain-config"
import { createOnchainPoolsProvider } from "@/app/lib/swap-system/providers/onchain-pools"
import {
  LENS_PARAMETER_STORE_ABI,
  SWAP_DEADLINE_SECONDS,
  minimumOut,
  routeAmountIn,
  swapCalls,
  venueRouter,
} from "@/app/lib/swap-system/swap-execution"

const RPC = process.env.AVANA_FORK_RPC_ETHEREUM
const CONVEX = process.env.AVANA_LOCAL_CONVEX_URL
const KEYSTORE = process.env.AVANA_FORK_KEYSTORE
const PASSWORD_FILE = process.env.AVANA_FORK_PASSWORD_FILE

const ERC20 = parseAbi(["function balanceOf(address) view returns (uint256)", "function allowance(address,address) view returns (uint256)"])
const STORE = parseAbi(["function feeRecipient() view returns (address)"])

function castEnv() {
  return { ...process.env, CAST_PASSWORD: readFileSync(PASSWORD_FILE!, "utf8").trim() }
}

function send(call: { to: Address; data?: Hex; value?: bigint }) {
  const args = ["send", "--keystore", KEYSTORE!, "--rpc-url", RPC!, "--json", call.to, call.data ?? "0x"]
  if (call.value) args.push("--value", call.value.toString())
  const receipt = JSON.parse(execFileSync("cast", args, { env: castEnv(), encoding: "utf8" })) as { status: string }
  expect(receipt.status).toBe("0x1")
}

describe.skipIf(!RPC || !CONVEX || !KEYSTORE || !PASSWORD_FILE)("swap front-end fee on the local fork", () => {
  let client: PublicClient
  let contracts: SwapContracts
  let account: Address
  let recipient: Address

  beforeAll(async () => {
    client = createPublicClient({ transport: http(RPC) })
    const chainId = await client.getChainId()
    const served = await new ConvexHttpClient(CONVEX!).query(api.deployments.swapContractsOf, { chainId })
    if (!served?.lens) throw new Error(`the local Convex serves no swap contracts with a Lens for chain ${chainId}`)
    contracts = served as SwapContracts
    account = getAddress(execFileSync("cast", ["wallet", "address", "--keystore", KEYSTORE!], { env: castEnv(), encoding: "utf8" }).trim())
    // The recipient read independently of the app's batch code: Lens → ParameterStore → feeRecipient.
    const store = await client.readContract({ address: contracts.lens as Address, abi: LENS_PARAMETER_STORE_ABI, functionName: "PARAMETER_STORE" })
    recipient = await client.readContract({ address: store, abi: STORE, functionName: "feeRecipient" })
  })

  async function swap(inputAssetId: string, outputAssetId: string, inputAmount: number) {
    const config = onchainPoolsConfig(contracts, SWAP_ASSETS)!
    const provider = createOnchainPoolsProvider(config, client as never)
    const request = { walletId: account, chainId: contracts.chainId, inputAssetId, outputAssetId, inputAmount, slippageBps: 50 }
    const quote = await quoteWithFrontendFee(provider, request, SWAP_ASSETS, DEFAULT_FEE_RULES)
    expect(quote.status).toBe("valid")
    const route = provider.executionRoute!(quote.id)!
    const input = SWAP_ASSETS.find((a) => a.id === inputAssetId)!
    const output = SWAP_ASSETS.find((a) => a.id === outputAssetId)!
    const { fee, amountIn } = routeAmountIn(inputAmount, input, DEFAULT_FEE_RULES)
    expect(amountIn).toBe(route.amountIn)
    const router = venueRouter(contracts, route.venue)!
    const latest = (await client.getBlock({ blockTag: "latest" })).timestamp
    const minOut = minimumOut(route.amountOut, quote.slippageBps)
    const calls = swapCalls({
      route,
      router,
      account,
      minOut,
      deadline: latest + SWAP_DEADLINE_SECONDS,
      approve: !input.isNative,
      inputNative: Boolean(input.isNative),
      outputNative: Boolean(output.isNative),
    })
    const store = (await client.readContract({ address: contracts.lens as Address, abi: LENS_PARAMETER_STORE_ABI, functionName: "PARAMETER_STORE" })) as Address
    const batch = await buildActionBatch({
      action: "swap",
      account,
      calls,
      quote: { feeAmount: fee },
      feeToken: input.isNative ? "native" : route.route.tokens[0]!.address,
      chain: viemBatchChain(client, store),
    })
    // The batch the wallet would sign: fee first, to the on-chain recipient.
    expect(batch.fee).toMatchObject({ recipient, amount: fee, index: 0 })
    expect(batch.calls).toHaveLength(calls.length + 1)
    return { batch, fee, minOut, router, tokenIn: route.route.tokens[0]!.address, tokenOut: route.route.tokens.at(-1)!.address }
  }

  const balance = (token: Address, owner: Address) => client.readContract({ address: token, abi: ERC20, functionName: "balanceOf", args: [owner] })

  it("1,000 USDC → WETH pays the recipient exactly 1.000000 USDC", async () => {
    const { batch, fee, minOut, router, tokenIn, tokenOut } = await swap("usdc", "weth", 1_000)
    expect(fee).toBe(1_000_000n)
    const before = { recipient: await balance(tokenIn, recipient), user: await balance(tokenIn, account), out: await balance(tokenOut, account) }
    for (const call of batch.calls) send(call)
    expect((await balance(tokenIn, recipient)) - before.recipient).toBe(1_000_000n)
    expect(before.user - (await balance(tokenIn, account))).toBe(1_000_000_000n)
    expect((await balance(tokenOut, account)) - before.out).toBeGreaterThanOrEqual(minOut)
    expect(await client.readContract({ address: tokenIn, abi: ERC20, functionName: "allowance", args: [account, router] })).toBe(0n)
  })

  it("1 ETH → USDC pays the recipient exactly 0.001 ETH", async () => {
    const { batch, fee, minOut, tokenOut } = await swap("eth", "usdc", 1)
    expect(fee).toBe(10n ** 15n)
    expect(batch.calls[0]).toEqual({ to: recipient, value: 10n ** 15n })
    const before = { recipient: await client.getBalance({ address: recipient }), out: await balance(tokenOut, account) }
    for (const call of batch.calls) send(call)
    expect((await client.getBalance({ address: recipient })) - before.recipient).toBe(10n ** 15n)
    expect((await balance(tokenOut, account)) - before.out).toBeGreaterThanOrEqual(minOut)
  })
})
