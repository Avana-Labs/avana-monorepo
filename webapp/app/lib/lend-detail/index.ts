/**
 * Public types of the lend detail page — UI imports only from here. `./convex-detail.ts` builds
 * a page from services/convex and stays OUT of this barrel so client components don't pull in
 * `server-only`.
 */

export type { LendMarketDetail, LendMarketHero, LendTokenVisual } from "./types"
export { alignRiskSupplyApyMetric, buildLendMarketDetail, type LendDetailReference } from "./detail-base"
