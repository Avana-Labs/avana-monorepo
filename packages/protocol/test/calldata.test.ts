// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Each AaveAdapter calldata builder: encode, decode with the ABI, and compare the function and every argument.

import { getAddress, toFunctionSelector, type Hex } from "viem";
import { describe, expect, it } from "vitest";
import { aaveAdapterAbi } from "../src/abis/index.ts";
import {
  aaveAdapterCall,
  decodeAaveAdapterCall,
  encodeBorrow,
  encodeCollectFees,
  encodePledge,
  encodeRecredit,
  encodeRemoveLiquidity,
  encodeRepay,
  encodeRepayAll,
  encodeRepayAllAndWithdraw,
  encodeRepayWithCollateral,
  encodeWithdraw,
} from "../src/calldata/index.ts";

const RECEIVER = getAddress("0x00000000000000000000000000000000000000aa");
const BORROWER = getAddress("0x00000000000000000000000000000000000000bb");
const ADAPTER = getAddress("0x0000000000000000000000000000000000000ada");
const position = { integrationId: 2, positionKey: `0x${"ab".repeat(32)}` as Hex };
const deadline = 1_900_000_000n;
const WAD = 10n ** 18n;
const MAX_UINT128 = 2n ** 128n - 1n;
const MAX_UINT256 = 2n ** 256n - 1n;

const selector = (name: string) => {
  const f = aaveAdapterAbi.find((x) => x.type === "function" && x.name === name);
  if (!f || f.type !== "function") throw new Error(name);
  return toFunctionSelector(f);
};

describe("AaveAdapter calldata", () => {
  it("borrow", () => {
    const data = encodeBorrow({ marketId: 7n, debtReserveId: 3n, amount: 2_500_000_000n, receiver: RECEIVER, deadline, minHealthFactor: (11n * WAD) / 10n, expectedNonce: 4n });
    expect(data.slice(0, 10)).toBe(selector("borrow"));
    const d = decodeAaveAdapterCall(data);
    expect(d.functionName).toBe("borrow");
    expect(d.args).toEqual([7n, 3n, 2_500_000_000n, RECEIVER, deadline, (11n * WAD) / 10n, 4n]);
  });

  it("repay leaves repayAll false; repayAll sets it", () => {
    const args = { borrower: BORROWER, marketId: 7n, debtReserveId: 3n, maxRepaySpend: 1_000_000n, deadline };
    const part = decodeAaveAdapterCall(encodeRepay(args));
    expect(part.functionName).toBe("repay");
    expect(part.args).toEqual([BORROWER, 7n, 3n, 1_000_000n, false, deadline]);
    const all = decodeAaveAdapterCall(encodeRepayAll({ ...args, maxRepaySpend: MAX_UINT256 }));
    expect(all.functionName).toBe("repay");
    expect(all.args).toEqual([BORROWER, 7n, 3n, MAX_UINT256, true, deadline]);
  });

  it("repayWithCollateral", () => {
    const data = encodeRepayWithCollateral({
      marketId: 7n,
      position,
      units: MAX_UINT128,
      debtReserveId: 3n,
      minAmounts: [10n, 20n],
      minDebtRepaid: 4_000_000_000n,
      minAssetOut: 1n,
      deadline,
      minHealthFactor: WAD,
    });
    const d = decodeAaveAdapterCall(data);
    expect(d.functionName).toBe("repayWithCollateral");
    expect(d.args).toEqual([
      { marketId: 7n, position, units: MAX_UINT128, debtReserveId: 3n, minAmounts: [10n, 20n], minDebtRepaid: 4_000_000_000n, minAssetOut: 1n, deadline, minHealthFactor: WAD },
    ]);
  });

  it("pledge", () => {
    const d = decodeAaveAdapterCall(encodePledge({ marketId: 7n, position, deadline }));
    expect(d.functionName).toBe("pledge");
    expect(d.args).toEqual([7n, position, deadline]);
  });

  it("recredit, with and without a top-up", () => {
    const withTopUp = decodeAaveAdapterCall(encodeRecredit({ marketId: 7n, position, topUp: "0x1234", deadline }));
    expect(withTopUp.functionName).toBe("recredit");
    expect(withTopUp.args).toEqual([7n, position, "0x1234", deadline]);
    expect(decodeAaveAdapterCall(encodeRecredit({ marketId: 7n, position, topUp: "0x", deadline })).args).toEqual([7n, position, "0x", deadline]);
  });

  it("withdraw", () => {
    const d = decodeAaveAdapterCall(encodeWithdraw({ marketId: 7n, position, units: 5_000n, deadline, minHealthFactor: 0n }));
    expect(d.functionName).toBe("withdraw");
    expect(d.args).toEqual([7n, position, 5_000n, deadline, 0n]);
  });

  it("removeLiquidity", () => {
    const d = decodeAaveAdapterCall(encodeRemoveLiquidity({ marketId: 7n, position, units: 1_500n, minAmounts: [1n, 2n], deadline, minHealthFactor: WAD }));
    expect(d.functionName).toBe("removeLiquidity");
    expect(d.args).toEqual([7n, position, 1_500n, [1n, 2n], deadline, WAD]);
  });

  it("repayAllAndWithdraw, and refuses mismatched reserve and spend lists", () => {
    const d = decodeAaveAdapterCall(encodeRepayAllAndWithdraw({ marketId: 7n, position, units: 5_000n, debtReserveIds: [3n, 4n], maxRepaySpends: [100n, 200n], deadline }));
    expect(d.functionName).toBe("repayAllAndWithdraw");
    expect(d.args).toEqual([7n, position, 5_000n, [3n, 4n], [100n, 200n], deadline]);
    expect(() => encodeRepayAllAndWithdraw({ marketId: 7n, position, units: 5_000n, debtReserveIds: [3n, 4n], maxRepaySpends: [100n], deadline })).toThrow(/2 debt reserves but 1/);
  });

  it("collectFees", () => {
    const d = decodeAaveAdapterCall(encodeCollectFees({ marketId: 7n, position, deadline }));
    expect(d.functionName).toBe("collectFees");
    expect(d.args).toEqual([7n, position, deadline]);
  });

  it("refuses an amount outside its integer type", () => {
    expect(() => encodeWithdraw({ marketId: 7n, position, units: 1n, deadline: MAX_UINT256 + 1n, minHealthFactor: 0n })).toThrow();
    expect(() => encodeRemoveLiquidity({ marketId: 7n, position, units: MAX_UINT128 + 1n, minAmounts: [], deadline, minHealthFactor: 0n })).toThrow();
    expect(() => encodePledge({ marketId: 7n, position: { ...position, integrationId: 2 ** 32 }, deadline })).toThrow();
  });

  it("wraps calldata as a non-payable call to the Adapter", () => {
    const data = encodePledge({ marketId: 1n, position, deadline });
    expect(aaveAdapterCall(ADAPTER, data)).toEqual({ to: ADAPTER, data, value: 0n });
  });
});
