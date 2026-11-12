// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralization} from "../../../src/custody/collateralization/ICollateralization.sol";
import {BackingRecord} from "../../../src/custody/collateralization/types/BackingRecord.sol";
import {IAaveV4Hub} from "../../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {Lock} from "../../../src/lock/lock/Lock.sol";
import {PositionShape} from "../../../src/types/PositionShape.sol";
import {ShapeKind} from "../../../src/types/ShapeKind.sol";
import {VaultTokenFactory} from "../../../src/vault-token/vault-token-factory/VaultTokenFactory.sol";
import {VaultToken} from "../../../src/vault-token/vault-token/VaultToken.sol";
import {CollLPVaultMock, CollOracleMock, CollPoolToken, CollRiskModuleMock} from "../mocks/CollateralizationMocks.sol";
import {AaveV4Fixture} from "./AaveV4Fixture.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Hub `SpokeConfig` of aave-v4 a3ef63e.
struct CollHubSpokeConfig {
    uint40 addCap;
    uint40 drawCap;
    uint24 riskPremiumThreshold;
    bool active;
    bool halted;
}

/// @dev Spoke `ReserveConfig` of aave-v4 a3ef63e.
struct CollSpokeReserveConfig {
    uint24 collateralRisk;
    bool paused;
    bool frozen;
    bool borrowable;
    bool receiveSharesEnabled;
}

/// @dev Spoke `DynamicReserveConfig` of aave-v4 a3ef63e.
struct CollSpokeDynamicReserveConfig {
    uint16 collateralFactor;
    uint32 maxLiquidationBonus;
    uint16 liquidationFee;
}

/// @dev Spoke `LiquidationConfig` of aave-v4 a3ef63e.
struct CollSpokeLiquidationConfig {
    uint128 targetHealthFactor;
    uint64 healthFactorForMaxBonus;
    uint16 liquidationBonusFactor;
}

/// @dev `AssetInterestRateStrategy.InterestRateData` of aave-v4 a3ef63e.
struct CollInterestRateData {
    uint16 optimalUsageRatio;
    uint32 baseDrawnRate;
    uint32 rateGrowthBeforeOptimal;
    uint32 rateGrowthAfterOptimal;
}

interface ICollHubConfigurator {
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
        CollHubSpokeConfig calldata config
    ) external;
}

interface ICollSpokeConfigurator {
    function addReserve(
        address spoke,
        address hub,
        uint256 assetId,
        address priceSource,
        CollSpokeReserveConfig calldata config,
        CollSpokeDynamicReserveConfig calldata dynamicConfig
    ) external returns (uint256);
    function updateLiquidationConfig(
        address spoke,
        CollSpokeLiquidationConfig calldata config
    ) external;
}

/// @notice 8-decimal price source the AaveOracle reads with `latestAnswer`.
contract CollPriceSource {
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

/// @title CollateralizationFixture
/// @notice Collateralization on the real local Aave V4 (pinned release), with the real Lock, the real
/// VaultTokenFactory and the real vault token of one USDC/USDT market (integration 1, market 4, 6 decimals). The
/// LPVault, RiskModule and LPOracle are mocks (stand-ins in these tests); the AaveAdapter and
/// LPVaultSwap are pranked addresses, the two members of the Lock.
/// @dev Suites set `isolate = false` so one test is one transaction: each helper takes the Lock as its member, runs one
/// Avana call tree and releases the Lock, as the member's outer entry point would.
abstract contract CollateralizationFixture is AaveV4Fixture {
    uint32 internal constant INTEGRATION = 1;
    uint256 internal constant MARKET_ID = 4;
    uint8 internal constant VT_DECIMALS = 6;
    uint256 internal constant BORROW_CAP = 1_000_000;

    address internal adapter = makeAddr("aaveAdapter");
    address internal lpVaultSwap = makeAddr("lpVaultSwap");
    address internal timelock = makeAddr("timelock");
    /// @dev The MarketRegistry every registered LPVault names; the same label as the Uniswap v3 suite's registry.
    address internal marketRegistry = makeAddr("marketRegistry");
    address internal pool = makeAddr("usdcUsdtPool");
    address internal aliceProxy = makeAddr("aliceProxy");
    address internal bobProxy = makeAddr("bobProxy");

    Lock internal lock;
    VaultTokenFactory internal factory;
    ICollateralization internal coll;
    CollLPVaultMock internal lpVault;
    CollRiskModuleMock internal riskModule;
    CollOracleMock internal oracle;
    CollPoolToken internal usdc;
    CollPoolToken internal usdt;
    VaultToken internal token;
    address internal vt;
    CollPoolToken internal debt;
    CollPriceSource internal vtPrice;
    CollPriceSource internal debtPrice;
    uint256 internal vtReserveId;
    uint256 internal debtReserveId;
    uint256 internal vtAssetId;
    /// @notice Market tokens after USDC and USDT (0 by default; a suite sets it before `_deployCollateralization` for
    /// a market of up to 8 tokens). Each is 18 decimals and pays 1.0 raw token per unit.
    uint256 internal extraTokenCount;
    CollPoolToken[] internal extraTokens;

    function _deployCollateralization() internal {
        _deployAaveV4();
        lock = new Lock(adapter, lpVaultSwap);
        riskModule = new CollRiskModuleMock();
        oracle = new CollOracleMock();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        factory = new VaultTokenFactory(adapter, lpVaultSwap, predicted, timelock, marketRegistry);
        coll = ICollateralization(
            deployCode(
                "Collateralization.sol:Collateralization",
                abi.encode(adapter, lpVaultSwap, address(riskModule), address(lock), address(factory))
            )
        );
        require(address(coll) == predicted, "predicted Collateralization");
        lpVault = new CollLPVaultMock(INTEGRATION, address(coll), address(lock));
        lpVault.setCore(timelock, marketRegistry);
        vm.prank(timelock);
        factory.registerIntegration(INTEGRATION, address(lpVault));

        usdc = new CollPoolToken("USDC", 6);
        usdt = new CollPoolToken("USDT", 6);
        address[] memory tokens = new address[](2 + extraTokenCount);
        tokens[0] = address(usdc);
        tokens[1] = address(usdt);
        uint256[] memory rates = new uint256[](2 + extraTokenCount);
        rates[0] = 800_000; // 0.8 raw USDC per unit
        rates[1] = 1_250_000; // 1.25 raw USDT per unit
        for (uint256 i = 0; i < extraTokenCount; ++i) {
            CollPoolToken t = new CollPoolToken("T", 18);
            t.mint(address(lpVault), 1e30);
            extraTokens.push(t);
            tokens[2 + i] = address(t);
            rates[2 + i] = 1_000_000;
        }
        lpVault.bind(MARKET_ID, pool, tokens, rates);
        usdc.mint(address(lpVault), 1e30);
        usdt.mint(address(lpVault), 1e30);

        vm.prank(timelock);
        vt = factory.deployVaultToken(
            INTEGRATION,
            pool,
            bytes32(0),
            PositionShape(ShapeKind.TickRange, -50, 50),
            aave.hub,
            aave.cdpSpoke,
            MARKET_ID,
            address(oracle),
            VT_DECIMALS,
            "Avana USDC/USDT",
            "avUSDC-USDT"
        );
        token = VaultToken(vt);
        debt = new CollPoolToken("GHO", 18);
        vtPrice = new CollPriceSource(2e8);
        debtPrice = new CollPriceSource(1e8);
        _listReserves();
        _labels();
    }

    // ─── Flows (one Avana call tree each) ───

    function _pledge(
        address depositor,
        address proxy,
        bytes32 key,
        uint128 units
    ) internal returns (uint256 id) {
        lpVault.mintPosition(key, depositor, MARKET_ID, units);
        vm.startPrank(adapter);
        lock.acquire();
        if (!token.isValidProxy(proxy)) token.addValidProxy(proxy);
        uint128 credited;
        (id, credited) = coll.pledge(depositor, proxy, vt, key, false);
        token.mint(proxy, credited);
        vm.stopPrank();
        _supply(proxy, credited);
        vm.prank(adapter);
        lock.release();
    }

    function _supply(
        address proxy,
        uint256 units
    ) internal {
        vm.startPrank(proxy);
        token.approve(aave.cdpSpoke, units);
        IAaveV4Spoke(aave.cdpSpoke).supply(vtReserveId, units, proxy);
        IAaveV4Spoke(aave.cdpSpoke).setUsingAsCollateral(vtReserveId, true, proxy);
        vm.stopPrank();
    }

    /// @notice The Adapter's withdrawal: the proxy withdraws `units`, the Adapter burns them and calls `release`.
    function _withdraw(
        address proxy,
        bytes32 key,
        uint256 units
    ) internal {
        vm.prank(adapter);
        lock.acquire();
        _withdrawAndBurn(proxy, units);
        vm.startPrank(adapter);
        coll.release(proxy, vt, key, units);
        lock.release();
        vm.stopPrank();
    }

    function _withdrawAndBurn(
        address proxy,
        uint256 units
    ) internal {
        if (units == 0) return;
        vm.prank(proxy);
        IAaveV4Spoke(aave.cdpSpoke).withdraw(vtReserveId, units, proxy);
        vm.prank(adapter);
        token.burn(proxy, units);
    }

    function _borrow(
        address proxy,
        uint256 amount
    ) internal {
        vm.prank(proxy);
        IAaveV4Spoke(aave.cdpSpoke).borrow(debtReserveId, amount, proxy);
    }

    /// @notice A liquidation by LPVaultSwap that keeps the seized units and never calls Collateralization (a
    /// non-conforming implementation). Returns the units seized.
    function _seizeAndKeep(
        address proxy,
        uint256 debtToCover
    ) internal returns (uint256 seized) {
        uint256 before = token.balanceOf(lpVaultSwap);
        debt.mint(lpVaultSwap, debtToCover);
        vm.startPrank(lpVaultSwap);
        debt.approve(aave.cdpSpoke, debtToCover);
        IAaveV4Spoke(aave.cdpSpoke).liquidationCall(vtReserveId, debtReserveId, proxy, debtToCover, false);
        vm.stopPrank();
        seized = token.balanceOf(lpVaultSwap) - before;
    }

    /// @notice An honest LPVaultSwap liquidation: snapshot, liquidation, burn, settlement, one Lock session.
    function _liquidate(
        address proxy,
        uint256 debtToCover
    ) internal returns (uint256 seized, uint256[] memory amounts) {
        vm.prank(lpVaultSwap);
        lock.acquire();
        vm.prank(lpVaultSwap);
        coll.beginSeizure(proxy, vt);
        seized = _seizeAndKeep(proxy, debtToCover);
        vm.prank(adapter);
        token.burn(lpVaultSwap, seized);
        vm.startPrank(lpVaultSwap);
        amounts = coll.settleSeizure(proxy, vt, seized, new uint256[](2));
        lock.release();
        vm.stopPrank();
    }

    /// @notice LPVaultSwap's pending settlement: the Adapter burns `units` from LPVaultSwap, then `settlePending`.
    function _settlePending(
        uint256 units
    ) internal returns (uint256[] memory amounts) {
        vm.prank(lpVaultSwap);
        lock.acquire();
        vm.prank(adapter);
        token.burn(lpVaultSwap, units);
        vm.startPrank(lpVaultSwap);
        amounts = coll.settlePending(vt, units);
        lock.release();
        vm.stopPrank();
    }

    // ─── Reads ───

    function _record(
        bytes32 key
    ) internal view returns (BackingRecord memory) {
        return coll.getRecord(coll.recordIdOf(INTEGRATION, key));
    }

    function _shares(
        address proxy
    ) internal view returns (uint256) {
        return IAaveV4Spoke(aave.cdpSpoke).getUserSuppliedShares(vtReserveId, proxy);
    }

    function _gap() internal view returns (int256) {
        return int256(coll.getTotalCredited(vt)) + int256(coll.getPending(vt).units) - int256(token.totalSupply());
    }

    function _key(
        uint256 tokenId
    ) internal pure returns (bytes32) {
        return bytes32(tokenId);
    }

    // ─── Setup ───

    function _listReserves() private {
        IAaveV4Hub hubView = IAaveV4Hub(aave.hub);
        uint40 maxCap = hubView.MAX_ALLOWED_SPOKE_CAP();
        uint24 maxRp = hubView.MAX_RISK_PREMIUM_THRESHOLD();
        bytes memory irData = abi.encode(CollInterestRateData(9000, 0, 400, 6000));
        ICollHubConfigurator hubCfg = ICollHubConfigurator(aave.hubConfigurator);
        ICollSpokeConfigurator spokeCfg = ICollSpokeConfigurator(aave.spokeConfigurator);

        vm.startPrank(aaveDao);
        uint256 debtAssetId =
            hubCfg.addAssetWithDecimals(aave.hub, address(debt), 18, aave.treasurySpoke, 0, aave.irStrategy, irData);
        hubCfg.addSpoke(aave.hub, aave.lendSpoke, debtAssetId, CollHubSpokeConfig(maxCap, 0, maxRp, true, false));
        hubCfg.addSpoke(
            aave.hub, aave.cdpSpoke, debtAssetId, CollHubSpokeConfig(0, uint40(BORROW_CAP), maxRp, true, false)
        );
        uint256 lendReserveId = spokeCfg.addReserve(
            aave.lendSpoke,
            aave.hub,
            debtAssetId,
            address(debtPrice),
            CollSpokeReserveConfig(0, false, false, true, false),
            CollSpokeDynamicReserveConfig(0, 10_000, 0)
        );
        debtReserveId = spokeCfg.addReserve(
            aave.cdpSpoke,
            aave.hub,
            debtAssetId,
            address(debtPrice),
            CollSpokeReserveConfig(0, false, false, true, false),
            CollSpokeDynamicReserveConfig(0, 10_000, 0)
        );
        vtAssetId =
            hubCfg.addAssetWithDecimals(aave.hub, vt, VT_DECIMALS, aave.treasurySpoke, 0, aave.irStrategy, irData);
        hubCfg.addSpoke(aave.hub, aave.cdpSpoke, vtAssetId, CollHubSpokeConfig(5_500_000, 0, maxRp, true, false));
        vtReserveId = spokeCfg.addReserve(
            aave.cdpSpoke,
            aave.hub,
            vtAssetId,
            address(vtPrice),
            CollSpokeReserveConfig(0, false, false, false, false),
            CollSpokeDynamicReserveConfig(8000, 10_500, 0)
        );
        spokeCfg.updateLiquidationConfig(aave.cdpSpoke, CollSpokeLiquidationConfig(1.1e18, 0.95e18, 5000));
        vm.stopPrank();

        debt.mint(daoTreasury, 1_000_000e18);
        vm.startPrank(daoTreasury);
        ERC20(address(debt)).approve(aave.lendSpoke, 1_000_000e18);
        IAaveV4Spoke(aave.lendSpoke).supply(lendReserveId, 1_000_000e18, daoTreasury);
        vm.stopPrank();
    }

    function _labels() private {
        vm.label(address(coll), "Collateralization");
        vm.label(address(lock), "Lock");
        vm.label(address(factory), "VaultTokenFactory");
        vm.label(address(lpVault), "LPVault(mock)");
        vm.label(address(riskModule), "RiskModule(mock)");
        vm.label(address(oracle), "LPOracle(mock)");
        vm.label(vt, "VaultToken");
        vm.label(address(usdc), "USDC");
        vm.label(address(usdt), "USDT");
        vm.label(address(debt), "GHO");
    }
}
