// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {AdapterTestHub, AdapterTestRiskModule, AdapterTestSpoke} from "./AaveAdapterTestMocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The adapter's RiskModule stand-in plus what the LiquidationModule reads: its own address, the fee share and
/// the fee recipient.
contract LiquidationTestRiskModule is AdapterTestRiskModule {
    address internal _module;
    uint256 public feeShareBps;
    address public feeRecipient;

    constructor(
        address lpVault
    ) AdapterTestRiskModule(lpVault) {}

    function setLiquidationModule(
        address module
    ) external {
        _module = module;
    }

    /// @dev Until one is set, the caller: a module being constructed finds itself named.
    function LIQUIDATION_MODULE() external view returns (address) {
        return _module == address(0) ? msg.sender : _module;
    }

    function setFee(
        uint256 shareBps,
        address recipient
    ) external {
        (feeShareBps, feeRecipient) = (shareBps, recipient);
    }
}

/// @notice The adapter's small Spoke plus Aave's liquidation: below health factor 1 the caller repays up to
/// `debtToCover` (at most `closeBps` of the debt, like Aave's sizing toward the target), and receives
/// `repaid · bonusBps / 10,000 / price` collateral units from the Hub. Debt left with no collateral becomes a deficit.
contract LiquidationTestSpoke is AdapterTestSpoke {
    error Healthy();

    uint256 public bonusBps = 10_500;
    uint256 public closeBps = 10_000;
    mapping(uint256 reserveId => uint256 amount) public deficit;

    constructor(
        AdapterTestHub hub
    ) AdapterTestSpoke(hub) {}

    function setBonus(
        uint256 bps
    ) external {
        bonusBps = bps;
    }

    function setClose(
        uint256 bps
    ) external {
        closeBps = bps;
    }

    function setCf(
        uint256 reserveId,
        uint256 cf
    ) external {
        cfBps[reserveId] = cf;
    }

    function healthFactor(
        address user
    ) public view returns (uint256) {
        (uint256 power, uint256 owed) = headroom(user);
        return owed == 0 ? type(uint256).max : power * 1e18 / owed;
    }

    function getLiquidationBonus(
        uint256,
        address,
        uint256
    ) external view returns (uint256) {
        return bonusBps;
    }

    function liquidationCall(
        uint256 collateralReserveId,
        uint256 debtReserveId,
        address user,
        uint256 debtToCover,
        bool
    ) external {
        if (healthFactor(user) >= 1e18) revert Healthy();
        uint256 owed = debt[user][debtReserveId];
        uint256 maxClose = owed * closeBps / 10_000;
        uint256 repaid = debtToCover < maxClose ? debtToCover : maxClose;
        uint256 price = collateralPrice[collateralReserveId];
        uint256 seized = repaid * bonusBps / 10_000 / price;
        uint256 have = supplied[user][collateralReserveId];
        if (seized > have) {
            seized = have;
            repaid = seized * price * 10_000 / bonusBps;
        }
        IERC20(underlyingOf[debtReserveId]).transferFrom(msg.sender, address(HUB), repaid);
        debt[user][debtReserveId] = owed - repaid;
        supplied[user][collateralReserveId] = have - seized;
        if (seized != 0) HUB.pay(underlyingOf[collateralReserveId], msg.sender, seized);
        if (have == seized && owed > repaid) {
            deficit[debtReserveId] += owed - repaid;
            debt[user][debtReserveId] = 0;
        }
    }
}
