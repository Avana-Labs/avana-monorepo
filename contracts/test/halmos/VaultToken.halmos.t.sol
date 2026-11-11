// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {VaultTokenBindings} from "../../src/types/VaultTokenBindings.sol";
import {IVaultToken} from "../../src/vault-token/vault-token/IVaultToken.sol";
import {VaultToken} from "../../src/vault-token/vault-token/VaultToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

/// @title VaultTokenHalmosTest
/// @notice Symbolic checks of the vault token for every caller, selector and argument: supply changes only through
/// the Adapter's mint and burn, a burn needs no allowance and lowers exactly the holder and the supply, every
/// successful transfer is on an allowed path, the registry is append-only and written only by the Adapter, and the
/// bindings never change.
/// @dev The bindings are fixed concrete addresses; callers, selectors and arguments are symbolic. The pre-state has
/// one registered proxy holding units, the Hub holding supplied units and LPVaultSwap holding seized units, so every
/// path has a non-zero source.
contract VaultTokenHalmosTest is Test {
    address internal constant LP_VAULT = address(0x1A9);
    address internal constant HUB = address(0x4B);
    address internal constant SPOKE = address(0x590);
    address internal constant LP_ORACLE = address(0x0AC1E);
    address internal constant ADAPTER = address(0xADA9);
    address internal constant SWAP = address(0x5A9);
    address internal constant COLL = address(0xC011);
    address internal constant PROXY = address(0x9A0);
    bytes32 internal constant KEY = keccak256("market");

    VaultToken internal token;

    function setUp() public {
        token = new VaultToken(
            VaultTokenBindings({
                marketKey: KEY,
                integrationId: 1,
                integration: LP_VAULT,
                hub: HUB,
                spoke: SPOKE,
                marketId: 4,
                lpOracle: LP_ORACLE,
                adapter: ADAPTER,
                lpVaultSwap: SWAP,
                collateralization: COLL,
                decimals: 6,
                name: "VT",
                symbol: "VT"
            })
        );
        vm.startPrank(ADAPTER);
        token.addValidProxy(PROXY);
        token.mint(PROXY, 1000);
        vm.stopPrank();
        vm.prank(PROXY);
        token.transfer(HUB, 600);
        vm.prank(HUB);
        token.transfer(SWAP, 100);
    }

    function _call(
        address caller,
        bytes4 selector,
        address a,
        address b,
        uint256 v
    ) internal returns (bool ok) {
        vm.prank(caller);
        (ok,) = address(token).call(abi.encodePacked(selector, abi.encode(a, b, v)));
    }

    // PROP-005 verifies: INV-009, INV-010, REQ-VTOKEN-015, REQ-VTOKEN-027, REQ-VTOKEN-032, Q-069, Q-224
    /// @notice A supply rise is a mint by the Adapter, a supply fall is a burn by the Adapter, whatever the call.
    function check_PROP_005_supplyChangesOnlyThroughAdapter(
        address caller,
        bytes4 selector,
        address a,
        address b,
        uint256 v
    ) public {
        uint256 before = token.totalSupply();
        _call(caller, selector, a, b, v);
        uint256 afterSupply = token.totalSupply();
        if (afterSupply > before) assert(caller == ADAPTER && selector == IVaultToken.mint.selector);
        if (afterSupply < before) assert(caller == ADAPTER && selector == IVaultToken.burn.selector);
    }

    // PROP-005 verifies: INV-009, INV-010, INV-012, REQ-VTOKEN-032
    function check_PROP_005_adapterOnlyFunctionsRefuseOtherCallers(
        address caller,
        address a,
        uint256 v,
        uint8 which
    ) public {
        vm.assume(caller != ADAPTER);
        bytes memory data;
        if (which % 3 == 0) data = abi.encodeCall(IVaultToken.mint, (a, v));
        else if (which % 3 == 1) data = abi.encodeCall(IVaultToken.burn, (a, v));
        else data = abi.encodeCall(IVaultToken.addValidProxy, (a));
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(token).call(data);
        assert(!ok);
        assert(keccak256(ret) == keccak256(abi.encodeWithSelector(IVaultToken.OnlyAdapter.selector)));
    }

    // PROP-055 verifies: INV-010, REQ-VTOKEN-014, REQ-VTOKEN-042, SPEC-UNIT-002, Q-224, Q-226
    /// @notice A successful burn lowers exactly `balanceOf(from)` and `totalSupply` by `amount`, moves no other balance
    /// and reads or spends no allowance; it succeeds only from a registered proxy or LPVaultSwap.
    function check_PROP_055_burnNeedsNoAllowanceAndLowersExactly(
        address from,
        address other,
        address spender,
        uint256 amount
    ) public {
        vm.assume(other != from);
        uint256 fromBefore = token.balanceOf(from);
        uint256 otherBefore = token.balanceOf(other);
        uint256 supplyBefore = token.totalSupply();
        uint256 allowanceBefore = token.allowance(from, spender);
        vm.prank(ADAPTER);
        (bool ok,) = address(token).call(abi.encodeCall(IVaultToken.burn, (from, amount)));
        if (ok) {
            assert(token.isValidProxy(from) || from == SWAP);
            assert(token.balanceOf(from) == fromBefore - amount);
            assert(token.totalSupply() == supplyBefore - amount);
            assert(token.balanceOf(other) == otherBefore);
            assert(token.allowance(from, spender) == allowanceBefore);
        } else {
            assert(!(token.isValidProxy(from) || from == SWAP) || amount > fromBefore);
        }
    }

    // PROP-008 verifies: INV-011, REQ-VTOKEN-006, REQ-VTOKEN-008, REQ-VTOKEN-012, REQ-VTOKEN-048, Q-068, Q-224, Q-300
    // PROP-055 verifies: INV-011, REQ-VTOKEN-008, REQ-VTOKEN-040, Q-224, Q-300
    /// @notice A `transfer`, `transferFrom` or `mint` succeeds only on an allowed path: proxy to Hub, Hub to proxy, Hub
    /// to LPVaultSwap; mint only to a registered proxy; a `transfer` or `transferFrom` of 0 never succeeds.
    function check_PROP_008_movementsOnlyOnAllowedPaths(
        address caller,
        address from,
        address to,
        uint256 v,
        uint8 which
    ) public {
        bool ok;
        if (which % 3 == 0) {
            vm.prank(caller);
            (ok,) = address(token).call(abi.encodeCall(IERC20.transfer, (to, v)));
            if (ok) assert(token.isAllowedTransfer(caller, to) && v > 0);
        } else if (which % 3 == 1) {
            vm.prank(caller);
            (ok,) = address(token).call(abi.encodeCall(IERC20.transferFrom, (from, to, v)));
            if (ok) assert(token.isAllowedTransfer(from, to) && v > 0);
        } else {
            vm.prank(ADAPTER);
            (ok,) = address(token).call(abi.encodeCall(IVaultToken.mint, (to, v)));
            if (ok) assert(token.isValidProxy(to) && to != address(0));
        }
        if (ok) assert(token.isAllowedRecipient(to));
    }

    // PROP-055 verifies: INV-011, REQ-VTOKEN-006, REQ-VTOKEN-040, REQ-VTOKEN-041
    /// @notice The views equal the formulas of `REQ-VTOKEN-040` for every pair; the Adapter is never an allowed holder.
    function check_PROP_055_viewsAreTheFixedFormulas(
        address from,
        address to
    ) public view {
        bool valid = token.isValidProxy(to);
        assert(token.isAllowedRecipient(to) == (to == HUB || to == SWAP || valid));
        assert(
            token.isAllowedTransfer(from, to)
                == ((to == HUB && token.isValidProxy(from)) || (from == HUB && (valid || to == SWAP)))
        );
        assert(!token.isAllowedRecipient(ADAPTER) && !token.isAllowedTransfer(SWAP, HUB));
    }

    // PROP-009 verifies: INV-012, REQ-VTOKEN-007, REQ-VTOKEN-039, Q-224, Q-225
    /// @notice No call removes a registry entry, and an entry appears only through `addValidProxy` by the Adapter, never
    /// for any of the seven bindings (Hub, CDP Spoke, Adapter, LPVaultSwap, Collateralization, LPVault, LPOracle), the
    /// zero address or the token itself.
    function check_PROP_009_registryAppendOnlyByAdapter(
        address caller,
        bytes4 selector,
        address p,
        address b,
        uint256 v
    ) public {
        bool before = token.isValidProxy(p);
        bool proxyBefore = token.isValidProxy(PROXY);
        _call(caller, selector, p, b, v);
        assert(token.isValidProxy(PROXY) == proxyBefore);
        if (before) assert(token.isValidProxy(p));
        if (!before && token.isValidProxy(p)) {
            assert(caller == ADAPTER && selector == IVaultToken.addValidProxy.selector);
            assert(p != HUB && p != SWAP && p != ADAPTER && p != SPOKE && p != address(0) && p != address(token));
            assert(p != COLL && p != LP_VAULT && p != LP_ORACLE);
        }
    }

    // PROP-055 verifies: INV-009, INV-011, INV-012, REQ-VTOKEN-001, REQ-VTOKEN-003, Q-224, Q-226
    function check_PROP_055_bindingsNeverChange(
        address caller,
        bytes4 selector,
        address a,
        address b,
        uint256 v
    ) public {
        _call(caller, selector, a, b, v);
        assert(token.adapter() == ADAPTER && token.hub() == HUB && token.spoke() == SPOKE);
        assert(token.lpVaultSwap() == SWAP && token.collateralization() == COLL && token.integration() == LP_VAULT);
        assert(token.lpOracle() == LP_ORACLE && token.marketKey() == KEY && token.marketId() == 4);
        assert(token.integrationId() == 1 && token.decimals() == 6);
    }
}
