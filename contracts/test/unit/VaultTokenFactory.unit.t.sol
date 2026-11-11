// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PoolKeying} from "../../src/amm/types/PoolKeying.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {VaultTokenBindings} from "../../src/types/VaultTokenBindings.sol";
import {IVaultTokenFactory} from "../../src/vault-token/vault-token-factory/IVaultTokenFactory.sol";
import {VaultTokenFactory} from "../../src/vault-token/vault-token-factory/VaultTokenFactory.sol";
import {IVaultToken} from "../../src/vault-token/vault-token/IVaultToken.sol";
import {VaultToken} from "../../src/vault-token/vault-token/VaultToken.sol";
import {VaultTokenFactoryFixture} from "../utils/fixtures/VaultTokenFactoryFixture.sol";
import {CollateralizationLockMock} from "../utils/mocks/CollateralizationLockMock.sol";
import {LPVaultIdentityMock} from "../utils/mocks/LPVaultIdentityMock.sol";
import {CREATE3} from "solady/utils/CREATE3.sol";

/// @notice An LPVault whose identity getters misbehave: each getter reverts, returns a short answer, or (for
/// `INTEGRATION_ID`) writes state, which a `STATICCALL` refuses.
contract HostileLPVaultMock {
    uint256 public mode;
    uint256 public writes;

    function setMode(
        uint256 m
    ) external {
        mode = m;
    }

    function INTEGRATION_ID() external returns (uint32) {
        if (mode == 0) revert("hostile");
        if (mode == 1) {
            // A one-byte answer: shorter than the 32-byte word the factory requires.
            assembly ("memory-safe") {
                mstore(0, 0)
                return(0, 1)
            }
        }
        ++writes;
        return 2;
    }
}

/// @title VaultTokenFactoryUnitTest
/// @notice The VaultTokenFactory (2.4 Deployment): constructor checks, the write-once integration registry, and
/// `deployVaultToken`: timelock only, the listing checks in order, the token's binding checks surfaced before CREATE3,
/// one token per (CDP Spoke, market key) at the predicted address, and the bindings each token receives.
contract VaultTokenFactoryUnitTest is VaultTokenFactoryFixture {
    function setUp() public {
        _deployFactory();
        _register(V3_ID, address(v3Vault));
    }

    // ─── Constructor (TEST-024) ───

    // TEST-024 verifies: REQ-VTOKEN-023, Q-228
    // Sources: 5.1 TEST-024, 2.4 Storage
    function test_TEST_024_constructorFixesBindings() public view {
        assertEq(factory.ADAPTER(), adapter, "adapter");
        assertEq(factory.LP_VAULT_SWAP(), address(lpVaultSwap), "lpVaultSwap");
        assertEq(factory.COLLATERALIZATION(), address(collateralization), "collateralization");
        assertEq(factory.TIMELOCK(), address(timelock), "timelock");
        assertEq(factory.MARKET_REGISTRY(), address(marketRegistry), "marketRegistry");
    }

    // TEST-024 verifies: REQ-VTOKEN-023, REQ-VTOKEN-046
    function test_TEST_024_constructorRefusesZeroOrSharedBindings() public {
        address s = address(lpVaultSwap);
        address c = address(collateralization);
        address t = address(timelock);
        address r = address(marketRegistry);
        vm.expectRevert(IVaultTokenFactory.ZeroAddress.selector);
        new VaultTokenFactory(address(0), s, c, t, r);
        vm.expectRevert(IVaultTokenFactory.ZeroAddress.selector);
        new VaultTokenFactory(adapter, address(0), c, t, r);
        vm.expectRevert(IVaultTokenFactory.ZeroAddress.selector);
        new VaultTokenFactory(adapter, s, address(0), t, r);
        vm.expectRevert(IVaultTokenFactory.ZeroAddress.selector);
        new VaultTokenFactory(adapter, s, c, address(0), r);
        vm.expectRevert(IVaultTokenFactory.ZeroAddress.selector);
        new VaultTokenFactory(adapter, s, c, t, address(0));
        vm.expectRevert(IVaultToken.InvalidBinding.selector);
        new VaultTokenFactory(adapter, adapter, c, t, r);
        vm.expectRevert(IVaultToken.InvalidBinding.selector);
        new VaultTokenFactory(adapter, s, adapter, t, r);
        vm.expectRevert(IVaultToken.InvalidBinding.selector);
        new VaultTokenFactory(adapter, s, s, t, r);
    }

    // ─── registerIntegration (TEST-024) ───

    // TEST-024 verifies: REQ-VTOKEN-044, REQ-AMM-CORE-001, Q-291, Q-374
    function test_TEST_024_registerIntegrationWritesOnceAndEmits() public {
        assertEq(factory.lpVaultOf(V3_ID), address(v3Vault), "v3 registered in setUp");
        LPVaultIdentityMock slip = _vault(SLIPSTREAM_ID, AERODROME_SLIPSTREAM);
        vm.expectEmit(true, true, false, true, address(factory));
        emit IVaultTokenFactory.IntegrationRegistered(
            SLIPSTREAM_ID, address(slip), AERODROME_SLIPSTREAM, PoolKeying.Address, ShapeKind.TickRange
        );
        _register(SLIPSTREAM_ID, address(slip));
        assertEq(factory.lpVaultOf(SLIPSTREAM_ID), address(slip), "slipstream");
        assertEq(factory.lpVaultOf(3), address(0), "unregistered id");
        (PoolKeying keying, ShapeKind kind) = factory.integrationKindOf(SLIPSTREAM_ID);
        assertEq(uint8(keying), uint8(PoolKeying.Address), "keying recorded");
        assertEq(uint8(kind), uint8(ShapeKind.TickRange), "kind recorded");
        (, kind) = factory.integrationKindOf(3);
        assertEq(uint8(kind), uint8(ShapeKind.None), "unregistered kind");
    }

    // TEST-024 verifies: REQ-VTOKEN-044, REQ-VTOKEN-045
    function test_TEST_024_registerIntegrationOnlyTimelock() public {
        LPVaultIdentityMock slip = _vault(SLIPSTREAM_ID, AERODROME_SLIPSTREAM);
        vm.expectRevert(IVaultTokenFactory.NotTimelock.selector);
        vm.prank(governanceMultisig);
        factory.registerIntegration(SLIPSTREAM_ID, address(slip));
    }

    // TEST-024 verifies: REQ-VTOKEN-044, REQ-VTOKEN-045, Q-291
    function test_TEST_024_registerIntegrationRefusesBadIdOrAddress() public {
        LPVaultIdentityMock zeroId = _vault(0, UNISWAP_V3);
        _expectInvalidIntegration(0, address(zeroId));
        _expectInvalidIntegration(SLIPSTREAM_ID, address(0));
        _expectInvalidIntegration(SLIPSTREAM_ID, adapter);
        _expectInvalidIntegration(SLIPSTREAM_ID, address(lpVaultSwap));
        _expectInvalidIntegration(SLIPSTREAM_ID, address(collateralization));
        // The ID is taken, and the registered LPVault cannot be registered again under another ID.
        _expectInvalidIntegration(V3_ID, address(_vault(V3_ID, UNISWAP_V3)));
        _expectInvalidIntegration(V3_ID, address(v3Vault));
        _expectInvalidIntegration(SLIPSTREAM_ID, address(v3Vault));
        assertEq(factory.lpVaultOf(V3_ID), address(v3Vault), "entry unchanged");
    }

    // TEST-024 verifies: REQ-VTOKEN-044, REQ-VTOKEN-045, Q-291, Q-374
    /// @notice An LPVault bound to another integration ID, Collateralization, Lock, timelock or MarketRegistry, with a
    /// zero AMM protocol or a `None` shape kind, is refused.
    function test_TEST_024_registerIntegrationRefusesForeignCore() public {
        address c = address(collateralization);
        address t = address(timelock);
        bytes32 p = AERODROME_SLIPSTREAM;
        uint32 id = SLIPSTREAM_ID;
        address r = address(marketRegistry);
        _expectInvalidIntegration(id, address(new LPVaultIdentityMock(3, c, lock, p, t, r)));
        _expectInvalidIntegration(id, address(new LPVaultIdentityMock(id, alice, lock, p, t, r)));
        _expectInvalidIntegration(id, address(new LPVaultIdentityMock(id, c, makeAddr("otherLock"), p, t, r)));
        _expectInvalidIntegration(id, address(new LPVaultIdentityMock(id, c, lock, p, alice, r)));
        _expectInvalidIntegration(id, address(new LPVaultIdentityMock(id, c, lock, p, t, alice)));
        _expectInvalidIntegration(id, address(new LPVaultIdentityMock(id, c, lock, bytes32(0), t, r)));
        LPVaultIdentityMock noShape = _vault(id, p);
        noShape.setKind(PoolKeying.Address, ShapeKind.None);
        _expectInvalidIntegration(id, address(noShape));
        // `capabilities()` that reverts, answers short, or answers a keying or shape kind outside its enum.
        LPVaultIdentityMock badCaps = _vault(id, p);
        badCaps.setRawCapabilities("", true);
        _expectInvalidIntegration(id, address(badCaps));
        badCaps.setRawCapabilities(abi.encode(uint256(0), uint256(0), uint256(0)), false);
        _expectInvalidIntegration(id, address(badCaps));
        badCaps.setRawCapabilities(abi.encode(uint256(2), 0, 0, uint256(1), 0, 0, 0, 0), false);
        _expectInvalidIntegration(id, address(badCaps));
        badCaps.setRawCapabilities(abi.encode(uint256(0), 0, 0, uint256(3), 0, 0, 0, 0), false);
        _expectInvalidIntegration(id, address(badCaps));
        badCaps.setRawCapabilities(abi.encode(uint256(1), 0, 0, uint256(2), 0, 0, 0, 0), false);
        _register(id, address(badCaps));
        (PoolKeying k, ShapeKind sk) = factory.integrationKindOf(id);
        assertTrue(k == PoolKeying.Id && sk == ShapeKind.FullPool, "well-formed raw answer recorded");
    }

    // TEST-024 verifies: REQ-VTOKEN-044, Q-374
    /// @notice A Collateralization that does not name this factory, its Adapter or its LPVaultSwap makes every
    /// registration fail, so a mis-wired core is caught before any registry slot is used.
    function test_TEST_024_registerIntegrationRefusesMiswiredCollateralization() public {
        LPVaultIdentityMock slip = _vault(SLIPSTREAM_ID, AERODROME_SLIPSTREAM);
        address s = address(lpVaultSwap);
        collateralization.setCore(alice, adapter, s);
        _expectInvalidIntegration(SLIPSTREAM_ID, address(slip));
        collateralization.setCore(address(factory), alice, s);
        _expectInvalidIntegration(SLIPSTREAM_ID, address(slip));
        collateralization.setCore(address(factory), adapter, alice);
        _expectInvalidIntegration(SLIPSTREAM_ID, address(slip));
        collateralization.setCore(address(factory), adapter, s);
        _register(SLIPSTREAM_ID, address(slip));
        assertEq(factory.lpVaultOf(SLIPSTREAM_ID), address(slip), "registered once wired");
    }

    // TEST-024 verifies: REQ-VTOKEN-044
    /// @notice An address without code, a getter that reverts, a getter with a short answer and a getter that writes
    /// state (refused by the `STATICCALL`) each give `InvalidIntegration`, and a codeless Collateralization makes every
    /// registration fail the same way.
    function test_TEST_024_registerIntegrationRefusesCodelessOrHostileGetters() public {
        _expectInvalidIntegration(SLIPSTREAM_ID, bob);
        HostileLPVaultMock hostile = new HostileLPVaultMock();
        for (uint256 m = 0; m < 3; ++m) {
            hostile.setMode(m);
            _expectInvalidIntegration(SLIPSTREAM_ID, address(hostile));
        }
        assertEq(hostile.writes(), 0, "a getter wrote state");
        CollateralizationLockMock codeless = CollateralizationLockMock(makeAddr("codelessCollateralization"));
        VaultTokenFactory f = new VaultTokenFactory(
            adapter, address(lpVaultSwap), address(codeless), address(timelock), address(marketRegistry)
        );
        LPVaultIdentityMock v = new LPVaultIdentityMock(
            SLIPSTREAM_ID, address(codeless), lock, UNISWAP_V3, address(timelock), address(marketRegistry)
        );
        vm.prank(address(timelock));
        vm.expectRevert(IVaultTokenFactory.InvalidIntegration.selector);
        f.registerIntegration(SLIPSTREAM_ID, address(v));
    }

    // ─── deployVaultToken: success (TEST-024) ───

    // TEST-024 verifies: REQ-VTOKEN-019, REQ-VTOKEN-020, REQ-VTOKEN-021, REQ-VTOKEN-022, REQ-VTOKEN-024, REQ-VTOKEN-038, Q-068, Q-224, Q-299
    // Sources: 5.1 TEST-024, 2.4 REQ-VTOKEN-038 example
    function test_TEST_024_deployLandsAtPredictedAddressWithBindings() public {
        Listing memory l = _listing();
        bytes32 key = _key(l);
        address predicted = factory.predictAddress(spoke, key);
        assertEq(predicted.code.length, 0, "no code before the listing");
        VaultTokenBindings memory b = VaultTokenBindings({
            marketKey: key,
            integrationId: V3_ID,
            integration: address(v3Vault),
            hub: hub,
            spoke: spoke,
            marketId: MARKET_ID,
            lpOracle: lpOracle,
            adapter: adapter,
            lpVaultSwap: address(lpVaultSwap),
            collateralization: address(collateralization),
            decimals: DECIMALS,
            name: NAME,
            symbol: SYMBOL
        });
        vm.expectEmit(true, true, true, true, address(factory));
        emit IVaultTokenFactory.VaultTokenDeployed(predicted, MARKET_ID, spoke, b, pool, bytes32(0), l.shape);
        address token = _deploy(l);
        assertEq(token, predicted, "CREATE3 address");
        assertGt(token.code.length, 0, "token deployed");
        assertEq(factory.tokenOf(spoke, key), token, "tokenOf");
        assertTrue(factory.isVaultToken(token), "isVaultToken");
        VaultToken vt = VaultToken(token);
        assertEq(vt.marketKey(), key, "marketKey");
        assertEq(vt.integrationId(), V3_ID, "integrationId");
        assertEq(vt.integration(), address(v3Vault), "integration is the registered LPVault");
        assertEq(vt.hub(), hub, "hub");
        assertEq(vt.spoke(), spoke, "spoke");
        assertEq(vt.marketId(), MARKET_ID, "marketId");
        assertEq(vt.lpOracle(), lpOracle, "lpOracle");
        assertEq(vt.adapter(), adapter, "adapter");
        assertEq(vt.lpVaultSwap(), address(lpVaultSwap), "lpVaultSwap");
        assertEq(vt.collateralization(), address(collateralization), "collateralization");
        assertEq(vt.decimals(), DECIMALS, "decimals");
        assertEq(vt.name(), NAME, "name");
        assertEq(vt.symbol(), SYMBOL, "symbol");
        assertEq(vt.totalSupply(), 0, "no supply");
    }

    // TEST-024 verifies: REQ-VTOKEN-020, SPEC-AMM-CORE-002
    function test_TEST_024_marketKeyFormula() public {
        Listing memory l = _listing();
        bytes32 expected =
            keccak256(abi.encode(block.chainid, V3_ID, pool, bytes32(0), ShapeKind.TickRange, FULL_LOWER, FULL_UPPER));
        assertEq(_key(l), expected, "market key");
        vm.chainId(8453);
        assertTrue(_key(l) != expected, "the chain is in the key");
    }

    // TEST-024 verifies: REQ-VTOKEN-020, REQ-VTOKEN-021, REQ-VTOKEN-028, ATTACK-179, Q-299, Q-355, Q-374
    // Sources: 5.1 TEST-024, 2.4 REQ-VTOKEN-021 example
    /// @notice Two ranges of one pool, the same market on a successor Spoke, and the same pool and range under another
    /// integration are four (Spoke, market key) pairs with four tokens at four addresses.
    function test_TEST_024_onePairOneTokenNeverOnePerPool() public {
        Listing memory full = _listing();
        Listing memory narrow = _listing();
        narrow.shape = PositionShape(ShapeKind.TickRange, -50, 50);
        narrow.marketId = 5;
        narrow.decimals = 9;
        Listing memory relisted = _listing();
        relisted.spoke = successorSpoke;
        relisted.marketId = 6;
        LPVaultIdentityMock v3Fixed = _vault(3, UNISWAP_V3);
        _register(3, address(v3Fixed));
        Listing memory fixedVault = _listing();
        fixedVault.integrationId = 3;
        fixedVault.marketId = 7;

        address a = _deploy(full);
        address b = _deploy(narrow);
        address c = _deploy(relisted);
        address d = _deploy(fixedVault);
        assertTrue(a != b && a != c && a != d && b != c && b != d && c != d, "four tokens");
        assertTrue(_key(full) != _key(narrow) && _key(full) != _key(fixedVault), "shape and integration in the key");
        assertEq(_key(relisted), _key(full), "same market");
        assertEq(factory.tokenOf(successorSpoke, _key(full)), c, "successor Spoke token");
        assertEq(factory.tokenOf(spoke, _key(full)), a, "first Spoke token unchanged");
        assertEq(VaultToken(d).integration(), address(v3Fixed), "fixed LPVault bound");
    }

    // TEST-024 verifies: REQ-VTOKEN-022, REQ-VTOKEN-020, REQ-VTOKEN-049
    /// @notice On an integration keyed by `poolId` with full-pool shapes, an identifier-keyed full-pool market deploys;
    /// the same pool passed by address, or with ticks, is refused.
    function test_TEST_024_poolIdKeyedMarketDeploys() public {
        LPVaultIdentityMock v4 = _vault(SLIPSTREAM_ID, keccak256("UNISWAP_V4"));
        v4.setKind(PoolKeying.Id, ShapeKind.FullPool);
        _register(SLIPSTREAM_ID, address(v4));
        Listing memory l = _listing();
        l.integrationId = SLIPSTREAM_ID;
        l.pool = address(0);
        l.poolId = keccak256("v4.poolId");
        l.shape = PositionShape(ShapeKind.FullPool, 0, 0);
        address token = _deploy(l);
        assertEq(factory.tokenOf(spoke, _key(l)), token);
        l.spoke = successorSpoke;
        l.pool = pool;
        l.poolId = bytes32(0);
        _expectDeployRevert(l, IVaultTokenFactory.ZeroAddress.selector);
        l.pool = address(0);
        l.poolId = keccak256("v4.poolId");
        l.shape = PositionShape(ShapeKind.FullPool, 0, 1);
        _expectDeployRevert(l, IVaultTokenFactory.InvalidShape.selector);
    }

    // TEST-024 verifies: REQ-VTOKEN-021, REQ-VTOKEN-049, ATTACK-179
    // Sources: VaultTokenFactory review 2026-11-10 (Low-1)
    /// @notice One pool gets one market key per integration and Spoke: `ShapeKind.None`, a full-pool shape on a
    /// tick-range integration, an inverted or empty range, and the pool passed as a `poolId` are all refused, so no
    /// second token can be deployed for the same pool and range.
    function test_TEST_024_nonCanonicalShapesAndKeyingRefused() public {
        Listing memory l = _listing();
        l.shape = PositionShape(ShapeKind.None, FULL_LOWER, FULL_UPPER);
        _expectDeployRevert(l, IVaultTokenFactory.InvalidShape.selector);
        l.shape = PositionShape(ShapeKind.FullPool, 0, 0);
        _expectDeployRevert(l, IVaultTokenFactory.InvalidShape.selector);
        l.shape = PositionShape(ShapeKind.TickRange, 50, -50);
        _expectDeployRevert(l, IVaultTokenFactory.InvalidShape.selector);
        l.shape = PositionShape(ShapeKind.TickRange, 50, 50);
        _expectDeployRevert(l, IVaultTokenFactory.InvalidShape.selector);
        l = _listing();
        l.pool = address(0);
        l.poolId = bytes32(uint256(uint160(pool)));
        _expectDeployRevert(l, IVaultTokenFactory.ZeroAddress.selector);
        _deploy(_listing());
        assertTrue(factory.tokenOf(spoke, _key(_listing())) != address(0), "canonical listing deploys");
    }

    // TEST-024 verifies: REQ-VTOKEN-020, ATTACK-179
    /// @notice The address depends on the deploying factory: another factory, or anyone else using the same salt,
    /// reaches a different address, so no one can occupy a listing's address in advance.
    function test_TEST_024_predictedAddressDependsOnFactory() public {
        VaultTokenFactory other = new VaultTokenFactory(
            adapter, address(lpVaultSwap), address(collateralization), address(timelock), address(marketRegistry)
        );
        bytes32 key = _key(_listing());
        assertTrue(other.predictAddress(spoke, key) != factory.predictAddress(spoke, key), "factory in the address");
        assertTrue(factory.predictAddress(successorSpoke, key) != factory.predictAddress(spoke, key), "spoke in salt");
    }

    // ─── deployVaultToken: rejections (TEST-024) ───

    // TEST-024 verifies: REQ-VTOKEN-019, REQ-VTOKEN-037, Q-228
    function testFuzz_TEST_024_deployOnlyByTimelock(
        address caller
    ) public {
        vm.assume(caller != address(timelock));
        Listing memory l = _listing();
        vm.expectRevert(IVaultTokenFactory.NotTimelock.selector);
        _deployAs(caller, l);
    }

    // TEST-024 verifies: REQ-VTOKEN-021, REQ-VTOKEN-028, REQ-VTOKEN-035, Q-068, Q-299
    function test_TEST_024_secondTokenForPairReverts() public {
        Listing memory l = _listing();
        address first = _deploy(l);
        l.marketId = 9;
        l.lpOracle = makeAddr("anotherOracle");
        vm.expectRevert(IVaultTokenFactory.TokenExistsForMarket.selector);
        _deploy(l);
        assertEq(factory.tokenOf(spoke, _key(l)), first, "entry unchanged");
    }

    // TEST-024 verifies: REQ-VTOKEN-022, REQ-VTOKEN-036
    function test_TEST_024_unknownIntegrationReverts() public {
        Listing memory l = _listing();
        l.integrationId = 7;
        vm.expectRevert(abi.encodeWithSelector(IVaultTokenFactory.UnknownIntegration.selector, uint32(7)));
        _deploy(l);
        l.integrationId = 0;
        vm.expectRevert(abi.encodeWithSelector(IVaultTokenFactory.UnknownIntegration.selector, uint32(0)));
        _deploy(l);
    }

    // TEST-024 verifies: REQ-VTOKEN-022, REQ-VTOKEN-036
    function test_TEST_024_zeroAddressesAndPoolKeyingRevert() public {
        Listing memory l = _listing();
        l.poolId = keccak256("both");
        _expectDeployRevert(l, IVaultTokenFactory.ZeroAddress.selector);
        l = _listing();
        l.pool = address(0);
        _expectDeployRevert(l, IVaultTokenFactory.ZeroAddress.selector);
        l = _listing();
        l.hub = address(0);
        _expectDeployRevert(l, IVaultTokenFactory.ZeroAddress.selector);
        l = _listing();
        l.spoke = address(0);
        _expectDeployRevert(l, IVaultTokenFactory.ZeroAddress.selector);
        l = _listing();
        l.lpOracle = address(0);
        _expectDeployRevert(l, IVaultTokenFactory.ZeroAddress.selector);
    }

    // TEST-024 verifies: REQ-VTOKEN-004, REQ-VTOKEN-022, REQ-VTOKEN-036, SPEC-UNIT-001
    function testFuzz_TEST_024_decimalsSixToEighteenOnly(
        uint8 d
    ) public {
        Listing memory l = _listing();
        l.decimals = d;
        if (d < 6 || d > 18) {
            _expectDeployRevert(l, IVaultTokenFactory.DecimalsOutOfRange.selector);
        } else {
            assertEq(VaultToken(_deploy(l)).decimals(), d);
        }
    }

    // TEST-024 verifies: REQ-VTOKEN-022, REQ-VTOKEN-036, REQ-VTOKEN-038, REQ-CONFIG-006
    /// @notice `marketId` must lie in `[1, 2^32)`: 0 and `2^32` are refused, `2^32 − 1` deploys.
    function test_TEST_024_marketIdBounds() public {
        Listing memory l = _listing();
        l.marketId = 0;
        _expectDeployRevert(l, IVaultTokenFactory.InvalidMarketId.selector);
        l.marketId = 1 << 32;
        _expectDeployRevert(l, IVaultTokenFactory.InvalidMarketId.selector);
        l.marketId = (1 << 32) - 1;
        assertEq(VaultToken(_deploy(l)).marketId(), (1 << 32) - 1, "largest marketId");
    }

    // TEST-024 verifies: REQ-VTOKEN-022, REQ-VTOKEN-050
    /// @notice The name must have 1 to 128 bytes and the symbol 1 to 32; the token carries them unchanged.
    function test_TEST_024_nameAndSymbolLengths() public {
        Listing memory l = _listing();
        string memory name129 = string(new bytes(129));
        string memory symbol33 = string(new bytes(33));
        string[4] memory names = ["", name129, NAME, NAME];
        string[4] memory symbols = [SYMBOL, SYMBOL, "", symbol33];
        for (uint256 i = 0; i < 4; ++i) {
            vm.prank(address(timelock));
            vm.expectRevert(IVaultTokenFactory.InvalidTokenMetadata.selector);
            factory.deployVaultToken(
                l.integrationId,
                l.pool,
                l.poolId,
                l.shape,
                l.hub,
                l.spoke,
                l.marketId,
                l.lpOracle,
                l.decimals,
                names[i],
                symbols[i]
            );
        }
        vm.prank(address(timelock));
        address token = factory.deployVaultToken(
            l.integrationId,
            l.pool,
            l.poolId,
            l.shape,
            l.hub,
            l.spoke,
            l.marketId,
            l.lpOracle,
            l.decimals,
            string(new bytes(128)),
            "avLP-4294967295"
        );
        assertEq(bytes(VaultToken(token).name()).length, 128, "128-byte name");
        assertEq(VaultToken(token).symbol(), "avLP-4294967295", "symbol");
    }

    // TEST-024 verifies: REQ-VTOKEN-022, REQ-VTOKEN-024
    /// @notice A failed CREATE3 deployment (here the CREATE2 proxy address already holds code) reverts
    /// `DeploymentFailed` and rolls back both registry writes and the event.
    function test_TEST_024_create3FailureRollsBack() public {
        Listing memory l = _listing();
        bytes32 key = _key(l);
        bytes32 salt = keccak256(abi.encode(spoke, key));
        address proxy = vm.computeCreate2Address(salt, CREATE3.PROXY_INITCODE_HASH, address(factory));
        vm.etch(proxy, hex"00");
        vm.recordLogs();
        vm.expectRevert(CREATE3.DeploymentFailed.selector);
        _deploy(l);
        assertEq(vm.getRecordedLogs().length, 0, "event emitted");
        address predicted = factory.predictAddress(spoke, key);
        assertEq(factory.tokenOf(spoke, key), address(0), "tokenOf written");
        assertFalse(factory.isVaultToken(predicted), "isVaultToken written");
    }

    // TEST-024 verifies: REQ-VTOKEN-022, REQ-VTOKEN-036
    /// @notice With several faults the first check of the documented order decides the error.
    function test_TEST_024_checkOrder() public {
        Listing memory l = _listing();
        _deploy(l);
        l.integrationId = 9;
        l.hub = address(0);
        l.decimals = 5;
        l.marketId = 0;
        vm.expectRevert(abi.encodeWithSelector(IVaultTokenFactory.UnknownIntegration.selector, uint32(9)));
        _deploy(l);
        l.integrationId = V3_ID;
        _expectDeployRevert(l, IVaultTokenFactory.ZeroAddress.selector);
        l.hub = hub;
        l.shape = PositionShape(ShapeKind.TickRange, 1, 1);
        _expectDeployRevert(l, IVaultTokenFactory.InvalidShape.selector);
        l.shape = _fullRange();
        _expectDeployRevert(l, IVaultTokenFactory.DecimalsOutOfRange.selector);
        l.decimals = DECIMALS;
        _expectDeployRevert(l, IVaultTokenFactory.InvalidMarketId.selector);
        l.marketId = MARKET_ID;
        l.lpOracle = hub;
        _expectDeployRevert(l, IVaultTokenFactory.TokenExistsForMarket.selector);
    }

    // TEST-024 verifies: REQ-VTOKEN-022, REQ-VTOKEN-036, REQ-VTOKEN-046, Q-224, Q-226
    // Sources: 2.4 REQ-VTOKEN-046 example (the Hub passed as LPOracle)
    /// @notice Each of the Hub, Spoke and LPOracle equal to another binding or to the token's own predicted address
    /// reverts with the token's `InvalidBinding`, raised by the factory before CREATE3, and leaves the pair empty.
    function test_TEST_024_sharedBindingRevertsWithTokenError() public {
        Listing memory base = _listing();
        address predicted = factory.predictAddress(spoke, _key(base));
        address[8] memory others = [
            hub, spoke, lpOracle, address(v3Vault), adapter, address(lpVaultSwap), address(collateralization), predicted
        ];
        for (uint256 field = 0; field < 3; ++field) {
            for (uint256 j = 0; j < 8; ++j) {
                if (j == field) continue;
                Listing memory l = _listing();
                if (field == 0) l.hub = others[j];
                if (field == 1) l.spoke = others[j];
                if (field == 2) l.lpOracle = others[j];
                // A different Spoke moves the predicted address; the token's own address is checked for its own Spoke.
                if (field == 1 && j == 7) continue;
                _expectDeployRevert(l, IVaultToken.InvalidBinding.selector);
            }
        }
        assertEq(factory.tokenOf(spoke, _key(base)), address(0), "pair still empty");
    }

    // TEST-024 verifies: REQ-VTOKEN-022, REQ-VTOKEN-046
    /// @notice The factory's `ZeroAddress` and the token's `ZeroAddress` are one selector, so a zero binding surfaces
    /// the same error whichever contract raises it.
    function test_TEST_024_zeroAddressSelectorIsTheTokens() public pure {
        assertEq(IVaultTokenFactory.ZeroAddress.selector, IVaultToken.ZeroAddress.selector);
    }

    // ─── TEST-166: one timelock delay ───

    // TEST-166 verifies: REQ-VTOKEN-019, REQ-VTOKEN-037, REQ-ROLE-106, INV-051, INV-052, Q-228
    // Sources: 5.1 TEST-166, 2.15 normal delay
    /// @notice Registration and deployment scheduled at the normal delay execute right after it, never before; the
    /// governance multisig calling the factory directly is refused.
    function test_TEST_166_deployRunsAfterOneNormalDelay() public {
        LPVaultIdentityMock slip = _vault(SLIPSTREAM_ID, AERODROME_SLIPSTREAM);
        Listing memory l = _listing();
        l.integrationId = SLIPSTREAM_ID;
        Call[] memory calls = _two(
            Call(address(factory), abi.encodeCall(factory.registerIntegration, (SLIPSTREAM_ID, address(slip)))),
            Call(address(factory), _deployCall(l))
        );
        assertEq(_required(calls), NORMAL_DELAY, "normal delay");
        bytes32 salt = keccak256("listing");
        _schedule(governanceMultisig, calls, NORMAL_DELAY, salt);
        vm.warp(block.timestamp + NORMAL_DELAY - 1);
        vm.expectRevert();
        _execute(attacker, calls, salt);
        vm.warp(block.timestamp + 1);
        _execute(attacker, calls, salt);
        address token = factory.tokenOf(spoke, _key(l));
        assertEq(token, factory.predictAddress(spoke, _key(l)), "deployed at the predicted address");
        assertEq(VaultToken(token).integration(), address(slip), "registered in the same batch");

        l.spoke = successorSpoke;
        vm.expectRevert(IVaultTokenFactory.NotTimelock.selector);
        _deployAs(governanceMultisig, l);
    }

    // ─── Helpers ───

    function _expectDeployRevert(
        Listing memory l,
        bytes4 selector
    ) internal {
        vm.expectRevert(selector);
        _deploy(l);
    }

    function _expectInvalidIntegration(
        uint32 id,
        address vault
    ) internal {
        vm.expectRevert(IVaultTokenFactory.InvalidIntegration.selector);
        _register(id, vault);
    }
}
