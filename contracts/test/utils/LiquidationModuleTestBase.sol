// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AaveAdapter} from "../../src/AaveAdapter.sol";
import {LPOracle} from "../../src/LPOracle.sol";
import {LiquidationModule} from "../../src/LiquidationModule.sol";
import {VaultToken} from "../../src/VaultToken.sol";
import {ILPOracle} from "../../src/interfaces/ILPOracle.sol";
import {ILPVault} from "../../src/interfaces/ILPVault.sol";
import {ILiquidationModule} from "../../src/interfaces/ILiquidationModule.sol";
import {IRiskModule} from "../../src/interfaces/IRiskModule.sol";
import {IVaultToken} from "../../src/interfaces/IVaultToken.sol";
import {AdapterTestHub} from "./mocks/AaveAdapterTestMocks.sol";
import {BandTestFeed, BandTestPriceSpoke} from "./mocks/BandOracleMocks.sol";
import {LPVaultTestToken, MockLPVault, MockPositionManager} from "./mocks/LPVaultMocks.sol";
import {LiquidationTestRiskModule, LiquidationTestSpoke} from "./mocks/LiquidationTestMocks.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Shared setup: the real LPVault (mock AMM), VaultTokens, LPOracles (both tokens at $1), AaveAdapter and
/// LiquidationModule; a RiskModule stand-in with a 20% fee share; a small Spoke with Aave's liquidation. One pool is
/// listed as Full range (market 1) and Custom range `[-1000, 1000]` (market 2).
abstract contract LiquidationModuleTestBase is Test {
    uint64 internal constant ADAPTER_ROLE = 11;
    uint64 internal constant LIQUIDATION_ROLE = 12;
    uint64 internal constant BURN_ROLE = 13;
    bytes32 internal constant POOL = bytes32(uint256(0xA001));
    int24 internal constant SPACING = 10;
    int24 internal constant FULL_LOWER = -887_270;
    int24 internal constant FULL_UPPER = 887_270;
    int24 internal constant BAND_LOWER = -1000;
    int24 internal constant BAND_UPPER = 1000;
    uint256 internal constant FULL = 1;
    uint256 internal constant CUSTOM = 2;
    uint256 internal constant DEBT_RESERVE = 10;
    uint256 internal constant CF_BPS = 8000;
    uint256 internal constant FEE_SHARE_BPS = 2000;

    AccessManager internal am;
    LPVaultTestToken internal token0;
    LPVaultTestToken internal token1;
    LPVaultTestToken internal usdc;
    MockPositionManager internal pm;
    MockLPVault internal vault;
    LiquidationTestRiskModule internal rm;
    AdapterTestHub internal hub;
    LiquidationTestSpoke internal spoke;
    VaultToken internal vtFull;
    VaultToken internal vtCustom;
    BandTestFeed internal feed0;
    BandTestFeed internal feed1;
    BandTestPriceSpoke internal priceSpoke;
    uint256 internal priceReserve0;
    uint256 internal priceReserve1;
    AaveAdapter internal adapter;
    LiquidationModule internal module;

    address internal alice;
    address internal bob;
    address internal liquidator;
    address internal feeRecipient;

    function setUp() public virtual {
        (alice,) = makeAddrAndKey(string(abi.encode("alice", block.timestamp)));
        (bob,) = makeAddrAndKey(string(abi.encode("bob", block.timestamp)));
        (liquidator,) = makeAddrAndKey(string(abi.encode("liquidator", block.timestamp)));
        (feeRecipient,) = makeAddrAndKey(string(abi.encode("feeRecipient", block.timestamp)));

        am = new AccessManager(address(this));
        token0 = new LPVaultTestToken("T0");
        token1 = new LPVaultTestToken("T1");
        usdc = new LPVaultTestToken("USDC");
        pm = new MockPositionManager(token0, token1);
        vault = new MockLPVault(address(am), pm);
        vault.setPool(POOL, SPACING);
        vault.listMarket(FULL, POOL, FULL_LOWER, FULL_UPPER);
        vault.listMarket(CUSTOM, POOL, BAND_LOWER, BAND_UPPER);

        hub = new AdapterTestHub();
        spoke = new LiquidationTestSpoke(hub);
        hub.setSpoke(address(spoke));
        rm = new LiquidationTestRiskModule(address(vault));
        module = new LiquidationModule(address(rm));
        rm.setLiquidationModule(address(module));
        rm.setFee(FEE_SHARE_BPS, feeRecipient);
        adapter = new AaveAdapter(address(rm));
        spoke.setManagerActive(address(adapter), true);

        vtFull = new VaultToken(_params("F", FULL));
        vtCustom = new VaultToken(_params("C", CUSTOM));
        spoke.setReserve(FULL, address(vtFull), 1, CF_BPS);
        spoke.setReserve(CUSTOM, address(vtCustom), 1, CF_BPS);
        spoke.setReserve(DEBT_RESERVE, address(usdc), 0, 0);
        usdc.mint(address(hub), 1e30);

        feed0 = new BandTestFeed(8, 1e8);
        feed1 = new BandTestFeed(8, 1e8);
        priceSpoke = new BandTestPriceSpoke(8);
        priceSpoke.init();
        priceReserve0 = priceSpoke.addReserve(address(token0), token0.decimals(), address(feed0));
        priceReserve1 = priceSpoke.addReserve(address(token1), token1.decimals(), address(feed1));
        rm.setMarket(FULL, _market(FULL, FULL_LOWER, FULL_UPPER, IRiskModule.MarketKind.FullRange, vtFull));
        rm.setMarket(CUSTOM, _market(CUSTOM, BAND_LOWER, BAND_UPPER, IRiskModule.MarketKind.CustomRange, vtCustom));

        _grantRoles();
        address[2] memory wallets = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            vm.startPrank(wallets[i]);
            pm.setApprovalForAll(address(vault), true);
            usdc.approve(address(adapter), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(liquidator);
        usdc.approve(address(module), type(uint256).max);
        usdc.mint(liquidator, 1e30);
    }

    function _grantRoles() internal {
        bytes4[] memory vaultSelectors = new bytes4[](5);
        vaultSelectors[0] = ILPVault.pledge.selector;
        vaultSelectors[1] = ILPVault.addLiquidity.selector;
        vaultSelectors[2] = ILPVault.removeLiquidity.selector;
        vaultSelectors[3] = ILPVault.release.selector;
        vaultSelectors[4] = ILPVault.collectFees.selector;
        am.setTargetFunctionRole(address(vault), vaultSelectors, ADAPTER_ROLE);
        bytes4[] memory unwind = new bytes4[](1);
        unwind[0] = ILPVault.unwind.selector;
        am.setTargetFunctionRole(address(vault), unwind, LIQUIDATION_ROLE);
        bytes4[] memory tokenSelectors = new bytes4[](2);
        tokenSelectors[0] = IVaultToken.mint.selector;
        tokenSelectors[1] = IVaultToken.addValidProxy.selector;
        bytes4[] memory burn = new bytes4[](1);
        burn[0] = IVaultToken.burn.selector;
        for (uint256 i; i < 2; ++i) {
            address vt = i == 0 ? address(vtFull) : address(vtCustom);
            am.setTargetFunctionRole(vt, tokenSelectors, ADAPTER_ROLE);
            // `burn` has one role, held by both the adapter (withdrawals) and the module (seized units).
            am.setTargetFunctionRole(vt, burn, BURN_ROLE);
        }
        am.grantRole(ADAPTER_ROLE, address(adapter), 0);
        am.grantRole(BURN_ROLE, address(adapter), 0);
        am.grantRole(BURN_ROLE, address(module), 0);
        am.grantRole(LIQUIDATION_ROLE, address(module), 0);
    }

    function _params(
        string memory tag,
        uint256 marketId
    ) internal view returns (IVaultToken.Params memory) {
        return IVaultToken.Params({
            name: string.concat("Avana T0/T1 ", tag),
            symbol: string.concat("avT-", tag),
            decimals: 18,
            marketId: marketId,
            hub: address(hub),
            liquidationModule: address(module),
            authority: address(am)
        });
    }

    function _market(
        uint256 reserveId,
        int24 lower,
        int24 upper,
        IRiskModule.MarketKind kind,
        VaultToken vt
    ) internal returns (IRiskModule.Market memory m) {
        m.pool = POOL;
        m.spoke = address(spoke);
        m.vaultToken = address(vt);
        m.lpOracle = address(new LPOracle(_oracleParams(reserveId)));
        m.reserveId = reserveId;
        (m.priceReserveId0, m.priceReserveId1) = (priceReserve0, priceReserve1);
        m.bandLower = lower;
        m.bandUpper = upper;
        m.ltvBps = uint16(CF_BPS);
        m.unitDecimals = 18;
        m.kind = kind;
        m.active = true;
    }

    function _oracleParams(
        uint256 marketId
    ) internal view returns (ILPOracle.Params memory p) {
        p.lpVault = address(vault);
        p.marketId = marketId;
        p.unitDecimals = 18;
        p.priceSpoke = address(priceSpoke);
        p.reserveId0 = priceReserve0;
        p.reserveId1 = priceReserve1;
        p.description = "Avana T0/T1 band unit";
    }

    // ─── Helpers ───

    function _mint(
        address to,
        int24 lower,
        int24 upper,
        uint128 liquidity
    ) internal returns (bytes32) {
        return bytes32(pm.mint(to, POOL, lower, upper, liquidity));
    }

    function _pledge(
        address wallet,
        bytes32 key
    ) internal returns (uint256 marketId, uint128 credit) {
        vm.prank(wallet);
        return adapter.pledge(key);
    }

    function _borrow(
        address wallet,
        uint256 marketId,
        uint256 amount
    ) internal {
        vm.prank(wallet);
        adapter.borrow(marketId, DEBT_RESERVE, amount, wallet);
    }

    function _account(
        address wallet,
        uint256 marketId
    ) internal view returns (address) {
        return adapter.accountOf(wallet, marketId);
    }

    /// @notice Pledges `key`, borrows `borrowBps` of the borrowing power, then lowers the collateral factor to `cfAfter`.
    function _openUnhealthy(
        address wallet,
        bytes32 key,
        uint256 borrowBps,
        uint256 cfAfter
    ) internal returns (uint256 marketId, address account) {
        uint128 credit;
        (marketId, credit) = _pledge(wallet, key);
        _borrow(wallet, marketId, uint256(credit) * CF_BPS / 10_000 * borrowBps / 10_000);
        spoke.setCf(marketId, cfAfter);
        account = _account(wallet, marketId);
    }

    function _liquidate(
        uint256 marketId,
        address account,
        uint256 debtToCover
    ) internal returns (ILiquidationModule.LiquidationResult memory r) {
        vm.prank(liquidator);
        r = module.liquidate(
            ILiquidationModule.LiquidationParams({
                marketId: marketId,
                debtReserveId: DEBT_RESERVE,
                account: account,
                debtToCover: debtToCover,
                minAmount0: 0,
                minAmount1: 0,
                receiver: liquidator
            })
        );
    }
}
