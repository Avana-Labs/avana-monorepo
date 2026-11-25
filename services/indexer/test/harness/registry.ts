// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Stands in for Ponder's `ponder:registry` in the handler tests (vitest.config.ts aliases it): `ponder.on` records each
// handler by its `<Source>:<Event>` name, so a test delivers logs to exactly the code Ponder would run.

/** The handlers' event and context types come from Ponder's codegen; here they are untyped. */
export type Context = any;
export type Handler = (a: { event: any; context: Context }) => Promise<void>;

export const registered = new Map<string, Handler>();

export const ponder = {
  on(name: string, handler: Handler): void {
    if (registered.has(name)) throw new Error(`${name} is registered twice`);
    registered.set(name, handler);
  },
};
