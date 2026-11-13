// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AaveV3FlashSource} from "../../../src/flash/AaveV3FlashSource.sol";
import {ILPVaultSwap} from "../../../src/liquidation/lp-vault-swap/ILPVaultSwap.sol";
import {LPVaultSwap} from "../../../src/liquidation/lp-vault-swap/LPVaultSwap.sol";
import {LPVaultSwapImmutables} from "../../../src/liquidation/lp-vault-swap/types/LPVaultSwapImmutables.sol";
import {LPVaultSwapLogics} from "../../../src/liquidation/lp-vault-swap/types/LPVaultSwapLogics.sol";
import {PayoutEscrow} from "../../../src/liquidation/payout-escrow/PayoutEscrow.sol";
import {AaveAdapter} from "../../../src/policy/aave-adapter/AaveAdapter.sol";
import {AaveAdapterCollateralLogic} from "../../../src/policy/aave-adapter/AaveAdapterCollateralLogic.sol";
import {AaveAdapterExitLogic} from "../../../src/policy/aave-adapter/AaveAdapterExitLogic.sol";
import {AaveAdapterSettlementLogic} from "../../../src/policy/aave-adapter/AaveAdapterSettlementLogic.sol";
import {AaveAdapterUserLogic} from "../../../src/policy/aave-adapter/AaveAdapterUserLogic.sol";
import {IAaveAdapter} from "../../../src/policy/aave-adapter/IAaveAdapter.sol";
import {AaveAdapterImmutables} from "../../../src/policy/aave-adapter/types/AaveAdapterImmutables.sol";
import {AaveAdapterLogics} from "../../../src/policy/aave-adapter/types/AaveAdapterLogics.sol";
import {ProxyManager} from "../../../src/proxy/proxy-manager/ProxyManager.sol";
import {
    AdapterParameterStoreMock,
    AdapterPlaceholder,
    AdapterRegistryMock,
    AdapterRiskModuleMock
} from "../mocks/AaveAdapterMocks.sol";
import {MockAaveV3ACLManager, MockAaveV3AddressesProvider, MockAaveV3Pool} from "../mocks/AaveV3PoolMocks.sol";
import {LVSLPOracleMock, LVSLyingRoute, LVSParameterStoreMock} from "../mocks/LPVaultSwapMocks.sol";
import {AaveAdapterFixture} from "./AaveAdapterFixture.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title AdapterSwapFixture
/// @notice The real AaveAdapter and the real LPVaultSwap wired to each other on the real local Aave V4, with the real
/// Lock, Collateralization, VaultTokenFactory, vault tokens, ProxyManager, PositionProxies, PayoutEscrow and
/// AaveV3FlashSource (over a mocked Aave V3 Pool). The MarketRegistry and RiskModule are the Adapter suites' stand-ins;
/// the ParameterStore is LPVaultSwap's stand-in, which also answers the Adapter's `sequencer()`; the LPOracle LPVaultSwap
/// reads for market 4 is `LVSLPOracleMock` at $2.00 with USDC $1.00 and USDT $1.00; each pool token swaps into GHO
/// through an `LVSLyingRoute` whose output each test sets (a sandwiched leg is a lower output).
/// @dev Both proxies are deployed first behind a placeholder, so every immutable contract is built with their final
/// addresses; each is then upgraded to its real implementation.
abstract contract AdapterSwapFixture is AaveAdapterFixture {
    uint256 internal constant P_VT = 200_000_000;

    ILPVaultSwap internal lvs;
    LVSParameterStoreMock internal lvsStore;
    LVSLPOracleMock internal lvsOracle;
    PayoutEscrow internal escrow;
    AaveV3FlashSource internal flashSource;
    MockAaveV3Pool internal v3Pool;
    LVSLyingRoute internal usdcRoute;
    LVSLyingRoute internal usdtRoute;

    function setUp() public virtual override {
        AdapterPlaceholder placeholder = new AdapterPlaceholder();
        adapter = address(new ERC1967Proxy(address(placeholder), ""));
        lpVaultSwap = address(new ERC1967Proxy(address(placeholder), ""));
        _deployCollateralization();

        registry = new AdapterRegistryMock();
        proxyManager = new ProxyManager(adapter, address(registry));
        risk = new AdapterRiskModuleMock(aave.cdpSpoke, address(coll));
        risk.setVaultToken(vt);
        lvsStore = new LVSParameterStoreMock();
        im = AaveAdapterImmutables({
            proxyManager: address(proxyManager),
            collateralization: address(coll),
            riskModule: address(risk),
            marketRegistry: address(registry),
            parameterStore: address(lvsStore),
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
        _deploySwap();
        _wireSwap();
    }

    /// @dev The real LPVaultSwap (three logic contracts and the implementation) behind the predicted proxy.
    function _deploySwap() internal {
        escrow = new PayoutEscrow(lpVaultSwap, address(lock));
        LPVaultSwapImmutables memory lim = LPVaultSwapImmutables({
            lock: address(lock),
            aaveAdapter: adapter,
            collateralization: address(coll),
            marketRegistry: address(registry),
            parameterStore: address(lvsStore),
            payoutEscrow: address(escrow),
            keeperFloor: KEEPER_FLOOR
        });
        address liq = deployCode("LPVaultSwapLiquidationLogic.sol:LPVaultSwapLiquidationLogic", abi.encode(lim));
        address pend = deployCode("LPVaultSwapPendingLogic.sol:LPVaultSwapPendingLogic", abi.encode(lim));
        address delev = deployCode("LPVaultSwapDeleverageLogic.sol:LPVaultSwapDeleverageLogic", abi.encode(lim));
        LPVaultSwap impl = new LPVaultSwap(lim, LPVaultSwapLogics(liq, pend, delev));
        address[] memory keepers = new address[](1);
        keepers[0] = keeper;
        AdapterPlaceholder(lpVaultSwap)
            .upgradeToAndCall(address(impl), abi.encodeCall(LPVaultSwap.initialize, (timelock, keepers)));
        lvs = ILPVaultSwap(lpVaultSwap);
    }

    /// @dev LPVaultSwap's reads for market 4 and the GHO reserve: its oracle, slippage, floor allowance, flash source,
    /// routes and escrow.
    function _wireSwap() internal {
        uint256[] memory prices = new uint256[](2);
        (prices[0], prices[1]) = (1e8, 1e8);
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(usdc), address(usdt));
        lvsOracle = new LVSLPOracleMock(int256(P_VT), tokens, prices);
        registry.setMarketOracle(MARKET_ID, address(lvsOracle), address(lpVault));
        lvsStore.setSlippage(MARKET_ID, 100);
        lvsStore.setFloorRoundingAllowance(address(debt), 1e18);
        lvsStore.setFeeRecipient(makeAddr("feeRecipient"));
        registry.setPayoutEscrow(address(escrow));

        MockAaveV3ACLManager acl = new MockAaveV3ACLManager();
        v3Pool = new MockAaveV3Pool(address(new MockAaveV3AddressesProvider(address(acl))), 5);
        address aToken = v3Pool.listReserve(address(debt));
        debt.mint(aToken, 1_000_000e18);
        v3Pool.recordSupply(address(debt), 1_000_000e18);
        flashSource = new AaveV3FlashSource(address(v3Pool), lpVaultSwap, address(lvsStore));
        registry.setFlashSource(address(flashSource));

        usdcRoute = new LVSLyingRoute(address(usdc), address(debt));
        usdtRoute = new LVSLyingRoute(address(usdt), address(debt));
        debt.mint(address(usdcRoute), 1_000_000e18);
        debt.mint(address(usdtRoute), 1_000_000e18);
        for (uint8 kind = 0; kind < 2; ++kind) {
            registry.setRouteContract(MARKET_ID, address(usdc), address(debt), kind, address(usdcRoute));
            registry.setRouteContract(MARKET_ID, address(usdt), address(debt), kind, address(usdtRoute));
        }
        vm.label(lpVaultSwap, "LPVaultSwap");
        vm.label(address(flashSource), "AaveV3FlashSource");
    }

    /// @dev Each leg of an unwind of `units` swaps at $1 per pool token (GHO wei per raw unit 1e12), less `cutBps`.
    function _setLegs(
        uint256 units,
        uint256 cutBps
    ) internal {
        usdcRoute.setOut(units * 800_000 / 1e6 * 1e12 * (10_000 - cutBps) / 10_000);
        usdtRoute.setOut(units * 1_250_000 / 1e6 * 1e12 * (10_000 - cutBps) / 10_000);
    }
}
