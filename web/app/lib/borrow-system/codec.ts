import type { BorrowAccountState, BorrowSystemState } from "@/app/lib/credit-engine"

function normalizeBorrowAccount(account: BorrowAccountState): BorrowAccountState {
  return {
    ...account,
    walletLpBalancesUsd6: account.walletLpBalancesUsd6 ?? {},
    walletReturnedLpBalancesUsd6: account.walletReturnedLpBalancesUsd6 ?? {},
    collateralPositions: account.collateralPositions ?? [],
    debtPositions: account.debtPositions ?? [],
    rewardPositions: account.rewardPositions ?? [],
  }
}

/** Repair persisted sandbox sessions that predate rewardPositions on accounts. */
export function normalizeBorrowSystemState(state: BorrowSystemState): BorrowSystemState {
  const accounts: BorrowSystemState["accounts"] = {}
  for (const [walletId, account] of Object.entries(state.accounts)) {
    accounts[walletId] = normalizeBorrowAccount(account)
  }
  return {
    ...state,
    accounts,
  }
}

type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue }

function encode(value: unknown): JsonValue {
  if (typeof value === "bigint") {
    return { __bigint: value.toString() }
  }
  if (Array.isArray(value)) {
    return value.map((entry) => encode(entry))
  }
  if (value && typeof value === "object") {
    const encoded: Record<string, JsonValue> = {}
    for (const [key, entry] of Object.entries(value)) {
      encoded[key] = encode(entry)
    }
    return encoded
  }
  return value as JsonValue
}

function decode(value: JsonValue): unknown {
  if (Array.isArray(value)) {
    return value.map((entry) => decode(entry))
  }
  if (value && typeof value === "object") {
    if ("__bigint" in value && typeof value.__bigint === "string") {
      return BigInt(value.__bigint)
    }
    const decoded: Record<string, unknown> = {}
    for (const [key, entry] of Object.entries(value)) {
      decoded[key] = decode(entry)
    }
    return decoded
  }
  return value
}

export function serializeBorrowValue(value: unknown) {
  return JSON.stringify(encode(value))
}

export function deserializeBorrowValue<T>(serialized: string): T {
  return decode(JSON.parse(serialized) as JsonValue) as T
}

export function serializeBorrowSystemState(state: BorrowSystemState) {
  return serializeBorrowValue(state)
}

export function deserializeBorrowSystemState(serialized: string): BorrowSystemState {
  return normalizeBorrowSystemState(deserializeBorrowValue<BorrowSystemState>(serialized))
}
