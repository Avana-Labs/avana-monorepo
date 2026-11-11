// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ProxyManager} from "../../src/proxy/proxy-manager/ProxyManager.sol";
import {AaveV4Fixture} from "../utils/fixtures/AaveV4Fixture.sol";
import {FreezeRegistryMock, ProxyTestToken} from "../utils/mocks/ProxyMocks.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @dev Aave V4 Spoke position-manager entry points of aave-v4 a3ef63e.
interface ISpokePositionManagers {
    struct PositionManagerUpdate {
        address positionManager;
        bool approve;
    }

    struct SetUserPositionManagers {
        address onBehalfOf;
        PositionManagerUpdate[] updates;
        uint256 nonce;
        uint256 deadline;
    }

    function setUserPositionManager(
        address positionManager,
        bool approve
    ) external;

    function setUserPositionManagersWithSig(
        SetUserPositionManagers calldata params,
        bytes calldata signature
    ) external;

    function isPositionManager(
        address user,
        address positionManager
    ) external view returns (bool);
}

/// @dev Aave V4 SpokeConfigurator call that activates a position manager.
interface ISpokeConfiguratorPositionManager {
    function updatePositionManager(
        address spoke,
        address positionManager,
        bool active
    ) external;
}

/// @notice An ERC-2612 token, as a debt asset with `permit` (GHO, USDC) is.
contract ProxyPermitToken is ERC20Permit {
    constructor() ERC20("Permit", "PRM") ERC20Permit("Permit") {}
}

/// @notice Code standing in for whoever controls a colliding address before the proxy exists: it grants an allowance
/// and an Aave position-manager approval as that address, then is removed.
contract CollisionSquatter {
    function run(
        address token,
        address spender,
        address spoke,
        address positionManager
    ) external {
        ProxyTestToken(token).approve(spender, type(uint256).max);
        ISpokePositionManagers(spoke).setUserPositionManager(positionManager, true);
    }
}

/// @title PositionProxyAaveV4IntegrationTest
/// @notice A PositionProxy created by the real ProxyManager against the standard CDP Spoke of the real local Aave V4:
/// no third party acts on the proxy's account, no signature or permit names the proxy, and state placed at the
/// predicted address before deployment (reachable only through an address collision) survives deployment, which is why
/// REQ-PROXY-055 states the collision assumption and the Adapter's first pledge checks for an empty account.
/// @dev The AaveAdapter is a pranked address; the MarketRegistry is the freeze-only mock.
contract PositionProxyAaveV4IntegrationTest is AaveV4Fixture {
    uint256 internal constant MARKET = 3;

    address internal adapter = makeAddr("AaveAdapter");
    FreezeRegistryMock internal registry;
    ProxyManager internal manager;
    address internal proxy;

    function setUp() public {
        _deployAaveV4();
        registry = new FreezeRegistryMock();
        manager = new ProxyManager(adapter, address(registry));
        vm.prank(adapter);
        proxy = manager.deployProxy(carol, aave.cdpSpoke, MARKET);
    }

    // TEST-187 verifies: REQ-PROXY-040, REQ-PROXY-087, REQ-PROXY-089, INV-016, INV-063, Q-223
    /// @notice A third party, the bound wallet included, calling `supply`, `withdraw`, `borrow`, `repay` or
    /// `setUsingAsCollateral` with `onBehalfOf = proxy` is refused by the Spoke's position-manager check.
    function test_TEST_187_thirdPartyOnBehalfOfProxyRefused() public {
        address[3] memory callers = [attacker, carol, adapter];
        bytes4 unauthorized = bytes4(keccak256("Unauthorized()"));
        IAaveV4Spoke spoke = IAaveV4Spoke(aave.cdpSpoke);
        for (uint256 i = 0; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(unauthorized);
            spoke.supply(0, 1, proxy);
            vm.expectRevert(unauthorized);
            spoke.withdraw(0, 1, proxy);
            vm.expectRevert(unauthorized);
            spoke.borrow(0, 1, proxy);
            vm.expectRevert(unauthorized);
            spoke.repay(0, 1, proxy);
            vm.expectRevert(unauthorized);
            spoke.setUsingAsCollateral(0, true, proxy);
            vm.stopPrank();
        }
    }

    // TEST-187 verifies: REQ-PROXY-011, REQ-PROXY-089, INV-063, Q-223
    /// @notice A signature naming the proxy never approves a position manager: the proxy has no ERC-1271, so every
    /// signature check fails; and no ERC-2612 permit can name the proxy as owner, so `permitReserve` for it can grant
    /// no allowance.
    function test_TEST_187_signatureAndPermitForProxyRefused() public {
        ISpokePositionManagers spoke = ISpokePositionManagers(aave.cdpSpoke);
        ISpokePositionManagers.PositionManagerUpdate[] memory updates =
            new ISpokePositionManagers.PositionManagerUpdate[](1);
        updates[0] = ISpokePositionManagers.PositionManagerUpdate(attacker, true);
        ISpokePositionManagers.SetUserPositionManagers memory params =
            ISpokePositionManagers.SetUserPositionManagers(proxy, updates, 0, block.timestamp + 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xA11CE, keccak256("any digest"));
        vm.prank(attacker);
        vm.expectRevert(bytes4(keccak256("InvalidSignature()")));
        spoke.setUserPositionManagersWithSig(params, abi.encodePacked(r, s, v));
        assertFalse(spoke.isPositionManager(proxy, attacker), "manager approved for the proxy");

        // An ERC-2612 permit naming the proxy as owner needs an ECDSA signature by the proxy's address, which no key
        // produces (OpenZeppelin's permit has no ERC-1271 path).
        ProxyPermitToken permitToken = new ProxyPermitToken();
        vm.prank(attacker);
        vm.expectRevert();
        permitToken.permit(proxy, aave.cdpSpoke, type(uint256).max, block.timestamp + 1, v, r, s);
        assertEq(permitToken.allowance(proxy, aave.cdpSpoke), 0, "allowance granted");
    }

    // TEST-190 verifies: REQ-PROXY-055, REQ-PROXY-097, ATTACK-029
    // Sources: PositionProxy review 2026-11-10 (L-1)
    /// @notice State placed at a predicted address before deployment survives it: an allowance and an Aave
    /// position-manager approval granted by whoever controlled the colliding address stay with the new proxy (and the
    /// approval takes effect once the DAO activates that manager). Reaching such an address takes a ~2^80 collision
    /// search, which REQ-PROXY-055 assumes infeasible; the Adapter's first pledge also requires an empty account.
    function test_TEST_190_collisionPreStateSurvivesDeployment() public {
        ProxyTestToken token = new ProxyTestToken();
        address pm = makeAddr("positionManager");
        address predicted = manager.predictProxy(attacker, aave.cdpSpoke, MARKET);
        vm.etch(predicted, type(CollisionSquatter).runtimeCode);
        CollisionSquatter(predicted).run(address(token), attacker, aave.cdpSpoke, pm);
        vm.etch(predicted, "");
        vm.prank(adapter);
        assertEq(manager.deployProxy(attacker, aave.cdpSpoke, MARKET), predicted, "deployed at the prediction");
        assertEq(token.allowance(predicted, attacker), type(uint256).max, "allowance inherited");
        vm.prank(aaveDao);
        ISpokeConfiguratorPositionManager(aave.spokeConfigurator).updatePositionManager(aave.cdpSpoke, pm, true);
        assertTrue(ISpokePositionManagers(aave.cdpSpoke).isPositionManager(predicted, pm), "approval inherited");
    }

    // TEST-190 verifies: REQ-PROXY-097
    /// @notice A predicted address with a nonce but no code (reachable only through a collision) makes CREATE2 fail:
    /// `deployProxy` reverts with OpenZeppelin's `FailedDeployment()`.
    function test_TEST_190_nonceAtPredictionRevertsFailedDeployment() public {
        address predicted = manager.predictProxy(bob, aave.cdpSpoke, MARKET);
        vm.setNonce(predicted, 1);
        vm.prank(adapter);
        vm.expectRevert(bytes4(keccak256("FailedDeployment()")));
        manager.deployProxy(bob, aave.cdpSpoke, MARKET);
    }
}
