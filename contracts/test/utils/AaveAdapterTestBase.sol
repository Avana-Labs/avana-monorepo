// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AaveAdapter} from "../../src/adapter/AaveAdapter.sol";
import {IRiskModule} from "../../src/risk/interfaces/IRiskModule.sol";
import {VaultToken} from "../../src/token/VaultToken.sol";
import {IVaultToken} from "../../src/token/interfaces/IVaultToken.sol";
import {ILPVault} from "../../src/vault/interfaces/ILPVault.sol";
import {AdapterTestHub, AdapterTestRiskModule, AdapterTestSpoke} from "./mocks/AaveAdapterTestMocks.sol";
import {LPVaultTestToken, MockLPVault, MockPositionManager} from "./mocks/LPVaultMocks.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Shared setup: the real LPVault (mock AMM) and VaultTokens, a RiskModule stand-in with the real routing
/// rule, a small Spoke with a health check, one pool listed as Full range (market 1) and Custom range `[-1000, 1000]`
/// (market 2), a debt reserve funded on the Hub, and the adapter holding its roles.
abstract contract AaveAdapterTestBase is Test {
    uint64 internal constant ADAPTER_ROLE = 11;
    bytes32 internal constant POOL = bytes32(uint256(0xA001));
    bytes32 internal constant POOL_UNLISTED = bytes32(uint256(0xB002));
    int24 internal constant SPACING = 10;
    int24 internal constant FULL_LOWER = -887_270;
    int24 internal constant FULL_UPPER = 887_270;
    int24 internal constant BAND_LOWER = -1000;
    int24 internal constant BAND_UPPER = 1000;
    uint256 internal constant FULL = 1;
    uint256 internal constant CUSTOM = 2;
    uint256 internal constant DEBT_RESERVE = 10;
    /// @dev Collateral factor of both markets: one credit unit backs 0.8 debt units.
    uint256 internal constant CF_BPS = 8000;

    AccessManager internal am;
    LPVaultTestToken internal token0;
    LPVaultTestToken internal token1;
    LPVaultTestToken internal usdc;
    MockPositionManager internal pm;
    MockLPVault internal vault;
    AdapterTestRiskModule internal rm;
    AdapterTestHub internal hub;
    AdapterTestSpoke internal spoke;
    VaultToken internal vtFull;
    VaultToken internal vtCustom;
    AaveAdapter internal adapter;

    address internal alice;
    address internal bob;
    address internal carol;
    address internal liquidationModule = makeAddr("liquidationModule");

    function setUp() public virtual {
        // Wallets come from keys made at run time.
        (alice,) = makeAddrAndKey(string(abi.encode("alice", block.timestamp)));
        (bob,) = makeAddrAndKey(string(abi.encode("bob", block.timestamp)));
        (carol,) = makeAddrAndKey(string(abi.encode("carol", block.timestamp)));

        am = new AccessManager(address(this));
        token0 = new LPVaultTestToken("T0");
        token1 = new LPVaultTestToken("T1");
        usdc = new LPVaultTestToken("USDC");
        pm = new MockPositionManager(token0, token1);
        vault = new MockLPVault(address(am), pm);
        vault.setPool(POOL, SPACING);
        vault.setPool(POOL_UNLISTED, SPACING);
        vault.listMarket(FULL, POOL, FULL_LOWER, FULL_UPPER);
        vault.listMarket(CUSTOM, POOL, BAND_LOWER, BAND_UPPER);

        hub = new AdapterTestHub();
        spoke = new AdapterTestSpoke(hub);
        hub.setSpoke(address(spoke));
        rm = new AdapterTestRiskModule(address(vault));
        adapter = new AaveAdapter(address(rm));
        spoke.setManagerActive(address(adapter), true);

        vtFull = new VaultToken(_params("F", FULL));
        vtCustom = new VaultToken(_params("C", CUSTOM));
        spoke.setReserve(FULL, address(vtFull), 1, CF_BPS);
        spoke.setReserve(CUSTOM, address(vtCustom), 1, CF_BPS);
        spoke.setReserve(DEBT_RESERVE, address(usdc), 0, 0);
        usdc.mint(address(hub), 1e30);

        rm.setMarket(FULL, _market(FULL, FULL_LOWER, FULL_UPPER, IRiskModule.MarketKind.FullRange, vtFull));
        rm.setMarket(CUSTOM, _market(CUSTOM, BAND_LOWER, BAND_UPPER, IRiskModule.MarketKind.CustomRange, vtCustom));

        _grantAdapterRoles();
        address[3] memory wallets = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(wallets[i]);
            pm.setApprovalForAll(address(vault), true);
            token0.approve(address(vault), type(uint256).max);
            token1.approve(address(vault), type(uint256).max);
            usdc.approve(address(adapter), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _grantAdapterRoles() internal {
        bytes4[] memory vaultSelectors = new bytes4[](5);
        vaultSelectors[0] = ILPVault.pledge.selector;
        vaultSelectors[1] = ILPVault.addLiquidity.selector;
        vaultSelectors[2] = ILPVault.removeLiquidity.selector;
        vaultSelectors[3] = ILPVault.release.selector;
        vaultSelectors[4] = ILPVault.collectFees.selector;
        am.setTargetFunctionRole(address(vault), vaultSelectors, ADAPTER_ROLE);
        bytes4[] memory tokenSelectors = new bytes4[](3);
        tokenSelectors[0] = IVaultToken.mint.selector;
        tokenSelectors[1] = IVaultToken.burn.selector;
        tokenSelectors[2] = IVaultToken.addValidProxy.selector;
        am.setTargetFunctionRole(address(vtFull), tokenSelectors, ADAPTER_ROLE);
        am.setTargetFunctionRole(address(vtCustom), tokenSelectors, ADAPTER_ROLE);
        am.grantRole(ADAPTER_ROLE, address(adapter), 0);
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
            liquidationModule: liquidationModule,
            authority: address(am)
        });
    }

    function _market(
        uint256 reserveId,
        int24 lower,
        int24 upper,
        IRiskModule.MarketKind kind,
        VaultToken vt
    ) internal view returns (IRiskModule.Market memory m) {
        m.pool = POOL;
        m.spoke = address(spoke);
        m.vaultToken = address(vt);
        m.lpOracle = address(0xBEEF);
        m.reserveId = reserveId;
        m.bandLower = lower;
        m.bandUpper = upper;
        m.ltvBps = uint16(CF_BPS);
        m.unitDecimals = 18;
        m.kind = kind;
        m.active = true;
    }

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

    function _supplied(
        address wallet,
        uint256 marketId
    ) internal view returns (uint256) {
        return spoke.supplied(adapter.accountOf(wallet, marketId), marketId);
    }
}
