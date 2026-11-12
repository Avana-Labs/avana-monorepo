// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationViews} from "../../../src/custody/collateralization/ICollateralizationViews.sol";
import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IAaveAdapter} from "../../../src/policy/aave-adapter/IAaveAdapter.sol";
import {BreakerReasons} from "../../../src/policy/market-registry/types/Breaker.sol";
import {MarketStatus} from "../../../src/policy/market-registry/types/MarketStatus.sol";
import {PositionRef} from "../../../src/types/PositionRef.sol";
import {PriceState} from "../../../src/types/PriceState.sol";
import {AdapterRegistryMock} from "../../utils/mocks/AaveAdapterMocks.sol";
import {CollLPVaultMock, CollPoolToken} from "../../utils/mocks/CollateralizationMocks.sol";
import {RiskDebtOracleMock, RiskLPOracleMock} from "../../utils/mocks/RiskModuleMocks.sol";
import {Test} from "forge-std/Test.sol";

interface IRiskHandlerConfigurator {
    function updateFrozen(
        address spoke,
        uint256 reserveId,
        bool frozen
    ) external;
    function updateReceiveSharesEnabled(
        address spoke,
        uint256 reserveId,
        bool receiveSharesEnabled
    ) external;
}

/// @notice The contracts and parameters the risk handler drives.
struct RiskWorld {
    IAaveAdapter adapter;
    ICollateralizationViews coll;
    AdapterRegistryMock registry;
    RiskLPOracleMock lpOracle;
    RiskDebtOracleMock usdcOracle;
    CollLPVaultMock lpVault;
    IAaveV4Spoke spoke;
    address configurator;
    address aaveDao;
    uint256 market;
    uint256 vtReserve;
    CollPoolToken gho;
    uint256 ghoReserve;
    uint32 integrationId;
    address usdc;
    address usdt;
    address feedUsdc;
    address feedUsdt;
    uint32 feedAge;
}

/// @title AaveAdapterRiskHandler
/// @notice Random changes of everything the reviewed RiskModule reads (the market's price state, its feed ages, the
/// USDC DebtOracle, a latched breaker, `Offboarding`, an Aave freeze of the vault-token reserve, a drift the DAO
/// introduces), interleaved with borrows, withdrawals that leave debt and exits through the Adapter. The handler keeps
/// its own copy of each condition; a borrow or a withdrawal with debt that completes while a condition refusing it
/// holds is counted in `uncheckedSuccesses`, and an exit that reverts in `exitFailures`.
contract AaveAdapterRiskHandler is Test {
    RiskWorld internal w;
    address[3] internal wallets;

    PriceState public priceState = PriceState.Live;
    bool public priceBorrowAllowed = true;
    uint64 public reportedAt;
    uint64 public debtServedAt;
    bool public debtLive = true;
    bool public breakerLatched;
    bool public offboarding;
    bool public reserveFrozen;
    bool public drift;

    mapping(address => bytes32[]) internal keys;
    uint256 internal nonce;

    uint256 public uncheckedSuccesses;
    uint256 public exitFailures;
    uint256 public borrowsDone;
    uint256 public withdrawalsWithDebtDone;
    uint256 public exitsDone;
    bytes public lastError;

    constructor(
        RiskWorld memory world,
        address[3] memory wallets_
    ) {
        w = world;
        wallets = wallets_;
        reportedAt = uint64(block.timestamp);
        debtServedAt = uint64(block.timestamp);
    }

    function track(
        address wallet,
        bytes32 key
    ) external {
        keys[wallet].push(key);
    }

    // ─── Conditions ───

    function setPrice(
        uint8 seed
    ) external {
        priceState = PriceState(seed % 4);
        priceBorrowAllowed = priceState == PriceState.Live && seed % 7 != 0;
        w.lpOracle.setState(priceState, 0, priceBorrowAllowed);
    }

    function report(
        uint32 ageSeed
    ) external {
        uint256 age = bound(ageSeed, 0, 2 * uint256(w.feedAge));
        reportedAt = uint64(block.timestamp - age);
        address[] memory toks = new address[](2);
        (toks[0], toks[1]) = (w.usdc, w.usdt);
        address[] memory feeds = new address[](2);
        (feeds[0], feeds[1]) = (w.feedUsdc, w.feedUsdt);
        uint64[] memory ats = new uint64[](2);
        (ats[0], ats[1]) = (reportedAt, reportedAt);
        uint256[] memory quotes = new uint256[](2);
        (quotes[0], quotes[1]) = (1e8, 1e8);
        w.lpOracle.setTokens(toks, feeds, ats, quotes, new uint32[](2));
    }

    function debtReport(
        uint32 ageSeed,
        bool live
    ) external {
        uint256 age = bound(ageSeed, 0, 200_000);
        debtServedAt = uint64(block.timestamp - age);
        debtLive = live;
        w.usdcOracle.setReport(live ? PriceState.Live : PriceState.Expired, debtServedAt, true);
    }

    function setBreaker(
        bool on
    ) external {
        breakerLatched = on;
        w.registry.setLatched(bytes32(w.market), on ? BreakerReasons.MANUAL : 0, 0);
    }

    function setOffboarding(
        bool on
    ) external {
        offboarding = on;
        w.registry.setMarketStatus(w.market, on ? MarketStatus.Offboarding : MarketStatus.Active);
    }

    function setReserveFrozen(
        bool on
    ) external {
        reserveFrozen = on;
        vm.prank(w.aaveDao);
        IRiskHandlerConfigurator(w.configurator).updateFrozen(address(w.spoke), w.vtReserve, on);
    }

    function setDrift(
        bool on
    ) external {
        drift = on;
        vm.prank(w.aaveDao);
        IRiskHandlerConfigurator(w.configurator).updateReceiveSharesEnabled(address(w.spoke), w.vtReserve, on);
    }

    function warp(
        uint32 secs
    ) external {
        vm.warp(block.timestamp + bound(secs, 0, 2 days));
    }

    // ─── Risk-increasing actions ───

    function borrow(
        uint8 actorSeed,
        uint256 amount
    ) external {
        address wallet = wallets[actorSeed % 3];
        address proxy = w.adapter.proxyOf(wallet, w.market);
        amount = bound(amount, 1e18, 3000e18);
        bool clean = _withDebtClean() && !offboarding && !reserveFrozen;
        uint256 n = w.adapter.borrowNonce(proxy);
        vm.prank(wallet);
        try w.adapter.borrow(w.market, w.ghoReserve, amount, wallet, block.timestamp, 0, n) {
            ++borrowsDone;
            if (!clean) ++uncheckedSuccesses;
        } catch {}
    }

    function withdrawWithDebt(
        uint8 actorSeed
    ) external {
        address wallet = wallets[actorSeed % 3];
        address proxy = w.adapter.proxyOf(wallet, w.market);
        if (keys[wallet].length < 2 || w.spoke.getUserAccountData(proxy).borrowCount == 0) return;
        bool clean = _withDebtClean();
        bytes32 key = keys[wallet][keys[wallet].length - 1];
        uint256 units = w.coll.previewRelease(w.integrationId, key);
        vm.prank(wallet);
        try w.adapter.withdraw(w.market, PositionRef(w.integrationId, key), units, block.timestamp, 0) {
            keys[wallet].pop();
            ++withdrawalsWithDebtDone;
            if (!clean) ++uncheckedSuccesses;
        } catch {}
    }

    // ─── Exits ───

    function repay(
        uint8 actorSeed,
        uint256 amount
    ) external {
        address wallet = wallets[actorSeed % 3];
        address proxy = w.adapter.proxyOf(wallet, w.market);
        uint256 owed = w.spoke.getUserTotalDebt(w.ghoReserve, proxy);
        if (owed == 0) return;
        amount = bound(amount, 1, owed);
        w.gho.mint(wallet, amount);
        vm.prank(wallet);
        w.gho.approve(address(w.adapter), amount);
        vm.prank(wallet);
        try w.adapter.repay(wallet, w.market, w.ghoReserve, amount, false, block.timestamp) {
            ++exitsDone;
        } catch (bytes memory err) {
            ++exitFailures;
            lastError = err;
        }
    }

    function pledge(
        uint8 actorSeed
    ) external {
        address wallet = wallets[actorSeed % 3];
        bytes32 key = keccak256(abi.encode("risk-handler", ++nonce));
        w.lpVault.mintPosition(key, wallet, w.market, 1_000_000_000);
        vm.prank(wallet);
        try w.adapter.pledge(w.market, PositionRef(w.integrationId, key), block.timestamp) {
            keys[wallet].push(key);
        } catch {}
    }

    // ─── The handler's copy of the gates ───

    /// @dev Every condition the reviewed RiskModule applies to a withdrawal that leaves debt: the market Live and
    /// borrowable, both feeds within their maximum age, the USDC DebtOracle Live and fresh, no breaker, no drift.
    function _withDebtClean() internal view returns (bool) {
        bool priceOk = priceState == PriceState.Live && priceBorrowAllowed && reportedAt <= block.timestamp
            && block.timestamp - reportedAt <= w.feedAge;
        bool debtOk = debtLive && debtServedAt <= block.timestamp && block.timestamp - debtServedAt <= 88_200;
        return priceOk && debtOk && !breakerLatched && !drift;
    }
}
