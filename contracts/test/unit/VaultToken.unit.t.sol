// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {VaultTokenBindings} from "../../src/types/VaultTokenBindings.sol";
import {IVaultToken} from "../../src/vault-token/vault-token/IVaultToken.sol";
import {VaultToken} from "../../src/vault-token/vault-token/VaultToken.sol";
import {VaultTokenFixture} from "../utils/fixtures/VaultTokenFixture.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title VaultTokenUnitTest
/// @notice The vault token on its own (2.4): fixed bindings and constructor checks, no admin surface, mint and burn by
/// the AaveAdapter only, and the append-only proxy registry.
/// @dev Token-side parts of TEST-022, TEST-023 and TEST-188; the Adapter-side halves (the Adapter checks
/// `isValidProxy` first, one `ProxyAdded` per market at the first pledge) join those rows with the AaveAdapter.
contract VaultTokenUnitTest is VaultTokenFixture {
    function setUp() public {
        _deployToken();
    }

    // ─── Construction and bindings (TEST-023) ───

    // TEST-023 verifies: REQ-VTOKEN-001, REQ-VTOKEN-003, REQ-VTOKEN-004, REQ-VTOKEN-028, REQ-VTOKEN-038, SPEC-UNIT-001, Q-224, Q-226
    // Sources: 5.1 TEST-023, 2.4 Storage
    function test_TEST_023_bindingsAreTheConstructorValues() public view {
        assertEq(token.marketKey(), MARKET_KEY, "marketKey");
        assertEq(token.integrationId(), INTEGRATION_ID, "integrationId");
        assertEq(token.integration(), lpVault, "integration");
        assertEq(token.hub(), hub, "hub");
        assertEq(token.spoke(), spoke, "spoke");
        assertEq(token.marketId(), MARKET_ID, "marketId");
        assertEq(token.lpOracle(), lpOracle, "lpOracle");
        assertEq(token.adapter(), adapter, "adapter");
        assertEq(token.lpVaultSwap(), lpVaultSwap, "lpVaultSwap");
        assertEq(token.collateralization(), collateralization, "collateralization");
        assertEq(token.decimals(), DECIMALS, "decimals");
        assertEq(token.name(), NAME, "name");
        assertEq(token.symbol(), SYMBOL, "symbol");
        assertEq(token.totalSupply(), 0, "no supply at deployment");
    }

    // TEST-023 verifies: REQ-VTOKEN-004, REQ-VTOKEN-046, SPEC-UNIT-001
    function testFuzz_TEST_023_decimalsInSixToEighteenOnly(
        uint8 d
    ) public {
        VaultTokenBindings memory b = _bindings();
        b.decimals = d;
        if (d < 6 || d > 18) {
            vm.expectRevert(IVaultToken.InvalidBinding.selector);
            new VaultToken(b);
        } else {
            assertEq(new VaultToken(b).decimals(), d);
        }
    }

    // TEST-023 verifies: REQ-VTOKEN-046, REQ-VTOKEN-038
    function test_TEST_023_constructorRefusesZeroIdsAndKey() public {
        VaultTokenBindings memory b = _bindings();
        b.integrationId = 0;
        vm.expectRevert(IVaultToken.InvalidBinding.selector);
        new VaultToken(b);
        b = _bindings();
        b.marketKey = bytes32(0);
        vm.expectRevert(IVaultToken.InvalidBinding.selector);
        new VaultToken(b);
        b = _bindings();
        b.marketId = 0;
        vm.expectRevert(IVaultToken.InvalidBinding.selector);
        new VaultToken(b);
    }

    // TEST-023 verifies: REQ-VTOKEN-046, REQ-VTOKEN-028
    /// @notice Each of the seven address bindings set to zero reverts `ZeroAddress`; each pair set equal reverts
    /// `InvalidBinding`.
    function test_TEST_023_constructorRefusesZeroOrEqualAddresses() public {
        for (uint256 i = 0; i < 7; ++i) {
            VaultTokenBindings memory b = _bindings();
            _setAddress(b, i, address(0));
            vm.expectRevert(IVaultToken.ZeroAddress.selector);
            new VaultToken(b);
            for (uint256 j = i + 1; j < 7; ++j) {
                b = _bindings();
                _setAddress(b, j, _getAddress(b, i));
                vm.expectRevert(IVaultToken.InvalidBinding.selector);
                new VaultToken(b);
            }
        }
    }

    // TEST-023 verifies: REQ-VTOKEN-046
    /// @notice A binding equal to the token's own (CREATE-predicted) address reverts `InvalidBinding`, in each of the
    /// seven address slots.
    function test_TEST_023_constructorRefusesItsOwnAddressAsBinding() public {
        for (uint256 i = 0; i < 7; ++i) {
            VaultTokenBindings memory b = _bindings();
            address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
            _setAddress(b, i, next);
            vm.expectRevert(IVaultToken.InvalidBinding.selector);
            new VaultToken(b);
        }
    }

    // TEST-023 verifies: REQ-VTOKEN-046
    /// @notice Check order: a zero address binding reverts `ZeroAddress` even when another binding is duplicated or an
    /// identifier, the key or the decimals are invalid; with every address non-zero, a duplicate and an invalid integer
    /// both give `InvalidBinding`.
    function test_TEST_023_constructorZeroAddressComesFirst() public {
        VaultTokenBindings memory b = _bindings();
        b.hub = address(0);
        b.spoke = b.lpOracle;
        b.integrationId = 0;
        b.decimals = 5;
        vm.expectRevert(IVaultToken.ZeroAddress.selector);
        new VaultToken(b);
        b = _bindings();
        b.spoke = b.lpOracle;
        b.marketId = 0;
        vm.expectRevert(IVaultToken.InvalidBinding.selector);
        new VaultToken(b);
    }

    // TEST-023 verifies: REQ-VTOKEN-001, REQ-VTOKEN-002, REQ-VTOKEN-029, Q-064, Q-068
    /// @notice No permit, owner, pause, upgrade, flash-mint or hook entry point exists: each selector reverts with no
    /// data (the token has no fallback), and ETH is refused.
    function test_TEST_023_noAdminPermitOrHookSurface() public {
        bytes[] memory calls = new bytes[](12);
        calls[0] = abi.encodeWithSignature(
            "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)", proxyA, spoke, 1, 0, 0, 0, 0
        );
        calls[1] = abi.encodeWithSignature("nonces(address)", proxyA);
        calls[2] = abi.encodeWithSignature("DOMAIN_SEPARATOR()");
        calls[3] = abi.encodeWithSignature("owner()");
        calls[4] = abi.encodeWithSignature("transferOwnership(address)", wallet);
        calls[5] = abi.encodeWithSignature("pause()");
        calls[6] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", wallet, "");
        calls[7] = abi.encodeWithSignature("flashLoan(address,address,uint256,bytes)", wallet, address(token), 1, "");
        calls[8] = abi.encodeWithSignature("transferAndCall(address,uint256)", hub, 1);
        calls[9] = abi.encodeWithSignature("removeValidProxy(address)", proxyA);
        calls[10] = abi.encodeWithSignature("setAdapter(address)", wallet);
        calls[11] = "";
        for (uint256 i = 0; i < calls.length; ++i) {
            vm.prank(adapter);
            (bool ok, bytes memory ret) = address(token).call(calls[i]);
            assertFalse(ok, "selector exists");
            assertEq(ret.length, 0, "no fallback");
        }
        vm.deal(wallet, 1 ether);
        vm.prank(wallet);
        (bool sent,) = address(token).call{value: 1}("");
        assertFalse(sent, "accepts ETH");
    }

    // ─── Mint (TEST-022) ───

    // TEST-022 verifies: REQ-VTOKEN-012, REQ-VTOKEN-027, REQ-VTOKEN-032, INV-009, Q-224
    // Sources: 5.1 TEST-022, 2.4 REQ-VTOKEN-012
    function testFuzz_TEST_022_mintOnlyByAdapter(
        address caller
    ) public {
        vm.assume(caller != adapter);
        _register(proxyA);
        vm.prank(caller);
        vm.expectRevert(IVaultToken.OnlyAdapter.selector);
        token.mint(proxyA, 1);
    }

    // TEST-022 verifies: REQ-VTOKEN-012, REQ-VTOKEN-033, REQ-VTOKEN-043, INV-009, Q-224, Q-300
    /// @notice Mint reaches only a registered proxy: never the Hub, the Adapter, LPVaultSwap, the zero address or any
    /// unregistered address; the checks run in the order OnlyAdapter, ZeroAddress, UnauthorizedRecipient.
    function test_TEST_022_mintOnlyToRegisteredProxy() public {
        vm.prank(wallet);
        vm.expectRevert(IVaultToken.OnlyAdapter.selector);
        token.mint(address(0), 1);
        vm.prank(adapter);
        vm.expectRevert(IVaultToken.ZeroAddress.selector);
        token.mint(address(0), 1);
        address[5] memory refused = [hub, adapter, lpVaultSwap, wallet, proxyA];
        for (uint256 i = 0; i < refused.length; ++i) {
            vm.prank(adapter);
            vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedRecipient.selector, refused[i]));
            token.mint(refused[i], 1);
        }
        _register(proxyA);
        vm.expectEmit(address(token));
        emit IERC20.Transfer(address(0), proxyA, 5_000_000_000);
        _mint(proxyA, 5_000_000_000);
        assertEq(token.balanceOf(proxyA), 5_000_000_000, "proxy balance");
        assertEq(token.totalSupply(), 5_000_000_000, "supply");
    }

    // ─── Burn (TEST-022) ───

    // TEST-022 verifies: REQ-VTOKEN-014, REQ-VTOKEN-027, REQ-VTOKEN-032, INV-010, Q-224
    function testFuzz_TEST_022_burnOnlyByAdapter(
        address caller
    ) public {
        vm.assume(caller != adapter);
        _register(proxyA);
        _mint(proxyA, 10);
        vm.prank(caller);
        vm.expectRevert(IVaultToken.OnlyAdapter.selector);
        token.burn(proxyA, 1);
    }

    // TEST-022 verifies: REQ-VTOKEN-014, REQ-VTOKEN-015, REQ-VTOKEN-042, SPEC-UNIT-002, INV-010, Q-224, Q-254
    /// @notice Burn from a registered proxy needs no allowance and lowers exactly the holder's balance and the supply.
    function test_TEST_022_burnFromProxyWithoutAllowance() public {
        _register(proxyA);
        _mint(proxyA, 5_000_000_000);
        assertEq(token.allowance(proxyA, adapter), 0, "no allowance");
        vm.expectEmit(address(token));
        emit IERC20.Transfer(proxyA, address(0), 1_000_000_000);
        vm.prank(adapter);
        token.burn(proxyA, 1_000_000_000);
        assertEq(token.balanceOf(proxyA), 4_000_000_000, "proxy balance");
        assertEq(token.totalSupply(), 4_000_000_000, "supply");
    }

    // TEST-022 verifies: REQ-VTOKEN-014, REQ-VTOKEN-042, SPEC-UNIT-002, INV-010, Q-255
    /// @notice A seizure burn: units the Hub paid to LPVaultSwap are burned from LPVaultSwap without an allowance.
    function test_TEST_022_burnSeizedFromLpVaultSwap() public {
        _pledge(proxyA, 5_000_000_000);
        vm.prank(hub);
        token.transfer(lpVaultSwap, 1_575_000_000);
        vm.prank(adapter);
        token.burn(lpVaultSwap, 1_575_000_000);
        assertEq(token.balanceOf(lpVaultSwap), 0, "seized units burned");
        assertEq(token.totalSupply(), 3_425_000_000, "supply fell by the seizure");
        assertEq(token.balanceOf(hub), 3_425_000_000, "hub keeps the rest");
    }

    // TEST-022 verifies: REQ-VTOKEN-014, REQ-VTOKEN-033, REQ-VTOKEN-042, REQ-VTOKEN-043, INV-010, Q-224
    /// @notice The Hub's balance can never be burned, nor any address outside the proxies and LPVaultSwap.
    function test_TEST_022_burnRefusesHubAndOutsiders() public {
        _pledge(proxyA, 1000);
        vm.prank(adapter);
        vm.expectRevert(IVaultToken.ZeroAddress.selector);
        token.burn(address(0), 1);
        address[4] memory refused = [hub, adapter, wallet, spoke];
        for (uint256 i = 0; i < refused.length; ++i) {
            vm.prank(adapter);
            vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, refused[i], address(0)));
            token.burn(refused[i], 0);
        }
        assertEq(token.balanceOf(hub), 1000, "hub balance intact");
    }

    // TEST-022 verifies: REQ-VTOKEN-034
    function test_TEST_022_burnAboveBalanceReverts() public {
        _register(proxyA);
        _mint(proxyA, 10);
        vm.prank(adapter);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, proxyA, 10, 11));
        token.burn(proxyA, 11);
    }

    // TEST-022 verifies: REQ-VTOKEN-012, REQ-VTOKEN-014, REQ-VTOKEN-048
    /// @notice A zero `mint` or `burn` by the Adapter is the only zero-value movement: it keeps the path rule (a zero
    /// mint to an unregistered address still reverts), changes no balance or supply and emits a zero `Transfer`.
    function test_TEST_022_zeroMintAndBurnByAdapterChangeNothing() public {
        vm.prank(adapter);
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedRecipient.selector, wallet));
        token.mint(wallet, 0);
        _register(proxyA);
        _mint(proxyA, 10);
        vm.expectEmit(address(token));
        emit IERC20.Transfer(address(0), proxyA, 0);
        _mint(proxyA, 0);
        vm.expectEmit(address(token));
        emit IERC20.Transfer(proxyA, address(0), 0);
        vm.prank(adapter);
        token.burn(proxyA, 0);
        assertEq(token.balanceOf(proxyA), 10, "balance");
        assertEq(token.totalSupply(), 10, "supply");
    }

    // ─── Proxy registry (TEST-188) ───

    // TEST-188 verifies: REQ-VTOKEN-007, REQ-VTOKEN-032, REQ-VTOKEN-039, INV-012, Q-224, Q-225
    // Sources: 5.1 TEST-188
    function testFuzz_TEST_188_addValidProxyOnlyByAdapter(
        address caller,
        address proxy
    ) public {
        vm.assume(caller != adapter);
        vm.prank(caller);
        vm.expectRevert(IVaultToken.OnlyAdapter.selector);
        token.addValidProxy(proxy);
        assertFalse(token.isValidProxy(proxy), "registered");
    }

    // TEST-188 verifies: REQ-VTOKEN-007, REQ-VTOKEN-039, INV-012, Q-225
    /// @notice First registration appends and emits `ProxyAdded` once; a second call is a no-op without an event.
    function test_TEST_188_registerOnceThenNoOp() public {
        assertFalse(token.isValidProxy(proxyA), "valid before");
        vm.expectEmit(address(token));
        emit IVaultToken.ProxyAdded(proxyA);
        _register(proxyA);
        assertTrue(token.isValidProxy(proxyA), "not valid");
        vm.recordLogs();
        _register(proxyA);
        assertEq(vm.getRecordedLogs().length, 0, "second registration emitted");
        assertTrue(token.isValidProxy(proxyA), "removed");
        assertFalse(token.isValidProxy(proxyB), "other proxy registered");
    }

    // TEST-188 verifies: REQ-VTOKEN-039, REQ-VTOKEN-042, REQ-VTOKEN-043, REQ-VTOKEN-047, INV-012, Q-224
    /// @notice No Adapter can register the zero address, a binding or the token itself, so the Hub never becomes
    /// burnable, LPVaultSwap never gains a path to the Hub and the Adapter never becomes a seizure recipient.
    function test_TEST_188_refusesZeroAndReservedAddresses() public {
        vm.prank(adapter);
        vm.expectRevert(IVaultToken.ZeroAddress.selector);
        token.addValidProxy(address(0));
        address[8] memory reserved =
            [hub, spoke, adapter, lpVaultSwap, collateralization, lpVault, lpOracle, address(token)];
        for (uint256 i = 0; i < reserved.length; ++i) {
            vm.prank(adapter);
            vm.expectRevert(abi.encodeWithSelector(IVaultToken.ReservedAddress.selector, reserved[i]));
            token.addValidProxy(reserved[i]);
            assertFalse(token.isValidProxy(reserved[i]), "reserved registered");
        }
    }

    // TEST-188 verifies: REQ-VTOKEN-007, REQ-VTOKEN-039, INV-012
    /// @notice An unregistered address stays invalid and cannot receive the token; registration is never undone by any
    /// later call of the token's state-changing functions.
    function test_TEST_188_unregisteredCannotReceiveAndEntriesStay() public {
        _pledge(proxyA, 100);
        vm.prank(hub);
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, hub, proxyB));
        token.transfer(proxyB, 1);
        vm.prank(adapter);
        token.burn(proxyA, 0);
        vm.prank(hub);
        token.transfer(proxyA, 100);
        vm.prank(adapter);
        token.burn(proxyA, 100);
        assertTrue(token.isValidProxy(proxyA), "entry removed");
        assertFalse(token.isValidProxy(proxyB), "unregistered became valid");
    }

    // ─── Helpers ───

    function _setAddress(
        VaultTokenBindings memory b,
        uint256 i,
        address a
    ) private pure {
        if (i == 0) b.integration = a;
        else if (i == 1) b.hub = a;
        else if (i == 2) b.spoke = a;
        else if (i == 3) b.lpOracle = a;
        else if (i == 4) b.adapter = a;
        else if (i == 5) b.lpVaultSwap = a;
        else b.collateralization = a;
    }

    function _getAddress(
        VaultTokenBindings memory b,
        uint256 i
    ) private pure returns (address) {
        if (i == 0) return b.integration;
        if (i == 1) return b.hub;
        if (i == 2) return b.spoke;
        if (i == 3) return b.lpOracle;
        if (i == 4) return b.adapter;
        if (i == 5) return b.lpVaultSwap;
        return b.collateralization;
    }
}
