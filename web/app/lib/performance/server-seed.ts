/** Maximum cold-cache wait for optional display data before SSR uses its fallback. */
export const SERVER_SEED_WAIT_MS = 250

/**
 * Bound the render wait, not the cached request: a slow successful request can still
 * populate Next's cache for the next visitor. Apply server overlays only after this
 * resolves so a late response cannot change prices midway through the current render.
 */
export async function waitForServerSeed<T>(request: Promise<T>, fallback: T): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    return await Promise.race([
      request,
      new Promise<T>((resolve) => {
        timer = setTimeout(() => resolve(fallback), SERVER_SEED_WAIT_MS)
      }),
    ])
  } finally {
    clearTimeout(timer)
  }
}
