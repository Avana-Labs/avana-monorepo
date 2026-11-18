// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {IAaveAdapterBase} from "../../src/policy/aave-adapter/IAaveAdapterBase.sol";
import {RepayWithCollateralParams} from "../../src/policy/aave-adapter/types/AaveAdapterTypes.sol";
import {PriceState} from "../../src/types/OracleTypes.sol";
import {ClTestToken, IClPool} from "../utils/fixtures/ClPoolFixture.sol";
import {RealStackFlows} from "../utils/fixtures/RealStackFlows.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title DeleverageRepayHfOrderIntegrationTest
/// @notice Repay with collateral reads `hfBefore` after LPVaultSwap pokes both oracles, on the real stack
/// (`RealStackFlows`): the real AaveAdapter, LPVaultSwap, market LPOracle and USDC DebtOracle. The other
/// repay-with-collateral tests are in `Deleverage.RepayWithCollateral.integration.t.sol`.
/// @dev Bob: 10,000 vault tokens at $2.00 ($20,000, CF 30 %) against 3,571 USDC (HF 1.68).
/// forge-config: default.isolate = false
contract DeleverageRepayHfOrderIntegrationTest is RealStackFlows {
    uint128 internal constant RELEASE = 150e6;

    uint256 internal mA;
    address internal proxy;
    bytes32 internal key;

    function setUp() public {
        _setUpFullStack();
        mA = _addMarket(poolA);
        (key, proxy) = _pledgeAs(bob, mA, UNITS);
        _borrowAs(bob, mA, usdcReserveId, 3571e6);
    }

    function _rwc(
        uint128 units,
        uint256 reserveId
    ) internal view returns (RepayWithCollateralParams memory p) {
        p = _rwcParams(mA, key, units, reserveId);
    }

    function _hfLog(
        Vm.Log[] memory logs
    ) internal view returns (uint256 hfBefore, uint256 hfAfter) {
        bytes32 sig = IAaveAdapterBase.RepaidWithCollateral.selector;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == adapter && logs[i].topics[0] == sig) {
                (,,,,, hfBefore, hfAfter) =
                    abi.decode(logs[i].data, (bytes32, uint128, uint256, uint256, uint256, uint256, uint256));
                return (hfBefore, hfAfter);
            }
        }
        revert("no RepaidWithCollateral");
    }
}
