/** Borrow product — About / FAQs / parameter-change history. Table: `borrowMarketContent`. */

import { defineContentModule } from "../silo/content"

export const { readContent, getContent, upsertContent } = defineContentModule("borrowMarketContent", {
  product: "borrow",
  withKind: true,
})
