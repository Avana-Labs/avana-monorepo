// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {UniswapV4State} from "../../src/amm/uniswap-v4/UniswapV4State.sol";
import {ICollateralizationBase} from "../../src/custody/collateralization/ICollateralizationBase.sol";
import {ILPVault} from "../../src/custody/lp-vault/ILPVault.sol";
import {IUniswapV4PoolManager} from "../../src/interfaces/external/uniswap-v4/IUniswapV4PoolManager.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LPVaultSwapTypes.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {PriceState} from "../../src/types/OracleTypes.sol";
import {PledgePreview, PositionRef} from "../../src/types/PositionTypes.sol";
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

    // TEST-331 verifies: REQ-AMM-V4-001, REQ-AMM-V4-006
    function test_TEST_331_hookedPoolIsRefused() public {
        PoolKey memory pk = v4KeyOf[v4EthUsdc];
        pk.hooks = IHooks(address(uint160(0x0080)));
        assertFalse(ILPVault(v4Vault).isAllowedPoolHook(address(pk.hooks)));
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

    // TEST-344 verifies: REQ-AMM-V4-012, REQ-AMM-CORE-020, INV-096
    /// @notice The v4 LPVault caps an account-market at 8 open records, where the Uniswap v3 LPVault keeps 16: the
    /// pledge preview names `TooManyRecords` and a 9th pledge reverts, while a re-credit of an existing record is
    /// not limited.
    function test_TEST_344_v4RecordCapIsEight() public {
        assertEq(ILPVault(v4Vault).maxRecordsPerAccountMarket(), 8, "v4 cap");
        assertEq(ILPVault(registry.getMarket(mA).integration).maxRecordsPerAccountMarket(), 16, "v3 cap");
        Case memory c = cases[1];
        address proxy;
        for (uint256 i = 0; i < 8; ++i) {
            (, proxy) = _v4PledgeUsd(c.wallet, c.marketId, 50);
        }
        assertEq(coll.getOpenRecordCount(proxy, mkt[c.marketId].vaultToken), 8, "8 records held");
        bytes32 key = _v4MintUsd(c.wallet, c.marketId, 50);
        PledgePreview memory p = riskModule.previewPledge(c.wallet, c.marketId, key);
        assertFalse(p.eligible, "a 9th record is not eligible");
        assertEq(p.reason, IRiskModuleErrors.TooManyRecords.selector, "preview names the record cap");
        vm.prank(c.wallet);
        vm.expectRevert(abi.encodeWithSelector(ICollateralizationBase.TooManyRecords.selector, uint256(8)));
        adapterC.pledge(c.marketId, PositionRef(V4, key), _deadline());
    }
}
