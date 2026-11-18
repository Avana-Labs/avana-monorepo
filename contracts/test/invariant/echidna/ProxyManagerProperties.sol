// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IPositionProxy} from "../../../src/proxy/position-proxy/IPositionProxy.sol";
import {PositionProxy} from "../../../src/proxy/position-proxy/PositionProxy.sol";
import {IProxyManager} from "../../../src/proxy/proxy-manager/IProxyManager.sol";
import {ProxyManager} from "../../../src/proxy/proxy-manager/ProxyManager.sol";
import {ProxyCaller, StubRegistryMock} from "../../utils/mocks/ProxyMocks.sol";

/// @title ProxyManagerProperties
/// @notice Echidna and Medusa properties of the ProxyManager (2.5) over 12 triples (3 wallets, 2 Spokes, 2 markets).
/// Between transactions: a triple has code at `predictProxy` exactly when it was deployed, that code is the
/// PositionProxy bound to the triple and the Adapter, and the immutables never change. Inside one transaction: the
/// Adapter (this harness) deploys a fresh triple at `predictProxy`, a second deployment reverts `ProxyExists`, and any
/// other caller reverts `OnlyAdapter`.
/// @dev `deploy` and `outsiderDeploy` are assertion entry points; the triple is chosen by arithmetic on the index, so
/// branching stays finite for hevm.
contract ProxyManagerProperties {
    uint256 internal constant TRIPLES = 12;
    address internal constant SPOKE_1 = address(0x5B0CE1);
    address internal constant SPOKE_2 = address(0x5B0CE2);

    StubRegistryMock internal immutable REGISTRY;
    ProxyManager internal immutable MANAGER;
    ProxyCaller internal immutable OUTSIDER;
    bytes32 internal immutable CREATION_CODE_HASH;

    /// @notice Whether triple `i` was deployed by `deploy`.
    mapping(uint256 => bool) public deployed;
    /// @notice Number of assertion sequences run; written so each call is a transaction.
    uint256 public sequences;

    constructor() {
        REGISTRY = new StubRegistryMock();
        MANAGER = new ProxyManager(address(this), address(REGISTRY));
        OUTSIDER = new ProxyCaller();
        CREATION_CODE_HASH = keccak256(type(PositionProxy).creationCode);
    }

    // ─── Properties (between transactions) ───

    function property_immutablesFixed() external view returns (bool) {
        return MANAGER.ADAPTER() == address(this) && MANAGER.MARKET_REGISTRY() == address(REGISTRY)
            && MANAGER.PROXY_CREATION_CODE_HASH() == CREATION_CODE_HASH;
    }

    function property_codeOnlyAtDeployedTriples() external view returns (bool) {
        for (uint256 i = 0; i < TRIPLES; ++i) {
            (address w, address s, uint256 m) = _triple(i);
            address p = MANAGER.predictProxy(w, s, m);
            if (deployed[i] != (p.code.length != 0)) return false;
            if (deployed[i] && !_bound(p, w, s, m)) return false;
        }
        return true;
    }

    // ─── Assertion entry points (inside one transaction) ───

    /// @notice The Adapter deploys triple `i`; the outcome is a proxy at `predictProxy` for a fresh triple and
    /// `ProxyExists` for a deployed one.
    function deploy(
        uint8 index
    ) external {
        uint256 i = index % TRIPLES;
        (address w, address s, uint256 m) = _triple(i);
        address predicted = MANAGER.predictProxy(w, s, m);
        try MANAGER.deployProxy(w, s, m) returns (address p) {
            assert(!deployed[i]);
            assert(p == predicted && _bound(p, w, s, m));
            deployed[i] = true;
        } catch (bytes memory reason) {
            assert(deployed[i]);
            assert(keccak256(reason) == keccak256(abi.encodeWithSelector(IProxyManager.ProxyExists.selector, w, s, m)));
        }
        ++sequences;
    }

    /// @notice A caller other than the Adapter is refused with `OnlyAdapter` and nothing is deployed.
    function outsiderDeploy(
        uint8 index
    ) external {
        uint256 i = index % TRIPLES;
        (address w, address s, uint256 m) = _triple(i);
        (bool ok, bytes memory ret) = OUTSIDER.callDeploy(address(MANAGER), w, s, m);
        assert(!ok);
        assert(keccak256(ret) == keccak256(abi.encodeWithSelector(IProxyManager.OnlyAdapter.selector)));
        assert((MANAGER.predictProxy(w, s, m).code.length != 0) == deployed[i]);
        ++sequences;
    }

    function _triple(
        uint256 i
    ) internal pure returns (address wallet, address spoke, uint256 marketId) {
        wallet = address(uint160(0x10000 * (1 + (i % 3))));
        spoke = (i / 3) % 2 == 0 ? SPOKE_1 : SPOKE_2;
        marketId = 1 + (i / 6);
    }

    function _bound(
        address p,
        address w,
        address s,
        uint256 m
    ) internal view returns (bool) {
        IPositionProxy proxy = IPositionProxy(p);
        return proxy.ADAPTER() == address(this) && proxy.WALLET() == w && proxy.SPOKE() == s && proxy.MARKET_ID() == m;
    }
}
