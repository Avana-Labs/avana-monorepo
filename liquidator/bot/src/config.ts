// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The bot's settings, from the environment. The signer is an encrypted Foundry keystore (`cast wallet new` or
// `cast wallet import`) and the file holding its password, or a prompt for it; a private key, mnemonic or password
// value in the environment is refused, so none can sit in a .env file, a CI variable or a command line.

import { type Address, getAddress, isAddress } from "viem";

export interface SwapLeg {
  /** Pool token to sell. */
  readonly token: Address;
  /** Uniswap v3 fee tier of the pool the router sells it in, in hundredths of a bip (500 = 0.05%). */
  readonly fee: number;
}

export interface Config {
  readonly rpcUrl: string;
  readonly chainId: number;
  readonly adapter: Address;
  readonly liquidationModule: Address;
  /** The FlashLiquidator; without it the bot liquidates only with its own funds. */
  readonly flashLiquidator?: Address;
  /** SwapRouter02 the flash path sells through. */
  readonly swapRouter?: Address;
  readonly swapLegs: readonly SwapLeg[];
  /** Debt reserves to check on every Spoke. */
  readonly debtReserves: readonly bigint[];
  /** Debt reserves per Spoke (lower-case address); a Spoke listed here is checked for these instead of `debtReserves`. */
  readonly spokeDebtReserves?: ReadonlyMap<string, readonly bigint[]>;
  readonly fromBlock: bigint;
  readonly pollMs: number;
  /** Most debt asset the bot adds to a flash liquidation that sells at a loss (committed operator). */
  readonly maxTopUp: bigint;
  /** Share of the simulated profit the sent transaction may lose to price moves, in basis points. */
  readonly profitSlippageBps: bigint;
  readonly keystore: string;
  /** File holding the keystore password; without it the bot prompts on its terminal. */
  readonly passwordFile?: string;
}

const FORBIDDEN = /(PRIVATE_?KEY|MNEMONIC|SEED_?PHRASE|PASSWORD$)/i;

type Env = Readonly<Record<string, string | undefined>>;

function need(env: Env, name: string): string {
  const v = env[name];
  if (v === undefined || v === "") throw new Error(`${name} is required`);
  return v;
}

function address(env: Env, name: string, optional = false): Address | undefined {
  const v = env[name];
  if ((v === undefined || v === "") && optional) return undefined;
  const s = need(env, name);
  if (!isAddress(s)) throw new Error(`${name} is not an address`);
  return getAddress(s);
}

/** Refuses any variable that would hold a key or a password instead of pointing to a keystore or a file. */
export function refuseSecrets(env: Env): void {
  const bad = Object.keys(env).filter((k) => FORBIDDEN.test(k) && env[k] !== undefined && env[k] !== "");
  if (bad.length) throw new Error(`refusing secret-bearing variables (${bad.join(", ")}): use LIQUIDATION_BOT_KEYSTORE and LIQUIDATION_BOT_PASSWORD_FILE`);
}

/** `0xToken:500,0xToken:3000`. */
export function parseSwapLegs(s: string | undefined): SwapLeg[] {
  if (!s) return [];
  return s.split(",").map((part) => {
    const [token, fee] = part.split(":");
    if (!token || !isAddress(token) || !fee || !/^\d+$/.test(fee)) throw new Error(`bad swap leg "${part}"`);
    return { token: getAddress(token), fee: Number(fee) };
  });
}

/** The settings every instance of the bot on a chain shares; the contracts it calls come from `loadConfig` or a manifest. */
export type Settings = Omit<Config, "adapter" | "liquidationModule" | "flashLiquidator" | "debtReserves" | "spokeDebtReserves">;

/** The shared settings from the environment (the bot runner takes the contracts from the release manifest). */
export function loadSettings(env: Env): Settings {
  refuseSecrets(env);
  const swapRouter = address(env, "LIQUIDATION_BOT_SWAP_ROUTER", true);
  const slippage = BigInt(env.LIQUIDATION_BOT_PROFIT_SLIPPAGE_BPS ?? "50");
  if (slippage > 10_000n) throw new Error("LIQUIDATION_BOT_PROFIT_SLIPPAGE_BPS is above 10,000");
  return {
    rpcUrl: need(env, "LIQUIDATION_BOT_RPC_URL"),
    chainId: Number(need(env, "LIQUIDATION_BOT_CHAIN_ID")),
    ...(swapRouter ? { swapRouter } : {}),
    swapLegs: parseSwapLegs(env.LIQUIDATION_BOT_SWAP_LEGS),
    fromBlock: BigInt(env.LIQUIDATION_BOT_FROM_BLOCK ?? "0"),
    pollMs: Number(env.LIQUIDATION_BOT_POLL_MS ?? "4000"),
    maxTopUp: BigInt(env.LIQUIDATION_BOT_MAX_TOP_UP ?? "0"),
    profitSlippageBps: slippage,
    keystore: need(env, "LIQUIDATION_BOT_KEYSTORE"),
    ...(env.LIQUIDATION_BOT_PASSWORD_FILE ? { passwordFile: env.LIQUIDATION_BOT_PASSWORD_FILE } : {}),
  };
}

/** One instance's whole configuration from the environment, for a run of the bot alone (bot/src/main.ts). */
export function loadConfig(env: Env): Config {
  const settings = loadSettings(env);
  const flashLiquidator = address(env, "LIQUIDATION_BOT_FLASH_LIQUIDATOR", true);
  if (flashLiquidator && !settings.swapRouter) throw new Error("LIQUIDATION_BOT_SWAP_ROUTER is required with LIQUIDATION_BOT_FLASH_LIQUIDATOR");
  return {
    ...settings,
    adapter: address(env, "LIQUIDATION_BOT_ADAPTER")!,
    liquidationModule: address(env, "LIQUIDATION_BOT_LIQUIDATION_MODULE")!,
    ...(flashLiquidator ? { flashLiquidator } : {}),
    debtReserves: need(env, "LIQUIDATION_BOT_DEBT_RESERVES").split(",").map((r) => BigInt(r.trim())),
  };
}
