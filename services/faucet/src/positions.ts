// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The starting positions of a grant on a local fork, opened as the wallet itself (anvil_impersonateAccount), through
// the same contracts the app's actions use: LP positions minted in the listed markets, most of them pledged, a USDC
// and a USDT debt, and Lend supplies. Tokens come from fundToken (cheatcodes). No key is involved and no front-end
// fee is charged (the faucet is not an app action).

import { decodeEventLog, decodeFunctionResult, encodeFunctionData, formatUnits, getAddress, parseAbi, parseUnits, toHex, type Address, type Hex } from "viem";
import { fundToken, tokenBalance, tokenDecimals, type Rpc } from "./chain.ts";
import { resolveLine, type ExternalEntry } from "./manifest.ts";
import type { GrantStep } from "./setup.ts";

/** The release-manifest fields the starting positions read. */
export interface PositionsManifest {
  readonly avana: {
    readonly aaveAdapter: { readonly address: string };
    readonly marketRegistry: { readonly address: string };
    readonly lpVaults: readonly { readonly address: string; readonly integrationId: number; readonly kind: string }[];
  };
  readonly markets: readonly { readonly marketId: string }[];
  readonly debtReserves: readonly { readonly spoke: string; readonly debtReserveId: string; readonly asset: string }[];
  readonly aave: { readonly hubs: readonly { readonly address: string }[]; readonly lendSpokes: readonly { readonly address: string }[] };
}

/** The reference portfolio: LP positions of $43,750 each (6 pledged, the rest left in the wallet), two debts, Lend supplies. */
export const STARTING_POSITIONS = {
  lpPositions: 8,
  lpUsdEach: 43_750,
  pledged: 6,
  debts: [
    { symbol: "USDC", usd: 1_200 },
    { symbol: "USDT", usd: 800 },
  ],
  lendSupplies: 8,
  lendUsdEach: 37_500,
  lendSymbols: ["USDC", "USDT", "GHO", "WETH", "WBTC", "LINK", "AAVE", "DAI", "cbBTC", "wstETH"],
} as const;

const WAD = 10n ** 18n;
const ERC20 = parseAbi(["function approve(address spender, uint256 amount) returns (bool)"]);
const REGISTRY = parseAbi([
  "function getMarket(uint256 marketId) view returns ((uint64 chainId, address hub, address spoke, uint32 integrationId, address integration, address pool, bytes32 poolId, (uint8 kind, int24 tickLower, int24 tickUpper) shape, address[] tokens, uint8[] tokenDecimals, address vaultToken, uint8 decimals, address lpOracle, uint256 hubAssetId, uint256 reserveId, uint8 status, uint64 registeredAt, uint64 activatedAt))",
]);
const POOL = parseAbi(["function fee() view returns (uint24)", "function tickSpacing() view returns (int24)"]);
const UNI_NPM = parseAbi([
  "function mint((address token0, address token1, uint24 fee, int24 tickLower, int24 tickUpper, uint256 amount0Desired, uint256 amount1Desired, uint256 amount0Min, uint256 amount1Min, address recipient, uint256 deadline)) payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)",
]);
const SLIP_NPM = parseAbi([
  "function mint((address token0, address token1, int24 tickSpacing, int24 tickLower, int24 tickUpper, uint256 amount0Desired, uint256 amount1Desired, uint256 amount0Min, uint256 amount1Min, address recipient, uint256 deadline, uint160 sqrtPriceX96)) payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)",
]);
const NFT = parseAbi([
  "function approve(address to, uint256 tokenId)",
  "event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)",
]);
const ADAPTER = parseAbi([
  "function pledge(uint256 marketId, (uint32 integrationId, bytes32 positionKey) position, uint256 deadline) returns (address proxy, uint256 recordId, uint256 credited)",
  "function proxyOf(address wallet, uint256 marketId) view returns (address)",
  "function borrowNonce(address proxy) view returns (uint256)",
  "function borrow(uint256 marketId, uint256 debtReserveId, uint256 amount, address receiver, uint256 deadline, uint256 minHealthFactor, uint256 expectedNonce)",
]);
const HUB = parseAbi(["function getAssetId(address underlying) view returns (uint256)"]);
const LEND_SPOKE = parseAbi([
  "function getReserveId(address hub, uint256 assetId) view returns (uint256)",
  "function supply(uint256 reserveId, uint256 amount, address onBehalfOf) returns (uint256, uint256)",
]);

type Log = { address: Address; topics: Hex[]; data: Hex };

async function read<T>(rpc: Rpc, to: string, abi: readonly unknown[], functionName: string, args: readonly unknown[] = []): Promise<T> {
  const data = encodeFunctionData({ abi, functionName, args } as unknown as Parameters<typeof encodeFunctionData>[0]);
  const out = (await rpc.request({ method: "eth_call", params: [{ to, data }, "latest"] })) as Hex;
  return decodeFunctionResult({ abi, functionName, data: out } as unknown as Parameters<typeof decodeFunctionResult>[0]) as T;
}

/** Sends a call as `from` (impersonated) and returns its receipt logs; a revert throws, naming `what`. */
async function sendAs(rpc: Rpc, from: Address, to: string, data: Hex, what: string): Promise<{ hash: Hex; logs: Log[] }> {
  const hash = (await rpc.request({ method: "eth_sendTransaction", params: [{ from, to, data }] })) as Hex;
  for (let i = 0; i < 50; i++) {
    const r = (await rpc.request({ method: "eth_getTransactionReceipt", params: [hash] })) as { status: Hex; logs: Log[] } | null;
    if (r) {
      if (r.status !== "0x1") throw new Error(`${what} reverted`);
      return { hash, logs: r.logs };
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`${what}: no receipt`);
}

async function deadline(rpc: Rpc): Promise<bigint> {
  const block = (await rpc.request({ method: "eth_getBlockByNumber", params: ["latest", false] })) as { timestamp: Hex };
  return BigInt(block.timestamp) + 3_600n;
}

const symbolOf = (external: readonly ExternalEntry[], token: string) =>
  external.find((e) => e.group === "token" && e.address.toLowerCase() === token.toLowerCase())?.name;
const tokenOf = (external: readonly ExternalEntry[], symbol: string) =>
  external.find((e) => e.group === "token" && e.name.toUpperCase() === symbol.toUpperCase())?.address;

/** The position managers the manifest lists: Uniswap v3's, and Slipstream's by generation (`.1`, `.2` … after 0). */
function positionManagers(external: readonly ExternalEntry[]) {
  const uni = external.find((e) => e.group === "uniswap-v3" && e.name === "UniswapV3PositionManager")?.address;
  const slip = external
    .filter((e) => e.group === "slipstream" && /^SlipstreamPositionManager(\.\d+)?$/.test(e.name))
    .map((e) => ({ generation: Number(e.name.split(".")[1] ?? 0), address: e.address }))
    .sort((a, b) => a.generation - b.generation);
  return { uni, slip };
}

/** Whole tokens worth `usd` at the token's primary feed, as base units. */
async function unitsForUsd(rpc: Rpc, external: readonly ExternalEntry[], symbol: string, usd: number, decimals: number): Promise<bigint> {
  const line = await resolveLine(rpc, external, { symbol, usd });
  return parseUnits(line.amount, decimals);
}

type Pledgeable = { marketId: bigint; integrationId: number; positionKey: Hex; spoke: string };

/** Mints one LP position of a market as the wallet and approves its LPVault; null for a market it cannot mint (Uniswap v4). */
async function mintPosition(rpc: Rpc, wallet: Address, m: PositionsManifest, external: readonly ExternalEntry[], marketId: bigint): Promise<{ hash: Hex; position: Pledgeable; detail: string } | null> {
  const market = await read<{ spoke: Address; integrationId: number; pool: Address; shape: { tickLower: number; tickUpper: number }; tokens: readonly Address[]; tokenDecimals: readonly number[] }>(
    rpc,
    m.avana.marketRegistry.address,
    REGISTRY,
    "getMarket",
    [marketId],
  );
  const vault = m.avana.lpVaults.find((v) => v.integrationId === Number(market.integrationId));
  if (!vault || vault.kind === "uniswap-v4") return null;
  const [t0, t1] = market.tokens as [Address, Address];
  const [s0, s1] = [symbolOf(external, t0), symbolOf(external, t1)];
  if (!s0 || !s1) throw new Error(`market ${marketId}: a pool token is not in the manifest`);
  const half = STARTING_POSITIONS.lpUsdEach / 2;
  const a0 = await unitsForUsd(rpc, external, s0, half, Number(market.tokenDecimals[0]));
  const a1 = await unitsForUsd(rpc, external, s1, half, Number(market.tokenDecimals[1]));
  // fundToken sets the balance: add to what the token grant gave instead of replacing it.
  for (const [token, amount, decimals] of [[t0, a0, market.tokenDecimals[0]], [t1, a1, market.tokenDecimals[1]]] as const) {
    const have = await tokenBalance(rpc, token, wallet);
    await fundToken(rpc, token, wallet, formatUnits(have + amount, Number(decimals)));
  }
  const { uni, slip } = positionManagers(external);
  const end = await deadline(rpc);
  const common = { token0: t0, token1: t1, tickLower: market.shape.tickLower, tickUpper: market.shape.tickUpper, amount0Desired: a0, amount1Desired: a1, amount0Min: 0n, amount1Min: 0n, recipient: wallet, deadline: end };
  const candidates =
    vault.kind === "slipstream"
      ? slip.map((s) => ({ npm: s.address, generation: s.generation }))
      : uni
        ? [{ npm: uni, generation: 0 }]
        : [];
  if (candidates.length === 0) throw new Error(`market ${marketId}: no ${vault.kind} position manager in the manifest`);
  let lastError: unknown;
  for (const { npm, generation } of candidates) {
    try {
      await sendAs(rpc, wallet, t0, encodeFunctionData({ abi: ERC20, functionName: "approve", args: [getAddress(npm), a0] }), "approve token0");
      await sendAs(rpc, wallet, t1, encodeFunctionData({ abi: ERC20, functionName: "approve", args: [getAddress(npm), a1] }), "approve token1");
      const data =
        vault.kind === "slipstream"
          ? encodeFunctionData({ abi: SLIP_NPM, functionName: "mint", args: [{ ...common, tickSpacing: Number(await read<number>(rpc, market.pool, POOL, "tickSpacing")), sqrtPriceX96: 0n }] })
          : encodeFunctionData({ abi: UNI_NPM, functionName: "mint", args: [{ ...common, fee: Number(await read<number>(rpc, market.pool, POOL, "fee")) }] });
      const minted = await sendAs(rpc, wallet, npm, data, "mint");
      const tokenId = mintedTokenId(minted.logs, npm, wallet);
      await sendAs(rpc, wallet, npm, encodeFunctionData({ abi: NFT, functionName: "approve", args: [getAddress(vault.address), tokenId] }), "approve the LPVault");
      const key = toHex(vault.kind === "slipstream" ? (BigInt(generation) << 248n) | tokenId : tokenId, { size: 32 });
      return {
        hash: minted.hash,
        position: { marketId, integrationId: Number(market.integrationId), positionKey: key, spoke: market.spoke },
        detail: `${s0}/${s1} market ${marketId}: token ${tokenId} (~$${STARTING_POSITIONS.lpUsdEach.toLocaleString("en-US")})`,
      };
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError instanceof Error ? lastError : new Error(`market ${marketId}: mint failed`);
}

function mintedTokenId(logs: readonly Log[], npm: string, owner: Address): bigint {
  for (const log of logs) {
    if (log.address.toLowerCase() !== npm.toLowerCase()) continue;
    try {
      const e = decodeEventLog({ abi: NFT, data: log.data, topics: log.topics as [Hex, ...Hex[]] });
      if (e.eventName === "Transfer" && BigInt(e.args.from) === 0n && e.args.to.toLowerCase() === owner.toLowerCase()) return e.args.tokenId;
    } catch {
      // Not a Transfer of this manager.
    }
  }
  throw new Error("no minted token id");
}

/**
 * Opens the reference portfolio for `wallet` as the wallet itself. Each position is one step; a step that fails is
 * recorded with `failed: true` and the rest go on, so a market or reserve the chain does not serve never blocks the grant.
 */
export async function openStartingPositions(rpc: Rpc, wallet: Address, m: PositionsManifest, external: readonly ExternalEntry[]): Promise<GrantStep[]> {
  const steps: GrantStep[] = [];
  const attempt = async (step: string, action: () => Promise<{ detail: string; txHash?: Hex }>) => {
    try {
      steps.push({ step, ...(await action()) });
      return true;
    } catch (error) {
      steps.push({ step, detail: error instanceof Error ? error.message : String(error), failed: true });
      return false;
    }
  };
  const adapter = m.avana.aaveAdapter.address;

  await rpc.request({ method: "anvil_impersonateAccount", params: [wallet] });
  try {
    // LP positions, in manifest market order; the first `pledged` are pledged.
    const minted: Pledgeable[] = [];
    for (const { marketId } of m.markets) {
      if (minted.length >= STARTING_POSITIONS.lpPositions) break;
      await attempt(`LP position market ${marketId}`, async () => {
        const r = await mintPosition(rpc, wallet, m, external, BigInt(marketId));
        if (!r) throw new Error(`market ${marketId}: not mintable here (Uniswap v4)`);
        minted.push(r.position);
        return { detail: r.detail, txHash: r.hash };
      });
    }
    const pledged: Pledgeable[] = [];
    for (const p of minted.slice(0, STARTING_POSITIONS.pledged)) {
      const ok = await attempt(`pledge market ${p.marketId}`, async () => {
        const data = encodeFunctionData({ abi: ADAPTER, functionName: "pledge", args: [p.marketId, { integrationId: p.integrationId, positionKey: p.positionKey }, await deadline(rpc)] });
        const r = await sendAs(rpc, wallet, adapter, data, "pledge");
        return { detail: `position ${p.positionKey} into market ${p.marketId}`, txHash: r.hash };
      });
      if (ok) pledged.push(p);
    }

    // Debts: each in the first pledged market whose Spoke lends the asset.
    for (const debt of STARTING_POSITIONS.debts) {
      await attempt(`borrow ${debt.symbol}`, async () => {
        const token = tokenOf(external, debt.symbol);
        const found = pledged
          .map((p) => ({ p, reserve: m.debtReserves.find((r) => r.spoke.toLowerCase() === p.spoke.toLowerCase() && token && r.asset.toLowerCase() === token.toLowerCase()) }))
          .find((x) => x.reserve);
        if (!token || !found?.reserve) throw new Error(`no pledged market borrows ${debt.symbol}`);
        const amount = await unitsForUsd(rpc, external, debt.symbol, debt.usd, await tokenDecimals(rpc, getAddress(token)));
        const proxy = await read<Address>(rpc, adapter, ADAPTER, "proxyOf", [wallet, found.p.marketId]);
        const nonce = await read<bigint>(rpc, adapter, ADAPTER, "borrowNonce", [proxy]);
        const data = encodeFunctionData({
          abi: ADAPTER,
          functionName: "borrow",
          args: [found.p.marketId, BigInt(found.reserve.debtReserveId), amount, wallet, await deadline(rpc), WAD, nonce],
        });
        const r = await sendAs(rpc, wallet, adapter, data, "borrow");
        return { detail: `$${debt.usd.toLocaleString("en-US")} ${debt.symbol} against market ${found.p.marketId}`, txHash: r.hash };
      });
    }

    // Lend supplies: the first `lendSupplies` tokens some Hub's Lend Spoke lists.
    let supplied = 0;
    for (const symbol of STARTING_POSITIONS.lendSymbols) {
      if (supplied >= STARTING_POSITIONS.lendSupplies) break;
      const token = tokenOf(external, symbol);
      if (!token) continue;
      const target = await lendTarget(rpc, m, token);
      if (!target) continue;
      const ok = await attempt(`lend ${symbol}`, async () => {
        const decimals = await tokenDecimals(rpc, getAddress(token));
        const amount = await unitsForUsd(rpc, external, symbol, STARTING_POSITIONS.lendUsdEach, decimals);
        const have = await tokenBalance(rpc, getAddress(token), wallet);
        await fundToken(rpc, getAddress(token), wallet, formatUnits(have + amount, decimals));
        await sendAs(rpc, wallet, token, encodeFunctionData({ abi: ERC20, functionName: "approve", args: [getAddress(target.spoke), amount] }), "approve");
        const r = await sendAs(rpc, wallet, target.spoke, encodeFunctionData({ abi: LEND_SPOKE, functionName: "supply", args: [target.reserveId, amount, wallet] }), "supply");
        return { detail: `$${STARTING_POSITIONS.lendUsdEach.toLocaleString("en-US")} ${symbol} on Lend Spoke ${target.spoke}`, txHash: r.hash };
      });
      if (ok) supplied++;
    }
  } finally {
    await rpc.request({ method: "anvil_stopImpersonatingAccount", params: [wallet] }).catch(() => undefined);
  }
  return steps;
}

/** The first Lend Spoke and reserve that lend `token` on one of the manifest's Hubs, or null. */
async function lendTarget(rpc: Rpc, m: PositionsManifest, token: string): Promise<{ spoke: string; reserveId: bigint } | null> {
  for (const hub of m.aave.hubs) {
    let assetId: bigint;
    try {
      assetId = await read<bigint>(rpc, hub.address, HUB, "getAssetId", [token]);
    } catch {
      continue;
    }
    for (const spoke of m.aave.lendSpokes) {
      try {
        return { spoke: spoke.address, reserveId: await read<bigint>(rpc, spoke.address, LEND_SPOKE, "getReserveId", [hub.address, assetId]) };
      } catch {
        // This Spoke does not lend the asset on this Hub.
      }
    }
  }
  return null;
}
