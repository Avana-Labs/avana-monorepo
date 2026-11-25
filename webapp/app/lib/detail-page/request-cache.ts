import { cache as reactCache } from "react"

/**
 * `React.cache()` when the runtime provides it (the RSC server render, where
 * repeated server reads should share one value per request), else an identity
 * passthrough.
 *
 * Unit tests import the server detail builders directly in a non-RSC environment
 * (React 18.3 `react` has no `cache` export), so there the wrapper is a no-op —
 * memoization is a pure optimization, so identity is behaviorally correct.
 */
export const requestCache: <A extends unknown[], R>(fn: (...args: A) => R) => (...args: A) => R =
  typeof reactCache === "function" ? reactCache : (fn) => fn
