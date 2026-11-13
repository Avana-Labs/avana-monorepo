// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralization} from "../../../src/custody/collateralization/ICollateralization.sol";
import {AvanaRoles} from "../../../src/governance/roles/AvanaRoles.sol";
import {AvanaTimelock} from "../../../src/governance/timelock/AvanaTimelock.sol";
import {GovernedTargets} from "../../../src/governance/timelock/types/GovernedTargets.sol";
import {SelectorPair} from "../../../src/governance/timelock/types/SelectorPair.sol";
import {Lock} from "../../../src/lock/lock/Lock.sol";
import {AaveAdapter} from "../../../src/policy/aave-adapter/AaveAdapter.sol";
import {AaveAdapterCollateralLogic} from "../../../src/policy/aave-adapter/AaveAdapterCollateralLogic.sol";
import {AaveAdapterExitLogic} from "../../../src/policy/aave-adapter/AaveAdapterExitLogic.sol";
import {AaveAdapterSettlementLogic} from "../../../src/policy/aave-adapter/AaveAdapterSettlementLogic.sol";
import {AaveAdapterUserLogic} from "../../../src/policy/aave-adapter/AaveAdapterUserLogic.sol";
import {IAaveAdapter} from "../../../src/policy/aave-adapter/IAaveAdapter.sol";
import {AaveAdapterImmutables} from "../../../src/policy/aave-adapter/types/AaveAdapterImmutables.sol";
import {AaveAdapterLogics} from "../../../src/policy/aave-adapter/types/AaveAdapterLogics.sol";
import {MarketRegistry} from "../../../src/policy/market-registry/MarketRegistry.sol";
import {MarketRegistryActivationLogic} from "../../../src/policy/market-registry/MarketRegistryActivationLogic.sol";
import {MarketRegistryHubsLogic} from "../../../src/policy/market-registry/MarketRegistryHubsLogic.sol";
import {MarketRegistryListingLogic} from "../../../src/policy/market-registry/MarketRegistryListingLogic.sol";
import {MarketRegistryRoutesLogic} from "../../../src/policy/market-registry/MarketRegistryRoutesLogic.sol";
import {MarketRegistrySafetyLogic} from "../../../src/policy/market-registry/MarketRegistrySafetyLogic.sol";
import {MarketRegistryWindDownLogic} from "../../../src/policy/market-registry/MarketRegistryWindDownLogic.sol";
import {MarketRegistryImmutables} from "../../../src/policy/market-registry/types/MarketRegistryImmutables.sol";
import {MarketRegistryLogics} from "../../../src/policy/market-registry/types/MarketRegistryLogics.sol";
import {IParameterStore} from "../../../src/policy/parameter-store/IParameterStore.sol";
import {IParameterStoreAdmin} from "../../../src/policy/parameter-store/IParameterStoreAdmin.sol";
import {ParameterStore} from "../../../src/policy/parameter-store/ParameterStore.sol";
import {ParameterStoreAdminOracleLogic} from "../../../src/policy/parameter-store/ParameterStoreAdminOracleLogic.sol";
import {ParameterStoreAdminRiskLogic} from "../../../src/policy/parameter-store/ParameterStoreAdminRiskLogic.sol";
import {ParameterStoreListingLogic} from "../../../src/policy/parameter-store/ParameterStoreListingLogic.sol";
import {ParameterStoreLoosenLogic} from "../../../src/policy/parameter-store/ParameterStoreLoosenLogic.sol";
import {ParameterStoreTightenLogic} from "../../../src/policy/parameter-store/ParameterStoreTightenLogic.sol";
import {GlobalParams} from "../../../src/policy/parameter-store/types/GlobalParams.sol";
import {ParameterStoreLogics} from "../../../src/policy/parameter-store/types/ParameterStoreLogics.sol";
import {RiskModule} from "../../../src/policy/risk-module/RiskModule.sol";
import {RiskModuleBorrowLogic} from "../../../src/policy/risk-module/RiskModuleBorrowLogic.sol";
import {RiskModuleBreakerLogic} from "../../../src/policy/risk-module/RiskModuleBreakerLogic.sol";
import {RiskModuleDriftLogic} from "../../../src/policy/risk-module/RiskModuleDriftLogic.sol";
import {RiskModulePledgeLogic} from "../../../src/policy/risk-module/RiskModulePledgeLogic.sol";
import {RiskModuleSpeedLogic} from "../../../src/policy/risk-module/RiskModuleSpeedLogic.sol";
import {RiskModuleStatusLogic} from "../../../src/policy/risk-module/RiskModuleStatusLogic.sol";
import {RiskModuleImmutables} from "../../../src/policy/risk-module/types/RiskModuleImmutables.sol";
import {RiskModuleLogics} from "../../../src/policy/risk-module/types/RiskModuleLogics.sol";
import {ProxyManager} from "../../../src/proxy/proxy-manager/ProxyManager.sol";
import {VaultTokenFactory} from "../../../src/vault-token/vault-token-factory/VaultTokenFactory.sol";
import {AdapterPlaceholder} from "../mocks/AaveAdapterMocks.sol";
import {FullStackLPVaultMock} from "../mocks/FullStackLPVaultMock.sol";
import {LPVaultSwapMock} from "../mocks/LPVaultSwapMock.sol";
import {AaveV4Fixture} from "./AaveV4Fixture.sol";
import {ClPoolFixture} from "./ClPoolFixture.sol";
import {TimelockLaunchLists} from "./TimelockLaunchLists.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title FullStackDeploy
/// @notice The Avana core as one chain runs it, on the real local Aave V4 (pinned release): the real AvanaTimelock
/// (launch short-delay list and DAO-only cancel set naming the real ParameterStore and MarketRegistry), the
/// MarketRegistry (six logic contracts), the ParameterStore (five logic contracts), the RiskModule (six logic
/// contracts) and the AaveAdapter (four logic contracts), each behind its ERC-1967 proxy and initialized by the
/// timelock, with the real Lock, Collateralization (built from its artifact), VaultTokenFactory and ProxyManager.
/// @dev The four upgradeable proxies are created first over a placeholder, so every immutable contract and every
/// implementation is built with their final addresses and no address is predicted. Stand-ins, each named: LPVaultSwap
/// (`LPVaultSwapMock`, which liquidates on the Spoke through the real Collateralization and AaveAdapter) and the
/// LPVault (`FullStackLPVaultMock`). Nothing here imports Aave V4 sources or a via-IR contract's source.
abstract contract FullStackDeploy is AaveV4Fixture, ClPoolFixture {
    uint32 internal constant V3 = 1;
    uint32 internal constant BLOCK_TIME = 12;
    uint256 internal constant T0 = 1_762_650_000;
    uint256 internal constant MAX_MARKETS = 64;
    /// @dev Per-depositor exposure cap on the Hub, 8-decimal USD.
    uint256 internal constant DEPOSITOR_CAP = 5_000_000e8;
    /// @dev Launch `poolShareMaxBps` (TEST-218: 10 %).
    uint16 internal constant POOL_SHARE_MAX_BPS = 1000;

    AvanaTimelock internal timelock;
    MarketRegistry internal registry;
    IParameterStore internal store;
    RiskModule internal riskModule;
    IAaveAdapter internal adapterC;
    address internal adapter;
    LPVaultSwapMock internal swap;
    Lock internal lock;
    VaultTokenFactory internal vtFactory;
    ICollateralization internal coll;
    ProxyManager internal proxyManager;
    FullStackLPVaultMock internal lpVault;
    MarketRegistryImmutables internal registryIm;
    RiskModuleImmutables internal riskIm;
    AaveAdapterImmutables internal adapterIm;
    address internal payoutEscrow = makeAddr("payoutEscrow");
    address internal flashLiquidator = makeAddr("flashLiquidator");

    /// @dev Proxies, timelock, immutable contracts, then each implementation behind its proxy.
    function _deployCore() internal {
        adapter = _placeholderProxy();
        address registryAddr = _placeholderProxy();
        address storeAddr = _placeholderProxy();
        address riskAddr = _placeholderProxy();
        swap = new LPVaultSwapMock(adapter);
        timelock = _launchTimelock(storeAddr, registryAddr, address(swap));
        address tl = address(timelock);
        lock = new Lock(adapter, address(swap));
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        vtFactory = new VaultTokenFactory(adapter, address(swap), predicted, tl, registryAddr);
        coll = ICollateralization(
            deployCode(
                "Collateralization.sol:Collateralization",
                abi.encode(adapter, address(swap), riskAddr, address(lock), address(vtFactory))
            )
        );
        require(address(coll) == predicted, "predicted Collateralization");
        swap.wire(address(lock), address(coll));
        lpVault = new FullStackLPVaultMock(V3, address(coll), address(lock), keccak256("UNISWAP_V3"));
        lpVault.setCore(tl, registryAddr);
        lpVault.setDepth(1e30, true);
        proxyManager = new ProxyManager(adapter, registryAddr);
        _installRegistry(registryAddr, storeAddr, riskAddr);
        _installStore(storeAddr, registryAddr);
        _installRiskModule(riskAddr, registryAddr, storeAddr);
        _installAdapter(registryAddr, storeAddr, riskAddr);
        vm.startPrank(tl);
        registry.grantRole(AvanaRoles.APPLICATION_PAUSE_GUARDIAN, emergencyGuardian);
        registry.grantRole(AvanaRoles.APPLICATION_FREEZE_GUARDIAN, emergencyGuardian);
        store.grantRole(AvanaRoles.APPLICATION_PAUSE_GUARDIAN, emergencyGuardian);
        vm.stopPrank();
        _labelCore();
    }

    function _placeholderProxy() private returns (address) {
        return address(new ERC1967Proxy(address(new AdapterPlaceholder()), ""));
    }

    struct TimelockArgs {
        address[] proposers;
        address[] executors;
        address[] cancellers;
        address[] daoCancellers;
        SelectorPair[] shortEligible;
        SelectorPair[] daoOnly;
        GovernedTargets targets;
    }

    /// @dev The launch configuration of `REQ-ACCESS-027` (as `TimelockFixture`), bound to the real targets.
    function _launchTimelock(
        address storeAddr,
        address registryAddr,
        address swapAddr
    ) private returns (AvanaTimelock) {
        TimelockArgs memory a;
        a.proposers = new address[](2);
        (a.proposers[0], a.proposers[1]) = (governanceMultisig, aaveGovernanceExecutor);
        a.executors = new address[](1);
        a.executors[0] = governanceMultisig;
        a.cancellers = new address[](2);
        (a.cancellers[0], a.cancellers[1]) = (emergencyGuardian, aaveGuardian);
        a.daoCancellers = new address[](1);
        a.daoCancellers[0] = aaveGovernanceExecutor;
        a.shortEligible = TimelockLaunchLists.shortEligible(storeAddr, registryAddr, swapAddr);
        a.daoOnly = TimelockLaunchLists.daoOnlyCancel(registryAddr, swapAddr);
        a.targets = GovernedTargets(storeAddr, registryAddr, swapAddr);
        return new AvanaTimelock(
            a.proposers,
            a.executors,
            a.cancellers,
            a.daoCancellers,
            NORMAL_DELAY,
            true,
            a.shortEligible,
            a.daoOnly,
            a.targets
        );
    }

    function _installRegistry(
        address registryAddr,
        address storeAddr,
        address riskAddr
    ) private {
        registryIm = MarketRegistryImmutables({
            timelock: address(timelock),
            aaveGovernanceExecutor: aaveGovernanceExecutor,
            vaultTokenFactory: address(vtFactory),
            aaveAdapter: adapter,
            collateralization: address(coll),
            lock: address(lock),
            proxyManager: address(proxyManager),
            parameterStore: storeAddr,
            riskModule: riskAddr,
            lpVaultSwap: address(swap),
            payoutEscrow: payoutEscrow,
            flashLiquidator: flashLiquidator,
            standardSpokeImplementation: aave.cdpSpokeImplementation,
            maxMarketCount: MAX_MARKETS
        });
        MarketRegistryLogics memory l;
        l.hubs = address(new MarketRegistryHubsLogic(registryIm));
        l.listing = address(new MarketRegistryListingLogic(registryIm));
        l.activation = address(new MarketRegistryActivationLogic(registryIm));
        l.routes = address(new MarketRegistryRoutesLogic(registryIm));
        l.safety = address(new MarketRegistrySafetyLogic(registryIm));
        l.windDown = address(new MarketRegistryWindDownLogic(registryIm));
        MarketRegistry impl = new MarketRegistry(registryIm, l);
        AdapterPlaceholder(registryAddr)
            .upgradeToAndCall(address(impl), abi.encodeCall(MarketRegistry.initialize, (address(timelock))));
        registry = MarketRegistry(registryAddr);
    }

    function _installStore(
        address storeAddr,
        address registryAddr
    ) private {
        address tl = address(timelock);
        ParameterStoreLogics memory l = ParameterStoreLogics({
            tighten: address(new ParameterStoreTightenLogic(tl, registryAddr, BLOCK_TIME, false)),
            loosen: address(new ParameterStoreLoosenLogic(tl, registryAddr, BLOCK_TIME, false)),
            listing: address(new ParameterStoreListingLogic(tl, registryAddr, BLOCK_TIME, false)),
            adminOracle: address(new ParameterStoreAdminOracleLogic(tl, registryAddr, BLOCK_TIME, false)),
            adminRisk: address(new ParameterStoreAdminRiskLogic(tl, registryAddr, BLOCK_TIME, false))
        });
        ParameterStore impl = new ParameterStore(tl, registryAddr, BLOCK_TIME, false, l);
        AdapterPlaceholder(storeAddr)
            .upgradeToAndCall(
                address(impl), abi.encodeCall(IParameterStoreAdmin.initialize, (tl, _globals(), 0, POOL_SHARE_MAX_BPS))
            );
        store = IParameterStore(storeAddr);
    }

    /// @dev Launch global values (as `ParameterStoreRegistryFixture`).
    function _globals() internal view returns (GlobalParams memory g) {
        g.cachedWindow = 3600;
        g.disagreementPauseMax = 3600;
        g.usdBandLow = 0.9e8;
        g.usdBandHigh = 1.02e8;
        g.graceDuration = 1800;
        g.graceHealthFactor = 0.95e18;
        g.maxFlashFeeBps = uint16(MAX_FLASH_FEE_BPS);
        g.avanaFeeShareBps = uint16(AVANA_FEE_SHARE_BPS);
        g.feeRecipient = feeRecipient;
        g.feedAgreementMarginBps = 50;
        g.gateRecoverySeconds = 1800;
        g.maxShortfallBps = uint16(MAX_SHORTFALL_BPS);
    }

    function _installRiskModule(
        address riskAddr,
        address registryAddr,
        address storeAddr
    ) private {
        riskIm = RiskModuleImmutables({
            marketRegistry: registryAddr,
            parameterStore: storeAddr,
            collateralization: address(coll),
            adapter: adapter,
            lpVaultSwap: address(swap),
            timelock: address(timelock)
        });
        RiskModuleLogics memory l;
        l.drift = address(new RiskModuleDriftLogic(riskIm));
        l.breaker = address(new RiskModuleBreakerLogic(riskIm, l.drift));
        l.pledge = address(new RiskModulePledgeLogic(riskIm, l.drift, l.breaker));
        l.borrow = address(new RiskModuleBorrowLogic(riskIm, l.drift, l.breaker));
        l.status = address(new RiskModuleStatusLogic(riskIm, l.drift, l.breaker, l.borrow));
        l.speed = address(new RiskModuleSpeedLogic(riskIm));
        RiskModule impl = new RiskModule(riskIm, l);
        AdapterPlaceholder(riskAddr)
            .upgradeToAndCall(address(impl), abi.encodeCall(RiskModule.initialize, (address(timelock))));
        riskModule = RiskModule(riskAddr);
    }

    function _installAdapter(
        address registryAddr,
        address storeAddr,
        address riskAddr
    ) private {
        adapterIm = AaveAdapterImmutables({
            proxyManager: address(proxyManager),
            collateralization: address(coll),
            riskModule: riskAddr,
            marketRegistry: registryAddr,
            parameterStore: storeAddr,
            lpVaultSwap: address(swap),
            lock: address(lock),
            vaultTokenFactory: address(vtFactory),
            timelock: address(timelock)
        });
        AaveAdapter impl = new AaveAdapter(adapterIm, _adapterLogics(adapterIm));
        AdapterPlaceholder(adapter)
            .upgradeToAndCall(address(impl), abi.encodeCall(AaveAdapter.initialize, (address(timelock))));
        adapterC = IAaveAdapter(adapter);
    }

    /// @dev The Adapter's four logic contracts for `im` (an upgrade test builds a second reviewed implementation).
    function _adapterLogics(
        AaveAdapterImmutables memory im
    ) internal returns (AaveAdapterLogics memory) {
        return AaveAdapterLogics({
            user: address(new AaveAdapterUserLogic(im)),
            exit: address(new AaveAdapterExitLogic(im)),
            collateral: address(new AaveAdapterCollateralLogic(im)),
            settlement: address(new AaveAdapterSettlementLogic(im))
        });
    }

    function _labelCore() private {
        vm.label(address(timelock), "AvanaTimelock");
        vm.label(address(registry), "MarketRegistry");
        vm.label(address(store), "ParameterStore");
        vm.label(address(riskModule), "RiskModule");
        vm.label(adapter, "AaveAdapter");
        vm.label(address(swap), "LPVaultSwap(stand-in)");
        vm.label(address(lock), "Lock");
        vm.label(address(vtFactory), "VaultTokenFactory");
        vm.label(address(coll), "Collateralization");
        vm.label(address(proxyManager), "ProxyManager");
        vm.label(address(lpVault), "LPVault(stand-in)");
    }
}
