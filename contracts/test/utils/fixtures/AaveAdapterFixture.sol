// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {AaveAdapter} from "../../../src/policy/aave-adapter/AaveAdapter.sol";
import {AaveAdapterCollateralLogic} from "../../../src/policy/aave-adapter/AaveAdapterCollateralLogic.sol";
import {AaveAdapterExitLogic} from "../../../src/policy/aave-adapter/AaveAdapterExitLogic.sol";
import {AaveAdapterSettlementLogic} from "../../../src/policy/aave-adapter/AaveAdapterSettlementLogic.sol";
import {AaveAdapterUserLogic} from "../../../src/policy/aave-adapter/AaveAdapterUserLogic.sol";
import {IAaveAdapter} from "../../../src/policy/aave-adapter/IAaveAdapter.sol";
import {AaveAdapterImmutables} from "../../../src/policy/aave-adapter/types/AaveAdapterImmutables.sol";
import {AaveAdapterLogics} from "../../../src/policy/aave-adapter/types/AaveAdapterLogics.sol";
import {RepayWithCollateralParams} from "../../../src/policy/aave-adapter/types/RepayWithCollateralParams.sol";
import {DebtReserveDef} from "../../../src/policy/market-registry/types/DebtReserveDef.sol";
import {MarketStatus} from "../../../src/policy/market-registry/types/MarketStatus.sol";
import {RiskTier} from "../../../src/policy/market-registry/types/RiskTier.sol";
import {SpokeDef} from "../../../src/policy/market-registry/types/SpokeDef.sol";
import {ProxyManager} from "../../../src/proxy/proxy-manager/ProxyManager.sol";
import {Market} from "../../../src/types/Market.sol";
import {PauseReason} from "../../../src/types/PauseReason.sol";
import {PauseState} from "../../../src/types/PauseState.sol";
import {PositionRef} from "../../../src/types/PositionRef.sol";
import {PositionShape} from "../../../src/types/PositionShape.sol";
import {ShapeKind} from "../../../src/types/ShapeKind.sol";
import {VaultToken} from "../../../src/vault-token/vault-token/VaultToken.sol";
import {
    AdapterParameterStoreMock,
    AdapterPlaceholder,
    AdapterRegistryMock,
    AdapterRiskModuleMock
} from "../mocks/AaveAdapterMocks.sol";
import {CollPoolToken} from "../mocks/CollateralizationMocks.sol";
import {LPVaultSwapMock} from "../mocks/LPVaultSwapMock.sol";
import {
    CollHubSpokeConfig,
    CollInterestRateData,
    CollPriceSource,
    CollSpokeDynamicReserveConfig,
    CollSpokeReserveConfig,
    CollateralizationFixture,
    ICollHubConfigurator,
    ICollSpokeConfigurator
} from "./CollateralizationFixture.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title AaveAdapterFixture
/// @notice The AaveAdapter (router and its three logic contracts behind one ERC-1967 proxy) on the real local Aave V4
/// (pinned release), with the real Lock, Collateralization, VaultTokenFactory, vault tokens, ProxyManager and
/// PositionProxies of `CollateralizationFixture`. Two markets on the CDP Spoke (4 and 5, both USDC/USDT, 6-decimal vault
/// tokens at $2.00) and two debt reserves (GHO, 18 decimals, $1.00, and USDC, 6 decimals, $0.9999), both funded by the
/// Hub through the Lend Spoke. The MarketRegistry, the RiskModule, the ParameterStore and LPVaultSwap are stand-ins
/// (`AdapterRegistryMock`, `AdapterRiskModuleMock`, `AdapterParameterStoreMock`, `LPVaultSwapMock`), the LPVault is
/// `CollLPVaultMock` and the LPOracle `CollOracleMock`.
abstract contract AaveAdapterFixture is CollateralizationFixture {
    uint256 internal constant MARKET_B = 5;
    uint256 internal constant DEADLINE_SLACK = 600;
    /// @dev 10,000 whole vault tokens, $20,000 at $2.00.
    uint128 internal constant UNITS = 10_000_000_000;

    IAaveAdapter internal adapterC;
    AaveAdapter internal implementation;
    AaveAdapterImmutables internal im;
    AaveAdapterLogics internal logics;
    AdapterRegistryMock internal registry;
    AdapterRiskModuleMock internal risk;
    AdapterParameterStoreMock internal pstore;
    LPVaultSwapMock internal swap;
    ProxyManager internal proxyManager;

    CollPoolToken internal usdcDebt;
    CollPriceSource internal usdcPrice;
    uint256 internal usdcReserveId;
    uint256 internal ghoAssetId;
    uint256 internal usdcAssetId;

    VaultToken internal tokenB;
    address internal vtB;
    uint256 internal vtReserveIdB;
    address internal poolB = makeAddr("usdcUsdtPoolB");
    address internal firstLossReserve = makeAddr("firstLossReserve");

    uint256 internal keyNonce;

    function setUp() public virtual {
        // The Adapter's proxy first, so every immutable contract is built with its final address.
        AdapterPlaceholder placeholder = new AdapterPlaceholder();
        ERC1967Proxy proxy = new ERC1967Proxy(address(placeholder), "");
        adapter = address(proxy);
        swap = new LPVaultSwapMock(adapter);
        lpVaultSwap = address(swap);
        _deployCollateralization();
        swap.wire(address(lock), address(coll));

        registry = new AdapterRegistryMock();
        proxyManager = new ProxyManager(adapter, address(registry));
        risk = new AdapterRiskModuleMock(aave.cdpSpoke, address(coll));
        risk.setVaultToken(vt);
        pstore = new AdapterParameterStoreMock();
        im = AaveAdapterImmutables({
            proxyManager: address(proxyManager),
            collateralization: address(coll),
            riskModule: address(risk),
            marketRegistry: address(registry),
            parameterStore: address(pstore),
            lpVaultSwap: lpVaultSwap,
            lock: address(lock),
            vaultTokenFactory: address(factory),
            timelock: timelock
        });
        logics = AaveAdapterLogics({
            user: address(new AaveAdapterUserLogic(im)),
            exit: address(new AaveAdapterExitLogic(im)),
            collateral: address(new AaveAdapterCollateralLogic(im)),
            settlement: address(new AaveAdapterSettlementLogic(im))
        });
        implementation = new AaveAdapter(im, logics);
        AdapterPlaceholder(adapter)
            .upgradeToAndCall(address(implementation), abi.encodeCall(AaveAdapter.initialize, (timelock)));
        adapterC = IAaveAdapter(adapter);

        _addUsdcDebtReserve();
        _addMarketB();
        _configureRegistry();
        vm.label(adapter, "AaveAdapter");
        vm.label(address(swap), "LPVaultSwap(mock)");
        vm.label(address(registry), "MarketRegistry(mock)");
        vm.label(address(risk), "RiskModule(mock)");
        vm.label(address(proxyManager), "ProxyManager");
        vm.label(address(usdcDebt), "USDC(debt)");
    }

    // ─── Registry ───

    function _configureRegistry() internal {
        registry.setSpoke(
            aave.cdpSpoke,
            SpokeDef({
                approved: true,
                hub: aave.hub,
                integrationId: INTEGRATION,
                riskTier: RiskTier.Stable,
                implementation: aave.cdpSpokeImplementation,
                aaveOracle: aave.cdpOracle
            })
        );
        registry.setMarket(MARKET_ID, _marketDef(vt, vtReserveId, pool));
        registry.setMarket(MARKET_B, _marketDef(vtB, vtReserveIdB, poolB));
        registry.setDebtReserve(aave.cdpSpoke, debtReserveId, _debtDef(debtReserveId, address(debt), 18, ghoAssetId));
        registry.setDebtReserve(
            aave.cdpSpoke, usdcReserveId, _debtDef(usdcReserveId, address(usdcDebt), 6, usdcAssetId)
        );
        registry.setIntegrationId(address(lpVault), INTEGRATION);
        registry.setRecordedHub(aave.hub, true);
        registry.setPayoutEscrow(makeAddr("payoutEscrow"));
        registry.setFlashSource(makeAddr("flashSource"));
    }

    function _marketDef(
        address token_,
        uint256 reserveId,
        address pool_
    ) internal view returns (Market memory m) {
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(usdt);
        uint8[] memory decimals = new uint8[](2);
        decimals[0] = 6;
        decimals[1] = 6;
        m = Market({
            chainId: uint64(block.chainid),
            hub: aave.hub,
            spoke: aave.cdpSpoke,
            integrationId: INTEGRATION,
            integration: address(lpVault),
            pool: pool_,
            poolId: bytes32(0),
            shape: PositionShape(ShapeKind.TickRange, -50, 50),
            tokens: tokens,
            tokenDecimals: decimals,
            vaultToken: token_,
            decimals: VT_DECIMALS,
            lpOracle: address(oracle),
            hubAssetId: IAaveV4Hub(aave.hub).getAssetId(token_),
            reserveId: reserveId,
            status: MarketStatus.Active,
            registeredAt: uint64(block.timestamp),
            activatedAt: uint64(block.timestamp)
        });
    }

    function _debtDef(
        uint256 reserveId,
        address asset,
        uint8 decimals,
        uint256 hubAssetId
    ) internal view returns (DebtReserveDef memory def) {
        def = DebtReserveDef({
            reserveId: reserveId,
            asset: asset,
            decimals: decimals,
            fundingHub: aave.hub,
            hubAssetId: hubAssetId,
            priceSource: address(debtPrice),
            fixedPrice: decimals == 18,
            firstLossReserve: firstLossReserve,
            crossHub: false,
            approved: true
        });
    }

    // ─── Aave listing beyond CollateralizationFixture ───

    function _addUsdcDebtReserve() internal {
        ghoAssetId = IAaveV4Hub(aave.hub).getAssetId(address(debt));
        usdcDebt = new CollPoolToken("USDC", 6);
        usdcPrice = new CollPriceSource(99_990_000);
        IAaveV4Hub hubView = IAaveV4Hub(aave.hub);
        uint40 maxCap = hubView.MAX_ALLOWED_SPOKE_CAP();
        uint24 maxRp = hubView.MAX_RISK_PREMIUM_THRESHOLD();
        bytes memory irData = abi.encode(CollInterestRateData(9000, 0, 400, 6000));
        vm.startPrank(aaveDao);
        usdcAssetId = ICollHubConfigurator(aave.hubConfigurator)
            .addAssetWithDecimals(aave.hub, address(usdcDebt), 6, aave.treasurySpoke, 0, aave.irStrategy, irData);
        ICollHubConfigurator(aave.hubConfigurator)
            .addSpoke(aave.hub, aave.lendSpoke, usdcAssetId, CollHubSpokeConfig(maxCap, 0, maxRp, true, false));
        ICollHubConfigurator(aave.hubConfigurator)
            .addSpoke(aave.hub, aave.cdpSpoke, usdcAssetId, CollHubSpokeConfig(0, 1_000_000, maxRp, true, false));
        uint256 lendReserve = ICollSpokeConfigurator(aave.spokeConfigurator)
            .addReserve(
                aave.lendSpoke,
                aave.hub,
                usdcAssetId,
                address(usdcPrice),
                CollSpokeReserveConfig(0, false, false, true, false),
                CollSpokeDynamicReserveConfig(0, 10_000, 0)
            );
        usdcReserveId = ICollSpokeConfigurator(aave.spokeConfigurator)
            .addReserve(
                aave.cdpSpoke,
                aave.hub,
                usdcAssetId,
                address(usdcPrice),
                CollSpokeReserveConfig(0, false, false, true, false),
                CollSpokeDynamicReserveConfig(0, 10_000, 0)
            );
        vm.stopPrank();
        usdcDebt.mint(daoTreasury, 1_000_000e6);
        vm.startPrank(daoTreasury);
        ERC20(address(usdcDebt)).approve(aave.lendSpoke, 1_000_000e6);
        IAaveV4Spoke(aave.lendSpoke).supply(lendReserve, 1_000_000e6, daoTreasury);
        vm.stopPrank();
    }

    function _addMarketB() internal {
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(usdt);
        uint256[] memory rates = new uint256[](2);
        rates[0] = 800_000;
        rates[1] = 1_250_000;
        lpVault.bind(MARKET_B, poolB, tokens, rates);
        vm.prank(timelock);
        vtB = factory.deployVaultToken(
            INTEGRATION,
            poolB,
            bytes32(0),
            PositionShape(ShapeKind.TickRange, -60, 60),
            aave.hub,
            aave.cdpSpoke,
            MARKET_B,
            address(oracle),
            VT_DECIMALS,
            "Avana USDC/USDT B",
            "avUSDC-USDT-B"
        );
        tokenB = VaultToken(vtB);
        IAaveV4Hub hubView = IAaveV4Hub(aave.hub);
        uint24 maxRp = hubView.MAX_RISK_PREMIUM_THRESHOLD();
        bytes memory irData = abi.encode(CollInterestRateData(9000, 0, 400, 6000));
        vm.startPrank(aaveDao);
        uint256 assetB = ICollHubConfigurator(aave.hubConfigurator)
            .addAssetWithDecimals(aave.hub, vtB, VT_DECIMALS, aave.treasurySpoke, 0, aave.irStrategy, irData);
        ICollHubConfigurator(aave.hubConfigurator)
            .addSpoke(aave.hub, aave.cdpSpoke, assetB, CollHubSpokeConfig(5_500_000, 0, maxRp, true, false));
        vtReserveIdB = ICollSpokeConfigurator(aave.spokeConfigurator)
            .addReserve(
                aave.cdpSpoke,
                aave.hub,
                assetB,
                address(vtPrice),
                CollSpokeReserveConfig(0, false, false, false, false),
                CollSpokeDynamicReserveConfig(8000, 10_500, 0)
            );
        vm.stopPrank();
        vm.label(vtB, "VaultTokenB");
    }

    // ─── Flows through the Adapter ───

    function _ref(
        bytes32 key
    ) internal pure returns (PositionRef memory) {
        return PositionRef(INTEGRATION, key);
    }

    function _newKey() internal returns (bytes32 key) {
        key = keccak256(abi.encode("position", ++keyNonce));
    }

    function _deadline() internal view returns (uint256) {
        return block.timestamp + DEADLINE_SLACK;
    }

    /// @dev Mints a position of `units` for `wallet` in `marketId` and pledges it through the Adapter.
    function _pledgeAs(
        address wallet,
        uint256 marketId,
        uint128 units
    ) internal returns (bytes32 key, address proxy) {
        key = _newKey();
        lpVault.mintPosition(key, wallet, marketId, units);
        vm.prank(wallet);
        (proxy,,) = adapterC.pledge(marketId, _ref(key), _deadline());
    }

    function _borrowAs(
        address wallet,
        uint256 marketId,
        uint256 reserveId,
        uint256 amount
    ) internal {
        address proxy = adapterC.proxyOf(wallet, marketId);
        uint256 nonce = adapterC.borrowNonce(proxy);
        vm.prank(wallet);
        adapterC.borrow(marketId, reserveId, amount, wallet, _deadline(), 0, nonce);
    }

    /// @dev Funds `payer` with `amount` of the reserve's asset and approves the Adapter for exactly that.
    function _fund(
        address payer,
        uint256 reserveId,
        uint256 amount
    ) internal {
        CollPoolToken asset = reserveId == usdcReserveId ? usdcDebt : debt;
        asset.mint(payer, amount);
        vm.prank(payer);
        ERC20(address(asset)).approve(adapter, amount);
    }

    function _debtOf(
        address proxy,
        uint256 reserveId
    ) internal view returns (uint256) {
        return IAaveV4Spoke(aave.cdpSpoke).getUserTotalDebt(reserveId, proxy);
    }

    function _hf(
        address proxy
    ) internal view returns (uint256) {
        return IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(proxy).healthFactor;
    }

    function _borrowCountOf(
        address proxy
    ) internal view returns (uint256) {
        return IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(proxy).borrowCount;
    }

    function _sharesOf(
        address proxy,
        uint256 reserveId
    ) internal view returns (uint256) {
        return IAaveV4Spoke(aave.cdpSpoke).getUserSuppliedShares(reserveId, proxy);
    }

    function _pause(
        PauseState state,
        PauseReason reason
    ) internal {
        registry.setPause(aave.hub, state, reason);
    }

    function _mins() internal pure returns (uint256[] memory m) {
        m = new uint256[](2);
    }

    function _rwc(
        uint256 marketId,
        bytes32 key,
        uint128 units,
        uint256 reserveId
    ) internal view returns (RepayWithCollateralParams memory p) {
        p = RepayWithCollateralParams({
            marketId: marketId,
            position: _ref(key),
            units: units,
            debtReserveId: reserveId,
            minAmounts: _mins(),
            minDebtRepaid: 0,
            minAssetOut: 0,
            deadline: _deadline(),
            minHealthFactor: 0
        });
    }

    function _assetOf(
        uint256 reserveId
    ) internal view returns (CollPoolToken) {
        return reserveId == usdcReserveId ? usdcDebt : debt;
    }
}
