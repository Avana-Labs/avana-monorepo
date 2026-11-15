// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPVaultSwapLiquidation} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapLiquidation.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {IDebtOracle} from "../../src/oracle/debt-oracle/IDebtOracle.sol";
import {GasCalibration} from "../utils/GasCalibration.sol";
import {ClTestToken, IClPool} from "../utils/fixtures/ClPoolFixture.sol";
import {RealStackUniswapV4} from "../utils/fixtures/RealStackUniswapV4.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title LiquidationWholeAccountUniswapV4GasTest
/// @notice Whole-account seizure gas with Uniswap v4 records on the real stack (`RealStackUniswapV4`): the native
/// ETH/USDC v4 market (fee 0.05 %, full range) on the Volatile Hub's v4 CDP Spoke, an account of 1 record or of the v4
/// LPVault's cap of 12 records (`REQ-AMM-V4-012`), borrowing either USDC alone or, at the Spoke's 4 borrowed reserves,
/// USDC, GHO, WETH and DAI, up to HF 1.02; then ETH 99 % lower (a full-range ETH/USDC position keeps √0.01 = 10 % of its
/// value, below the debt) and one `LPVaultSwap.liquidate` by Avana's keeper that takes the whole collateral reserve:
/// Collateralization debits every record and the v4 LPVault removes each through one PositionManager batch (fees
/// first, native ETH wrapped and swept, `REQ-AMM-V4-004`), and the routes swap WETH into USDC. Gas is measured with
/// every account and slot cold (`GasCalibration`), recorded with `vm.snapshotValue` (group
/// `WholeAccountSeizureUniswapV4`), and the worst supported v4 account (12 records, 4 debts) must stay within the 7.5M
/// liquidation budget.
/// forge-config: default.isolate = false
contract LiquidationWholeAccountUniswapV4GasTest is RealStackUniswapV4, GasCalibration {
    /// @notice The liquidation gas budget of one whole-account seizure.
    uint256 internal constant LIQUIDATION_BUDGET = 7_500_000;
    /// @notice The v4 LPVault's open-record cap per account and market (`REQ-AMM-V4-012`).
    uint256 internal constant V4_RECORDS = 12;
    /// @notice Collateral of every account: about $32,000 of ETH/USDC liquidity, in 1 or 12 records.
    uint256 internal constant COLLATERAL_USD = 32_000;

    uint256 internal mV4;
    ClTestToken internal dai;
    IDebtOracle internal daiOracle;
    uint256 internal v4WethReserveV;
    uint256 internal v4DaiReserveV;

    function setUp() public {
        _setUpFullStack();
        _setUpUniswapV4();
        (PoolKey memory key, IClPool ref) = _newV4Pool(address(0), address(usdc), 500, 10, 1e18);
        IClPool[] memory refs = new IClPool[](1);
        refs[0] = ref;
        _ageNewPools(refs);
        mV4 = _addV4Market(key, ref, VT_CF);
        // WETH and DAI as DebtOracle-priced debt reserves of the Volatile Hub's v4 Spoke, so an account can borrow 4.
        _addWethDebtReserve();
        (uint256 wethAssetIdV,) = _volatileDebt(weth, 18, address(wethOracle), false);
        v4WethReserveV = _v4Debt(hubV, v4SpokeV, weth, wethAssetIdV, address(wethOracle), false);
        dai = new ClTestToken("DAI", 18);
        vm.label(address(dai), "DAI");
        _listPricedToken(dai, "DAI", 1e8, true);
        (daiOracle,,) = _addDebtReserve(dai, "DAI / USD", 9e17);
        (uint256 daiAssetIdV,) = _volatileDebt(dai, 18, address(daiOracle), false);
        v4DaiReserveV = _v4Debt(hubV, v4SpokeV, dai, daiAssetIdV, address(daiOracle), false);
        _pokeAll();
        _pokeDebtOracles();
    }

    function _pokeDebtOracles() internal {
        usdcOracle.poke();
        wethOracle.poke();
        daiOracle.poke();
    }

    /// @dev `wallet`'s account of `records` equal v4 records worth `COLLATERAL_USD` in all, borrowing USDC up to HF
    /// 1.02 (after $100 each of GHO, WETH and DAI when `fourDebts`), then ETH 99 % lower.
    function _account(
        address wallet,
        uint256 records,
        bool fourDebts
    ) internal returns (address proxy) {
        for (uint256 i = 0; i < records; ++i) {
            (, proxy) = _v4PledgeUsd(wallet, mV4, COLLATERAL_USD / records);
        }
        if (fourDebts) {
            _borrowAs(wallet, mV4, v4GhoReserveV, 100e18);
            _borrowAs(wallet, mV4, v4WethReserveV, 100e18 * 1e8 / WETH_PRICE);
            _borrowAs(wallet, mV4, v4DaiReserveV, 100e18);
        }
        uint256 max = lens.previewBorrowMax(wallet, mV4, v4UsdcReserveV, _deadline());
        _borrowAs(wallet, mV4, v4UsdcReserveV, max * 100 / 102);
        assertEq(coll.getOpenRecordCount(proxy, mkt[mV4].vaultToken), records, "records held");
        assertEq(IAaveV4Spoke(v4SpokeV).getUserAccountData(proxy).borrowCount, fourDebts ? 4 : 1, "borrowed reserves");
        _publish(address(weth), WETH_PRICE / 100);
        _repriceV4Markets();
        _pokeDebtOracles();
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
        uint256 records,
        bool fourDebts
    ) internal returns (uint256 used) {
        address proxy = _account(bob, records, fourDebts);
        used = _wholeSeizure(proxy);
        string memory k = string.concat(vm.toString(records), "records_", fourDebts ? "4debts" : "1debt");
        vm.snapshotValue("WholeAccountSeizureUniswapV4", string.concat("liquidate_", k), used);
        emit log_named_uint(string.concat("whole-account liquidate, v4 records, ", k), used);
        assertLt(used, LIQUIDATION_BUDGET, "within the 7.5M liquidation budget");
        assertLt(used, TX_GAS_CAP / 2, "within half the per-transaction gas limit");
    }

    // TEST-336 verifies: SPEC-BACK-016, REQ-VAULT-108, REQ-AMM-V4-004, REQ-AMM-V4-012
    /// @notice One native ETH/USDC v4 record, USDC debt: the whole reserve in one call.
    function test_TEST_336_v4OneRecordOneDebt() public {
        _run(1, false);
    }

    // TEST-336 verifies: SPEC-BACK-016, REQ-VAULT-108, REQ-AMM-V4-004, REQ-AMM-V4-012
    /// @notice The v4 cap of 12 records, USDC debt: every record debited and removed in one call.
    function test_TEST_336_v4TwelveRecordsOneDebt() public {
        _run(V4_RECORDS, false);
    }

    // TEST-336 verifies: SPEC-BACK-016, REQ-VAULT-108, REQ-AMM-V4-012
    /// @notice One v4 record at the Spoke's limit of 4 borrowed reserves.
    function test_TEST_336_v4OneRecordFourDebts() public {
        _run(1, true);
    }

    // TEST-336 verifies: SPEC-BACK-016, REQ-VAULT-108, REQ-AMM-V4-004, REQ-AMM-V4-012, INV-096
    /// @notice The worst supported v4 account: 12 records at the Spoke's limit of 4 borrowed reserves, within 7.5M.
    function test_TEST_336_v4TwelveRecordsFourDebts() public {
        _run(V4_RECORDS, true);
    }
}
