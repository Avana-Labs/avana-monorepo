// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// A schema-valid release manifest for the tests: the package's own sample, with the placeholder helpers it is built from.

export { sampleManifest } from "../../src/manifest/sample.ts";

export const A = (n: number) => `0x${n.toString(16).padStart(40, "0")}` as `0x${string}`;
export const H = (n: number) => `0x${n.toString(16).padStart(64, "0")}` as `0x${string}`;
