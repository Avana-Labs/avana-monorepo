declare global {
  interface ImportMeta {
    // `any` is intentional: convex-test's import.meta.glob yields opaque module factories.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    glob(pattern: string): Record<string, () => Promise<any>>
  }
}

export {}
