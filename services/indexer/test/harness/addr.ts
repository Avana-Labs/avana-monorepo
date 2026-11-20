// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs

import type { Address } from "viem";

/** A fixed address from a small number. */
export const addr = (n: number): Address => `0x${n.toString(16).padStart(40, "0")}` as Address;
