// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV3ACLManager} from "../../../src/interfaces/external/aave/IAaveV3ACLManager.sol";
import {IAaveV3FlashLoanReceiver} from "../../../src/interfaces/external/aave/IAaveV3FlashLoanReceiver.sol";
import {IAaveV3Pool} from "../../../src/interfaces/external/aave/IAaveV3Pool.sol";
import {IAaveV3PoolAddressesProvider} from "../../../src/interfaces/external/aave/IAaveV3PoolAddressesProvider.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title MockAaveV3ACLManager
/// @notice The `FLASH_BORROWER` role of the Aave V3 ACLManager: anyone may grant or revoke in tests.
contract MockAaveV3ACLManager is IAaveV3ACLManager {
    mapping(address borrower => bool isBorrower) private _flashBorrowers;

    function addFlashBorrower(
        address borrower
    ) external override {
        _flashBorrowers[borrower] = true;
    }

    function removeFlashBorrower(
        address borrower
    ) external {
        _flashBorrowers[borrower] = false;
    }

    function isFlashBorrower(
        address borrower
    ) external view override returns (bool) {
        return _flashBorrowers[borrower];
    }
}

/// @title MockAaveV3AddressesProvider
/// @notice PoolAddressesProvider that names the ACLManager; the ACLManager can be replaced, as Aave governance can.
contract MockAaveV3AddressesProvider is IAaveV3PoolAddressesProvider {
    address public aclManager;

    constructor(
        address aclManager_
    ) {
        aclManager = aclManager_;
    }

    function setACLManager(
        address aclManager_
    ) external {
        aclManager = aclManager_;
    }

    function getACLManager() external view override returns (address) {
        return aclManager;
    }
}

/// @title MockAToken
/// @notice Holds a reserve's idle underlying; only its Pool moves it out. `totalSupply` is the supply its Pool recorded
/// (`recordSupply`), which the Pool's flash-loan validation reads.
contract MockAToken {
    using SafeERC20 for IERC20;

    address public immutable POOL;
    address public immutable UNDERLYING;
    uint256 public totalSupply;

    constructor(
        address pool,
        address underlying
    ) {
        POOL = pool;
        UNDERLYING = underlying;
    }

    function transferUnderlyingTo(
        address to,
        uint256 amount
    ) external {
        require(msg.sender == POOL, "only pool");
        // Aave transfers zero amounts too; a token that reverts on zero makes a zero loan revert here.
        IERC20(UNDERLYING).safeTransfer(to, amount);
    }

    function addSupply(
        uint256 amount
    ) external {
        require(msg.sender == POOL, "only pool");
        totalSupply += amount;
    }
}

/// @title MockAaveV3Pool
/// @notice The Aave V3.4 Pool `flashLoan` path as `FlashLoanLogic.executeFlashLoan` and `ValidationLogic` run it:
/// equal array lengths, per asset an active, unpaused, flash-enabled reserve (a frozen reserve still lends) whose
/// aToken `totalSupply() >= amount`, the premium 0 for an ACLManager `FLASH_BORROWER` and otherwise
/// `percentMul(amount, FLASHLOAN_PREMIUM_TOTAL) = ⌊(amount × FLASHLOAN_PREMIUM_TOTAL + 5,000) / 10⁴⌋` (half-up, never
/// above the source's ceiling quote), the virtual underlying balance lowered by `amount` with checked arithmetic
/// (V3.1+ virtual accounting: a direct transfer to the aToken is not lendable), the underlying sent from the aToken
/// (zero amounts included), `executeOperation(assets, amounts, premiums, msg.sender, params)` required to return true,
/// then `amount + premium` pulled with `transferFrom` into the aToken and added back to the virtual balance for each
/// mode-0 leg. No reentrancy lock, as on V3.
/// @dev Test switches (all off after deployment) turn the Pool hostile: a callback with a reshaped argument
/// (`callbackShape`), another initiator, a raised premium, no callback, a second callback, a short pull.
contract MockAaveV3Pool is IAaveV3Pool {
    using SafeERC20 for IERC20;

    uint256 internal constant ACTIVE_BIT = 1 << 56;
    uint256 internal constant FROZEN_BIT = 1 << 57;
    uint256 internal constant PAUSED_BIT = 1 << 60;
    uint256 internal constant FLASHLOAN_ENABLED_BIT = 1 << 63;

    /// @notice Callback argument reshaping: 0 none, 1 two assets, 2 two amounts, 3 two premiums, 4 another asset,
    /// 5 another amount, 6 other params.
    uint8 public callbackShape;
    address public initiatorOverride;
    bool public premiumOverridden;
    uint256 public premiumOverride;
    bool public skipCallback;
    bool public callbackTwice;
    uint256 public pullShortBy;
    uint256 public flashLoanCalls;

    uint128 public override FLASHLOAN_PREMIUM_TOTAL;
    address public override ADDRESSES_PROVIDER;
    mapping(address asset => uint256 data) internal _configuration;
    mapping(address asset => address aToken) internal _aTokens;
    mapping(address asset => uint128 balance) internal _virtualBalance;

    constructor(
        address provider,
        uint128 premiumTotal
    ) {
        ADDRESSES_PROVIDER = provider;
        FLASHLOAN_PREMIUM_TOTAL = premiumTotal;
    }

    // ─── Configuration ───

    function listReserve(
        address asset
    ) external returns (address aToken) {
        aToken = address(new MockAToken(address(this), asset));
        _aTokens[asset] = aToken;
        _configuration[asset] = ACTIVE_BIT | FLASHLOAN_ENABLED_BIT;
    }

    /// @notice Records `amount` supplied to `asset`'s reserve: the virtual balance and the aToken supply rise; the
    /// caller mints the underlying to the aToken itself.
    function recordSupply(
        address asset,
        uint256 amount
    ) external {
        _virtualBalance[asset] += uint128(amount);
        MockAToken(_aTokens[asset]).addSupply(amount);
    }

    function setVirtualBalance(
        address asset,
        uint128 balance
    ) external {
        _virtualBalance[asset] = balance;
    }

    function getVirtualUnderlyingBalance(
        address asset
    ) external view override returns (uint128) {
        return _virtualBalance[asset];
    }

    function setConfiguration(
        address asset,
        uint256 data
    ) external {
        _configuration[asset] = data;
    }

    function setFlags(
        address asset,
        bool active,
        bool frozen,
        bool paused,
        bool flashEnabled
    ) external {
        uint256 data = _configuration[asset] & ~(ACTIVE_BIT | FROZEN_BIT | PAUSED_BIT | FLASHLOAN_ENABLED_BIT);
        if (active) data |= ACTIVE_BIT;
        if (frozen) data |= FROZEN_BIT;
        if (paused) data |= PAUSED_BIT;
        if (flashEnabled) data |= FLASHLOAN_ENABLED_BIT;
        _configuration[asset] = data;
    }

    function setReserveAToken(
        address asset,
        address aToken
    ) external {
        _aTokens[asset] = aToken;
    }

    function setPremiumTotal(
        uint128 premiumTotal
    ) external {
        FLASHLOAN_PREMIUM_TOTAL = premiumTotal;
    }

    function setCallbackShape(
        uint8 shape
    ) external {
        callbackShape = shape;
    }

    function setInitiatorOverride(
        address initiator
    ) external {
        initiatorOverride = initiator;
    }

    function setPremiumOverride(
        uint256 premium
    ) external {
        premiumOverridden = true;
        premiumOverride = premium;
    }

    function setSkipCallback(
        bool on
    ) external {
        skipCallback = on;
    }

    function setCallbackTwice(
        bool on
    ) external {
        callbackTwice = on;
    }

    function setPullShortBy(
        uint256 units
    ) external {
        pullShortBy = units;
    }

    // ─── IAaveV3Pool ───

    function getConfiguration(
        address asset
    ) external view override returns (uint256) {
        return _configuration[asset];
    }

    function getReserveAToken(
        address asset
    ) external view override returns (address) {
        return _aTokens[asset];
    }

    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata interestRateModes,
        address, /* onBehalfOf */
        bytes calldata params,
        uint16 /* referralCode */
    ) external override {
        require(assets.length == amounts.length && assets.length == interestRateModes.length, "inconsistent params");
        ++flashLoanCalls;
        uint256[] memory premiums = _lendAll(receiverAddress, assets, amounts, interestRateModes);
        if (!skipCallback) {
            _callback(receiverAddress, assets, amounts, premiums, params);
            if (callbackTwice) _callback(receiverAddress, assets, amounts, premiums, params);
        }
        for (uint256 i = 0; i < assets.length; ++i) {
            _pull(receiverAddress, assets[i], amounts[i] + premiums[i] - pullShortBy);
            _virtualBalance[assets[i]] += uint128(amounts[i] + premiums[i]);
            // The premium accrues to the treasury as aToken supply (V3.4: the whole premium is the protocol's).
            MockAToken(_aTokens[assets[i]]).addSupply(premiums[i]);
        }
    }

    function _lendAll(
        address receiver,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes
    ) internal returns (uint256[] memory premiums) {
        bool authorized = IAaveV3ACLManager(IAaveV3PoolAddressesProvider(ADDRESSES_PROVIDER).getACLManager())
            .isFlashBorrower(msg.sender);
        premiums = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; ++i) {
            uint256 data = _configuration[assets[i]];
            require(data & ACTIVE_BIT != 0, "reserve inactive");
            require(data & PAUSED_BIT == 0, "reserve paused");
            require(data & FLASHLOAN_ENABLED_BIT != 0, "flashloan disabled");
            require(modes[i] == 0, "mode not supported by the mock");
            require(MockAToken(_aTokens[assets[i]]).totalSupply() >= amounts[i], "invalid amount");
            // V3.4 percentMul: half-up.
            premiums[i] = authorized ? 0 : (amounts[i] * FLASHLOAN_PREMIUM_TOTAL + 5000) / 1e4;
            _virtualBalance[assets[i]] -= uint128(amounts[i]);
            MockAToken(_aTokens[assets[i]]).transferUnderlyingTo(receiver, amounts[i]);
        }
        if (premiumOverridden) premiums[0] = premiumOverride;
    }

    function _pull(
        address receiver,
        address asset,
        uint256 amount
    ) internal {
        IERC20(asset).safeTransferFrom(receiver, _aTokens[asset], amount);
    }

    function _callback(
        address receiver,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] memory premiums,
        bytes calldata params
    ) internal {
        address[] memory a = assets;
        uint256[] memory m = amounts;
        uint256[] memory p = premiums;
        bytes memory data = params;
        uint8 shape = callbackShape;
        if (shape == 1) a = _two(assets[0]);
        if (shape == 2) m = _twoAmounts(amounts[0]);
        if (shape == 3) p = _twoAmounts(premiums[0]);
        if (shape == 4) a[0] = address(uint160(assets[0]) + 1);
        if (shape == 5) m[0] = amounts[0] + 1;
        if (shape == 6) data = abi.encodePacked(params, uint8(1));
        address initiator = initiatorOverride == address(0) ? msg.sender : initiatorOverride;
        require(IAaveV3FlashLoanReceiver(receiver).executeOperation(a, m, p, initiator, data), "invalid return");
    }

    function _two(
        address x
    ) internal pure returns (address[] memory list) {
        list = new address[](2);
        (list[0], list[1]) = (x, x);
    }

    function _twoAmounts(
        uint256 x
    ) internal pure returns (uint256[] memory list) {
        list = new uint256[](2);
        (list[0], list[1]) = (x, x);
    }
}
