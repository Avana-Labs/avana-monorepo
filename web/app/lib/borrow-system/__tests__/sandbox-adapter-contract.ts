import { expect } from "vitest"
import { calculateCreditMetrics, type BorrowAction } from "@/app/lib/borrow-system/model"
import type { SandboxActionResult, TransactionIntent } from "@/app/lib/borrow-system/contracts"
import type { SandboxTransactionAdapter } from "@/app/lib/borrow-system/sandbox-transaction-adapter"
import type { BorrowSystemState } from "@/app/lib/borrow-system/model"

type SandboxHarness = {
  adapter: SandboxTransactionAdapter
  getState: () => BorrowSystemState
}

function snapshotTransactions(state: BorrowSystemState) {
  return structuredClone(state.transactions)
}

export async function assertSandboxActionContract(
  harness: SandboxHarness,
  action: BorrowAction,
  {
    expectedActionType,
    previewOnly = false,
    walletId,
  }: {
    expectedActionType: TransactionIntent["actionType"]
    previewOnly?: boolean
    walletId: string
  },
) {
  const beforeState = harness.getState()
  const beforeTransactions = snapshotTransactions(beforeState)

  const intent = harness.adapter.createIntent(action)
  expect(intent.simulated).toBe(true)
  expect(intent.actionType).toBe(expectedActionType)
  expect(intent.payload).toEqual(action)

  const preview = await harness.adapter.previewTransaction(intent)
  expect(preview.intent.id).toBe(intent.id)
  expect(preview.before).toBeDefined()
  expect(preview.after).toBeDefined()
  expect(harness.getState().transactions).toEqual(beforeTransactions)

  if (previewOnly) {
    const blocked = await harness.adapter.executeTransaction(intent)
    expect(blocked.receipt.status).toBe("failed")
    expect(blocked.receipt.error).toContain("preview-only")
    expect(harness.getState().transactions).toEqual(beforeTransactions)
    return { intent, preview, result: blocked }
  }

  if (!preview.allowed) {
    const blocked = await harness.adapter.executeTransaction(intent)
    expect(blocked.receipt.status).toBe("failed")
    expect(blocked.receipt.simulated).toBe(true)
    expect(blocked.historyItem.status).toBe("failed")
    expect(harness.getState().transactions).toEqual(beforeTransactions)
    return { intent, preview, result: blocked }
  }

  const result = await harness.adapter.executeTransaction(intent)
  assertSandboxExecutionResult(result, intent, walletId)
  expect(harness.getState().transactions.length).toBeGreaterThan(beforeTransactions.length)

  return { intent, preview, result }
}

function assertSandboxExecutionResult(result: SandboxActionResult, intent: TransactionIntent, walletId: string) {
  expect(result.receipt.simulated).toBe(true)
  expect(result.receipt.hash).toMatch(/^sim/)
  expect(result.receipt.status).toBe("success")
  expect(result.receipt.actionType).toBe(intent.actionType)
  expect(result.result.simulated).toBe(true)
  expect(result.historyItem.simulated).toBe(true)
  expect(result.historyItem.intentId).toBe(intent.id)
  expect(result.historyItem.kind).toBe(intent.actionType)
  expect(result.historyItem.status).toBe("success")
  expect(result.historyItem.hash).toBe(result.receipt.hash)

  const metrics = calculateCreditMetrics(result.state, walletId)
  expect(result.preview.after.totalBorrowedUsd6).toBe(metrics.totalBorrowedUsd6)
}
