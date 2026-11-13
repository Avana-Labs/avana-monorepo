// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title TokenProbe
/// @notice `REQ-ARCH-014` before a token is listed (09-listing-setup): the token answers `decimals()`, a transfer
/// delivers exactly the amount sent, and a balance does not change without a transfer. Deployed and called only in a
/// script's simulation, on a snapshot the script reverts: it writes a balance with forge's storage cheats.
contract TokenProbe {
    using stdStorage for StdStorage;

    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    StdStorage private _store;

    /// @notice Reverts with the reason when `t` shows a behaviour listing refuses.
    function check(
        address t
    ) external {
        (bool ok, bytes memory ret) = t.staticcall(abi.encodeWithSignature("decimals()"));
        require(ok && ret.length == 32, "no decimals()");
        uint256 amount = 1000 * 10 ** abi.decode(ret, (uint8));
        address a = address(uint160(uint256(keccak256("avana.listing.probe.sender"))));
        address b = address(uint160(uint256(keccak256("avana.listing.probe.recipient"))));
        _store.target(t).sig(IERC20.balanceOf.selector).with_key(a).checked_write(amount);
        VM.prank(a);
        (ok, ret) = t.call(abi.encodeCall(IERC20.transfer, (b, amount / 2)));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "a transfer reverted or returned false");
        require(IERC20(t).balanceOf(b) == amount / 2, "transfer fee: the recipient received less than was sent");
        require(IERC20(t).balanceOf(a) == amount - amount / 2, "the sender's balance did not fall by the amount sent");
        VM.warp(block.timestamp + 1 days);
        VM.roll(block.number + 1);
        require(IERC20(t).balanceOf(b) == amount / 2, "a balance changed without a transfer (rebasing)");
    }
}
