// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IVaultToken} from "../../src/vault-token/IVaultToken.sol";
import {VaultToken} from "../../src/vault-token/VaultToken.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The vault token on its own: AccessManager roles for the adapter (mint, burn, register) and the
/// LiquidationModule (burn), and the transfer paths Aave V4 uses (supply, withdrawal, seizure). The real Hub and Spoke
/// run in `VaultToken.AaveV4.integration.t.sol`.
contract VaultTokenUnitTest is Test {
    uint64 internal constant ADAPTER_ROLE = 11;
    uint64 internal constant LIQUIDATION_ROLE = 12;

    AccessManager internal am;
    VaultToken internal token;
    address internal adapter = makeAddr("adapter");
    address internal hub = makeAddr("hub");
    address internal spoke = makeAddr("spoke");
    address internal lm = makeAddr("liquidationModule");
    address internal proxyA = makeAddr("proxyA");
    address internal proxyB = makeAddr("proxyB");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        am = new AccessManager(address(this));
        token = new VaultToken(_params());
        bytes4[] memory adapterSelectors = new bytes4[](3);
        adapterSelectors[0] = IVaultToken.mint.selector;
        adapterSelectors[1] = IVaultToken.burn.selector;
        adapterSelectors[2] = IVaultToken.addValidProxy.selector;
        am.setTargetFunctionRole(address(token), adapterSelectors, ADAPTER_ROLE);
        am.grantRole(ADAPTER_ROLE, adapter, 0);
        am.grantRole(ADAPTER_ROLE, lm, 0);
        vm.startPrank(adapter);
        token.addValidProxy(proxyA);
        token.addValidProxy(proxyB);
        vm.stopPrank();
    }

    function _params() internal view returns (IVaultToken.Params memory) {
        return IVaultToken.Params({
            name: "Avana WETH/USDC Full range",
            symbol: "avWETH-USDC-F",
            decimals: 18,
            marketId: 1,
            hub: hub,
            liquidationModule: lm,
            authority: address(am)
        });
    }

    /// @dev Mint to a proxy and supply it to the Hub through the Spoke, as `Spoke.supply` does.
    function _supply(
        address proxy,
        uint256 amount
    ) internal {
        vm.prank(adapter);
        token.mint(proxy, amount);
        vm.prank(proxy);
        token.approve(spoke, amount);
        vm.prank(spoke);
        token.transferFrom(proxy, hub, amount);
    }

    // ─── Construction ───

    function test_constructor() public view {
        assertEq(token.name(), "Avana WETH/USDC Full range");
        assertEq(token.symbol(), "avWETH-USDC-F");
        assertEq(token.decimals(), 18);
        assertEq(token.marketId(), 1);
        assertEq(token.hub(), hub);
        assertEq(token.liquidationModule(), lm);
        assertEq(token.authority(), address(am));
    }

    function test_revert_constructor() public {
        IVaultToken.Params memory p = _params();
        p.hub = address(0);
        vm.expectRevert(IVaultToken.ZeroAddress.selector);
        new VaultToken(p);
        p = _params();
        p.liquidationModule = address(0);
        vm.expectRevert(IVaultToken.ZeroAddress.selector);
        new VaultToken(p);
        p = _params();
        p.authority = address(0);
        vm.expectRevert(IVaultToken.ZeroAddress.selector);
        new VaultToken(p);
        p = _params();
        p.marketId = 0;
        _expectInvalid(p);
        p = _params();
        p.decimals = 5;
        _expectInvalid(p);
        p.decimals = 19;
        _expectInvalid(p);
        p = _params();
        p.name = "";
        _expectInvalid(p);
        p = _params();
        p.symbol = "";
        _expectInvalid(p);
        p = _params();
        p.liquidationModule = hub;
        _expectInvalid(p);
        p = _params();
        p.authority = hub;
        _expectInvalid(p);
        p = _params();
        p.authority = lm;
        _expectInvalid(p);
    }

    function _expectInvalid(
        IVaultToken.Params memory p
    ) internal {
        vm.expectRevert(IVaultToken.InvalidDeployment.selector);
        new VaultToken(p);
    }

    // ─── Roles ───

    function test_revert_unauthorizedCallers() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        token.mint(proxyA, 1);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        token.burn(proxyA, 1);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        token.addValidProxy(stranger);
        vm.stopPrank();
    }

    function test_addValidProxy() public {
        address p = makeAddr("proxyC");
        vm.expectEmit(address(token));
        emit IVaultToken.ProxyAdded(p);
        vm.prank(adapter);
        token.addValidProxy(p);
        assertTrue(token.isValidProxy(p));
        vm.recordLogs();
        vm.prank(adapter);
        token.addValidProxy(p);
        assertEq(vm.getRecordedLogs().length, 0, "repeat emits");
    }

    function test_revert_addValidProxy_reserved() public {
        address[4] memory reserved = [hub, lm, address(am), address(token)];
        for (uint256 i = 0; i < 4; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IVaultToken.ReservedAddress.selector, reserved[i]));
            vm.prank(adapter);
            token.addValidProxy(reserved[i]);
        }
        vm.expectRevert(IVaultToken.ZeroAddress.selector);
        vm.prank(adapter);
        token.addValidProxy(address(0));
    }

    // ─── Mint and burn ───

    function test_mint_onlyToProxy() public {
        vm.prank(adapter);
        token.mint(proxyA, 100);
        assertEq(token.balanceOf(proxyA), 100);
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedRecipient.selector, stranger));
        vm.prank(adapter);
        token.mint(stranger, 100);
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedRecipient.selector, hub));
        vm.prank(adapter);
        token.mint(hub, 100);
        vm.expectRevert(IVaultToken.ZeroAddress.selector);
        vm.prank(adapter);
        token.mint(address(0), 100);
    }

    function test_burn_fromProxyAndLiquidationModule() public {
        _supply(proxyA, 100);
        vm.prank(hub);
        token.transfer(proxyA, 40); // withdrawal
        vm.prank(adapter);
        token.burn(proxyA, 40);
        vm.prank(hub);
        token.transfer(lm, 60); // seizure
        vm.prank(lm);
        token.burn(lm, 60);
        assertEq(token.totalSupply(), 0);
    }

    function test_revert_burn_fromOthers() public {
        _supply(proxyA, 100);
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, hub, address(0)));
        vm.prank(adapter);
        token.burn(hub, 1);
        vm.expectRevert(IVaultToken.ZeroAddress.selector);
        vm.prank(adapter);
        token.burn(address(0), 1);
    }

    // ─── Paths ───

    function test_supplyWithdrawSeize() public {
        _supply(proxyA, 100);
        assertEq(token.balanceOf(hub), 100);
        assertEq(token.allowance(proxyA, spoke), 0);
        vm.startPrank(hub);
        token.transfer(proxyA, 10);
        token.transfer(proxyB, 10); // a withdrawal to another of the account's proxies
        token.transfer(lm, 10);
        vm.stopPrank();
        assertEq(token.balanceOf(lm), 10);
    }

    function test_revert_offPathTransfers() public {
        _supply(proxyA, 100);
        vm.prank(hub);
        token.transfer(proxyA, 50);
        vm.prank(hub);
        token.transfer(lm, 10);
        _expectBlocked(proxyA, proxyB, 1);
        _expectBlocked(proxyA, stranger, 1);
        _expectBlocked(proxyA, lm, 1);
        _expectBlocked(hub, stranger, 1); // a third-party liquidator
        _expectBlocked(lm, hub, 1);
        _expectBlocked(lm, stranger, 1);
        _expectBlocked(proxyA, hub, 0); // zero on an allowed path
        _expectBlocked(hub, proxyA, 0);
    }

    function _expectBlocked(
        address from,
        address to,
        uint256 amount
    ) internal {
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, from, to));
        vm.prank(from);
        token.transfer(to, amount);
    }

    function test_revert_transferFromWithoutAllowance() public {
        vm.prank(adapter);
        token.mint(proxyA, 100);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, 1));
        vm.prank(stranger);
        token.transferFrom(proxyA, hub, 1);
    }

    function test_isAllowedTransfer() public view {
        assertTrue(token.isAllowedTransfer(proxyA, hub));
        assertTrue(token.isAllowedTransfer(hub, proxyA));
        assertTrue(token.isAllowedTransfer(hub, lm));
        assertFalse(token.isAllowedTransfer(stranger, hub));
        assertFalse(token.isAllowedTransfer(hub, stranger));
        assertFalse(token.isAllowedTransfer(proxyA, proxyB));
        assertFalse(token.isAllowedTransfer(lm, hub));
    }

    /// @notice Whatever the sender and recipient, tokens only ever sit with proxies, the Hub or the LiquidationModule.
    function testFuzz_tokensStayOnPaths(
        uint8 fromIndex,
        uint8 toIndex,
        uint96 amount
    ) public {
        _supply(proxyA, 1000);
        vm.prank(hub);
        token.transfer(lm, 100);
        vm.prank(hub);
        token.transfer(proxyA, 100);
        address[5] memory actors = [proxyA, proxyB, hub, lm, stranger];
        address from = actors[fromIndex % 5];
        address to = actors[toIndex % 5];
        vm.prank(from);
        try token.transfer(to, bound(amount, 0, 100)) {} catch {}
        assertEq(token.balanceOf(stranger), 0);
        assertEq(token.balanceOf(proxyA) + token.balanceOf(proxyB) + token.balanceOf(hub) + token.balanceOf(lm), 1000);
    }
}
