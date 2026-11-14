// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPVaultSwapLiquidation} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapLiquidation.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {IDebtOracle} from "../../src/oracle/debt-oracle/IDebtOracle.sol";
import {GasCalibration} from "../utils/GasCalibration.sol";
import {ClTestToken} from "../utils/fixtures/ClPoolFixture.sol";
import {RealStackVolatile} from "../utils/fixtures/RealStackVolatile.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title LiquidationWholeAccountGasTest
/// @notice Whole-account seizure gas on the real stack (`RealStackVolatile`): the WBTC/WETH market (a real Uniswap v3
/// 0.3 % pool, CF 30 %) on the Volatile CDP Spoke, an account of 1 or 16 records (`INV-096`'s record bound), and one
/// `LPVaultSwap.liquidate` by Avana's keeper that takes the whole collateral reserve: WBTC and WETH fall 80 %, so the
/// USDC debt with the 5 % bonus exceeds the collateral and Aave seizes every share, Collateralization debits every
/// record and the real LPVault unwinds each through the NonfungiblePositionManager, the real routes swap both tokens
/// into USDC and Aave reports what is left as deficit. Each account borrows either USDC alone or, at the Spoke's
/// `MAX_USER_RESERVES_LIMIT` of 4 borrowed reserves, USDC, GHO, WETH and DAI (each DebtOracle-priced but GHO), so every
/// health-factor read prices 1 collateral and 4 debt reserves. Gas is measured with every account and slot cold
/// (`GasCalibration`), recorded with `vm.snapshotValue` (group `WholeAccountSeizure`) and compared with `G(16) = 5.15M`
/// of `SPEC-CHAIN-001` and the per-transaction gas limit. The same accounts give the cold cost of
/// `Spoke.getUserAccountData`, the read `markDebtFree` guards with `DEBT_MARK_GAS_FLOOR` (`REQ-COLL-040`): a failed read
/// that leaves 50,000 gas was given at least 63 × 50,000 = 3,150,000, which must exceed the read's cost.
/// @dev Stand-ins external to Avana and Aave V4, as in the fixture: Chainlink feeds (`OracleFeedMock`), GHO's fixed
/// price and the Aave V3 flash pool (not used: the keeper funds the repayment).
/// forge-config: default.isolate = false
contract LiquidationWholeAccountGasTest is RealStackVolatile, GasCalibration {
    /// @notice `G(16)` of `SPEC-BACK-016` / `SPEC-CHAIN-001`: the worst-case liquidation of 16 records.
    uint256 internal constant G16 = 5_150_000;
    /// @notice `63 × DEBT_MARK_GAS_FLOOR`: the least gas a failed `markDebtFree` read leaving the floor was given.
    uint256 internal constant DEBT_MARK_READ_BOUND = 63 * 50_000;
    /// @notice Collateral of every account: about $32,000 of WBTC/WETH liquidity, in 1 or 16 records.
    uint256 internal constant COLLATERAL_USD = 32_000;

    uint256 internal mV;
    ClTestToken internal dai;
    IDebtOracle internal daiOracle;
    uint256 internal wethReserveIdV;
    uint256 internal daiReserveIdV;

    function setUp() public {
        _setUpFullStack();
        mV = _wbtcWethMarket();
        // WETH and DAI as DebtOracle-priced debt reserves of the Stable and the Volatile Spoke, so an account of the
        // Volatile Spoke can borrow 4 reserves.
        _addWethDebtReserve();
        (, wethReserveIdV) = _volatileDebt(weth, 18, address(wethOracle), false);
        dai = new ClTestToken("DAI", 18);
        vm.label(address(dai), "DAI");
        _listPricedToken(dai, "DAI", 1e8, true);
        (daiOracle,,) = _addDebtReserve(dai, "DAI / USD", 9e17);
        (, daiReserveIdV) = _volatileDebt(dai, 18, address(daiOracle), false);
        _pokeDebtOracles();
    }

    function _pokeDebtOracles() internal {
        usdcOracle.poke();
        wethOracle.poke();
        daiOracle.poke();
    }

    /// @dev `wallet`'s account of `records` equal records worth `COLLATERAL_USD` in all, borrowing USDC up to HF 1.02
    /// (after $100 each of GHO, WETH and DAI when `fourDebts`), then WBTC and WETH 80 % lower.
    function _account(
        address wallet,
        uint256 records,
        bool fourDebts
    ) internal returns (address proxy) {
        for (uint256 i = 0; i < records; ++i) {
            (, proxy) = _pledgeUsd(wallet, mV, COLLATERAL_USD / records);
        }
        if (fourDebts) {
            _borrowAs(wallet, mV, ghoReserveIdV, 100e18);
            _borrowAs(wallet, mV, wethReserveIdV, 100e18 * 1e8 / WETH_PRICE);
            _borrowAs(wallet, mV, daiReserveIdV, 100e18);
        }
        uint256 max = lens.previewBorrowMax(wallet, mV, usdcReserveIdV, _deadline());
        _borrowAs(wallet, mV, usdcReserveIdV, max * 100 / 102);
        assertEq(coll.getOpenRecordCount(proxy, mkt[mV].vaultToken), records, "records held");
        assertEq(IAaveV4Spoke(spokeV).getUserAccountData(proxy).borrowCount, fourDebts ? 4 : 1, "borrowed reserves");
        _publish(address(wbtc), 12_000e8);
        _publish(address(weth), WETH_PRICE / 5);
        _repriceMarkets();
        _pokeDebtOracles();
    }

    /// @dev Cold gas of one keeper `liquidate` covering the whole USDC debt; checks the whole reserve was seized.
    function _wholeSeizure(
        address proxy
    ) internal returns (uint256 used) {
        uint256 debt = _debtOn(spokeV, proxy, usdcReserveIdV);
        LiquidationParams memory p = _liqParams(proxy, mV, usdcReserveIdV, debt);
        p.minAmounts = new uint256[](2);
        usdc.mint(keeper, debt);
        vm.prank(keeper);
        usdc.approve(lpVaultSwap, debt);
        used = _coldGas(keeper, lpVaultSwap, abi.encodeCall(ILPVaultSwapLiquidation.liquidate, (p)));
        assertEq(_sharesOn(spokeV, proxy, mkt[mV].reserveId), 0, "the whole collateral reserve was seized");
        assertEq(coll.getAccountCredited(proxy, mkt[mV].vaultToken), 0, "every record debited");
        assertEq(IERC20(mkt[mV].vaultToken).balanceOf(lpVaultSwap), 0, "LPVaultSwap keeps no vault token");
    }

    function _accountDataGas(
        address proxy
    ) internal returns (uint256) {
        return _coldGas(keeper, spokeV, abi.encodeCall(IAaveV4Spoke.getUserAccountData, (proxy)));
    }

    function _run(
        uint256 records,
        bool fourDebts
    ) internal returns (uint256 used, uint256 accountData) {
        address proxy = _account(bob, records, fourDebts);
        accountData = _accountDataGas(proxy);
        used = _wholeSeizure(proxy);
        string memory k = string.concat(vm.toString(records), "records_", fourDebts ? "4debts" : "1debt");
        vm.snapshotValue("WholeAccountSeizure", string.concat("liquidate_", k), used);
        vm.snapshotValue("WholeAccountSeizure", string.concat("getUserAccountData_", k), accountData);
        emit log_named_uint(string.concat("whole-account liquidate, ", k), used);
        emit log_named_uint(string.concat("getUserAccountData (cold), ", k), accountData);
        emit log_named_uint("G(16) of SPEC-CHAIN-001", G16);
        assertLt(used, TX_GAS_CAP / 2, "within half the per-transaction gas limit");
        assertLt(accountData, DEBT_MARK_READ_BOUND, "63 x DEBT_MARK_GAS_FLOOR covers the read");
    }

    // TEST-269 verifies: SPEC-BACK-016, REQ-VAULT-108, REQ-COLL-040
    /// @notice One record, USDC debt: the whole reserve in one call.
    function test_TEST_269_oneRecordOneDebt() public {
        _run(1, false);
    }

    // TEST-269 verifies: SPEC-BACK-016, REQ-VAULT-108, REQ-COLL-040
    /// @notice Sixteen records, USDC debt: every record debited and unwound in one call.
    function test_TEST_269_sixteenRecordsOneDebt() public {
        _run(16, false);
    }

    // TEST-269 verifies: SPEC-BACK-016, REQ-VAULT-108, REQ-COLL-040
    /// @notice One record at the Spoke's limit of 4 borrowed reserves.
    function test_TEST_269_oneRecordFourDebts() public {
        _run(1, true);
    }

    // TEST-269 verifies: SPEC-BACK-016, REQ-VAULT-108, REQ-COLL-040
    /// @notice Sixteen records at the Spoke's limit of 4 borrowed reserves: the worst supported whole-account seizure.
    function test_TEST_269_sixteenRecordsFourDebts() public {
        _run(16, true);
    }
}
