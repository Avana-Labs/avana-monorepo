// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
import { ConvexError } from "convex/values"

/**
 * A user-facing blocked state as a ConvexError. Convex replaces a plain Error's message with
 * "Server Error" in production, so the client could not tell UNAUTHENTICATED from
 * INSUFFICIENT_BALANCE. The payload is `{ code, message }`: `code` is the stable CODE prefix
 * ("UNAUTHENTICATED", "RATE_LIMITED", …), `message` the full "CODE: detail" text.
 */
export function codedError(message: string) {
  const code = /^([A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*)(?::|$)/.exec(message)?.[1] ?? "ERROR"
  return new ConvexError({ code, message })
}
