// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IMarketRegistry} from "../../src/policy/market-registry/IMarketRegistry.sol";
import {MarketRegistry} from "../../src/policy/market-registry/MarketRegistry.sol";
import {MarketRegistryActivationLogic} from "../../src/policy/market-registry/MarketRegistryActivationLogic.sol";
import {MarketRegistryHubsLogic} from "../../src/policy/market-registry/MarketRegistryHubsLogic.sol";
import {MarketRegistryListingLogic} from "../../src/policy/market-registry/MarketRegistryListingLogic.sol";
import {MarketRegistryRoutesLogic} from "../../src/policy/market-registry/MarketRegistryRoutesLogic.sol";
import {MarketRegistrySafetyLogic} from "../../src/policy/market-registry/MarketRegistrySafetyLogic.sol";
import {MarketRegistryWindDownLogic} from "../../src/policy/market-registry/MarketRegistryWindDownLogic.sol";
import {DebtReserveDef} from "../../src/policy/market-registry/types/DebtReserveDef.sol";
import {IssuerProbe} from "../../src/policy/market-registry/types/IssuerProbe.sol";
import {MarketRegistryImmutables} from "../../src/policy/market-registry/types/MarketRegistryImmutables.sol";
import {MarketRegistryLogics} from "../../src/policy/market-registry/types/MarketRegistryLogics.sol";
import {MarketStatus} from "../../src/policy/market-registry/types/MarketStatus.sol";
import {RiskTier} from "../../src/policy/market-registry/types/RiskTier.sol";
import {SpokeDef} from "../../src/policy/market-registry/types/SpokeDef.sol";
import {TokenDef} from "../../src/policy/market-registry/types/TokenDef.sol";
import {MarketDef} from "../../src/types/MarketDef.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {
    RegistryAaveOracleMock,
    RegistryHubMock,
    RegistrySpokeImplMock,
    RegistrySpokeMock
} from "../utils/mocks/MarketRegistryAaveMocks.sol";
import {
    RegistryAdapterMock,
    RegistryAvanaFirstLossReserveMock,
    RegistryCollateralizationMock,
    RegistryFeedMock,
    RegistryFlashSourceMock,
    RegistryLPOracleMock,
    RegistryLPVaultMock,
    RegistryParameterStoreMock,
    RegistryRiskModuleMock,
    RegistryRouteMock,
    RegistryTokenMock
} from "../utils/mocks/MarketRegistryMocks.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

/// @title HalmosVaultTokenMock
/// @notice The vault-token bindings the MarketRegistry reads at listing, fixed at creation.
contract HalmosVaultTokenMock {
    bytes32 public marketKey;
    uint32 public integrationId;
    address public integration;
    address public hub;
    address public spoke;
    uint256 public marketId;
    address public lpOracle;
    address public adapter;
    address public collateralization;
    address public lpVaultSwap;
    uint8 public constant decimals = 18;

    constructor(
        bytes32 key,
        uint32 id,
        address[7] memory a,
        uint256 marketId_
    ) {
        (marketKey, integrationId, marketId) = (key, id, marketId_);
        (integration, hub, spoke, lpOracle, adapter, collateralization, lpVaultSwap) =
        (a[0], a[1], a[2], a[3], a[4], a[5], a[6]);
    }
}

/// @title HalmosVaultTokenFactoryMock
/// @notice The VaultTokenFactory reads of the MarketRegistry with the factory's key formula and one token per
/// (Spoke, market key). Halmos assigns its own addresses to `CREATE`, so the real factory's CREATE3 address check
/// cannot run symbolically; the registry's own key checks are the subject here.
contract HalmosVaultTokenFactoryMock {
    address internal immutable _ADAPTER;
    address internal immutable _COLLATERALIZATION;
    address internal immutable _LP_VAULT_SWAP;
    mapping(uint32 => address) public lpVaultOf;
    mapping(address => mapping(bytes32 => address)) public tokenOf;

    constructor(
        address adapter,
        address collateralization,
        address lpVaultSwap
    ) {
        (_ADAPTER, _COLLATERALIZATION, _LP_VAULT_SWAP) = (adapter, collateralization, lpVaultSwap);
    }

    function registerIntegration(
        uint32 id,
        address lpVault
    ) external {
        lpVaultOf[id] = lpVault;
    }

    function marketKeyOf(
        uint32 integrationId,
        address pool,
        bytes32 poolId,
        PositionShape calldata shape
    ) public view returns (bytes32) {
        return
            keccak256(
                abi.encode(block.chainid, integrationId, pool, poolId, shape.kind, shape.tickLower, shape.tickUpper)
            );
    }

    function deploy(
        uint32 integrationId,
        address pool,
        PositionShape calldata shape,
        address hub,
        address spoke,
        uint256 marketId,
        address lpOracle
    ) external returns (address token) {
        bytes32 key = marketKeyOf(integrationId, pool, bytes32(0), shape);
        require(tokenOf[spoke][key] == address(0), "TokenExistsForMarket");
        address[7] memory a =
            [lpVaultOf[integrationId], hub, spoke, lpOracle, _ADAPTER, _COLLATERALIZATION, _LP_VAULT_SWAP];
        token = address(new HalmosVaultTokenMock(key, integrationId, a, marketId));
        tokenOf[spoke][key] = token;
    }
}

/// @title MarketRegistryMarketsHalmosTest
/// @notice Symbolic checks of the real MarketRegistry's market records: every sequence of lifecycle calls, at any
/// times, moves a market only along the status machine, and no two markets that share a key are live at once.
/// @dev World: the Stable LP Hub, integration 1, the CDP Spoke with GHO enabled, USDC and USDT listed, market 1
/// (USDC/USDT `[-50, 50]`) `Registered` with its Aave payload and routes in place, and a vault token for a second
/// shape `[-100, 100]` that names market 1's LPOracle, so listing it collides with market 1 on the LPOracle key. Actors
/// are constant addresses; the timelock is an EOA holding `APPLICATION_ADMIN`.
contract MarketRegistryMarketsHalmosTest is Test {
    address internal constant TIMELOCK = address(0x7311);
    address internal constant EXECUTOR = address(0x7312);
    address internal constant LOCK = address(0x7313);
    address internal constant PROXY_MANAGER = address(0x7314);
    address internal constant LP_VAULT_SWAP = address(0x7315);
    address internal constant ESCROW = address(0x7316);
    address internal constant HELPER = address(0x7317);
    address internal constant POOL = address(0x7318);
    address internal constant AAVE_POOL = address(0x7319);
    address internal constant PRICING = address(0x731A);
    address internal constant ANYONE = address(0x731B);
    uint32 internal constant V3 = 1;
    uint256 internal constant VT_ASSET = 1;
    uint256 internal constant VT_RESERVE = 1;

    IMarketRegistry internal registry;
    HalmosVaultTokenFactoryMock internal factory;
    RegistryParameterStoreMock internal ps;
    RegistryCollateralizationMock internal collat;
    RegistryHubMock internal hub;
    RegistrySpokeMock internal spoke;
    RegistryLPVaultMock internal lpVault;
    RegistryTokenMock internal usdc;
    RegistryTokenMock internal usdt;
    RegistryTokenMock internal gho;
    address internal vt1;
    address internal vt2;
    address internal oracle1;

    function setUp() public {
        collat = new RegistryCollateralizationMock(LOCK);
        ps = new RegistryParameterStoreMock();
        RegistryRiskModuleMock rm = new RegistryRiskModuleMock();
        RegistryAdapterMock adapter = new RegistryAdapterMock();
        RegistrySpokeImplMock spokeImpl = new RegistrySpokeImplMock();
        factory = new HalmosVaultTokenFactoryMock(address(adapter), address(collat), LP_VAULT_SWAP);
        MarketRegistryImmutables memory im = MarketRegistryImmutables({
            timelock: TIMELOCK,
            aaveGovernanceExecutor: EXECUTOR,
            vaultTokenFactory: address(factory),
            aaveAdapter: address(adapter),
            collateralization: address(collat),
            lock: LOCK,
            proxyManager: PROXY_MANAGER,
            parameterStore: address(ps),
            riskModule: address(rm),
            lpVaultSwap: LP_VAULT_SWAP,
            payoutEscrow: ESCROW,
            flashLiquidator: HELPER,
            standardSpokeImplementation: address(spokeImpl),
            maxMarketCount: 1000
        });
        MarketRegistryLogics memory l;
        l.hubs = address(new MarketRegistryHubsLogic(im));
        l.listing = address(new MarketRegistryListingLogic(im));
        l.activation = address(new MarketRegistryActivationLogic(im));
        l.routes = address(new MarketRegistryRoutesLogic(im));
        l.safety = address(new MarketRegistrySafetyLogic(im));
        l.windDown = address(new MarketRegistryWindDownLogic(im));
        MarketRegistry impl = new MarketRegistry(im, l);
        registry = IMarketRegistry(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(MarketRegistry.initialize, (TIMELOCK))))
        );
        hub = new RegistryHubMock();
        spoke = new RegistrySpokeMock();
        RegistryAaveOracleMock aaveOracle = new RegistryAaveOracleMock();
        spoke.setOracle(address(aaveOracle));
        spoke.setImplementation(address(spokeImpl));
        aaveOracle.setSpoke(address(spoke));
        lpVault = new RegistryLPVaultMock(V3, address(collat), LOCK);
        lpVault.setRegistry(address(registry));
        usdc = new RegistryTokenMock(6);
        usdt = new RegistryTokenMock(6);
        gho = new RegistryTokenMock(18);
        address[] memory toks = new address[](2);
        (toks[0], toks[1]) = (address(usdc), address(usdt));
        lpVault.setPoolTokens(toks, 18);
        RegistryFeedMock ghoSource = new RegistryFeedMock(8, 1e8);
        RegistryAvanaFirstLossReserveMock ghoCoverage =
            new RegistryAvanaFirstLossReserveMock(address(hub), address(gho), 0);
        ghoCoverage.setFunded(4e24, false);
        hub.setAsset(address(gho), 0);
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals) = (address(gho), address(hub), 0, 18);
        IAaveV4Spoke.ReserveConfig memory c;
        c.borrowable = true;
        IAaveV4Spoke.DynamicReserveConfig memory d;
        spoke.setReserve(0, r, c, d);
        aaveOracle.setSource(0, address(ghoSource));
        hub.setSpokeConfig(0, address(spoke), 0, 1_000_000);

        vm.startPrank(TIMELOCK);
        factory.registerIntegration(V3, address(lpVault));
        registry.recordHub(address(hub), RiskTier.Stable);
        registry.registerIntegration(V3, address(lpVault), PRICING);
        // The integration's position manager, recorded and finalized so its routes can be set (REQ-MREG-035).
        address[] memory amm = new address[](1);
        amm[0] = address(new RegistryTokenMock(18));
        registry.recordIntegrationContracts(V3, amm);
        registry.finalizeIntegrationContracts(V3);
        registry.deployCdpSpoke(
            SpokeDef(false, address(hub), V3, RiskTier.Stable, address(spokeImpl), address(aaveOracle))
        );
        registry.setFlashSource(address(new RegistryFlashSourceMock(AAVE_POOL, LP_VAULT_SWAP)));
        registry.setAvanaFirstLossReserve(address(hub), address(gho), address(ghoCoverage));
        registry.recordCreditLine(address(hub), address(gho), 20_000_000);
        vm.stopPrank();
        _listToken(address(gho), IssuerProbe.None);
        vm.prank(TIMELOCK);
        registry.enableDebtReserve(
            address(spoke),
            DebtReserveDef(
                0, address(gho), 18, address(hub), 0, address(ghoSource), true, address(ghoCoverage), false, false
            )
        );
        _listToken(address(usdc), IssuerProbe.PausedFlag);
        _listToken(address(usdt), IssuerProbe.PausedFlag);

        // Market 1, Registered, with its Aave payload, parameters and routes into GHO.
        oracle1 = address(new RegistryLPOracleMock(1, address(lpVault)));
        vt1 = _deployToken(1, _shape(-50, 50), oracle1);
        vm.prank(TIMELOCK);
        registry.listCollateralMarket(_def(vt1, -50, 50));
        hub.setAsset(vt1, VT_ASSET);
        hub.setSpokeConfig(VT_ASSET, address(spoke), 2_000_000, 0);
        (r.underlying, r.hub, r.assetId, r.decimals) = (vt1, address(hub), uint16(VT_ASSET), 18);
        c.borrowable = false;
        (d.collateralFactor, d.maxLiquidationBonus) = (7500, 10_500);
        spoke.setReserve(VT_RESERVE, r, c, d);
        spoke.setLiquidationConfig(1.1e18, 5000);
        ps.setLiquidationExpectations(address(spoke), 1.1e18, 200);
        ps.setMarket(1, 9500, 10e8, 1_000_000e8, 100_000e8, 1e8);
        _route(address(usdc), 0, address(0xD1));
        _route(address(usdc), 1, address(0xD2));
        _route(address(usdt), 0, address(0xD3));
        _route(address(usdt), 1, address(0xD4));
        // A second shape whose vault token names market 1's LPOracle: its listing collides on the LPOracle key.
        vt2 = _deployToken(2, _shape(-100, 100), oracle1);
    }

    function _shape(
        int24 lo,
        int24 hi
    ) internal pure returns (PositionShape memory) {
        return PositionShape(ShapeKind.TickRange, lo, hi);
    }

    function _def(
        address vaultToken,
        int24 lo,
        int24 hi
    ) internal view returns (MarketDef memory d) {
        d.hub = address(hub);
        d.spoke = address(spoke);
        d.integrationId = V3;
        d.pool = POOL;
        d.shape = _shape(lo, hi);
        d.vaultToken = vaultToken;
        d.lpOracle = oracle1;
    }

    function _deployToken(
        uint256 marketId,
        PositionShape memory shape,
        address lpOracle
    ) internal returns (address token) {
        token = factory.deploy(V3, POOL, shape, address(hub), address(spoke), marketId, lpOracle);
    }

    function _feed() internal returns (address[] memory route) {
        route = new address[](1);
        route[0] = address(new RegistryFeedMock(8, 1e8));
        ps.setFeed(route[0], 8, 86_400, 25, 25);
    }

    function _listToken(
        address token,
        IssuerProbe probe
    ) internal {
        TokenDef memory t;
        t.isUsdStable = true;
        t.primaryRoute = _feed();
        t.alternateRoute = _feed();
        t.standbyRoute = _feed();
        t.replacedSlot = RouteSlot.None;
        t.issuerProbe = probe;
        ps.setTolerance(token, 100, 50);
        vm.prank(TIMELOCK);
        registry.listToken(token, t);
    }

    function _route(
        address token,
        uint8 kind,
        address dep
    ) internal {
        address[] memory deps = new address[](1);
        deps[0] = dep;
        RegistryRouteMock route = new RegistryRouteMock(token, address(gho), LP_VAULT_SWAP, deps);
        vm.prank(TIMELOCK);
        registry.setRoute(1, token, address(gho), kind, address(route));
    }

    function _status(
        uint256 id
    ) internal view returns (MarketStatus) {
        return registry.getMarket(id).status;
    }

    function _live(
        MarketStatus s
    ) internal pure returns (bool) {
        return s == MarketStatus.Registered || s == MarketStatus.Active || s == MarketStatus.Offboarding;
    }

    /// @dev One lifecycle call chosen by `op`: activate, cancel or offboard market 1 (the timelock), close market 1
    /// (anyone), relist market 1, or list the colliding second shape (the timelock).
    function _op(
        uint8 op
    ) internal returns (bool ok) {
        uint8 k = op % 6;
        bytes memory data;
        address caller = TIMELOCK;
        if (k == 0) data = abi.encodeCall(registry.activateMarket, (1));
        else if (k == 1) data = abi.encodeCall(registry.cancelRegistration, (1));
        else if (k == 2) data = abi.encodeCall(registry.setMarketOffboarding, (1));
        else if (k == 3) (data, caller) = (abi.encodeCall(registry.closeMarket, (1)), ANYONE);
        else if (k == 4) data = abi.encodeCall(registry.listCollateralMarket, (_def(vt1, -50, 50)));
        else data = abi.encodeCall(registry.listCollateralMarket, (_def(vt2, -100, 100)));
        vm.prank(caller);
        (ok,) = address(registry).call(data);
    }

    // PROP-098 verifies: REQ-CONFIG-007, REQ-CONFIG-012, REQ-CONFIG-013, REQ-CONFIG-042, REQ-CONFIG-048, REQ-CONFIG-080, REQ-MREG-015, REQ-MREG-030
    /// @notice After any three lifecycle calls at any times: market 1 moves only Registered → Active → Offboarding →
    /// Closed or Registered ⇄ Cancelled (a relisting), never back to Active and never out of Closed; a close happens
    /// only after the notice period from `offboardedAt`; market 2, which shares market 1's LPOracle, is never live
    /// while market 1 is; and `marketOfLpOracle` names the live one.
    function check_PROP_098_statusMachineAndKeyUniqueness(
        uint8 op1,
        uint8 op2,
        uint8 op3,
        uint32 dt1,
        uint32 dt2,
        uint32 dt3
    ) public {
        uint8[3] memory ops = [op1, op2, op3];
        uint32[3] memory dts = [dt1, dt2, dt3];
        for (uint256 i = 0; i < 3; ++i) {
            vm.warp(block.timestamp + dts[i]);
            MarketStatus b1 = _status(1);
            MarketStatus b2 = _status(2);
            uint64 offboardedAt = registry.windDownState(1).offboardedAt;
            bool ok = _op(ops[i]);
            MarketStatus a1 = _status(1);
            MarketStatus a2 = _status(2);
            uint8 k = ops[i] % 6;
            if (!ok || k == 5) assert(a1 == b1);
            if (!ok || k != 5) assert(a2 == b2);
            if (ok && k == 0) assert(b1 == MarketStatus.Registered && a1 == MarketStatus.Active);
            if (ok && k == 1) assert(b1 == MarketStatus.Registered && a1 == MarketStatus.Cancelled);
            if (ok && k == 2) assert(b1 == MarketStatus.Active && a1 == MarketStatus.Offboarding);
            if (ok && k == 3) {
                assert(b1 == MarketStatus.Offboarding && a1 == MarketStatus.Closed);
                assert(block.timestamp >= uint256(offboardedAt) + 5 days);
            }
            if (ok && k == 4) assert(b1 == MarketStatus.Cancelled && a1 == MarketStatus.Registered);
            if (ok && k == 5) assert(!_live(b1) && a2 == MarketStatus.Registered);
            assert(!(_live(a1) && _live(a2)));
            uint256 m = registry.marketOfLpOracle(oracle1);
            if (_live(a1)) assert(m == 1);
            if (_live(a2)) assert(m == 2);
        }
    }
}
