// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IPayoutEscrow} from "../../../src/liquidation/payout-escrow/IPayoutEscrow.sol";
import {PayoutDepositor} from "../../utils/mocks/PayoutEscrowActors.sol";
import {PayoutToken} from "../../utils/mocks/PayoutToken.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @title EscrowHandler
/// @notice Actor handler of the escrow side of TEST-173: LPVaultSwap deposits failed payouts (borrower surplus, Avana
/// fee, keeper payout) for three accounts in two debt assets, one of which switches an issuer fee on and off; credited
/// accounts claim to recipients they choose, some blocklisted; strangers and other accounts try to claim; outsiders
/// try to deposit; donors send dust by plain transfer; a rounding-up deposit delivers more than requested; a token
/// switches on a fee charged to the sender of a claim; the issuer burns from the escrow (a seizure or a negative
/// rebase). Ghosts record credits, claims, donations, burns and every forbidden success.
contract EscrowHandler is CommonBase, StdUtils {
    /// @notice A call that found nothing to act on, or that the contract refused: reverting keeps it out of the
    /// campaign's success count, so the metrics show the calls that did real work.
    error Skipped();

    IPayoutEscrow public immutable ESCROW;
    PayoutDepositor public immutable SWAP;
    PayoutToken[2] internal tokens;
    address[3] internal accounts;
    address[3] internal recipients;

    mapping(address token => mapping(address account => uint256 amount)) public credited;
    mapping(address token => mapping(address account => uint256 amount)) public claimed;
    mapping(address token => uint256 amount) public donated;
    mapping(address token => uint256 amount) public burned;

    /// @notice A claim paid an amount other than the whole credit, or to an address other than the named recipient.
    uint256 public wrongPayouts;
    /// @notice A claim by an address without a credit, or a deposit by someone other than LPVaultSwap, succeeded.
    uint256 public forbiddenSuccesses;
    /// @notice A refused claim or deposit changed a credit.
    uint256 public refusalsWithEffect;
    uint256 public claims;
    uint256 public deposits;
    /// @notice A claim succeeded while a sender-side fee took more than the claim from the escrow.
    uint256 public senderFeeClaimsPaid;

    constructor(
        IPayoutEscrow escrow,
        PayoutDepositor swap,
        PayoutToken[2] memory tokens_,
        address[3] memory accounts_,
        address[3] memory recipients_
    ) {
        ESCROW = escrow;
        SWAP = swap;
        tokens = tokens_;
        accounts = accounts_;
        recipients = recipients_;
    }

    /// @notice LPVaultSwap escrows a failed payout under the Lock; the second token's issuer fee is 0 to 20 bps.
    function deposit(
        uint256 tokenSeed,
        uint256 accountSeed,
        uint256 amount,
        uint256 feeBps
    ) external {
        PayoutToken token = tokens[tokenSeed % 2];
        address account = accounts[accountSeed % 3];
        amount = bound(amount, 10_000, 1e27);
        if (tokenSeed % 2 == 1) token.setFeeBps(bound(feeBps, 0, 20));
        uint256 before = ESCROW.claimable(address(token), account);
        token.mint(address(SWAP), amount);
        SWAP.depositUnderLock(address(token), account, amount);
        credited[address(token)][account] += ESCROW.claimable(address(token), account) - before;
        ++deposits;
    }

    /// @notice A credited account claims its whole credit to one of the recipients; a blocklisted recipient keeps the
    /// credit in place.
    function claim(
        uint256 tokenSeed,
        uint256 accountSeed,
        uint256 recipientSeed,
        bool blockRecipient
    ) external {
        PayoutToken token = tokens[tokenSeed % 2];
        address account = accounts[accountSeed % 3];
        address recipient = recipients[recipientSeed % 3];
        token.setBlocked(recipient, blockRecipient);
        uint256 credit = ESCROW.claimable(address(token), account);
        uint256 recipientBefore = token.balanceOf(recipient);
        uint256 escrowBefore = token.balanceOf(address(ESCROW));
        vm.prank(account);
        try ESCROW.claim(address(token), recipient) returns (uint256 paid) {
            claimed[address(token)][account] += paid;
            // The issuer's fee, if any, is taken from the transfer the escrow makes; the escrow pays the whole credit.
            uint256 received = paid - paid * token.feeBps() / 10_000;
            if (
                paid != credit || token.balanceOf(recipient) != recipientBefore + received
                    || token.balanceOf(address(ESCROW)) != escrowBefore - paid
            ) ++wrongPayouts;
            ++claims;
        } catch {
            if (ESCROW.claimable(address(token), account) != credit) ++refusalsWithEffect;
        }
        token.setBlocked(recipient, false);
    }

    /// @notice An address without a credit (a stranger, or LPVaultSwap itself) tries to claim.
    function claimWithoutCredit(
        uint256 tokenSeed,
        address stranger
    ) external {
        PayoutToken token = tokens[tokenSeed % 2];
        if (ESCROW.claimable(address(token), stranger) != 0 || stranger == address(0)) revert Skipped();
        vm.prank(stranger);
        try ESCROW.claim(address(token), stranger) {
            ++forbiddenSuccesses;
        } catch {}
    }

    /// @notice An address other than LPVaultSwap tries to deposit, with an allowance and tokens in place.
    function depositByOutsider(
        uint256 tokenSeed,
        uint256 accountSeed,
        address outsider,
        uint256 amount
    ) external {
        if (outsider == address(SWAP) || outsider == address(0) || outsider == address(ESCROW)) revert Skipped();
        PayoutToken token = tokens[tokenSeed % 2];
        address account = accounts[accountSeed % 3];
        amount = bound(amount, 1, 1e27);
        uint256 before = ESCROW.claimable(address(token), account);
        token.mint(outsider, amount);
        vm.prank(outsider);
        token.approve(address(ESCROW), amount);
        vm.prank(outsider);
        try ESCROW.deposit(address(token), account, amount) {
            ++forbiddenSuccesses;
        } catch {
            if (ESCROW.claimable(address(token), account) != before) ++refusalsWithEffect;
        }
    }

    /// @notice LPVaultSwap deposits without holding the Lock.
    function depositUnlocked(
        uint256 tokenSeed,
        uint256 amount
    ) external {
        PayoutToken token = tokens[tokenSeed % 2];
        amount = bound(amount, 1, 1e27);
        token.mint(address(SWAP), amount);
        try SWAP.depositUnlocked(address(token), accounts[0], amount) {
            ++forbiddenSuccesses;
        } catch {}
    }

    /// @notice A rounding-up or positive-rebase token delivers `extra` more than requested: the credit is the request
    /// and the extra stays as a donation.
    function depositRoundingUp(
        uint256 accountSeed,
        uint256 amount,
        uint256 extra
    ) external {
        PayoutToken token = tokens[0];
        address account = accounts[accountSeed % 3];
        amount = bound(amount, 1, 1e27);
        extra = bound(extra, 1, 1e6);
        uint256 before = ESCROW.claimable(address(token), account);
        token.setBonus(extra);
        token.mint(address(SWAP), amount);
        SWAP.depositUnderLock(address(token), account, amount);
        token.setBonus(0);
        uint256 credit = ESCROW.claimable(address(token), account) - before;
        if (credit != amount) ++wrongPayouts;
        credited[address(token)][account] += credit;
        donated[address(token)] += extra;
        ++deposits;
    }

    /// @notice The token charges the sender of a claim 1 to 100 bps on top of the amount: a claim that would take more
    /// than the credit from the escrow reverts and the credit stays.
    function claimWithSenderFee(
        uint256 tokenSeed,
        uint256 accountSeed,
        uint256 bps
    ) external {
        PayoutToken token = tokens[tokenSeed % 2];
        address account = accounts[accountSeed % 3];
        uint256 credit = ESCROW.claimable(address(token), account);
        bps = bound(bps, 1, 100);
        token.setSenderFeeBps(bps);
        vm.prank(account);
        try ESCROW.claim(address(token), account) returns (uint256 paid) {
            if (paid * bps / 10_000 != 0) ++senderFeeClaimsPaid;
            claimed[address(token)][account] += paid;
            // A fee that rounds to 0 takes nothing extra: the escrow paid exactly the credit.
            burned[address(token)] += paid * bps / 10_000;
            ++claims;
        } catch {
            if (ESCROW.claimable(address(token), account) != credit) ++refusalsWithEffect;
        }
        token.setSenderFeeBps(0);
    }

    /// @notice The issuer burns up to `units` of the escrow's balance (a seizure or a negative rebase).
    function issuerBurn(
        uint256 tokenSeed,
        uint256 units
    ) external {
        PayoutToken token = tokens[tokenSeed % 2];
        units = bound(units, 0, token.balanceOf(address(ESCROW)) / 10);
        token.issuerBurn(address(ESCROW), units);
        burned[address(token)] += units;
    }

    /// @notice Dust sent to the escrow by plain transfer (1 wei to 10^6 wei).
    function donate(
        uint256 tokenSeed,
        uint256 dust
    ) external {
        PayoutToken token = tokens[tokenSeed % 2];
        dust = bound(dust, 1, 1e6);
        token.mint(address(ESCROW), dust);
        donated[address(token)] += dust;
    }
}
