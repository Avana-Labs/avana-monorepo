/**
 * The browser SDK surface the lazy loader uses, as NAMED re-exports. `import("@sentry/nextjs")`
 * keeps the whole namespace (Session Replay, Feedback, rrweb: ~200KB gzipped) because a dynamic
 * import of a module object can't be tree-shaken; importing this module instead lets the bundler
 * drop everything else.
 */
export { captureEvent, captureException, captureRouterTransitionStart, init } from "@sentry/nextjs"
