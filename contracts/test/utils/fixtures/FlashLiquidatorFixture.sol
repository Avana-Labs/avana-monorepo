// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationParams} from "../../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {RouteMode} from "../../../src/liquidation/lp-vault-swap/types/RouteMode.sol";
import {PayoutEscrow} from "../../../src/liquidation/payout-escrow/PayoutEscrow.sol";
import {Lock} from "../../../src/lock/lock/Lock.sol";
import {FlashLiquidator} from "../../../src/periphery/flash-liquidator/FlashLiquidator.sol";
import {OperatorFlashLiquidator} from "../../../src/periphery/flash-liquidator/OperatorFlashLiquidator.sol";
import {FlashLiquidationRequest} from "../../../src/periphery/flash-liquidator/types/FlashLiquidationRequest.sol";
import {DebtReserveDef} from "../../../src/policy/market-registry/types/DebtReserveDef.sol";
import {Market} from "../../../src/types/Market.sol";
import {MockAaveV3ACLManager, MockAaveV3AddressesProvider, MockAaveV3Pool} from "../mocks/AaveV3PoolMocks.sol";
import {LockMember} from "../mocks/LockMember.sol";
import {MockGhoFlashMinter} from "../mocks/MockGhoFlashMinter.sol";
import {MockLiquidationSwap} from "../mocks/MockLiquidationSwap.sol";
import {PayoutToken} from "../mocks/PayoutToken.sol";
import {ParameterStoreFixture} from "./ParameterStoreFixture.sol";

/// @title FlashLiquidatorFixture
/// @notice The public flash liquidation helper and an operator helper over a mocked Aave V3.4 Pool (5 bps premium
/// charged half-up, virtual accounting, 18,000,000 USDC idle), the real ParameterStore (`maxFlashFeeBps` launch value
/// 10), the mocked MarketRegistry (market 7 = USDC/USDT on the fixture's CDP Spoke, debt reserve 3 = USDC) and a mocked
/// LPVaultSwap that settles under the real Lock and escrows refused residues in the real PayoutEscrow.
/// @dev The outcome is the routed example of 2.11 (3.5 `LIQ-069`): `D = 1,950`, `R = 2,040.3`, `A = 19.5` USDC, so
/// `keeperOut = Kf + 90.8` USDC. The operator helper's `MAX_TOP_UP_BPS` is 100. GHO (18 decimals) is debt reserve 4
/// on the same Spoke and is lent by a mocked GHO flash minter (5 bps fee, 2,000,000 GHO bucket), which both helpers
/// are deployed with; the Pool has no GHO reserve.
abstract contract FlashLiquidatorFixture is ParameterStoreFixture {
    uint128 internal constant POOL_PREMIUM_BPS = 5;
    uint256 internal constant IDLE_USDC = 18_000_000e6;
    uint256 internal constant MARKET_ID = 7;
    uint256 internal constant DEBT_RESERVE = 3;
    uint256 internal constant OPERATOR_TOP_UP_BPS = 100;
    uint256 internal constant D_EXAMPLE = 1950e6;
    uint256 internal constant R_EXAMPLE = 2040.3e6;
    uint256 internal constant A_EXAMPLE = 19.5e6;
    uint256 internal constant GHO_RESERVE = 4;
    uint256 internal constant MINTER_FEE_BPS = 5;
    uint256 internal constant GHO_BUCKET = 2_000_000e18;

    MockAaveV3ACLManager internal acl;
    MockAaveV3AddressesProvider internal provider;
    MockAaveV3Pool internal aavePool;
    PayoutToken internal usdcToken;
    PayoutToken internal usdtToken;
    PayoutToken internal ghoToken;
    MockGhoFlashMinter internal ghoMinter;
    address internal aUsdc;
    MockLiquidationSwap internal lvs;
    Lock internal lock;
    PayoutEscrow internal escrow;
    LockMember internal adapter;
    FlashLiquidator internal helper;
    OperatorFlashLiquidator internal opHelper;

    address internal caller = makeAddr("caller");
    address internal signer = makeAddr("signer");
    address internal safe = makeAddr("fundingSafe");
    address internal treasury = makeAddr("treasury");
    address internal bobProxy = makeAddr("bobProxy");

    function _deployHelpers() internal {
        _deployStore(false);
        acl = new MockAaveV3ACLManager();
        provider = new MockAaveV3AddressesProvider(address(acl));
        aavePool = new MockAaveV3Pool(address(provider), POOL_PREMIUM_BPS);
        usdcToken = new PayoutToken("USDC", 6);
        usdtToken = new PayoutToken("USDT", 6);
        aUsdc = aavePool.listReserve(address(usdcToken));
        usdcToken.mint(aUsdc, IDLE_USDC);
        aavePool.recordSupply(address(usdcToken), IDLE_USDC);
        ghoToken = new PayoutToken("GHO", 18);
        ghoMinter = new MockGhoFlashMinter(ghoToken, acl, MINTER_FEE_BPS, GHO_BUCKET);

        lvs = new MockLiquidationSwap();
        adapter = new LockMember();
        lock = new Lock(address(adapter), address(lvs));
        adapter.setLock(lock);
        escrow = new PayoutEscrow(address(lvs), address(lock));
        lvs.setUp(lock, escrow, usdcToken, treasury);
        lvs.setOutcome(D_EXAMPLE, R_EXAMPLE, A_EXAMPLE);

        Market memory m;
        m.hub = address(hub);
        m.spoke = address(spoke);
        m.tokens = new address[](2);
        (m.tokens[0], m.tokens[1]) = (address(usdcToken), address(usdtToken));
        m.tokenDecimals = new uint8[](2);
        (m.tokenDecimals[0], m.tokenDecimals[1]) = (6, 6);
        registry.setMarket(MARKET_ID, m);
        DebtReserveDef memory d;
        d.reserveId = DEBT_RESERVE;
        d.asset = address(usdcToken);
        d.decimals = 6;
        d.fundingHub = address(hub);
        d.approved = true;
        registry.setDebtReserve(address(spoke), d);
        d.reserveId = GHO_RESERVE;
        d.asset = address(ghoToken);
        d.decimals = 18;
        registry.setDebtReserve(address(spoke), d);

        helper =
            new FlashLiquidator(address(aavePool), address(lvs), address(registry), address(store), address(ghoMinter));
        opHelper = new OperatorFlashLiquidator(
            address(aavePool),
            address(lvs),
            address(registry),
            address(store),
            address(ghoMinter),
            signer,
            safe,
            OPERATOR_TOP_UP_BPS
        );
        vm.label(address(aavePool), "AaveV3Pool");
        vm.label(address(lvs), "LPVaultSwap");
        vm.label(address(helper), "FlashLiquidator");
        vm.label(address(opHelper), "OperatorFlashLiquidator");
        vm.label(address(usdcToken), "USDC");
        vm.label(address(usdtToken), "USDT");
        vm.label(address(ghoToken), "GHO");
        vm.label(address(ghoMinter), "GhoFlashMinter");
    }

    function _params(
        uint256 debtToCover
    ) internal view returns (LiquidationParams memory p) {
        p.proxy = bobProxy;
        p.marketId = MARKET_ID;
        p.debtReserveId = DEBT_RESERVE;
        p.debtToCover = debtToCover;
        p.routeMode = RouteMode.PrimaryThenBackup;
        p.deadline = block.timestamp + 60;
    }

    function _request(
        uint256 debtToCover,
        uint256 flashAmount,
        uint256 maxPremium,
        uint256 maxTopUp,
        uint256 minPayout
    ) internal view returns (FlashLiquidationRequest memory r) {
        r.params = _params(debtToCover);
        r.flashAmount = flashAmount;
        r.maxPremium = maxPremium;
        r.maxTopUp = maxTopUp;
        r.minPayout = minPayout;
    }

    /// @dev The 2.11 example: X = F = 1,950 USDC, `maxPremium` 0.975 USDC, no top-up, `minPayout` 69 USDC.
    function _exampleRequest() internal view returns (FlashLiquidationRequest memory) {
        return _request(1950e6, 1950e6, 975_000, 0, 69e6);
    }

    /// @dev Funds `who` with `amount` USDC and approves `spender` for it.
    function _fund(
        address who,
        address spender,
        uint256 amount
    ) internal {
        usdcToken.mint(who, amount);
        vm.prank(who);
        usdcToken.approve(spender, amount);
    }

    /// @dev Sets `maxFlashFeeBps` through the timelock (the normal setter moves it either way within [0, 100]).
    function _setCap(
        uint256 bps
    ) internal {
        _tl();
        store.setMaxFlashFeeBps(uint16(bps));
    }
}
