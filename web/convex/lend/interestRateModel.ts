/** Lend product — Interest Rate Model params. Table: `lendInterestRateModels`. */

import { defineInterestRateModelModule } from "../silo/interestRateModel"

export const { readInterestRateModel, getInterestRateModel, upsertInterestRateModels } =
  defineInterestRateModelModule("lend")
