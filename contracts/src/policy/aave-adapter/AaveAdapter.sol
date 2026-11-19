// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVault} from "../../custody/lp-vault/ILPVault.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {IVaultToken} from "../../vault-token/IVaultToken.sol";
import {IRiskModule} from "../risk-module/IRiskModule.sol";
import {AaveAdapterStorage} from "./AaveAdapterStorage.sol";
import {AccountProxy} from "./AccountProxy.sol";
import {IAaveAdapter} from "./IAaveAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title AaveAdapter
/// @notice The only door for users: pledge with automatic routing, add liquidity, withdraw whole or part, borrow,
/// repay and collect fees. Each wallet holds one `AccountProxy` per market, and this adapter is its Aave position
/// manager.
/// @dev Not upgradeable, no admin. Needs the AccessManager roles for the LPVault's user calls and the vault tokens'
/// `mint`, `burn` and `addValidProxy`, and the Spokes must have it active as a position manager. It is the vault
/// tokens' only valid proxy: tokens are minted to it and supplied for the account in the same call, and Aave sends
/// withdrawn tokens back to it to burn. `multicall` batches calls with the caller kept as `msg.sender`.
contract AaveAdapter is IAaveAdapter, AaveAdapterStorage, ReentrancyGuardTransient, Multicall {
    using SafeERC20 for IERC20;

    /// @inheritdoc IAaveAdapter
    address public immutable override RISK_MODULE;
    /// @inheritdoc IAaveAdapter
    address public immutable override LP_VAULT;

    /// @dev Reads the LPVault from the RiskModule. Reverts `InvalidAddress` for a zero RiskModule.
    constructor(
        address riskModule
    ) {
        if (riskModule == address(0)) revert InvalidAddress(riskModule);
        RISK_MODULE = riskModule;
        LP_VAULT = IRiskModule(riskModule).LP_VAULT();
        if (LP_VAULT == address(0)) revert InvalidAddress(LP_VAULT);
    }

    // ─── Collateral ───

    /// @inheritdoc IAaveAdapter
    function pledge(
        bytes32 positionKey
    ) external override nonReentrant returns (uint256 marketId, uint128 credit) {
        (bytes32 pool, int24 tickLower, int24 tickUpper,) = ILPVault(LP_VAULT).positionInfo(positionKey);
        marketId = IRiskModule(RISK_MODULE).routeOf(pool, tickLower, tickUpper);
        if (marketId == 0) revert NoMarketFits(pool, tickLower, tickUpper);
        IRiskModule.Market memory m = IRiskModule(RISK_MODULE).getMarket(marketId);
        if (!m.active) revert MarketNotActive(marketId);
        (address account, bool created) = _accountFor(msg.sender, marketId, m.spoke);
        credit = ILPVault(LP_VAULT).pledge(msg.sender, account, marketId, positionKey);
        _supply(m, account, credit);
        if (created) IAaveV4Spoke(m.spoke).setUsingAsCollateral(m.reserveId, true, account);
        emit Pledged(msg.sender, marketId, positionKey, credit);
    }

    /// @inheritdoc IAaveAdapter
    function addLiquidity(
        bytes32 positionKey,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) external override nonReentrant returns (uint128 liquidity, uint128 credit, uint256 amount0, uint256 amount1) {
        (address account, uint256 marketId) = _ownedPosition(positionKey);
        (liquidity, credit, amount0, amount1) = ILPVault(LP_VAULT)
            .addLiquidity(positionKey, msg.sender, amount0Desired, amount1Desired, amount0Min, amount1Min);
        _supply(IRiskModule(RISK_MODULE).getMarket(marketId), account, credit);
        emit LiquidityAdded(msg.sender, positionKey, liquidity, credit);
    }

    /// @inheritdoc IAaveAdapter
    function withdraw(
        bytes32 positionKey,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) external override nonReentrant returns (uint256 burned) {
        if (recipient == address(0)) revert InvalidAddress(recipient);
        (address account, uint256 marketId) = _ownedPosition(positionKey);
        if (liquidity == 0 || liquidity >= ILPVault(LP_VAULT).getPosition(positionKey).liquidity) {
            liquidity = 0;
            ILPVault(LP_VAULT).release(positionKey, recipient);
        } else {
            ILPVault(LP_VAULT).removeLiquidity(positionKey, liquidity, amount0Min, amount1Min, recipient);
        }
        burned = _trimSupply(IRiskModule(RISK_MODULE).getMarket(marketId), account, marketId);
        emit Withdrawn(msg.sender, positionKey, recipient, liquidity, burned);
    }

    /// @inheritdoc IAaveAdapter
    function collectFees(
        uint256 marketId,
        bytes32[] calldata positionKeys
    ) external override nonReentrant returns (uint256[] memory amounts0, uint256[] memory amounts1) {
        return ILPVault(LP_VAULT).collectFees(_existing(msg.sender, marketId), positionKeys, msg.sender);
    }

    // ─── Debt ───

    /// @inheritdoc IAaveAdapter
    function borrow(
        uint256 marketId,
        uint256 reserveId,
        uint256 amount,
        address recipient
    ) external override nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (recipient == address(0) || recipient == address(this)) revert InvalidAddress(recipient);
        address account = _existing(msg.sender, marketId);
        address spoke = IRiskModule(RISK_MODULE).getMarket(marketId).spoke;
        IRiskModule(RISK_MODULE).checkBorrow(spoke, reserveId);
        (, uint256 drawn) = IAaveV4Spoke(spoke).borrow(reserveId, amount, account);
        IERC20(IAaveV4Spoke(spoke).getReserve(reserveId).underlying).safeTransfer(recipient, drawn);
        emit Borrowed(msg.sender, marketId, reserveId, drawn, recipient);
    }

    /// @inheritdoc IAaveAdapter
    function repay(
        uint256 marketId,
        uint256 reserveId,
        uint256 amount,
        address wallet
    ) external override nonReentrant returns (uint256 repaid) {
        if (amount == 0) revert InvalidAmount();
        address account = _existing(wallet, marketId);
        IAaveV4Spoke spoke = IAaveV4Spoke(IRiskModule(RISK_MODULE).getMarket(marketId).spoke);
        uint256 debt = spoke.getUserTotalDebt(reserveId, account);
        if (debt == 0) revert NoDebt(account, reserveId);
        if (amount > debt) amount = debt;
        IERC20 asset = IERC20(spoke.getReserve(reserveId).underlying);
        asset.safeTransferFrom(msg.sender, address(this), amount);
        asset.forceApprove(address(spoke), amount);
        (, repaid) = spoke.repay(reserveId, amount, account);
        asset.forceApprove(address(spoke), 0);
        if (repaid < amount) asset.safeTransfer(msg.sender, amount - repaid);
        emit Repaid(wallet, marketId, reserveId, repaid, msg.sender);
    }

    // ─── Views ───

    /// @inheritdoc IAaveAdapter
    function accountOf(
        address wallet,
        uint256 marketId
    ) external view override returns (address) {
        return _accounts[wallet][marketId];
    }

    /// @inheritdoc IAaveAdapter
    function predictAccount(
        address wallet,
        uint256 marketId
    ) external view override returns (address) {
        address deployed = _accounts[wallet][marketId];
        if (deployed != address(0)) return deployed;
        bytes32 codeHash =
            keccak256(_creationCode(IRiskModule(RISK_MODULE).getMarket(marketId).spoke, wallet, marketId));
        bytes32 h = keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt(wallet, marketId), codeHash));
        return address(uint160(uint256(h)));
    }

    // ─── Internals ───

    /// @dev The wallet's account in the market, deployed on first use.
    function _accountFor(
        address wallet,
        uint256 marketId,
        address spoke
    ) internal returns (address account, bool created) {
        account = _accounts[wallet][marketId];
        if (account != address(0)) return (account, false);
        account = address(new AccountProxy{salt: _salt(wallet, marketId)}(spoke, wallet, marketId));
        _accounts[wallet][marketId] = account;
        emit AccountCreated(wallet, marketId, account);
        return (account, true);
    }

    /// @dev The wallet's deployed account; reverts `NoAccount` when none.
    function _existing(
        address wallet,
        uint256 marketId
    ) internal view returns (address account) {
        account = _accounts[wallet][marketId];
        if (account == address(0)) revert NoAccount(wallet, marketId);
    }

    /// @dev The caller's account and market of a pledged position; reverts `NotPositionOwner` otherwise.
    function _ownedPosition(
        bytes32 positionKey
    ) internal view returns (address account, uint256 marketId) {
        ILPVault.Position memory p = ILPVault(LP_VAULT).getPosition(positionKey);
        account = p.account;
        marketId = p.marketId;
        if (account == address(0) || _accounts[msg.sender][marketId] != account) {
            revert NotPositionOwner(positionKey, msg.sender);
        }
    }

    /// @dev Mints `credit` vault tokens to this adapter and supplies them to Aave for `account`.
    function _supply(
        IRiskModule.Market memory m,
        address account,
        uint256 credit
    ) internal {
        if (credit == 0) return;
        IVaultToken token = IVaultToken(m.vaultToken);
        if (!token.isValidProxy(address(this))) token.addValidProxy(address(this));
        token.mint(address(this), credit);
        IERC20(address(token)).forceApprove(m.spoke, credit);
        IAaveV4Spoke(m.spoke).supply(m.reserveId, credit, account);
    }

    /// @dev Withdraws the account's supply above its remaining credit in the market and burns it, so supply never
    /// exceeds credit. Aave checks the health factor on the withdraw. A supply already at or below the remaining
    /// credit is left alone: the remaining NFTs still back every supplied token.
    function _trimSupply(
        IRiskModule.Market memory m,
        address account,
        uint256 marketId
    ) internal returns (uint256 burned) {
        uint256 remaining = ILPVault(LP_VAULT).accountCredit(account, marketId);
        uint256 supplied = IAaveV4Spoke(m.spoke).getUserSuppliedAssets(m.reserveId, account);
        if (supplied <= remaining) return 0;
        (, burned) = IAaveV4Spoke(m.spoke).withdraw(m.reserveId, supplied - remaining, account);
        IVaultToken(m.vaultToken).burn(address(this), burned);
    }

    /// @dev The CREATE2 salt of a wallet's account in a market.
    function _salt(
        address wallet,
        uint256 marketId
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(wallet, marketId));
    }

    /// @dev The account's creation code with its constructor arguments.
    function _creationCode(
        address spoke,
        address wallet,
        uint256 marketId
    ) internal pure returns (bytes memory) {
        return bytes.concat(type(AccountProxy).creationCode, abi.encode(spoke, wallet, marketId));
    }
}
