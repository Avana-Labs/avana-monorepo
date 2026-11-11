// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// One signer per instance and one lock around nonce allocation, so two concurrent submissions never take the
// same nonce. The local nonce is reset from the provider's pending count at startup, after every reorg and after
// any "nonce too low" error.

export class Mutex {
  private tail: Promise<void> = Promise.resolve();

  /** Runs `fn` after every earlier holder released; the lock is released even when `fn` throws. */
  async run<T>(fn: () => Promise<T>): Promise<T> {
    let release!: () => void;
    const next = new Promise<void>((r) => (release = r));
    const previous = this.tail;
    this.tail = previous.then(() => next);
    await previous;
    try {
      return await fn();
    } finally {
      release();
    }
  }
}

export class NonceManager {
  private readonly lock = new Mutex();
  private next: number | null = null;

  constructor(private readonly pendingCount: () => Promise<number>) {}

  /**
   * Allocates a nonce and passes it to `send` under the lock; a failed send returns the nonce to the pool.
   * `reuse` sends at a nonce already allocated to a pending transaction (replacement, rebuild after the deadline,
   * cancellation) without moving the counter.
   */
  async withNonce<T>(send: (nonce: number) => Promise<T>, reuse?: number): Promise<T> {
    return this.lock.run(async () => {
      if (reuse !== undefined) return send(reuse);
      if (this.next === null) this.next = await this.pendingCount();
      const nonce = this.next;
      try {
        const result = await send(nonce);
        this.next = nonce + 1;
        return result;
      } catch (err) {
        if (isNonceTooLow(err)) this.next = null;
        throw err;
      }
    });
  }

  /** Forces a re-read from the provider before the next allocation (startup, reorg, nonce too low). */
  async resync(): Promise<void> {
    await this.lock.run(async () => {
      this.next = await this.pendingCount();
    });
  }
}

export function isNonceTooLow(err: unknown): boolean {
  return err instanceof Error && /nonce too low/i.test(err.message);
}
