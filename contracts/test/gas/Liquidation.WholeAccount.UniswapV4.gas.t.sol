// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPVaultSwapLiquidation} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapLiquidation.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {GasCalibration} from "../utils/GasCalibration.sol";
import {IClPool} from "../utils/fixtures/ClPoolFixture.sol";
import {RealStackUniswapV4} from "../utils/fixtures/RealStackUniswapV4.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title LiquidationWholeAccountUniswapV4GasTest
/// @notice Whole-account seizure gas with Uniswap v4 records on the real stack (`RealStackUniswapV4`): the native
/// ETH/USDC v4 market (fee 0.05 %, full range) on the Volatile Hub's v4 CDP Spoke, an account of 1 or 16 records
/// (`INV-096`'s record bound) borrowing USDC up to HF 1.02, then ETH 99 % lower, and one `LPVaultSwap.liquidate` by
/// Avana's keeper that takes the whole collateral reserve: Collateralization debits every record and the v4 LPVault
/// removes each through one PositionManager batch (fees first, native ETH wrapped and swept, `REQ-AMM-V4-004`), and
/// the routes swap WETH into USDC. Gas is measured with every account and slot cold (`GasCalibration`), recorded with
/// `vm.snapshotValue` (group `WholeAccountSeizureUniswapV4`) and compared with the Uniswap v3 records of
/// `WholeAccountSeizure`, `G(16) = 5.15M` of `SPEC-CHAIN-001` and the per-transaction gas limit.
/// forge-config: default.isolate = false
contract LiquidationWholeAccountUniswapV4GasTest is RealStackUniswapV4, GasCalibration {
    /// @notice `G(16)` of `SPEC-BACK-016` / `SPEC-CHAIN-001`: the worst-case liquidation of 16 records.
    uint256 internal constant G16 = 5_150_000;
    /// @notice Collateral of every account: about $32,000 of ETH/USDC liquidity, in 1 or 16 records.
    uint256 internal constant COLLATERAL_USD = 32_000;

    uint256 internal mV4;

    function setUp() public {
        _setUpFullStack();
        _setUpUniswapV4();
        (PoolKey memory key, IClPool ref) = _newV4Pool(address(0), address(usdc), 500, 10, 1e18);
        IClPool[] memory refs = new IClPool[](1);
        refs[0] = ref;
        _ageNewPools(refs);
        mV4 = _addV4Market(key, ref, VT_CF);
        _pokeAll();
    }

    /// @dev `wallet`'s account of `records` equal v4 records worth `COLLATERAL_USD` in all, borrowing USDC up to HF
    /// 1.02, then ETH 99 % lower (a full-range ETH/USDC position keeps √0.01 = 10 % of its value, below the debt).
    function _account(
        address wallet,
        uint256 records
    ) internal returns (address proxy) {
        for (uint256 i = 0; i < records; ++i) {
            (, proxy) = _v4PledgeUsd(wallet, mV4, COLLATERAL_USD / records);
        }
        uint256 max = lens.previewBorrowMax(wallet, mV4, v4UsdcReserveV, _deadline());
        _borrowAs(wallet, mV4, v4UsdcReserveV, max * 100 / 102);
        assertEq(coll.getOpenRecordCount(proxy, mkt[mV4].vaultToken), records, "records held");
        assertEq(IAaveV4Spoke(v4SpokeV).getUserAccountData(proxy).borrowCount, 1, "borrowed reserves");
        _publish(address(weth), WETH_PRICE / 100);
        _repriceV4Markets();
        usdcOracle.poke();
    }

    /// @dev Cold gas of one keeper `liquidate` covering the whole USDC debt; checks the whole reserve was seized.
    function _wholeSeizure(
        address proxy
    ) internal returns (uint256 used) {
        uint256 debt = _debtOn(v4SpokeV, proxy, v4UsdcReserveV);
        LiquidationParams memory p = _liqParams(proxy, mV4, v4UsdcReserveV, debt);
        p.minAmounts = new uint256[](2);
        usdc.mint(keeper, debt);
        vm.prank(keeper);
        usdc.approve(lpVaultSwap, debt);
        used = _coldGas(keeper, lpVaultSwap, abi.encodeCall(ILPVaultSwapLiquidation.liquidate, (p)));
        assertEq(_sharesOn(v4SpokeV, proxy, mkt[mV4].reserveId), 0, "the whole collateral reserve was seized");
        assertEq(coll.getAccountCredited(proxy, mkt[mV4].vaultToken), 0, "every record debited");
        assertEq(IERC20(mkt[mV4].vaultToken).balanceOf(lpVaultSwap), 0, "LPVaultSwap keeps no vault token");
        assertEq(v4Vault.balance, 0, "the LPVault keeps no ETH");
    }

    function _run(
        uint256 records
    ) internal returns (uint256 used) {
        address proxy = _account(bob, records);
        used = _wholeSeizure(proxy);
        string memory k = string.concat(vm.toString(records), "records_1debt");
        vm.snapshotValue("WholeAccountSeizureUniswapV4", string.concat("liquidate_", k), used);
        emit log_named_uint(string.concat("whole-account liquidate, v4 records, ", k), used);
        emit log_named_uint("G(16) of SPEC-CHAIN-001", G16);
        assertLt(used, TX_GAS_CAP / 2, "within half the per-transaction gas limit");
    }

    // TEST-331 verifies: SPEC-BACK-016, REQ-VAULT-108, REQ-AMM-V4-004
    /// @notice One native ETH/USDC v4 record, USDC debt: the whole reserve in one call.
    function test_TEST_331_v4OneRecordOneDebt() public {
        _run(1);
    }

    // TEST-331 verifies: SPEC-BACK-016, REQ-VAULT-108, REQ-AMM-V4-004
    /// @notice Sixteen native ETH/USDC v4 records, USDC debt: every record debited and removed in one call.
    function test_TEST_331_v4SixteenRecordsOneDebt() public {
        _run(16);
    }
}
