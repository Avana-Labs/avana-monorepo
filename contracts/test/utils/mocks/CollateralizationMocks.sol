// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IntegrationCapabilities} from "../../../src/amm/types/IntegrationCapabilities.sol";
import {PoolKeying} from "../../../src/amm/types/PoolKeying.sol";
import {ILPVaultErrors} from "../../../src/custody/lp-vault/ILPVaultErrors.sol";
import {ILock} from "../../../src/lock/lock/ILock.sol";
import {PledgeCharge} from "../../../src/policy/risk-module/types/PledgeCharge.sol";
import {PledgeCounters} from "../../../src/types/PledgeCounters.sol";
import {PositionShape} from "../../../src/types/PositionShape.sol";
import {ShapeKind} from "../../../src/types/ShapeKind.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Pool token for the Collateralization suites: open mint, an optional sender-side transfer fee (an issuer that
/// switched a fee on, SPEC-BACK-015) and an optional revert on zero-amount transfers (TEST-177).
contract CollPoolToken is ERC20 {
    uint8 private immutable DECIMALS;
    uint256 public feeBps;
    bool public revertOnZero;

    error ZeroTransfer();

    constructor(
        string memory symbol_,
        uint8 decimals_
    ) ERC20(symbol_, symbol_) {
        DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return DECIMALS;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    function setFeeBps(
        uint256 bps
    ) external {
        feeBps = bps;
    }

    function setRevertOnZero(
        bool on
    ) external {
        revertOnZero = on;
    }

    /// @dev Transfer hook (ERC-777 style), off by default: the next transfer between two non-zero addresses first
    /// calls `hookTarget` with `hookData` once and keeps the outcome, standing in for a token that calls back.
    address public hookTarget;
    bytes public hookData;
    bool public hookFired;
    bool public hookSucceeded;
    bytes public hookReturn;

    function armHook(
        address target,
        bytes calldata data
    ) external {
        hookTarget = target;
        hookData = data;
        hookFired = false;
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        if (value == 0 && revertOnZero) revert ZeroTransfer();
        address hook = hookTarget;
        if (hook != address(0) && from != address(0) && to != address(0)) {
            hookTarget = address(0);
            hookFired = true;
            (hookSucceeded, hookReturn) = hook.call(hookData);
        }
        if (from != address(0) && to != address(0) && feeBps != 0) {
            uint256 fee = value * feeBps / 10_000;
            super._update(from, address(0xFEE), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

/// @notice LPVault stand-in implementing the AMM integration calls Collateralization makes, with the custody rules of
/// 2.2 that matter to the ledger: Collateralization-only value moves under the Lock of either member, a position taken
/// only from its owner (never from the LPVault itself), a position returned only to its depositor of record, principal
/// of exactly the removed units paid to the named recipient, fees paid only to the depositor.
/// @dev Principal per removed unit is `rate[i] / RATE_SCALE` raw units of token i, rounded down. The vault holds a
/// float of every pool token and pays from it, so a token's transfer fee reaches the recipient.
contract CollLPVaultMock is ILPVaultErrors {
    uint256 public constant RATE_SCALE = 1e6;

    struct Position {
        address owner;
        address depositor;
        uint256 marketId;
        uint128 units;
        uint256 fees;
    }

    uint32 public immutable INTEGRATION_ID;
    address public immutable COLLATERALIZATION;
    address public immutable LOCK;
    bytes32 public constant AMM_PROTOCOL = keccak256("UNISWAP_V3");
    /// @dev The timelock and MarketRegistry the VaultTokenFactory compares at registration (`setCore`).
    address public TIMELOCK;
    address public MARKET_REGISTRY;

    mapping(uint256 marketId => address[] tokens) internal _tokens;
    mapping(uint256 marketId => address pool) public poolOf;
    uint256[] public rate;
    mapping(bytes32 key => Position) public positions;
    bool public poolLocked;
    bool public fungible;
    uint256 public receiveOverride;
    uint256 public marketOfPositionOverride;
    uint256 public unwindCalls;
    address public lastRecipient;
    /// @dev Checks-effects-interactions probe (REQ-LOCK-017): when set, every position or unit move first staticcalls
    /// `observeTarget` with `observeData` and keeps the result, so a test sees Collateralization's state at the moment
    /// of the interaction.
    address public observeTarget;
    bytes public observeData;
    bytes public observed;
    uint256 public observations;

    constructor(
        uint32 integrationId,
        address collateralization,
        address lock
    ) {
        INTEGRATION_ID = integrationId;
        COLLATERALIZATION = collateralization;
        LOCK = lock;
    }

    // ─── Test controls ───

    function setObserver(
        address target,
        bytes calldata data
    ) external {
        observeTarget = target;
        observeData = data;
    }

    function _observe() internal {
        if (observeTarget == address(0)) return;
        (bool ok, bytes memory ret) = observeTarget.staticcall(observeData);
        require(ok, "observe failed");
        observed = ret;
        ++observations;
    }

    function setCore(
        address timelock,
        address marketRegistry
    ) external {
        TIMELOCK = timelock;
        MARKET_REGISTRY = marketRegistry;
    }

    /// @notice A pool-address keyed tick-range integration, as the factory records it.
    function capabilities() external pure returns (IntegrationCapabilities memory caps) {
        caps.poolKeying = PoolKeying.Address;
        caps.shapeKind = ShapeKind.TickRange;
        caps.hasTwap = true;
    }

    function bind(
        uint256 marketId,
        address pool,
        address[] calldata tokens,
        uint256[] calldata rates
    ) external {
        poolOf[marketId] = pool;
        _tokens[marketId] = tokens;
        rate = rates;
    }

    function mintPosition(
        bytes32 key,
        address owner,
        uint256 marketId,
        uint128 units
    ) external {
        positions[key] = Position(owner, address(0), marketId, units, 0);
    }

    function addUnits(
        bytes32 key,
        uint128 units
    ) external {
        positions[key].units += units;
    }

    function accrueFees(
        bytes32 key,
        uint256 amount
    ) external {
        positions[key].fees += amount;
    }

    function setPoolLocked(
        bool locked
    ) external {
        poolLocked = locked;
    }

    function setFungible(
        bool on
    ) external {
        fungible = on;
    }

    function setReceiveOverride(
        uint256 units
    ) external {
        receiveOverride = units;
    }

    function setMarketOfPositionOverride(
        uint256 marketId
    ) external {
        marketOfPositionOverride = marketId;
    }

    // ─── AMM integration surface ───

    function marketOf(
        uint256 marketId
    ) external view returns (address pool, bytes32 poolId, PositionShape memory shape, address[] memory tokens) {
        tokens = _tokens[marketId];
        if (tokens.length == 0) revert MarketBinding(marketId);
        pool = poolOf[marketId];
        poolId = bytes32(0);
        shape = PositionShape(ShapeKind.TickRange, -50, 50);
    }

    function checkReadSafe(
        uint256
    ) external view {
        if (poolLocked) revert PoolLocked();
    }

    /// @dev ERC-721 receive-callback stand-in, off by default: the next `receivePosition` calls `receiveHookTarget`
    /// with `receiveHookData` once and keeps the outcome.
    address public receiveHookTarget;
    bytes public receiveHookData;
    bool public receiveHookSucceeded;
    bytes public receiveHookReturn;

    function armReceiveHook(
        address target,
        bytes calldata data
    ) external {
        receiveHookTarget = target;
        receiveHookData = data;
    }

    function receivePosition(
        uint256 marketId,
        address owner,
        bytes32 key
    ) external returns (uint128 units) {
        _custodyCaller();
        address hook = receiveHookTarget;
        if (hook != address(0)) {
            receiveHookTarget = address(0);
            (receiveHookSucceeded, receiveHookReturn) = hook.call(receiveHookData);
        }
        if (poolLocked) revert PoolLocked();
        Position storage p = positions[key];
        if (owner == address(this) || p.owner != owner) revert NotTokenOwner();
        if (p.marketId != marketId) revert RangeMismatch(-1, 1);
        p.owner = address(this);
        p.depositor = owner;
        units = receiveOverride != 0 ? uint128(receiveOverride) : p.units;
        if (units == 0) revert ZeroUnits();
    }

    function returnPosition(
        bytes32 key
    ) external returns (address depositor) {
        _custodyCaller();
        _observe();
        Position storage p = positions[key];
        depositor = p.depositor;
        if (depositor == address(0)) revert NotInCustody();
        p.owner = depositor;
        p.depositor = address(0);
    }

    function topUpPosition(
        bytes32 key,
        address owner,
        bytes calldata topUp
    ) external returns (uint128 unitsAdded) {
        _custodyCaller();
        if (!fungible) revert TopUpNotSupported();
        Position storage p = positions[key];
        if (owner != p.depositor) revert NotDepositor();
        unitsAdded = abi.decode(topUp, (uint128));
        p.units += unitsAdded;
    }

    function unwind(
        bytes32 key,
        uint128 units,
        uint256[] calldata minAmounts,
        address recipient
    ) external returns (uint256[] memory amounts) {
        _custodyCaller();
        _observe();
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        amounts = _remove(key, units, minAmounts, recipient);
    }

    function releaseToDepositor(
        bytes32 key,
        uint128 units,
        uint256[] calldata minAmounts
    ) external returns (uint256[] memory amounts) {
        _custodyCaller();
        _observe();
        amounts = _remove(key, units, minAmounts, positions[key].depositor);
    }

    function collectFees(
        bytes32 key,
        address depositor
    ) external returns (uint256[] memory amounts) {
        _custodyCaller();
        Position storage p = positions[key];
        if (p.depositor == address(0)) revert NotInCustody();
        if (depositor != p.depositor) revert NotDepositor();
        address[] storage tokens = _tokens[p.marketId];
        amounts = new uint256[](tokens.length);
        uint256 fees = p.fees;
        p.fees = 0;
        for (uint256 i = 0; i < tokens.length; ++i) {
            amounts[i] = fees;
            if (fees != 0) ERC20(tokens[i]).transfer(depositor, fees);
        }
    }

    function unitsOf(
        bytes32 key
    ) external view returns (uint128) {
        Position storage p = positions[key];
        if (p.depositor == address(0)) revert NotInCustody();
        return p.units;
    }

    function marketOfPosition(
        bytes32 key
    ) external view returns (uint256) {
        if (marketOfPositionOverride != 0) return marketOfPositionOverride;
        Position storage p = positions[key];
        return p.depositor == address(0) ? 0 : p.marketId;
    }

    function depositorOf(
        bytes32 key
    ) external view returns (address) {
        return positions[key].depositor;
    }

    function ownerOf(
        bytes32 key
    ) external view returns (address) {
        return positions[key].owner;
    }

    // ─── Internals ───

    function _custodyCaller() internal view {
        if (msg.sender != COLLATERALIZATION) revert NotCollateralization();
        address holder = ILock(LOCK).holder();
        if (holder != ILock(LOCK).AAVE_ADAPTER() && holder != ILock(LOCK).LP_VAULT_SWAP()) revert LockNotHeld();
    }

    function _remove(
        bytes32 key,
        uint128 units,
        uint256[] calldata minAmounts,
        address recipient
    ) internal returns (uint256[] memory amounts) {
        if (poolLocked) revert PoolLocked();
        Position storage p = positions[key];
        if (p.depositor == address(0)) revert NotInCustody();
        p.units -= units;
        address[] storage tokens = _tokens[p.marketId];
        if (minAmounts.length != tokens.length) revert LengthMismatch(tokens.length, minAmounts.length);
        amounts = new uint256[](tokens.length);
        bool any = false;
        for (uint256 i = 0; i < tokens.length; ++i) {
            amounts[i] = uint256(units) * rate[i] / RATE_SCALE;
            if (amounts[i] < minAmounts[i]) revert BelowMinimum(i, amounts[i], minAmounts[i]);
            if (amounts[i] != 0) any = true;
        }
        ++unwindCalls;
        lastRecipient = recipient;
        if (!any) return amounts;
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (amounts[i] != 0) ERC20(tokens[i]).transfer(recipient, amounts[i]);
        }
    }
}

/// @notice RiskModule stand-in: `checkPledge` charges `ceil(units * price8 / 10^6)` (a 6-decimal vault token), books
/// `sliceUsd` of it in the slice and the matching rescue units, or returns an exact override, or reverts with
/// `Refused(units)`.
contract CollRiskModuleMock {
    error Refused(uint128 units);
    /// @dev Stands in for the RiskModule's `NotRescueTopUp` when `enforceRescue` is on and the pledge must be a rescue.
    error RescueRequired();

    bool public enforceRescue;

    function setEnforceRescue(
        bool on
    ) external {
        enforceRescue = on;
    }

    uint256 public price8 = 2e8;
    uint256 public sliceUsd;
    bool public rescue;
    bool public refuse;
    bool public useOverride;
    PledgeCharge internal _override;

    function setPrice(
        uint256 p
    ) external {
        price8 = p;
    }

    function setSlice(
        uint256 slice
    ) external {
        sliceUsd = slice;
    }

    function setRescue(
        bool on
    ) external {
        rescue = on;
    }

    function setRefuse(
        bool on
    ) external {
        refuse = on;
    }

    function setOverride(
        PledgeCharge calldata charge
    ) external {
        _override = charge;
        useOverride = true;
    }

    function clearOverride() external {
        useOverride = false;
    }

    function checkPledge(
        address,
        address,
        uint256,
        uint32,
        bytes32,
        uint128 units,
        PledgeCounters calldata,
        bool requireRescue
    ) external view returns (PledgeCharge memory charge) {
        if (refuse) revert Refused(units);
        if (enforceRescue && requireRescue) revert RescueRequired();
        if (useOverride) return _override;
        charge.usdCharge = (uint256(units) * price8 + 1e6 - 1) / 1e6;
        charge.sliceUsd = sliceUsd > charge.usdCharge ? charge.usdCharge : sliceUsd;
        charge.rescue = rescue;
        if (rescue) {
            charge.rescueUnits = units;
        } else if (charge.sliceUsd != 0) {
            charge.rescueUnits = uint128((uint256(units) * charge.sliceUsd + charge.usdCharge - 1) / charge.usdCharge);
        }
    }
}

/// @notice LPOracle stand-in: counts `poke()` calls, or reverts.
contract CollOracleMock {
    error PokeFailed();

    uint256 public pokes;
    bool public fail;

    function setFail(
        bool on
    ) external {
        fail = on;
    }

    function poke() external returns (uint8) {
        if (fail) revert PokeFailed();
        ++pokes;
        return 0;
    }
}
