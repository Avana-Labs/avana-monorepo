// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Keccak-256 (the original Keccak padding that Solidity and its metadata use, not SHA3-256), on 32-bit halves of each
// 64-bit lane. node:crypto offers SHA3-256 only. Used by verify.ts to compare a source with the hash a build recorded.

const RC_HI = [
  0x00000000, 0x00000000, 0x80000000, 0x80000000, 0x00000000, 0x00000000, 0x80000000, 0x80000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
  0x00000000, 0x80000000, 0x80000000, 0x80000000, 0x80000000, 0x80000000, 0x00000000, 0x80000000, 0x80000000, 0x80000000, 0x00000000, 0x80000000,
];
const RC_LO = [
  0x00000001, 0x00008082, 0x0000808a, 0x80008000, 0x0000808b, 0x80000001, 0x80008081, 0x00008009, 0x0000008a, 0x00000088, 0x80008009, 0x8000000a,
  0x8000808b, 0x0000008b, 0x00008089, 0x00008003, 0x00008002, 0x00000080, 0x0000800a, 0x8000000a, 0x80008081, 0x00008080, 0x80000001, 0x80008008,
];
/** The rotation of lane x + 5y. */
const ROT = [0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39, 41, 45, 15, 21, 8, 18, 2, 61, 56, 14];
const RATE = 136;

function permute(lo: Uint32Array, hi: Uint32Array): void {
  const cLo = new Uint32Array(5);
  const cHi = new Uint32Array(5);
  const bLo = new Uint32Array(25);
  const bHi = new Uint32Array(25);
  for (let round = 0; round < 24; round++) {
    // θ
    for (let x = 0; x < 5; x++) {
      cLo[x] = lo[x]! ^ lo[x + 5]! ^ lo[x + 10]! ^ lo[x + 15]! ^ lo[x + 20]!;
      cHi[x] = hi[x]! ^ hi[x + 5]! ^ hi[x + 10]! ^ hi[x + 15]! ^ hi[x + 20]!;
    }
    for (let x = 0; x < 5; x++) {
      const nLo = cLo[(x + 1) % 5]!;
      const nHi = cHi[(x + 1) % 5]!;
      const dLo = cLo[(x + 4) % 5]! ^ ((nLo << 1) | (nHi >>> 31));
      const dHi = cHi[(x + 4) % 5]! ^ ((nHi << 1) | (nLo >>> 31));
      for (let y = 0; y < 25; y += 5) {
        lo[x + y] = lo[x + y]! ^ dLo;
        hi[x + y] = hi[x + y]! ^ dHi;
      }
    }
    // ρ and π: lane (x, y) moves to (y, 2x + 3y), rotated.
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) {
        const i = x + 5 * y;
        const j = y + 5 * ((2 * x + 3 * y) % 5);
        const n = ROT[i]!;
        const l = lo[i]!;
        const h = hi[i]!;
        if (n === 0) {
          bLo[j] = l;
          bHi[j] = h;
        } else if (n < 32) {
          bLo[j] = (l << n) | (h >>> (32 - n));
          bHi[j] = (h << n) | (l >>> (32 - n));
        } else if (n === 32) {
          bLo[j] = h;
          bHi[j] = l;
        } else {
          const m = n - 32;
          bLo[j] = (h << m) | (l >>> (32 - m));
          bHi[j] = (l << m) | (h >>> (32 - m));
        }
      }
    }
    // χ
    for (let y = 0; y < 25; y += 5) {
      for (let x = 0; x < 5; x++) {
        lo[x + y] = bLo[x + y]! ^ (~bLo[((x + 1) % 5) + y]! & bLo[((x + 2) % 5) + y]!);
        hi[x + y] = bHi[x + y]! ^ (~bHi[((x + 1) % 5) + y]! & bHi[((x + 2) % 5) + y]!);
      }
    }
    // ι
    lo[0] = lo[0]! ^ RC_LO[round]!;
    hi[0] = hi[0]! ^ RC_HI[round]!;
  }
}

/** The Keccak-256 hash of `data` (a string is hashed as UTF-8), as 0x-prefixed lower-case hex. */
export function keccak256(data: Uint8Array | string): string {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
  const blocks = Math.floor(bytes.length / RATE) + 1;
  const padded = new Uint8Array(blocks * RATE);
  padded.set(bytes);
  padded[bytes.length] = padded[bytes.length]! ^ 0x01;
  padded[padded.length - 1] = padded[padded.length - 1]! ^ 0x80;
  const lo = new Uint32Array(25);
  const hi = new Uint32Array(25);
  const view = new DataView(padded.buffer);
  for (let b = 0; b < blocks; b++) {
    for (let i = 0; i < RATE / 8; i++) {
      lo[i] = lo[i]! ^ view.getUint32(b * RATE + i * 8, true);
      hi[i] = hi[i]! ^ view.getUint32(b * RATE + i * 8 + 4, true);
    }
    permute(lo, hi);
  }
  const out = new DataView(new ArrayBuffer(32));
  for (let i = 0; i < 4; i++) {
    out.setUint32(i * 8, lo[i]!, true);
    out.setUint32(i * 8 + 4, hi[i]!, true);
  }
  return `0x${Buffer.from(out.buffer).toString("hex")}`;
}
