// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Stands in for Ponder's `ponder:api` so modules that import it load in the handler tests; the API routes are not
// exercised here.

export const db = new Proxy({}, { get: () => { throw new Error("ponder:api db is not available in the handler tests"); } });
export const publicClients: Record<string, unknown> = {};
