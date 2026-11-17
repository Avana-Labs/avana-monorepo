// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs

import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { decodeFunctionData, encodeFunctionResult, getAddress, keccak256, encodeAbiParameters, parseAbi, type Address, type Hex } from "viem";
import { describe, expect, it } from "vitest";
import { ChainRefused, checkLocalFork, fundToken, type Rpc } from "../src/chain.ts";
import { loadConfig } from "../src/config.ts";
import { Faucet } from "../src/faucet.ts";
import { GRANTS } from "../src/grants.ts";
import type { ExternalEntry } from "../src/manifest.ts";
import { forkStrategy, testnetStrategy } from "../src/setup.ts";
import { GrantStore } from "../src/store.ts";

const erc20 = parseAbi(["function balanceOf(address) view returns (uint256)", "function decimals() view returns (uint8)"]);
const feedAbi = parseAbi(["function decimals() view returns (uint8)", "function latestRoundData() view returns (uint80, int256, uint256, uint256, uint80)"]);
const WALLET = getAddress("0x00000000000000000000000000000000000a11ce");

/** The manifest's token group (the fork's real addresses) and a USD feed per token, by `<SYMBOL> / USD (primary)`. */
const TOKENS: Record<string, Address> = {
  WETH: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
  USDC: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
  USDT: "0xdAC17F958D2ee523a2206206994597C13D831ec7",
  GHO: "0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f",
  WBTC: "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599",
  LINK: "0x514910771AF9Ca656af840dff83E8264EcF986CA",
  AAVE: "0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9",
};
const PRICES_8: Record<string, bigint> = { WETH: 3_000n * 10n ** 8n, USDC: 10n ** 8n, USDT: 10n ** 8n, GHO: 10n ** 8n, WBTC: 65_000n * 10n ** 8n, LINK: 18n * 10n ** 8n, AAVE: 105n * 10n ** 8n };
const feedOf = (symbol: string) => getAddress(`0x${(Object.keys(TOKENS).indexOf(symbol) + 1).toString(16).padStart(40, "f")}`);
const EXTERNAL: ExternalEntry[] = Object.entries(TOKENS).flatMap(([symbol, address]) => [
  { group: "token", name: symbol, address },
  { group: "feed", name: `${symbol} / USD (primary)`, address: feedOf(symbol) },
]);
const symbolAtFeed = (address: Address) => Object.keys(TOKENS).find((s) => feedOf(s) === getAddress(address));

/**
 * An in-memory anvil: native balances, ERC-20s whose balances live in a mapping at a given storage slot, and the
 * cheatcodes the faucet uses. `deal: false` drops anvil_dealERC20, as on an older anvil.
 */
function fakeAnvil(opts: { chainId?: number; client?: string; deal?: boolean; balanceSlot?: number } = {}) {
  const native = new Map<string, bigint>();
  const storage = new Map<string, Hex>();
  const calls: string[] = [];
  const slotOf = (holder: Address) =>
    keccak256(encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [holder, BigInt(opts.balanceSlot ?? 9)]));
  const decimalsOf = (token: Address) => (getAddress(token) === getAddress(TOKENS.USDC!) ? 6 : 18);
  const rpc: Rpc = {
    async request({ method, params = [] }) {
      calls.push(method);
      switch (method) {
        case "eth_chainId":
          return `0x${(opts.chainId ?? 31337).toString(16)}`;
        case "web3_clientVersion":
          return opts.client ?? "anvil/v1.4.0";
        case "anvil_setBalance":
          native.set(String(params[0]).toLowerCase(), BigInt(params[1] as string));
          return null;
        case "anvil_dealERC20": {
          if (opts.deal === false) throw new Error("method not found");
          const [holder, token, amount] = params as [Address, Address, Hex];
          storage.set(`${token}:${slotOf(holder)}`, `0x${BigInt(amount).toString(16).padStart(64, "0")}`);
          return null;
        }
        case "eth_getStorageAt": {
          const [token, key] = params as [Address, Hex];
          return storage.get(`${token}:${key}`) ?? `0x${"0".repeat(64)}`;
        }
        case "anvil_setStorageAt": {
          const [token, key, value] = params as [Address, Hex, Hex];
          storage.set(`${token}:${key}`, value);
          return true;
        }
        case "eth_call": {
          const { to, data } = params[0] as { to: Address; data: Hex };
          const feedSymbol = symbolAtFeed(to);
          if (feedSymbol) {
            const f = decodeFunctionData({ abi: feedAbi, data });
            if (f.functionName === "decimals") return encodeFunctionResult({ abi: feedAbi, functionName: "decimals", result: 8 });
            return encodeFunctionResult({ abi: feedAbi, functionName: "latestRoundData", result: [1n, PRICES_8[feedSymbol]!, 0n, 0n, 1n] });
          }
          const call = decodeFunctionData({ abi: erc20, data });
          if (call.functionName === "decimals") return encodeFunctionResult({ abi: erc20, functionName: "decimals", result: decimalsOf(to) });
          const value = storage.get(`${to}:${slotOf(call.args[0])}`);
          return encodeFunctionResult({ abi: erc20, functionName: "balanceOf", result: value ? BigInt(value) : 0n });
        }
        default:
          throw new Error(`unexpected ${method}`);
      }
    },
  };
  return { rpc, native, storage, calls, slotOf };
}

const USDC = TOKENS.USDC!;

describe("chain check", () => {
  it("accepts a local anvil fork chain", async () => {
    await expect(checkLocalFork(fakeAnvil().rpc, [31337, 31338])).resolves.toBe(31337);
  });

  it("refuses a chain id outside the list, and a node that is not anvil", async () => {
    await expect(checkLocalFork(fakeAnvil({ chainId: 1 }).rpc, [31337, 31338])).rejects.toBeInstanceOf(ChainRefused);
    await expect(checkLocalFork(fakeAnvil({ client: "Geth/v1.14" }).rpc, [31337])).rejects.toBeInstanceOf(ChainRefused);
  });
});

describe("token funding", () => {
  it("uses anvil_dealERC20 and checks the balance", async () => {
    const anvil = fakeAnvil();
    await expect(fundToken(anvil.rpc, USDC, WALLET, "25000")).resolves.toBe(25_000_000_000n);
    expect(anvil.calls).toContain("anvil_dealERC20");
    expect(anvil.calls).not.toContain("anvil_setStorageAt");
  });

  it("falls back to writing the balance slot, and restores every slot it probed", async () => {
    const anvil = fakeAnvil({ deal: false, balanceSlot: 3 });
    await expect(fundToken(anvil.rpc, USDC, WALLET, "25000")).resolves.toBe(25_000_000_000n);
    const written = [...anvil.storage.entries()].filter(([, v]) => BigInt(v) !== 0n);
    expect(written).toEqual([[`${USDC}:${anvil.slotOf(WALLET)}`, `0x${(25_000_000_000n).toString(16).padStart(64, "0")}`]]);
  });
});

describe("faucet", () => {
  const store = () => new GrantStore(mkdtempSync(join(tmpdir(), "faucet-")));

  it("sets gas and every wallet token on a fork, once per wallet", async () => {
    const anvil = fakeAnvil();
    const faucet = new Faucet({ ethereum: forkStrategy(anvil.rpc, [31337], EXTERNAL) }, store(), () => new Date("2026-11-16T00:00:00Z"));
    const first = await faucet.grant("ethereum", WALLET.toLowerCase());
    expect(first.ok).toBe(true);
    if (!first.ok) return;
    expect(first.existing).toBe(false);
    expect(first.record.steps.map((s) => s.step)).toEqual([
      "check chain",
      "gas",
      ...GRANTS.ethereum.tokens.map((t) => `token ${t.symbol}`),
    ]);
    expect(anvil.native.get(WALLET.toLowerCase())).toBe(6_463_300_000_000_000_000n);

    const again = await faucet.grant("ethereum", WALLET);
    expect(again.ok && again.existing).toBe(true);
    expect(faucet.lookup("ethereum", WALLET)?.grantedAt).toBe("2026-11-16T00:00:00.000Z");
  });

  it("stops at the chain check on a real network and funds nothing", async () => {
    const anvil = fakeAnvil({ chainId: 1 });
    const faucet = new Faucet({ ethereum: forkStrategy(anvil.rpc, [31337], EXTERNAL) }, store());
    const result = await faucet.grant("ethereum", WALLET);
    expect(result).toMatchObject({ ok: false, status: 409, failedStep: "check chain" });
    expect(anvil.calls).not.toContain("anvil_setBalance");
  });

  it("names the step that failed", async () => {
    const anvil = fakeAnvil({ deal: false, balanceSlot: 999 });
    const faucet = new Faucet({ ethereum: forkStrategy(anvil.rpc, [31337], EXTERNAL) }, store());
    const result = await faucet.grant("ethereum", WALLET);
    expect(result).toMatchObject({ ok: false, status: 500, failedStep: "token WETH" });
    expect(faucet.lookup("ethereum", WALLET)).toBeNull();
  });

  it("on Base, prices the USD lines at the primary feed when it grants", async () => {
    const anvil = fakeAnvil({ chainId: 31338 });
    const faucet = new Faucet({ base: forkStrategy(anvil.rpc, [31338], EXTERNAL) }, store());
    const result = await faucet.grant("base", WALLET);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    const detail = (symbol: string) => result.record.steps.find((s) => s.step === `token ${symbol}`)?.detail;
    expect(detail("WETH")).toBe("5 WETH (5000000000000000000 units)");
    expect(detail("USDC")).toBe("25000 USDC (25000000000 units)");
    // $12,500 at $18.00 → 694.44444444 LINK (8 decimals, rounded down).
    expect(detail("LINK")).toBe("694.44444444 LINK (694444444440000000000 units)");
  });

  it("fails only the line whose token or feed the manifest lacks, and names it", async () => {
    const anvil = fakeAnvil({ chainId: 31338 });
    const external = EXTERNAL.filter((e) => e.name !== "GHO" && e.name !== "LINK / USD (primary)");
    const faucet = new Faucet({ base: forkStrategy(anvil.rpc, [31338], external) }, store());
    const result = await faucet.grant("base", WALLET);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    const failed = result.record.steps.filter((s) => s.failed).map((s) => [s.step, s.detail]);
    expect(failed).toEqual([
      ["token GHO", "no GHO token in the manifest"],
      ["token LINK", 'no "LINK / USD (primary)" feed in the manifest'],
    ]);
    expect(result.record.steps.filter((s) => s.step.startsWith("token ") && !s.failed)).toHaveLength(GRANTS.base.tokens.length - 2);
  });

  it("rejects a bad chain or wallet, and refuses on a test network without a minter", async () => {
    const faucet = new Faucet({ ethereum: testnetStrategy() }, store());
    expect(await faucet.grant("polygon", WALLET)).toMatchObject({ ok: false, status: 400 });
    expect(await faucet.grant("ethereum", "0x123")).toMatchObject({ ok: false, status: 400 });
    expect(await faucet.grant("base", WALLET)).toMatchObject({ ok: false, status: 400 });
    expect(await faucet.grant("ethereum", WALLET)).toMatchObject({ ok: false, failedStep: "testnet" });
  });
});

const MINTER = getAddress("0x000000000000000000000000000000000000d3a1");
const testTokenAbi = parseAbi(["function MINTER() view returns (address)", "function mint(address to, uint256 amount)"]);

/**
 * A public test network: test tokens whose MINTER is `minterOf(symbol)` (MINTER by default), the USD feeds, native
 * balances; and the minter, which records each transaction it sends and confirms it unless `revert` names its index.
 */
function fakeTestnet(opts: { chainId?: number; minterOf?: (symbol: string) => Address | null; balance?: bigint; revert?: number; pending?: number } = {}) {
  const sent: { to: Address; data?: Hex; value?: bigint; nonce: number }[] = [];
  const symbolAt = (address: Address) => Object.keys(TOKENS).find((s) => getAddress(TOKENS[s]!) === getAddress(address));
  const rpc: Rpc = {
    async request({ method, params = [] }) {
      switch (method) {
        case "eth_chainId":
          return `0x${(opts.chainId ?? 11155111).toString(16)}`;
        case "eth_getBalance":
          return `0x${(opts.balance ?? 0n).toString(16)}`;
        case "eth_call": {
          const { to, data } = params[0] as { to: Address; data: Hex };
          const feedSymbol = symbolAtFeed(to);
          if (feedSymbol) {
            const f = decodeFunctionData({ abi: feedAbi, data });
            if (f.functionName === "decimals") return encodeFunctionResult({ abi: feedAbi, functionName: "decimals", result: 8 });
            return encodeFunctionResult({ abi: feedAbi, functionName: "latestRoundData", result: [1n, PRICES_8[feedSymbol]!, 0n, 0n, 1n] });
          }
          const symbol = symbolAt(to)!;
          if (data.startsWith("0x313ce567")) return encodeFunctionResult({ abi: erc20, functionName: "decimals", result: symbol === "USDC" ? 6 : 18 });
          const minter = opts.minterOf ? opts.minterOf(symbol) : MINTER;
          if (minter === null) throw new Error("execution reverted");
          return encodeFunctionResult({ abi: testTokenAbi, functionName: "MINTER", result: minter });
        }
        default:
          throw new Error(`unexpected ${method}`);
      }
    },
  };
  const minter = {
    address: MINTER,
    nonce: async () => opts.pending ?? 7,
    send: async (tx: { to: Address; data?: Hex; value?: bigint; nonce: number }) => {
      sent.push(tx);
      return `0x${sent.length.toString(16).padStart(64, "0")}` as Hex;
    },
    confirmed: async (hash: Hex) => Number(BigInt(hash)) - 1 !== opts.revert,
  };
  return { rpc, minter, sent };
}

describe("test-network faucet", () => {
  const store = () => new GrantStore(mkdtempSync(join(tmpdir(), "faucet-")));
  const strategy = (t: ReturnType<typeof fakeTestnet>, gasEth?: string) =>
    testnetStrategy({ rpc: t.rpc, allowedChainIds: [11155111, 84532], external: EXTERNAL, minter: t.minter, gasEth });

  it("mints every wallet token to the wallet from the minter, with consecutive nonces, and records the transactions", async () => {
    const t = fakeTestnet();
    const result = await new Faucet({ ethereum: strategy(t) }, store()).grant("ethereum", WALLET);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.record.steps.map((s) => s.step)).toEqual(["check chain", ...GRANTS.ethereum.tokens.map((x) => `token ${x.symbol}`)]);
    expect(t.sent.map((x) => x.nonce)).toEqual(GRANTS.ethereum.tokens.map((_, i) => 7 + i));
    const usdc = t.sent.find((x) => getAddress(x.to) === getAddress(USDC))!;
    expect(decodeFunctionData({ abi: testTokenAbi, data: usdc.data! })).toEqual({ functionName: "mint", args: [WALLET, 25_000_000_000n] });
    expect(t.sent.every((x) => x.value === undefined)).toBe(true);
    expect(result.record.steps.every((s) => s.step === "check chain" || s.txHash)).toBe(true);
  });

  it("tops the wallet up to FAUCET_GAS_ETH only when set, and only by what it lacks", async () => {
    const t = fakeTestnet({ balance: 4_000_000_000_000_000n });
    const result = await new Faucet({ ethereum: strategy(t, "0.01") }, store()).grant("ethereum", WALLET);
    expect(result.ok).toBe(true);
    expect(t.sent[0]).toMatchObject({ to: WALLET, value: 6_000_000_000_000_000n, nonce: 7 });
    expect(t.sent[1]?.nonce).toBe(8);
  });

  it("refuses a chain that is not an allowed test network, and sends nothing", async () => {
    for (const chainId of [1, 31337, 10]) {
      const t = fakeTestnet({ chainId });
      const result = await new Faucet({ ethereum: strategy(t) }, store()).grant("ethereum", WALLET);
      expect(result).toMatchObject({ ok: false, status: 409, failedStep: "check chain" });
      expect(t.sent).toEqual([]);
    }
  });

  it("fails only the line of a token the minter cannot mint", async () => {
    const t = fakeTestnet({ minterOf: (s) => (s === "LINK" ? null : s === "AAVE" ? getAddress("0x00000000000000000000000000000000000000e1") : MINTER) });
    const result = await new Faucet({ ethereum: strategy(t) }, store()).grant("ethereum", WALLET);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.record.steps.filter((s) => s.failed).map((s) => s.step)).toEqual(["token LINK", "token AAVE"]);
    expect(t.sent).toHaveLength(GRANTS.ethereum.tokens.length - 2);
  });

  it("names the token whose mint reverted and records no grant", async () => {
    const t = fakeTestnet({ revert: 1 });
    const faucet = new Faucet({ ethereum: strategy(t) }, store());
    expect(await faucet.grant("ethereum", WALLET)).toMatchObject({ ok: false, status: 500, failedStep: `token ${GRANTS.ethereum.tokens[1]!.symbol}` });
    expect(faucet.lookup("ethereum", WALLET)).toBeNull();
  });
});

describe("config", () => {
  it("defaults to the local fork chains on 127.0.0.1", () => {
    const config = loadConfig({ FAUCET_RPC_ETHEREUM: "http://127.0.0.1:8545" });
    expect(config).toMatchObject({ kind: "fork", chainIds: [31337, 31338], host: "127.0.0.1", port: 42080 });
  });

  it("refuses mainnet chain ids, other hosts and no RPC", () => {
    expect(() => loadConfig({ FAUCET_RPC_ETHEREUM: "x", FAUCET_CHAIN_IDS: "31337,1" })).toThrow(/mainnet/);
    expect(() => loadConfig({ FAUCET_RPC_ETHEREUM: "x", FAUCET_HOST: "0.0.0.0" })).toThrow(/127.0.0.1/);
    expect(() => loadConfig({})).toThrow(/FAUCET_RPC/);
  });

  it("on a test network, defaults to Sepolia and Base Sepolia and needs the minter's keystore", () => {
    const signer = { FAUCET_SIGNER_KEYSTORE: "/keys/deployer", FAUCET_SIGNER_PASSWORD_FILE: "/keys/password" };
    const config = loadConfig({ FAUCET_CHAIN_KIND: "testnet", FAUCET_RPC_ETHEREUM: "http://127.0.0.1:8665", ...signer });
    expect(config).toMatchObject({ kind: "testnet", chainIds: [11155111, 84532], signer: { keystore: "/keys/deployer", passwordFile: "/keys/password" }, gasEth: "0" });
    expect(() => loadConfig({ FAUCET_CHAIN_KIND: "testnet", FAUCET_RPC_ETHEREUM: "x" })).toThrow(/FAUCET_SIGNER_KEYSTORE/);
    expect(() => loadConfig({ FAUCET_CHAIN_KIND: "testnet", FAUCET_RPC_ETHEREUM: "x", FAUCET_CHAIN_IDS: "11155111,31337", ...signer })).toThrow(/test networks/);
    expect(() => loadConfig({ FAUCET_CHAIN_KIND: "testnet", FAUCET_RPC_ETHEREUM: "x", FAUCET_GAS_ETH: "lots", ...signer })).toThrow(/FAUCET_GAS_ETH/);
    expect(() => loadConfig({ FAUCET_RPC_ETHEREUM: "x", ...signer })).toThrow(/holds no key/);
  });
});
