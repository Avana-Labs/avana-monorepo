type CspViolation = Pick<
  SecurityPolicyViolationEvent,
  "disposition" | "blockedURI" | "effectiveDirective" | "sourceFile" | "lineNumber" | "columnNumber"
>

export function describeBlockedEval(event: CspViolation) {
  if (
    event.disposition !== "enforce" ||
    event.blockedURI !== "eval" ||
    !["script-src", "script-src-elem"].includes(event.effectiveDirective)
  ) {
    return null
  }

  // Only a script the page loaded over http(s) is actionable. Browser extensions (e.g. the Backpack
  // wallet) inject code with no source file or an extension URL; the bundle ships no eval, so those
  // reports were pure noise in production.
  let source: URL
  try {
    source = new URL(event.sourceFile)
  } catch {
    return null
  }
  if (source.protocol !== "http:" && source.protocol !== "https:") return null
  return {
    // Never send credentials, query strings or fragments.
    source_file: `${source.protocol}//${source.host}${source.pathname}`,
    line_number: event.lineNumber,
    column_number: event.columnNumber,
    directive: event.effectiveDirective,
  }
}
