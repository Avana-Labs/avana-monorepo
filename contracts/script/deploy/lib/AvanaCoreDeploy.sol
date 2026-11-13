// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {GovernedTargets} from "../../../src/governance/timelock/types/GovernedTargets.sol";
import {SelectorPair} from "../../../src/governance/timelock/types/SelectorPair.sol";
import {ILPVaultSwapAdmin} from "../../../src/liquidation/lp-vault-swap/ILPVaultSwapAdmin.sol";
import {LPVaultSwapImmutables} from "../../../src/liquidation/lp-vault-swap/types/LPVaultSwapImmutables.sol";
import {IAaveAdapterAdmin} from "../../../src/policy/aave-adapter/IAaveAdapterAdmin.sol";
import {AaveAdapterImmutables} from "../../../src/policy/aave-adapter/types/AaveAdapterImmutables.sol";
import {IMarketRegistryListing} from "../../../src/policy/market-registry/IMarketRegistryListing.sol";
import {MarketRegistryImmutables} from "../../../src/policy/market-registry/types/MarketRegistryImmutables.sol";
import {IParameterStoreAdmin} from "../../../src/policy/parameter-store/IParameterStoreAdmin.sol";
import {IRiskModuleAdmin} from "../../../src/policy/risk-module/IRiskModuleAdmin.sol";
import {RiskModuleImmutables} from "../../../src/policy/risk-module/types/RiskModuleImmutables.sol";
import {TimelockLaunchLists} from "../../../test/utils/fixtures/TimelockLaunchLists.sol";
import {DeployBase} from "./DeployBase.sol";
import {ChainInputs, UpgradeableDeployment} from "./DeployTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title AvanaCoreDeploy
/// @notice Steps 1–3 of the deployment order (`script/README.md`): the AvanaTimelock and the five upgradeable
/// contracts (implementation, logic contracts, fixed ERC-1967 proxy initialised in the deploying transaction).
/// @dev Every cross-reference is a predicted CREATE3 address of the deployer's namespace, so the order only has to
/// respect constructor and initializer reads: the MarketRegistry proxy exists before the ParameterStore's
/// `initialize` (which reads its recorded addresses) and before the flash liquidation helper (whose constructor
/// reads `isRecordedHub`). Each proxy is created by `AvanaCreate3Factory.deploy` with `ERC1967Proxy(impl, initData)`
/// as init code, so `initialize` runs inside the creating transaction and no one can call it first (`REQ-ACCESS-150`;
/// `LPVaultSwap.initialize` accepts any timelock, which is why it must never be a separate transaction).
abstract contract AvanaCoreDeploy is DeployBase {
    /// @notice Predicted addresses of everything that is referenced before it exists.
    struct Predicted {
        address timelock;
        address marketRegistry;
        address parameterStore;
        address riskModule;
        address aaveAdapter;
        address lpVaultSwap;
        address lock;
        address collateralization;
        address vaultTokenFactory;
        address proxyManager;
        address payoutEscrow;
        address flashSource;
        address flashLiquidator;
    }

    function _predictAll() internal view returns (Predicted memory p) {
        p.timelock = _predict("AvanaTimelock");
        p.marketRegistry = _predict("MarketRegistry");
        p.parameterStore = _predict("ParameterStore");
        p.riskModule = _predict("RiskModule");
        p.aaveAdapter = _predict("AaveAdapter");
        p.lpVaultSwap = _predict("LPVaultSwap");
        p.lock = _predict("Lock");
        p.collateralization = _predict("Collateralization");
        p.vaultTokenFactory = _predict("VaultTokenFactory");
        p.proxyManager = _predict("ProxyManager");
        p.payoutEscrow = _predict("PayoutEscrow");
        p.flashSource = _predict("AaveV3FlashSource");
        p.flashLiquidator = _predict("FlashLiquidator");
    }

    /// @notice Step 1: the timelock with `admin = address(0)` and the launch role table (`REQ-ACCESS-027`).
    function _deployTimelock(
        ChainInputs memory c,
        Predicted memory p
    ) internal returns (address) {
        address[] memory proposers = new address[](2);
        (proposers[0], proposers[1]) = (c.gov.governanceSafe, c.gov.aaveGovernanceExecutor);
        address[] memory executors = new address[](1);
        executors[0] = c.gov.governanceSafe;
        // Proposers are cancellers by construction (OpenZeppelin TimelockController); these are the other two.
        address[] memory cancellers = new address[](2);
        (cancellers[0], cancellers[1]) = (c.gov.emergencyGuardian, c.gov.aaveProtocolGuardian);
        address[] memory daoCancellers = new address[](1);
        daoCancellers[0] = c.gov.aaveGovernanceExecutor;
        SelectorPair[] memory shortList =
            TimelockLaunchLists.shortEligible(p.parameterStore, p.marketRegistry, p.lpVaultSwap);
        SelectorPair[] memory daoOnly = TimelockLaunchLists.daoOnlyCancel(p.marketRegistry, p.lpVaultSwap);
        // The selector pairs of both sets must name the chain's ParameterStore, MarketRegistry and LPVaultSwap
        // (`REQ-ACCESS-155`, `REQ-ACCESS-156`): the predicted proxy addresses.
        GovernedTargets memory targets = GovernedTargets({
            parameterStore: p.parameterStore, marketRegistry: p.marketRegistry, lpVaultSwap: p.lpVaultSwap
        });
        bytes memory args = abi.encode(
            proposers, executors, cancellers, daoCancellers, uint256(432_000), true, shortList, daoOnly, targets
        );
        return _deploy3("AvanaTimelock", bytes.concat(_artifact("AvanaTimelock.sol", "AvanaTimelock"), args));
    }

    /// @notice MarketRegistry: six logic contracts, the router implementation, the proxy with `initialize(timelock)`.
    function _deployMarketRegistry(
        ChainInputs memory c,
        Predicted memory p
    ) internal returns (UpgradeableDeployment memory d) {
        MarketRegistryImmutables memory im;
        im.timelock = p.timelock;
        im.aaveGovernanceExecutor = c.gov.aaveGovernanceExecutor;
        im.vaultTokenFactory = p.vaultTokenFactory;
        im.aaveAdapter = p.aaveAdapter;
        im.collateralization = p.collateralization;
        im.lock = p.lock;
        im.proxyManager = p.proxyManager;
        im.parameterStore = p.parameterStore;
        im.riskModule = p.riskModule;
        im.lpVaultSwap = p.lpVaultSwap;
        im.payoutEscrow = p.payoutEscrow;
        im.flashLiquidator = p.flashLiquidator;
        im.standardSpokeImplementation = c.aave.standardSpokeImplementation;
        im.maxMarketCount = c.maxMarketCount;
        string[6] memory names = [
            "MarketRegistryHubsLogic",
            "MarketRegistryListingLogic",
            "MarketRegistryActivationLogic",
            "MarketRegistryRoutesLogic",
            "MarketRegistrySafetyLogic",
            "MarketRegistryWindDownLogic"
        ];
        d.logics = new address[](6);
        for (uint256 i = 0; i < 6; ++i) {
            d.logics[i] =
                _deploy(names[i], bytes.concat(_artifact(string.concat(names[i], ".sol"), names[i]), abi.encode(im)));
        }
        // MarketRegistryLogics{hubs, listing, activation, routes, safety, windDown} has the order of `names`.
        bytes memory logics = abi.encode(d.logics[0], d.logics[1], d.logics[2], d.logics[3], d.logics[4], d.logics[5]);
        d.implementation = _deploy(
            "MarketRegistryImplementation",
            bytes.concat(_artifact("MarketRegistry.sol", "MarketRegistry"), abi.encode(im), logics)
        );
        d.proxy =
            _proxy("MarketRegistry", d.implementation, abi.encodeCall(IMarketRegistryListing.initialize, (p.timelock)));
    }

    /// @notice ParameterStore: five logic contracts, the router, the proxy with the launch values (`REQ-PSTORE-001`).
    function _deployParameterStore(
        ChainInputs memory c,
        Predicted memory p
    ) internal returns (UpgradeableDeployment memory d) {
        bytes memory im = abi.encode(p.timelock, p.marketRegistry, c.blockTime, c.hasSequencer);
        string[5] memory names = [
            "ParameterStoreTightenLogic",
            "ParameterStoreLoosenLogic",
            "ParameterStoreListingLogic",
            "ParameterStoreAdminOracleLogic",
            "ParameterStoreAdminRiskLogic"
        ];
        d.logics = new address[](5);
        for (uint256 i = 0; i < 5; ++i) {
            d.logics[i] = _deploy(names[i], bytes.concat(_artifact(string.concat(names[i], ".sol"), names[i]), im));
        }
        // ParameterStoreLogics{tighten, loosen, listing, adminOracle, adminRisk}.
        bytes memory logics = abi.encode(d.logics[0], d.logics[1], d.logics[2], d.logics[3], d.logics[4]);
        d.implementation = _deploy(
            "ParameterStoreImplementation", bytes.concat(_artifact("ParameterStore.sol", "ParameterStore"), im, logics)
        );
        d.proxy = _proxy(
            "ParameterStore",
            d.implementation,
            abi.encodeCall(IParameterStoreAdmin.initialize, (p.timelock, c.globals, 0, c.initialPoolShareMaxBps))
        );
    }

    /// @notice RiskModule: drift, breaker, pledge, borrow, status and speed logic, the router, the proxy.
    function _deployRiskModule(
        Predicted memory p
    ) internal returns (UpgradeableDeployment memory d) {
        bytes memory im = abi.encode(
            RiskModuleImmutables({
                marketRegistry: p.marketRegistry,
                parameterStore: p.parameterStore,
                collateralization: p.collateralization,
                adapter: p.aaveAdapter,
                lpVaultSwap: p.lpVaultSwap,
                timelock: p.timelock
            })
        );
        d.logics = new address[](6);
        d.logics[0] = _deploy(
            "RiskModuleDriftLogic", bytes.concat(_artifact("RiskModuleDriftLogic.sol", "RiskModuleDriftLogic"), im)
        );
        d.logics[1] = _deploy(
            "RiskModuleBreakerLogic",
            bytes.concat(_artifact("RiskModuleBreakerLogic.sol", "RiskModuleBreakerLogic"), im, abi.encode(d.logics[0]))
        );
        bytes memory db = abi.encode(d.logics[0], d.logics[1]);
        d.logics[2] = _deploy(
            "RiskModulePledgeLogic",
            bytes.concat(_artifact("RiskModulePledgeLogic.sol", "RiskModulePledgeLogic"), im, db)
        );
        d.logics[3] = _deploy(
            "RiskModuleBorrowLogic",
            bytes.concat(_artifact("RiskModuleBorrowLogic.sol", "RiskModuleBorrowLogic"), im, db)
        );
        d.logics[4] = _deploy(
            "RiskModuleStatusLogic",
            bytes.concat(
                _artifact("RiskModuleStatusLogic.sol", "RiskModuleStatusLogic"), im, db, abi.encode(d.logics[3])
            )
        );
        // The borrow-speed and pledge-speed reads (Q-411).
        d.logics[5] = _deploy(
            "RiskModuleSpeedLogic", bytes.concat(_artifact("RiskModuleSpeedLogic.sol", "RiskModuleSpeedLogic"), im)
        );
        // RiskModuleLogics{drift, breaker, pledge, borrow, status, speed}.
        bytes memory logics =
            abi.encode(d.logics[0], d.logics[1], d.logics[2], d.logics[3], d.logics[4], d.logics[5]);
        d.implementation =
            _deploy("RiskModuleImplementation", bytes.concat(_artifact("RiskModule.sol", "RiskModule"), im, logics));
        d.proxy = _proxy("RiskModule", d.implementation, abi.encodeCall(IRiskModuleAdmin.initialize, (p.timelock)));
    }

    /// @notice AaveAdapter: user, exit, collateral and settlement logic, the router, the proxy.
    function _deployAaveAdapter(
        Predicted memory p
    ) internal returns (UpgradeableDeployment memory d) {
        AaveAdapterImmutables memory a;
        a.proxyManager = p.proxyManager;
        a.collateralization = p.collateralization;
        a.riskModule = p.riskModule;
        a.marketRegistry = p.marketRegistry;
        a.parameterStore = p.parameterStore;
        a.lpVaultSwap = p.lpVaultSwap;
        a.lock = p.lock;
        a.vaultTokenFactory = p.vaultTokenFactory;
        a.timelock = p.timelock;
        bytes memory im = abi.encode(a);
        string[4] memory names = [
            "AaveAdapterUserLogic", "AaveAdapterExitLogic", "AaveAdapterCollateralLogic", "AaveAdapterSettlementLogic"
        ];
        d.logics = new address[](4);
        for (uint256 i = 0; i < 4; ++i) {
            d.logics[i] = _deploy(names[i], bytes.concat(_artifact(string.concat(names[i], ".sol"), names[i]), im));
        }
        // AaveAdapterLogics{user, exit, collateral, settlement}.
        bytes memory logics = abi.encode(d.logics[0], d.logics[1], d.logics[2], d.logics[3]);
        d.implementation =
            _deploy("AaveAdapterImplementation", bytes.concat(_artifact("AaveAdapter.sol", "AaveAdapter"), im, logics));
        d.proxy = _proxy("AaveAdapter", d.implementation, abi.encodeCall(IAaveAdapterAdmin.initialize, (p.timelock)));
    }

    /// @notice LPVaultSwap: liquidation, pending and deleverage logic, the router, the proxy with the keepers.
    function _deployLPVaultSwap(
        ChainInputs memory c,
        Predicted memory p
    ) internal returns (UpgradeableDeployment memory d) {
        bytes memory im = abi.encode(
            LPVaultSwapImmutables({
                lock: p.lock,
                aaveAdapter: p.aaveAdapter,
                collateralization: p.collateralization,
                marketRegistry: p.marketRegistry,
                parameterStore: p.parameterStore,
                payoutEscrow: p.payoutEscrow,
                keeperFloor: c.keeperFloor
            })
        );
        string[3] memory names =
            ["LPVaultSwapLiquidationLogic", "LPVaultSwapPendingLogic", "LPVaultSwapDeleverageLogic"];
        d.logics = new address[](3);
        for (uint256 i = 0; i < 3; ++i) {
            d.logics[i] = _deploy(names[i], bytes.concat(_artifact(string.concat(names[i], ".sol"), names[i]), im));
        }
        // LPVaultSwapLogics{liquidation, pending, deleverage}.
        bytes memory logics = abi.encode(d.logics[0], d.logics[1], d.logics[2]);
        d.implementation =
            _deploy("LPVaultSwapImplementation", bytes.concat(_artifact("LPVaultSwap.sol", "LPVaultSwap"), im, logics));
        d.proxy = _proxy(
            "LPVaultSwap", d.implementation, abi.encodeCall(ILPVaultSwapAdmin.initialize, (p.timelock, c.keepers))
        );
    }

    /// @notice A fixed ERC-1967 proxy at the CREATE3 address of `name`, initialised in its constructor.
    function _proxy(
        string memory name,
        address implementation,
        bytes memory initData
    ) internal returns (address) {
        return _deploy3(name, bytes.concat(type(ERC1967Proxy).creationCode, abi.encode(implementation, initData)));
    }
}
