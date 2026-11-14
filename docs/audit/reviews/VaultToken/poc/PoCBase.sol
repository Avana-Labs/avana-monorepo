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

/// @title VaultTokenAaveV4IntegrationTest
/// @notice The vault token listed as a collateral reserve of the standard CDP Spoke on the real local Aave V4 (pinned
/// release): `Spoke.supply` moves units proxy → Hub through `transferFrom` on the proxy's exact allowance,
/// `Spoke.withdraw` pays the proxy from the Hub, and `Spoke.liquidationCall` with `receiveShares = false` pays the
/// liquidator from the Hub, so every liquidator other than LPVaultSwap reverts on the token transfer.
/// @dev The AaveAdapter and LPVaultSwap are pranked addresses (their contracts come later); the proxy is a pranked
/// address registered by the Adapter. The listing follows the 2.1 required settings of a vault-token reserve
/// (`receiveSharesEnabled = false`, `liquidationFee = 0`, not borrowable, no reinvestment controller, `drawCap = 0`).
contract VaultTokenPoCBase is AaveV4Fixture {
    uint8 internal constant VT_DECIMALS = 6;
    uint16 internal LIQ_FEE;
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
            SpokeDynamicReserveConfig(8000, 10_500, LIQ_FEE)
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
