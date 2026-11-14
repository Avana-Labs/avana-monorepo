/** Multiply product — market identity. Table: `multiplyMarkets`. */

import { defineMarketsModule } from "../silo/markets"

export const { readMarket, getMarket, upsertMarkets } = defineMarketsModule("multiplyMarkets", {
  identity: () => ({ scope: "multiply" as const }),
})
