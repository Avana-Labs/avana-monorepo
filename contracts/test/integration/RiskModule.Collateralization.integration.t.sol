// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralization} from "../../src/custody/collateralization/ICollateralization.sol";
import {ICollateralizationBase} from "../../src/custody/collateralization/ICollateralizationBase.sol";
import {Lock} from "../../src/lock/lock/Lock.sol";
import {MarketRegistry} from "../../src/policy/market-registry/MarketRegistry.sol";
import {BreakerReasons} from "../../src/policy/market-registry/types/Breaker.sol";
import {MarketRegistryImmutables} from "../../src/policy/market-registry/types/MarketRegistryTypes.sol";
import {MarketDynamicCap} from "../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {RiskModule} from "../../src/policy/risk-module/RiskModule.sol";
import {RiskModuleImmutables} from "../../src/policy/risk-module/types/RiskModuleTypes.sol";
import {VaultTokenFactory} from "../../src/vault-token/vault-token-factory/VaultTokenFactory.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";
import {RegistrySpokeImplMock} from "../utils/mocks/MarketRegistryAaveMocks.sol";
import {
    RiskAdapterMock,
    RiskCollateralizationMock,
    RiskStoreMock,
    RiskSwapMock
} from "../utils/mocks/RiskModuleMocks.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

/// @title RiskModuleCollateralizationIntegrationTest
/// @notice The RiskModule's borrow-side checks against the real Collateralization and the real Lock, with the
/// AaveAdapter holding the Lock as it does in every borrow and withdrawal with debt: the health check reads
/// `getAccountRescueUnits` from the ledger inside that Lock session. The rest of
/// the RiskModule world (Aave reads, ParameterStore views, LPOracle, LPVault, LPVaultSwap's keeper count) is the
/// RiskModuleFixture's; the MarketRegistry, VaultTokenFactory, vault token and PositionProxy are real.
/// forge-config: default.isolate = false
contract RiskModuleCollateralizationIntegrationTest is RiskModuleFixture {
    using stdStorage for StdStorage;

    Lock internal realLock;
    ICollateralization internal ledger;

    function setUp() public {
        vm.warp(T0);
        _deployWithRealLedger();
        _world();
        _market();
        _account();
        _debt(1.5e18, 1000);
    }

    // TEST-028 verifies: REQ-VAULT-091, REQ-COLL-018, REQ-LOCK-016, REQ-RISK-065, SPEC-BRK-002
    // Sources: 2.3 REQ-COLL-018 (ledger views the RiskModule reads under the Adapter's Lock)
    /// @notice With the Adapter holding the Lock, `preBorrowCheck`, `preWithdrawCheck` and `postHealthCheck` run
    /// against the real ledger, the health check reading the rescue units.
    function test_TEST_028_borrowChecksReadLedgerUnderAdapterLock() public {
        _acquire(address(adapter));
        vm.startPrank(address(adapter));
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        riskModule.preWithdrawCheck(address(proxy));
        assertEq(riskModule.postHealthCheck(address(proxy), 0), 1.5e18);
        vm.stopPrank();
        _release(address(adapter));
    }

    // TEST-060 verifies: REQ-VAULT-091, REQ-COLL-018, REQ-LOCK-016
    /// @notice With LPVaultSwap holding the Lock, the health check's ledger read reverts `Locked`, so the post-action
    /// check cannot run inside a liquidation's call tree.
    function test_TEST_060_ledgerReadsRefusedUnderLPVaultSwapLock() public {
        address swapMember = address(lpVaultSwap);
        _acquire(swapMember);
        vm.expectRevert(ICollateralizationBase.Locked.selector);
        riskModule.postHealthCheck(address(proxy), 0);
        _release(swapMember);
        // Free again: the same check passes.
        assertEq(riskModule.postHealthCheck(address(proxy), 0), 1.5e18);
    }

    /// @notice Inside the Adapter's Lock session the dynamic borrow cap check stores the interval like any other
    /// borrow, and its view reads no ledger value, so it answers under any Lock holder.
    function test_borrowCapUnderTheAdapterLock() public {
        hub.setOwed(GHO_ASSET, address(spoke), 1_000_000e18, 0);
        store.setMarketDynamicCap(mid, MarketDynamicCap(21_600, 2500, 0, 2_500_000e8));
        _acquire(address(adapter));
        vm.prank(address(adapter));
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 100_000e18);
        (uint256 cap, uint256 debt,) = riskModule.getDynamicBorrowCap(mid);
        _release(address(adapter));
        assertEq(cap, 1_250_000e8, "D + 25 % of the debt before the first borrow: $1,000,000 + $250,000");
        assertEq(debt, 1_000_000e8);
        assertEq(riskModule.getDynamicCap(mid).cap, 1_250_000e8);
    }

    // ─── Helpers ───

    function _acquire(
        address member
    ) internal {
        vm.prank(member);
        realLock.acquire();
    }

    function _release(
        address member
    ) internal {
        vm.prank(member);
        realLock.release();
    }

    /// @dev `RiskModuleFixture._deployContracts` with the real Lock (members: the Adapter and LPVaultSwap) and the real
    /// Collateralization at the address the factory, the MarketRegistry and the RiskModule are built with.
    function _deployWithRealLedger() internal {
        _deployTimelock();
        store = new RiskStoreMock();
        ps = store;
        adapter = new RiskAdapterMock();
        adapterMock = adapter;
        swap = new RiskSwapMock();
        spokeImpl = new RegistrySpokeImplMock();
        realLock = new Lock(address(adapter), address(lpVaultSwap));
        lockAddr = address(realLock);
        // The factory names the registry, which is created after it: a dry run finds the registry's address, the state
        // is rolled back, and the same sequence of creations runs again with that address.
        uint256 dryRun = vm.snapshotState();
        _deployLedgerRegistryAndRisk(address(1));
        address registryAddress = address(registry);
        vm.revertToState(dryRun);
        _deployLedgerRegistryAndRisk(registryAddress);
    }

    /// @dev The VaultTokenFactory (naming `marketRegistry_`), the real Collateralization, the MarketRegistry and the
    /// RiskModule, each at the address the others were built with.
    function _deployLedgerRegistryAndRisk(
        address marketRegistry_
    ) internal {
        uint256 n = vm.getNonce(address(this));
        address predictedLedger = vm.computeCreateAddress(address(this), n + 1);
        factory = new VaultTokenFactory(
            address(adapter), address(lpVaultSwap), predictedLedger, address(timelock), marketRegistry_
        );
        // After the ledger (nonce n + 1): registry logics (5), registry implementation and proxy, risk logics (6),
        // risk implementation and proxy.
        address predictedRisk = vm.computeCreateAddress(address(this), n + 16);
        ledger = ICollateralization(
            deployCode(
                "Collateralization.sol:Collateralization",
                abi.encode(address(adapter), address(lpVaultSwap), predictedRisk, lockAddr, address(factory))
            )
        );
        require(address(ledger) == predictedLedger, "ledger prediction");
        coll = RiskCollateralizationMock(address(ledger));
        collat = coll;
        im = MarketRegistryImmutables({
            timelock: address(timelock),
            aaveGovernanceExecutor: aaveGovernanceExecutor,
            vaultTokenFactory: address(factory),
            aaveAdapter: address(adapter),
            collateralization: address(ledger),
            lock: lockAddr,
            proxyManager: proxyManager,
            parameterStore: address(store),
            riskModule: predictedRisk,
            lpVaultSwap: address(lpVaultSwap),
            payoutEscrow: payoutEscrow,
            flashLiquidator: flashLiquidator,
            standardSpokeImplementation: address(spokeImpl),
            maxMarketCount: 64
        });
        logics = _deployLogics(im);
        MarketRegistry impl = new MarketRegistry(im, logics);
        registry = MarketRegistry(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(MarketRegistry.initialize, (address(timelock)))))
        );
        rmIm = RiskModuleImmutables({
            marketRegistry: address(registry),
            parameterStore: address(store),
            collateralization: address(ledger),
            adapter: address(adapter),
            lpVaultSwap: address(swap),
            timelock: address(timelock)
        });
        rmLogics = _deployRiskLogics(rmIm);
        RiskModule rmImpl = new RiskModule(rmIm, rmLogics);
        riskModule = RiskModule(
            address(new ERC1967Proxy(address(rmImpl), abi.encodeCall(RiskModule.initialize, (address(timelock)))))
        );
        require(address(riskModule) == predictedRisk, "risk module prediction");
    }
}
