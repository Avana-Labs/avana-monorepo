// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Secret redaction. Provider credentials sit in the endpoint's host name or path, and viem names the full URL in its
// errors (`URL: …`; its getUrl strips only basic-auth credentials), so every message, log line and error the manager
// lets out passes through a Redactor first. Errors are scrubbed in place, keeping their class, so viem can still
// decode a revert from them.

export class Redactor {
  #secrets = new Map<string, string>();

  /** Registers `value` (a credential or an authenticated URL) under `label`. Values shorter than 6 characters are
   * skipped, as they would also match ordinary text; the URLs that carry them are registered whole. */
  add(value: string | undefined, label: string): void {
    const v = value?.trim();
    if (!v || v.length < 6) return;
    this.#secrets.set(v, label);
    // A URL also appears without its scheme or with its trailing slash dropped.
    if (/^(https?|wss?):\/\//.test(v)) {
      const bare = v.replace(/^(https?|wss?):\/\//, "").replace(/\/$/, "");
      if (bare.length >= 6) this.#secrets.set(bare, label);
    }
  }

  text(s: string): string {
    let out = s;
    for (const [v, label] of [...this.#secrets].sort((a, b) => b[0].length - a[0].length)) out = out.split(v).join(`<${label}>`);
    // Belt and braces: any provider path segment that slipped through (a credential added after the text was built).
    return out.replace(/(\.g\.alchemy\.com\/v2\/)[A-Za-z0-9_-]+/g, "$1<redacted>").replace(/(\.quiknode\.pro\/)[A-Za-z0-9_-]+/g, "$1<redacted>");
  }

  /** Scrubs `error` and its causes in place (message, shortMessage, details, metaMessages, url, stack). */
  error<E>(error: E): E {
    const seen = new Set<unknown>();
    let e: unknown = error;
    while (e && typeof e === "object" && !seen.has(e)) {
      seen.add(e);
      const o = e as Record<string, unknown>;
      for (const k of ["message", "shortMessage", "details", "url", "stack"]) {
        if (typeof o[k] === "string") {
          try {
            o[k] = this.text(o[k] as string);
          } catch {
            // a read-only property: left as it is
          }
        }
      }
      if (Array.isArray(o.metaMessages)) o.metaMessages = o.metaMessages.map((m) => (typeof m === "string" ? this.text(m) : m));
      e = o.cause;
    }
    return error;
  }
}
