// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../src/amm/IAmmIntegration.sol";
import {IAmmIntegrationHooks} from "../../src/amm/IAmmIntegrationHooks.sol";
import {UniswapV4State} from "../../src/amm/uniswap-v4/UniswapV4State.sol";
import {ICollateralizationErrors} from "../../src/custody/collateralization/ICollateralizationErrors.sol";
import {IUniswapV4PoolManager} from "../../src/interfaces/external/uniswap-v4/IUniswapV4PoolManager.sol";
import {LiquidationPreview} from "../../src/lens/lens/types/LiquidationPreview.sol";
import {PositionFeesView} from "../../src/lens/lens/types/PositionFeesView.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {PledgePreview} from "../../src/types/PledgePreview.sol";
import {PositionRef} from "../../src/types/PositionRef.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {ClTestToken, IClPool} from "../utils/fixtures/ClPoolFixture.sol";
import {RealStackUniswapV4} from "../utils/fixtures/RealStackUniswapV4.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Uniswap v4 markets on the full stack: a native ETH/USDC market on the Volatile Hub and a USDC/USDT market on
/// the Stable Hub, each priced by the real `LPOracleV4` against its v3 reference pool. Pledge, borrow, a price move,
/// seizure and the unwind through the existing v3 route DEX into USDC and GHO; a pool parked off-price failing closed;
/// a hooked pool refused; and the fee step on wrapped fee-growth accumulators.
contract MultiMarketUniswapV4IntegrationTest is RealStackUniswapV4 {
    struct Case {
        uint256 marketId;
        address wallet;
        uint256 usd;
        uint256 reserveId;
        uint256 borrowed;
    }

    Case[] internal cases;
    uint256 internal mA;
    uint256 internal v4EthUsdc;
    uint256 internal v4UsdcUsdt;

    function setUp() public {
        _setUpFullStack();
        mA = _addMarket(poolA);
        _setUpUniswapV4();
        (address s0, address s1) =
            address(usdc) < address(usdt) ? (address(usdc), address(usdt)) : (address(usdt), address(usdc));
        (PoolKey memory stableKey, IClPool stableRef) = _newV4Pool(s0, s1, 100, 1, 1e15);
        (PoolKey memory ethKey, IClPool ethRef) = _newV4Pool(address(0), address(usdc), 500, 10, 1e18);
        IClPool[] memory refs = new IClPool[](2);
        (refs[0], refs[1]) = (stableRef, ethRef);
        _ageNewPools(refs);
        v4UsdcUsdt = _addV4Market(stableKey, stableRef, VT_CF);
        v4EthUsdc = _addV4Market(ethKey, ethRef, VT_CF);
        _pokeAll();
        for (uint256 k = 0; k < 2; ++k) {
            IClPool r = routePoolOf[address(weth)][address(gho)][k];
            (int24 lower, int24 upper) = _fullRange(r);
            actor.mint(r, lower, upper, 1e22);
        }
        cases.push(Case(v4EthUsdc, makeAddr("v4EthGho"), 60_000, v4GhoReserveV, 17_142e18));
        cases.push(Case(v4UsdcUsdt, makeAddr("v4Stable"), 20_000, v4UsdcReserveS, 5714e6));
    }

    function _spokeOf(
        uint256 marketId
    ) internal view returns (address) {
        return registry.getMarket(marketId).spoke;
    }

    function _open(
        Case memory c
    ) internal returns (address proxy) {
        (, proxy) = _v4PledgeUsd(c.wallet, c.marketId, c.usd);
        _borrowAs(c.wallet, c.marketId, c.reserveId, c.borrowed);
    }

    // TEST-331 verifies: REQ-AMM-V4-004, REQ-AMM-V4-005, REQ-AMM-V4-008, SPEC-AMM-V4-001, REQ-AMM-CORE-007
    function test_TEST_331_v4MarketsPledgeBorrowAndLiquidate() public {
        address[] memory proxies = new address[](cases.length);
        for (uint256 i = 0; i < cases.length; ++i) {
            Case memory c = cases[i];
            PriceStateView memory v = mkt[c.marketId].oracle.getPriceState();
            assertEq(uint8(v.state), uint8(PriceState.Live), "v4 market Live, not Drifting");
            proxies[i] = _open(c);
            address spoke = _spokeOf(c.marketId);
            assertTrue(spoke == v4SpokeS || spoke == v4SpokeV, "a v4 CDP Spoke");
            assertGt(_sharesOn(spoke, proxies[i], mkt[c.marketId].reserveId), 0, "supplied on the market's Spoke");
            assertGt(_hfOn(spoke, proxies[i]), 1e18, "healthy after the borrow");
        }
        // Crash: WETH -20 %; USDT to $0.85.
        _publish(address(weth), 2400e8);
        _publish(address(usdt), 85_000_000);
        _repriceV4Markets();
        for (uint256 i = 0; i < cases.length; ++i) {
            _liquidateCase(cases[i], proxies[i]);
        }
        assertEq(v4Vault.balance, 0, "the LPVault never holds ETH");
    }

    function _liquidateCase(
        Case memory c,
        address proxy
    ) internal {
        address spoke = _spokeOf(c.marketId);
        assertLt(_hfOn(spoke, proxy), 1e18, "underwater after the crash");
        LiquidationPreview memory p = lens.previewLiquidation(proxy, c.reserveId, block.timestamp + 60);
        assertTrue(p.aaveLiquidatable && p.pricesUsable, "liquidatable with usable prices");
        p.params.maxShortfall = p.params.debtToCover / 20;
        uint256 debtBefore = _debtOn(spoke, proxy, c.reserveId);
        LiquidationResult memory r = _liquidateOn(spoke, keeper, p.params);
        assertEq(r.debtRepaid, p.expectedDebtRepaid, "D as previewed");
        assertEq(r.unitsSeized, p.expectedUnitsSeized, "c as previewed");
        assertApproxEqAbs(debtBefore - _debtOn(spoke, proxy, c.reserveId), r.debtRepaid, 1, "debt fell by D");
        assertEq(
            r.callerFunds + r.recovered + r.shortfall,
            r.debtRepaid + r.avanaFee + r.borrowerSurplus + r.keeperOut,
            "conservation"
        );
        assertGe(r.recovered + r.shortfall, r.minOut, "floor");
        ClTestToken[6] memory ts = [usdc, usdt, gho, weth, wbtc, meme];
        for (uint256 k = 0; k < ts.length; ++k) {
            assertEq(ts[k].balanceOf(lpVaultSwap), 0, "LPVaultSwap keeps no token");
        }
        assertFalse(lock.isLocked(), "Lock free");
    }

    // TEST-331 verifies: REQ-AMM-V4-005, SPEC-AMM-V4-002, REQ-ORACLE-015
    function test_TEST_331_parkedV4PoolFailsClosed() public {
        Case memory c = cases[0];
        (, address proxy) = _v4PledgeUsd(c.wallet, c.marketId, c.usd);
        uint256 nonce = adapterC.borrowNonce(proxy);
        PoolKey memory pk = v4KeyOf[c.marketId];
        (uint160 s,) = UniswapV4State.slot0(IUniswapV4PoolManager(address(v4pm)), keccak256(abi.encode(pk)));
        v4actor.swap(pk, true, -int256(uint256(type(uint128).max)), uint160((uint256(s) * 95) / 100));
        PriceStateView memory v = mkt[c.marketId].oracle.getPriceState();
        assertEq(uint8(v.state), uint8(PriceState.Drifting), "spot gate");
        assertFalse(v.borrowAllowed, "no new borrowing");
        vm.prank(c.wallet);
        vm.expectRevert();
        adapterC.borrow(c.marketId, c.reserveId, c.borrowed, c.wallet, _deadline(), 0, nonce);
    }

    // TEST-331 verifies: REQ-AMM-V4-001, REQ-AMM-V4-006
    function test_TEST_331_hookedPoolIsRefused() public {
        PoolKey memory pk = v4KeyOf[v4EthUsdc];
        pk.hooks = IHooks(address(uint160(0x0080)));
        assertFalse(IAmmIntegrationHooks(v4Vault).isAllowedPoolHook(address(pk.hooks)));
        vm.expectRevert();
        this.addMarketExternal(pk, mkt[v4EthUsdc].pool);
    }

    /// @dev `_addV4Market` behind an external call, so a refused listing reverts as one call.
    function addMarketExternal(
        PoolKey memory pk,
        IClPool ref
    ) external returns (uint256) {
        require(msg.sender == address(this), "self");
        return _addV4Market(pk, ref, VT_CF);
    }

    // TEST-331 verifies: REQ-AMM-V4-010, REQ-AMM-V4-004, REQ-LENS-050
    function test_TEST_331_wrappedFeeGrowthKeepsFeesAndExitsWorking() public {
        Case memory c = cases[1];
        PoolKey memory pk = v4KeyOf[c.marketId];
        bytes32 state = UniswapV4State.poolStateSlot(keccak256(abi.encode(pk)));
        vm.store(address(v4pm), bytes32(uint256(state) + 1), bytes32(type(uint256).max - 1e20));
        vm.store(address(v4pm), bytes32(uint256(state) + 2), bytes32(type(uint256).max - 1e20));
        (bytes32 key, address proxy) = _v4PledgeUsd(c.wallet, c.marketId, c.usd);
        for (uint256 i = 0; i < 3; ++i) {
            v4actor.swap(pk, true, -1e12, 4_295_128_740);
            v4actor.swap(pk, false, -1e12, 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341);
        }
        PositionFeesView memory f = lens.getPositionFees(c.marketId, key);
        assertTrue(f.supported, "v4 fees read");
        assertGt(f.amounts[0] + f.amounts[1], 0, "fees accrued across the wrap");
        uint256 units = coll.getRecord(coll.recordIdOf(V4, key)).credited;
        vm.prank(c.wallet);
        adapterC.withdraw(c.marketId, PositionRef(V4, key), units, _deadline(), 0);
        assertEq(v4posm.ownerOf(uint256(key)), c.wallet, "position returned");
        assertEq(_sharesOn(_spokeOf(c.marketId), proxy, mkt[c.marketId].reserveId), 0, "nothing supplied");
    }

    // TEST-331 verifies: REQ-AMM-V4-012, REQ-AMM-CORE-020, INV-096
    /// @notice The v4 LPVault caps an account-market at 12 open records, where the Uniswap v3 LPVault keeps 16: the
    /// pledge preview names `TooManyRecords` and a 13th pledge reverts, while a re-credit of an existing record is
    /// not limited.
    function test_TEST_331_v4RecordCapIsTwelve() public {
        assertEq(IAmmIntegration(v4Vault).maxRecordsPerAccountMarket(), 12, "v4 cap");
        assertEq(IAmmIntegration(registry.getMarket(mA).integration).maxRecordsPerAccountMarket(), 16, "v3 cap");
        Case memory c = cases[1];
        address proxy;
        for (uint256 i = 0; i < 12; ++i) {
            (, proxy) = _v4PledgeUsd(c.wallet, c.marketId, 50);
        }
        assertEq(coll.getOpenRecordCount(proxy, mkt[c.marketId].vaultToken), 12, "12 records held");
        bytes32 key = _v4MintUsd(c.wallet, c.marketId, 50);
        PledgePreview memory p = riskModule.previewPledge(c.wallet, c.marketId, key);
        assertFalse(p.eligible, "a 13th record is not eligible");
        assertEq(p.reason, IRiskModuleErrors.TooManyRecords.selector, "preview names the record cap");
        vm.prank(c.wallet);
        vm.expectRevert(abi.encodeWithSelector(ICollateralizationErrors.TooManyRecords.selector, uint256(12)));
        adapterC.pledge(c.marketId, PositionRef(V4, key), _deadline());
    }
}
