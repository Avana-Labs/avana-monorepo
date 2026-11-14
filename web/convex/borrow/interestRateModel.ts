/** Borrow product — Interest Rate Model params. Table: `borrowInterestRateModels`. */

import { defineInterestRateModelModule } from "../silo/interestRateModel"

export const { readInterestRateModel, getInterestRateModel, upsertInterestRateModels } =
  defineInterestRateModelModule("borrow")
