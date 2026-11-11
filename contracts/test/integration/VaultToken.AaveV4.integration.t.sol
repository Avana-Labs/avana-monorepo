// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {VaultTokenBindings} from "../../src/types/VaultTokenBindings.sol";
import {IVaultToken} from "../../src/vault-token/vault-token/IVaultToken.sol";
import {VaultToken} from "../../src/vault-token/vault-token/VaultToken.sol";
import {AaveV4Fixture} from "../utils/fixtures/AaveV4Fixture.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Hub `SpokeConfig` of aave-v4 a3ef63e.
struct HubSpokeConfig {
    uint40 addCap;
    uint40 drawCap;
    uint24 riskPremiumThreshold;
    bool active;
    bool halted;
}

/// @dev Spoke `ReserveConfig` of aave-v4 a3ef63e.
struct SpokeReserveConfig {
    uint24 collateralRisk;
    bool paused;
    bool frozen;
    bool borrowable;
    bool receiveSharesEnabled;
}

/// @dev Spoke `DynamicReserveConfig` of aave-v4 a3ef63e.
struct SpokeDynamicReserveConfig {
    uint16 collateralFactor;
    uint32 maxLiquidationBonus;
    uint16 liquidationFee;
}

/// @dev Spoke `LiquidationConfig` of aave-v4 a3ef63e.
struct SpokeLiquidationConfig {
    uint128 targetHealthFactor;
    uint64 healthFactorForMaxBonus;
    uint16 liquidationBonusFactor;
}

/// @dev `AssetInterestRateStrategy.InterestRateData` of aave-v4 a3ef63e.
struct InterestRateData {
    uint16 optimalUsageRatio;
    uint32 baseDrawnRate;
    uint32 rateGrowthBeforeOptimal;
    uint32 rateGrowthAfterOptimal;
}

interface IHubConfiguratorCalls {
    function addAssetWithDecimals(
        address hub,
        address underlying,
        uint8 decimals,
        address feeReceiver,
        uint256 liquidityFee,
        address irStrategy,
        bytes calldata irData
    ) external returns (uint256);
    function addSpoke(
        address hub,
        address spoke,
        uint256 assetId,
        HubSpokeConfig calldata config
    ) external;
}

interface ISpokeConfiguratorCalls {
    function addReserve(
        address spoke,
        address hub,
        uint256 assetId,
        address priceSource,
        SpokeReserveConfig calldata config,
        SpokeDynamicReserveConfig calldata dynamicConfig
    ) external returns (uint256);
    function updateLiquidationConfig(
        address spoke,
        SpokeLiquidationConfig calldata config
    ) external;
}

/// @notice 8-decimal price source the AaveOracle reads with `latestAnswer`.
contract VaultTokenTestPriceSource {
    int256 public latestAnswer;

    constructor(
        int256 answer
    ) {
        latestAnswer = answer;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function set(
        int256 answer
    ) external {
        latestAnswer = answer;
    }
}

/// @notice 18-decimal debt asset with an open mint, standing in for GHO.
contract VaultTokenTestDebtAsset is ERC20 {
    constructor() ERC20("Debt", "DEBT") {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }
}

/// @title VaultTokenAaveV4Base
/// @notice The vault token listed as a collateral reserve of the standard CDP Spoke on the real local Aave V4 (pinned
/// release), with one proxy, one debt asset and the 2.1 listing settings; `liquidationFeeBps` is the reserve's fee.
/// @dev The AaveAdapter and LPVaultSwap are pranked addresses; the proxy is a pranked address registered by the Adapter.
abstract contract VaultTokenAaveV4Base is AaveV4Fixture {
    uint8 internal constant VT_DECIMALS = 6;
    uint256 internal constant UNITS = 5_000_000_000; // 5,000 whole tokens at $2.00
    uint256 internal constant BORROWED = 7000e18;

    address internal adapter = makeAddr("aaveAdapter");
    address internal lpVaultSwap = makeAddr("lpVaultSwap");
    address internal proxy = makeAddr("proxy");

    VaultToken internal token;
    VaultTokenTestDebtAsset internal debt;
    VaultTokenTestPriceSource internal vtPrice;
    VaultTokenTestPriceSource internal debtPrice;
    uint256 internal vtReserveId;
    uint256 internal debtReserveId;
    /// @dev Liquidation fee of the vault-token reserve: 0, the only listed value; the fee suite sets 10% to show why.
    uint16 internal liquidationFeeBps;

    function setUp() public virtual {
        _deployAaveV4();
        token = new VaultToken(
            VaultTokenBindings({
                marketKey: keccak256("avana.test.market.usdc-usdt.full-range"),
                integrationId: 1,
                integration: makeAddr("lpVault"),
                hub: aave.hub,
                spoke: aave.cdpSpoke,
                marketId: 1,
                lpOracle: makeAddr("lpOracle"),
                adapter: adapter,
                lpVaultSwap: lpVaultSwap,
                collateralization: makeAddr("collateralization"),
                decimals: VT_DECIMALS,
                name: "Avana USDC/USDT Uniswap v3 Full Range",
                symbol: "avUSDC-USDT-v3"
            })
        );
        debt = new VaultTokenTestDebtAsset();
        vtPrice = new VaultTokenTestPriceSource(2e8);
        debtPrice = new VaultTokenTestPriceSource(1e8);
        _listReserves();
    }

    // ─── Setup ───

    function _vtAssetId() internal view returns (uint256) {
        return IAaveV4Hub(aave.hub).getAssetId(address(token));
    }

    function _pledge() internal {
        vm.startPrank(adapter);
        token.addValidProxy(proxy);
        token.mint(proxy, UNITS);
        vm.stopPrank();
        vm.startPrank(proxy);
        vm.expectEmit(address(token));
        emit IERC20.Approval(proxy, aave.cdpSpoke, UNITS);
        token.approve(aave.cdpSpoke, UNITS);
        vm.expectEmit(address(token));
        emit IERC20.Transfer(proxy, aave.hub, UNITS);
        IAaveV4Spoke(aave.cdpSpoke).supply(vtReserveId, UNITS, proxy);
        vm.stopPrank();
    }

    /// @dev $10,000 of collateral at CF 80%, 7,000 borrowed; the price falls to $1.50 per whole token, so the
    /// collateral counts for $6,000 and the health factor is about 0.86.
    function _pledgeAndBorrowUnderwater() internal {
        _pledge();
        vm.startPrank(proxy);
        IAaveV4Spoke(aave.cdpSpoke).setUsingAsCollateral(vtReserveId, true, proxy);
        IAaveV4Spoke(aave.cdpSpoke).borrow(debtReserveId, BORROWED, proxy);
        vm.stopPrank();
        vtPrice.set(1.5e8);
    }

    function _listReserves() internal {
        IAaveV4Hub hubView = IAaveV4Hub(aave.hub);
        uint40 maxCap = hubView.MAX_ALLOWED_SPOKE_CAP();
        uint24 maxRp = hubView.MAX_RISK_PREMIUM_THRESHOLD();
        bytes memory irData = abi.encode(InterestRateData(9000, 0, 400, 6000));
        IHubConfiguratorCalls hubCfg = IHubConfiguratorCalls(aave.hubConfigurator);
        ISpokeConfiguratorCalls spokeCfg = ISpokeConfiguratorCalls(aave.spokeConfigurator);

        vm.startPrank(aaveDao);
        // Debt asset: supplied through the Lend Spoke, drawn by the CDP Spoke.
        uint256 debtAssetId =
            hubCfg.addAssetWithDecimals(aave.hub, address(debt), 18, aave.treasurySpoke, 0, aave.irStrategy, irData);
        hubCfg.addSpoke(aave.hub, aave.lendSpoke, debtAssetId, HubSpokeConfig(maxCap, 0, maxRp, true, false));
        hubCfg.addSpoke(aave.hub, aave.cdpSpoke, debtAssetId, HubSpokeConfig(0, 1_000_000, maxRp, true, false));
        uint256 lendReserveId = spokeCfg.addReserve(
            aave.lendSpoke,
            aave.hub,
            debtAssetId,
            address(debtPrice),
            SpokeReserveConfig(0, false, false, true, false),
            SpokeDynamicReserveConfig(0, 10_000, 0)
        );
        debtReserveId = spokeCfg.addReserve(
            aave.cdpSpoke,
            aave.hub,
            debtAssetId,
            address(debtPrice),
            SpokeReserveConfig(0, false, false, true, false),
            SpokeDynamicReserveConfig(0, 10_000, 0)
        );
        // Vault-token asset: CDP Spoke only, addCap 5,500,000 whole tokens, drawCap 0, not borrowable, no shares.
        uint256 vtAssetId = hubCfg.addAssetWithDecimals(
            aave.hub, address(token), VT_DECIMALS, aave.treasurySpoke, 0, aave.irStrategy, irData
        );
        hubCfg.addSpoke(aave.hub, aave.cdpSpoke, vtAssetId, HubSpokeConfig(5_500_000, 0, maxRp, true, false));
        vtReserveId = spokeCfg.addReserve(
            aave.cdpSpoke,
            aave.hub,
            vtAssetId,
            address(vtPrice),
            SpokeReserveConfig(0, false, false, false, false),
            SpokeDynamicReserveConfig(8000, 10_500, liquidationFeeBps)
        );
        spokeCfg.updateLiquidationConfig(aave.cdpSpoke, SpokeLiquidationConfig(1.1e18, 0.95e18, 5000));
        vm.stopPrank();

        // Credit line supplied through the Lend Spoke.
        debt.mint(daoTreasury, 100_000e18);
        vm.startPrank(daoTreasury);
        debt.approve(aave.lendSpoke, 100_000e18);
        IAaveV4Spoke(aave.lendSpoke).supply(lendReserveId, 100_000e18, daoTreasury);
        vm.stopPrank();
    }
}

/// @title VaultTokenAaveV4IntegrationTest
/// @notice The vault token listed as a collateral reserve of the standard CDP Spoke on the real local Aave V4 (pinned
/// release): `Spoke.supply` moves units proxy → Hub through `transferFrom` on the proxy's exact allowance,
/// `Spoke.withdraw` pays the proxy from the Hub, and `Spoke.liquidationCall` with `receiveShares = false` pays the
/// liquidator from the Hub, so every liquidator other than LPVaultSwap reverts on the token transfer.
/// @dev The AaveAdapter and LPVaultSwap are pranked addresses (their contracts come later); the proxy is a pranked
/// address registered by the Adapter. The listing follows the 2.1 required settings of a vault-token reserve
/// (`receiveSharesEnabled = false`, `liquidationFee = 0`, not borrowable, no reinvestment controller, `drawCap = 0`).
contract VaultTokenAaveV4IntegrationTest is VaultTokenAaveV4Base {
    // TEST-022 verifies: REQ-VTOKEN-006, REQ-VTOKEN-009, REQ-VTOKEN-010, REQ-VTOKEN-018, INV-011, Q-119, Q-224
    // Sources: 5.1 TEST-022, 2.4 REQ-VTOKEN-010
    /// @notice Pledge and withdrawal on the real Spoke and Hub: `Approval(proxy, spoke, n)` then
    /// `Transfer(proxy, hub, n)` on supply, the Hub's balance equals its recorded liquidity, and `Spoke.withdraw` pays
    /// the proxy from the Hub before the Adapter burns the units.
    function test_TEST_022_supplyAndWithdrawThroughAaveV4() public {
        _pledge();
        assertEq(token.balanceOf(aave.hub), UNITS, "hub balance");
        assertEq(IAaveV4Hub(aave.hub).getAssetLiquidity(_vtAssetId()), UNITS, "hub liquidity");
        assertEq(IAaveV4Spoke(aave.cdpSpoke).getUserSuppliedShares(vtReserveId, proxy), UNITS, "supplied shares");
        assertEq(token.balanceOf(proxy), 0, "proxy keeps units");
        assertEq(token.allowance(proxy, aave.cdpSpoke), 0, "allowance left");

        vm.expectEmit(address(token));
        emit IERC20.Transfer(aave.hub, proxy, 1_000_000_000);
        vm.prank(proxy);
        IAaveV4Spoke(aave.cdpSpoke).withdraw(vtReserveId, 1_000_000_000, proxy);
        vm.prank(adapter);
        token.burn(proxy, 1_000_000_000);
        assertEq(token.totalSupply(), UNITS - 1_000_000_000, "supply");
        assertEq(token.balanceOf(aave.hub), IAaveV4Hub(aave.hub).getAssetLiquidity(_vtAssetId()), "hub = liquidity");
    }

    // TEST-189 verifies: REQ-VTOKEN-006, REQ-VTOKEN-025, REQ-VTOKEN-026, REQ-VTOKEN-030, INV-011, ATTACK-002, ATTACK-181, Q-116, Q-224, Q-300
    // Sources: 5.1 TEST-189, TEST-180 (token side), 3.5 LIQ-F-047
    /// @notice A third party's `liquidationCall(…, false)` on an account below HF 1 reverts on the Hub's transfer of
    /// the seized units; the account's debt and supplied shares are unchanged.
    function test_TEST_189_thirdPartyLiquidationRevertsOnTokenTransfer() public {
        _pledgeAndBorrowUnderwater();
        uint256 sharesBefore = IAaveV4Spoke(aave.cdpSpoke).getUserSuppliedShares(vtReserveId, proxy);
        debt.mint(attacker, 1000e18);
        vm.startPrank(attacker);
        debt.approve(aave.cdpSpoke, 1000e18);
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, aave.hub, attacker));
        IAaveV4Spoke(aave.cdpSpoke).liquidationCall(vtReserveId, debtReserveId, proxy, 1000e18, false);
        vm.stopPrank();
        assertEq(IAaveV4Spoke(aave.cdpSpoke).getUserSuppliedShares(vtReserveId, proxy), sharesBefore, "shares");
        assertEq(token.balanceOf(attacker), 0, "attacker holds units");
    }

    // TEST-189 verifies: REQ-VTOKEN-006, REQ-VTOKEN-041, INV-011, ATTACK-023, Q-224, Q-300
    /// @notice The Adapter, as liquidator, is refused like any third party.
    function test_TEST_189_adapterLiquidationRevertsOnTokenTransfer() public {
        _pledgeAndBorrowUnderwater();
        debt.mint(adapter, 1000e18);
        vm.startPrank(adapter);
        debt.approve(aave.cdpSpoke, 1000e18);
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, aave.hub, adapter));
        IAaveV4Spoke(aave.cdpSpoke).liquidationCall(vtReserveId, debtReserveId, proxy, 1000e18, false);
        vm.stopPrank();
    }

    // TEST-022 verifies: REQ-VTOKEN-006, REQ-VTOKEN-014, REQ-VTOKEN-017, INV-010, INV-011, Q-116, Q-255
    /// @notice LPVaultSwap's `liquidationCall(…, false)` receives the seized units from the Hub; the share drop equals
    /// the units received, and the Adapter's burn from LPVaultSwap retires them.
    function test_TEST_022_lpVaultSwapLiquidationReceivesSeizedUnits() public {
        _pledgeAndBorrowUnderwater();
        uint256 sharesBefore = IAaveV4Spoke(aave.cdpSpoke).getUserSuppliedShares(vtReserveId, proxy);
        debt.mint(lpVaultSwap, 1000e18);
        vm.startPrank(lpVaultSwap);
        debt.approve(aave.cdpSpoke, 1000e18);
        IAaveV4Spoke(aave.cdpSpoke).liquidationCall(vtReserveId, debtReserveId, proxy, 1000e18, false);
        vm.stopPrank();
        uint256 seized = token.balanceOf(lpVaultSwap);
        assertGt(seized, 0, "nothing seized");
        assertEq(
            sharesBefore - IAaveV4Spoke(aave.cdpSpoke).getUserSuppliedShares(vtReserveId, proxy), seized, "share drop"
        );
        vm.prank(adapter);
        token.burn(lpVaultSwap, seized);
        assertEq(token.totalSupply(), UNITS - seized, "supply");
        assertEq(token.balanceOf(aave.hub), IAaveV4Hub(aave.hub).getAssetLiquidity(_vtAssetId()), "hub = liquidity");
    }

    // TEST-189 verifies: REQ-VTOKEN-025, INV-013, INV-041, ATTACK-028
    /// @notice A third party's liquidation sized so its seizure rounds to zero shares succeeds: Aave skips the Hub
    /// transfer, so the token has nothing to refuse. No unit moves and no share leaves the borrower; the caller only
    /// repays part of the borrower's debt at its own expense.
    function test_TEST_189_dustThirdPartyLiquidationSeizesNothing() public {
        _pledgeAndBorrowUnderwater();
        uint256 sharesBefore = IAaveV4Spoke(aave.cdpSpoke).getUserSuppliedShares(vtReserveId, proxy);
        uint256 debtBefore = IAaveV4Spoke(aave.cdpSpoke).getUserTotalDebt(debtReserveId, proxy);
        debt.mint(attacker, 1e12);
        vm.startPrank(attacker);
        debt.approve(aave.cdpSpoke, 1e12);
        IAaveV4Spoke(aave.cdpSpoke).liquidationCall(vtReserveId, debtReserveId, proxy, 1e12, false);
        vm.stopPrank();
        assertEq(IAaveV4Spoke(aave.cdpSpoke).getUserSuppliedShares(vtReserveId, proxy), sharesBefore, "shares");
        assertLt(IAaveV4Spoke(aave.cdpSpoke).getUserTotalDebt(debtReserveId, proxy), debtBefore, "debt");
        assertEq(token.balanceOf(attacker), 0, "attacker holds units");
        assertEq(token.balanceOf(aave.hub), UNITS, "hub");
        assertEq(token.totalSupply(), UNITS, "supply");
    }

    // TEST-189 verifies: REQ-VTOKEN-013, INV-009, ATTACK-022
    /// @notice The registry bounds seizure only as far as the Adapter's registrations do: an address the Adapter
    /// registered receives seized units from the Hub like a proxy, which is why a reviewed Adapter registers only the
    /// proxies it deploys and a proxy has no `liquidationCall` path.
    function test_TEST_189_registeredAddressCanReceiveSeizure() public {
        _pledgeAndBorrowUnderwater();
        vm.prank(adapter);
        token.addValidProxy(attacker);
        debt.mint(attacker, 1000e18);
        vm.startPrank(attacker);
        debt.approve(aave.cdpSpoke, 1000e18);
        IAaveV4Spoke(aave.cdpSpoke).liquidationCall(vtReserveId, debtReserveId, proxy, 1000e18, false);
        vm.stopPrank();
        assertGt(token.balanceOf(attacker), 0, "registered address seized nothing");
    }

    // TEST-189 verifies: REQ-VTOKEN-008, REQ-VTOKEN-048, INV-011
    /// @notice On the real Spoke a zero `transferFrom(proxy, hub, 0)` by anyone reverts, so no zero `Transfer` from a
    /// proxy is ever emitted outside a supply.
    function test_TEST_189_zeroTransferFromByAnyoneReverts() public {
        _pledge();
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, proxy, aave.hub));
        token.transferFrom(proxy, aave.hub, 0);
    }
}

/// @title VaultTokenAaveV4LiquidationFeeIntegrationTest
/// @notice Why every vault-token reserve has `liquidationFee = 0` with no alternative: with a 10% fee on the real
/// local Aave V4, Aave pays the fee as Hub shares moved to the fee receiver with no token transfer. A third party's
/// fee-only liquidation then succeeds and moves the borrower's shares without any unit leaving the Hub, and in
/// LPVaultSwap's own liquidation the share drop exceeds the units it receives, so the fee units stay in the Hub for
/// good: the fee receiver can never withdraw them (the Hub can pay only registered proxies and LPVaultSwap).
/// @dev Same listing as the base suite except the fee. The drift check that refuses such a reserve is the RiskModule's
/// (`TEST-268`); this suite shows the Aave behaviour that makes 0 the only listed value.
contract VaultTokenAaveV4LiquidationFeeIntegrationTest is VaultTokenAaveV4Base {
    function setUp() public override {
        liquidationFeeBps = 1000;
        super.setUp();
    }

    // TEST-185 verifies: REQ-VTOKEN-006, REQ-VTOKEN-025, INV-093, ATTACK-014
    /// @notice A third party's 1-share liquidations pay the whole share as fee: 50 calls move 50 of the borrower's
    /// shares to the fee receiver, no unit moves and the supply is unchanged.
    function test_TEST_185_feeOnlyThirdPartyLiquidationMovesSharesWithoutTokens() public {
        _pledgeAndBorrowUnderwater();
        uint256 assetId = _vtAssetId();
        uint256 sharesBefore = IAaveV4Spoke(aave.cdpSpoke).getUserSuppliedShares(vtReserveId, proxy);
        uint256 feeSharesBefore = IAaveV4Hub(aave.hub).getSpokeAddedShares(assetId, aave.treasurySpoke);
        debt.mint(attacker, 1e18);
        vm.startPrank(attacker);
        debt.approve(aave.cdpSpoke, 1e18);
        for (uint256 i = 0; i < 50; ++i) {
            IAaveV4Spoke(aave.cdpSpoke).liquidationCall(vtReserveId, debtReserveId, proxy, 2e12, false);
        }
        vm.stopPrank();
        assertEq(sharesBefore - IAaveV4Spoke(aave.cdpSpoke).getUserSuppliedShares(vtReserveId, proxy), 50, "shares");
        assertEq(
            IAaveV4Hub(aave.hub).getSpokeAddedShares(assetId, aave.treasurySpoke) - feeSharesBefore, 50, "fee shares"
        );
        assertEq(token.balanceOf(attacker), 0, "units moved");
        assertEq(token.totalSupply(), UNITS, "supply");
    }

    // TEST-185 verifies: REQ-VTOKEN-025, INV-008, INV-093, ATTACK-014
    /// @notice In LPVaultSwap's liquidation with a fee the borrower's share drop exceeds the units LPVaultSwap
    /// receives; the difference stays in the Hub as fee-receiver shares that no unit can ever leave the Hub for.
    function test_TEST_185_feeLeavesUnitsLPVaultSwapCanNeverBurn() public {
        _pledgeAndBorrowUnderwater();
        uint256 sharesBefore = IAaveV4Spoke(aave.cdpSpoke).getUserSuppliedShares(vtReserveId, proxy);
        debt.mint(lpVaultSwap, 1000e18);
        vm.startPrank(lpVaultSwap);
        debt.approve(aave.cdpSpoke, 1000e18);
        IAaveV4Spoke(aave.cdpSpoke).liquidationCall(vtReserveId, debtReserveId, proxy, 1000e18, false);
        vm.stopPrank();
        uint256 drop = sharesBefore - IAaveV4Spoke(aave.cdpSpoke).getUserSuppliedShares(vtReserveId, proxy);
        uint256 seized = token.balanceOf(lpVaultSwap);
        assertGt(drop, seized, "fee units left the borrower without reaching LPVaultSwap");
        uint256 feeShares = IAaveV4Hub(aave.hub).getSpokeAddedShares(_vtAssetId(), aave.treasurySpoke);
        assertEq(drop - seized, feeShares, "fee receiver holds the difference");
        // The fee receiver's units can never leave the Hub: the Hub may pay only registered proxies and LPVaultSwap.
        assertFalse(token.isAllowedRecipient(aave.treasurySpoke), "fee receiver can hold units");
    }
}
