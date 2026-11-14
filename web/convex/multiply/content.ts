/** Multiply product — About / FAQs / parameter-change history. Table: `multiplyMarketContent`. */

import { defineContentModule } from "../silo/content"

export const { readContent, getContent, upsertContent } = defineContentModule("multiplyMarketContent", {
  product: "multiply",
})
