// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {FlashloanRepay} from "../../src/FlashloanRepay.sol";
import {IAaveV3FlashLoanReceiver} from "../../src/dependencies/aave/IAaveV3FlashLoanReceiver.sol";
import {IAaveAdapter} from "../../src/interfaces/IAaveAdapter.sol";
import {Swap} from "../../src/libraries/SwapCalls.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";

/// @title DelegateEntries
/// @notice Base of the fixed-length hevm entry points of `script/security-slow.sh` (`hevm src:<Name>`). hevm 0.58 has
/// no symbolic ABI encoding for dynamic arrays (`Internal Error: TODO: symbolic abi encoding for bytes[]`, and the same
/// for `address[]`), so it cannot run an entry point that takes one. Each wrapper takes fixed-length arguments, builds
/// the array the real caller would send and delegatecalls the analysed runtime code with it: `msg.sender` stays the
/// symbolic caller, the storage is this contract's (empty, as on the bare `src:` target) and the code's own immutables
/// are the filled ones. Any other call, such as OpenZeppelin `Multicall`'s delegatecall to `address(this)`, is passed on
/// to the same code by the fallback.
/// @dev No state variables: the analysed code owns every storage slot. The revert data of the analysed code is passed
/// on unchanged, so a Panic(1) can only come from an `assert` in that code.
abstract contract DelegateEntries {
    /// @notice The analysed runtime code (`HEVM_SRC_ADDRESS` in the script).
    address public immutable IMPL;

    constructor(
        address impl
    ) {
        IMPL = impl;
    }

    fallback() external payable {
        _delegate(msg.data);
    }

    receive() external payable {}

    function _delegate(
        bytes memory data
    ) internal returns (bytes memory result) {
        bool ok;
        (ok, result) = IMPL.delegatecall(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
    }
}

/// @title AaveAdapterFixedEntries
/// @notice Fixed-length entry points of `AaveAdapter.multicall(bytes[])` and `AaveAdapter.collectFees(uint256,bytes32[])`
/// for hevm. The batches are the ones the adapter's design record names (design/adapter.md): pledging several NFTs,
/// pledge then borrow, and moving headroom between a wallet's markets (borrow in one, repay in another). Two calls and
/// two position keys per run keep the symbolic search inside one CI job.
contract AaveAdapterFixedEntries is DelegateEntries {
    constructor(
        address impl
    ) DelegateEntries(impl) {}

    /// @notice `multicall([pledge(keyA), pledge(keyB)])`.
    function multicallPledgePledge(
        bytes32 keyA,
        bytes32 keyB
    ) external {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IAaveAdapter.pledge, (keyA));
        calls[1] = abi.encodeCall(IAaveAdapter.pledge, (keyB));
        _delegate(abi.encodeCall(Multicall.multicall, (calls)));
    }

    /// @notice `multicall([pledge(key), borrow(marketId, reserveId, amount, recipient)])`.
    function multicallPledgeBorrow(
        bytes32 key,
        uint256 marketId,
        uint256 reserveId,
        uint256 amount,
        address recipient
    ) external {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IAaveAdapter.pledge, (key));
        calls[1] = abi.encodeCall(IAaveAdapter.borrow, (marketId, reserveId, amount, recipient));
        _delegate(abi.encodeCall(Multicall.multicall, (calls)));
    }

    /// @notice `multicall([borrow(fromMarket, reserveId, amount, recipient), repay(toMarket, reserveId, repayAmount,
    /// wallet)])`.
    function multicallBorrowRepay(
        uint256 fromMarket,
        uint256 toMarket,
        uint256 reserveId,
        uint256 amount,
        uint256 repayAmount,
        address recipient,
        address wallet
    ) external {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IAaveAdapter.borrow, (fromMarket, reserveId, amount, recipient));
        calls[1] = abi.encodeCall(IAaveAdapter.repay, (toMarket, reserveId, repayAmount, wallet));
        _delegate(abi.encodeCall(Multicall.multicall, (calls)));
    }

    /// @notice `collectFees(marketId, [keyA, keyB])`.
    function collectFeesTwo(
        uint256 marketId,
        bytes32 keyA,
        bytes32 keyB
    ) external {
        bytes32[] memory keys = new bytes32[](2);
        keys[0] = keyA;
        keys[1] = keyB;
        _delegate(abi.encodeCall(IAaveAdapter.collectFees, (marketId, keys)));
    }
}

/// @title FlashloanRepayFixedEntries
/// @notice Fixed-length entry point of `FlashloanRepay.executeOperation(address[],uint256[],uint256[],address,bytes)`
/// for hevm. FlashloanRepay takes a loan of one asset (`onWithdrawAllowed` passes one-element arrays to the Pool, and
/// the callback rejects any other length), so the wrapper sends one asset, amount and premium. The `params` it sends
/// are what `onWithdrawAllowed` builds, `abi.encode(Context)`, with one swap whose call data is three words: a
/// symbolic-length `bytes` made hevm copy a buffer of unbounded size and stop at the memory cap (run 45056172049).
contract FlashloanRepayFixedEntries is DelegateEntries {
    constructor(
        address impl
    ) DelegateEntries(impl) {}

    /// @notice `executeOperation([asset], [amount], [premium], initiator, abi.encode(context))`.
    /// @param nums The context's market id, amount, reserve id, repay amount, amount0Min, amount1Min and the swap's
    /// amount-in offset, in that order.
    function executeOperationOneAsset(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        address wallet,
        bytes32 positionKey,
        uint128 liquidity,
        uint256[7] calldata nums,
        address swapTokenIn,
        address swapTarget,
        bytes32[3] calldata swapData
    ) external {
        FlashloanRepay.Context memory c = _context(wallet, positionKey, liquidity, nums);
        c.params.swaps = new Swap[](1);
        c.params.swaps[0] = Swap({
            tokenIn: swapTokenIn,
            target: swapTarget,
            data: bytes.concat(swapData[0], swapData[1], swapData[2]),
            amountInOffset: nums[6]
        });
        _call(asset, amount, premium, initiator, abi.encode(c));
    }

    function _context(
        address wallet,
        bytes32 positionKey,
        uint128 liquidity,
        uint256[7] calldata nums
    ) private pure returns (FlashloanRepay.Context memory c) {
        (c.wallet, c.positionKey, c.marketId, c.amount) = (wallet, positionKey, nums[0], nums[1]);
        (c.params.reserveId, c.params.amount, c.params.liquidity) = (nums[2], nums[3], liquidity);
        (c.params.amount0Min, c.params.amount1Min) = (nums[4], nums[5]);
    }

    function _call(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes memory params
    ) private {
        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory premiums = new uint256[](1);
        assets[0] = asset;
        amounts[0] = amount;
        premiums[0] = premium;
        _delegate(
            abi.encodeCall(IAaveV3FlashLoanReceiver.executeOperation, (assets, amounts, premiums, initiator, params))
        );
    }
}
