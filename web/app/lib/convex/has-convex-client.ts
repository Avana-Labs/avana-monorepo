/** True when a Convex deployment URL is configured (NEXT_PUBLIC_CONVEX_URL). */
const convexUrl = process.env.NEXT_PUBLIC_CONVEX_URL
export const hasConvexClient = Boolean(convexUrl && /^https?:\/\//.test(convexUrl))
