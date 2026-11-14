// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IPositionProxy} from "../../../src/proxy/position-proxy/IPositionProxy.sol";
import {ProxyManager} from "../../../src/proxy/proxy-manager/ProxyManager.sol";
import {FreezeRegistryMock, ProxyCallTarget} from "../../utils/mocks/ProxyMocks.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @title ProxyManagerHandler
/// @notice Actor handler of the TEST-089 suite over 12 triples (3 wallets, 2 Spokes, 2 markets): the Adapter deploys
/// (frozen or not), strangers try to deploy and to drive proxies, the Adapter drives proxies, guardians freeze and
/// unfreeze wallets. Ghosts record every outcome that breaks a rule, so the invariants only read counters.
contract ProxyManagerHandler is CommonBase, StdUtils {
    /// @notice A call that found nothing to act on, or that the contract refused: reverting keeps it out of the
    /// campaign's success count, so the metrics show the calls that did real work.
    error Skipped();

    uint256 public constant TRIPLES = 12;
    address public constant SPOKE_1 = address(0x5B0CE1);
    address public constant SPOKE_2 = address(0x5B0CE2);

    ProxyManager public immutable MANAGER;
    FreezeRegistryMock public immutable REGISTRY;
    ProxyCallTarget public immutable TARGET;
    address public immutable ADAPTER;

    mapping(uint256 => bool) public deployed;
    uint256 public deployments;
    uint256 public deployedAtWrongAddress;
    uint256 public secondDeploySucceeded;
    uint256 public frozenDeploySucceeded;
    uint256 public strangerDeploySucceeded;
    uint256 public strangerExecuteSucceeded;
    uint256 public adapterExecuteFailed;

    constructor(
        ProxyManager manager,
        FreezeRegistryMock registry,
        address adapter
    ) {
        MANAGER = manager;
        REGISTRY = registry;
        ADAPTER = adapter;
        TARGET = new ProxyCallTarget();
    }

    function triple(
        uint256 i
    ) public pure returns (address wallet, address spoke, uint256 marketId) {
        wallet = address(uint160(0x10000 * (1 + (i % 3))));
        spoke = (i / 3) % 2 == 0 ? SPOKE_1 : SPOKE_2;
        marketId = 1 + (i / 6);
    }

    function deploy(
        uint256 index
    ) external {
        uint256 i = index % TRIPLES;
        (address w, address s, uint256 m) = triple(i);
        address predicted = MANAGER.predictProxy(w, s, m);
        bool frozen = REGISTRY.frozen(w);
        vm.prank(ADAPTER);
        try MANAGER.deployProxy(w, s, m) returns (address p) {
            if (deployed[i]) ++secondDeploySucceeded;
            if (frozen) ++frozenDeploySucceeded;
            if (p != predicted) ++deployedAtWrongAddress;
            deployed[i] = true;
            ++deployments;
        } catch {
            revert Skipped();
        }
    }

    function strangerDeploy(
        address caller,
        uint256 index
    ) external {
        if (caller == ADAPTER) revert Skipped();
        (address w, address s, uint256 m) = triple(index % TRIPLES);
        vm.prank(caller);
        try MANAGER.deployProxy(w, s, m) returns (address) {
            ++strangerDeploySucceeded;
        } catch {}
    }

    function strangerExecute(
        address caller,
        uint256 index
    ) external {
        uint256 i = index % TRIPLES;
        if (caller == ADAPTER || !deployed[i]) revert Skipped();
        (address w, address s, uint256 m) = triple(i);
        address p = MANAGER.predictProxy(w, s, m);
        vm.prank(caller);
        try IPositionProxy(p).execute(address(TARGET), abi.encodeCall(ProxyCallTarget.ping, (1))) returns (
            bytes memory
        ) {
            ++strangerExecuteSucceeded;
        } catch {}
    }

    function adapterExecute(
        uint256 index,
        uint128 x
    ) external {
        uint256 i = index % TRIPLES;
        if (!deployed[i]) revert Skipped();
        (address w, address s, uint256 m) = triple(i);
        address p = MANAGER.predictProxy(w, s, m);
        vm.prank(ADAPTER);
        try IPositionProxy(p).execute(address(TARGET), abi.encodeCall(ProxyCallTarget.ping, (x))) returns (
            bytes memory r
        ) {
            if (abi.decode(r, (uint256)) != uint256(x) + 1 || TARGET.lastCaller() != p) ++adapterExecuteFailed;
        } catch {
            ++adapterExecuteFailed;
        }
    }

    function setFrozen(
        uint256 walletIndex,
        bool frozen
    ) external {
        (address w,,) = triple(walletIndex % 3);
        REGISTRY.setFrozen(w, frozen);
    }
}
