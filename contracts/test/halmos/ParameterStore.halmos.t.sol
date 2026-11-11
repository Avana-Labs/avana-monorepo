// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketStatus} from "../../src/policy/market-registry/types/MarketStatus.sol";
import {IParameterStore} from "../../src/policy/parameter-store/IParameterStore.sol";
import {IParameterStoreAdmin} from "../../src/policy/parameter-store/IParameterStoreAdmin.sol";
import {IParameterStoreBreakers} from "../../src/policy/parameter-store/IParameterStoreBreakers.sol";
import {IParameterStoreLiquidation} from "../../src/policy/parameter-store/IParameterStoreLiquidation.sol";
import {IParameterStoreLoosen} from "../../src/policy/parameter-store/IParameterStoreLoosen.sol";
import {IParameterStoreTighten} from "../../src/policy/parameter-store/IParameterStoreTighten.sol";
import {ParameterStore} from "../../src/policy/parameter-store/ParameterStore.sol";
import {ParameterStoreAdminOracleLogic} from "../../src/policy/parameter-store/ParameterStoreAdminOracleLogic.sol";
import {ParameterStoreAdminRiskLogic} from "../../src/policy/parameter-store/ParameterStoreAdminRiskLogic.sol";
import {ParameterStoreListingLogic} from "../../src/policy/parameter-store/ParameterStoreListingLogic.sol";
import {ParameterStoreLoosenLogic} from "../../src/policy/parameter-store/ParameterStoreLoosenLogic.sol";
import {ParameterStoreTightenLogic} from "../../src/policy/parameter-store/ParameterStoreTightenLogic.sol";
import {GlobalParams} from "../../src/policy/parameter-store/types/GlobalParams.sol";
import {MarketParams} from "../../src/policy/parameter-store/types/MarketParams.sol";
import {ParameterStoreLogics} from "../../src/policy/parameter-store/types/ParameterStoreLogics.sol";
import {Market} from "../../src/types/Market.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {MockMarketRegistry} from "../utils/mocks/MockMarketRegistry.sol";
import {MockIntegration, MockLPOracle, MockPool} from "../utils/mocks/ParameterStoreMocks.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

/// @title ParameterStoreHalmosTest
/// @notice Symbolic checks of PROP-042: for every value, each tighten setter succeeds exactly when the value is
/// strictly safer and inside its hard and liveness bounds, stores it, and otherwise leaves the parameter unchanged;
/// `minPledgeUsd` only rises through `tightenMinPledgeUsd` and only falls through `loosenMinPledgeUsd`, within
/// `[0, 100_000e8]`; the grace setters stay inside the global liveness bounds.
/// @dev The store runs behind its proxy with its five logic contracts; the timelock is a fixed address (no loosening
/// under test reads `normalDelay`). Market 1 is written in `setUp` with the launch values of 1.5 (twapWindow 0 on an
/// integration without a time-weighted price, so no feed is needed). Each check is one symbolic value per setter.
contract ParameterStoreHalmosTest is Test {
    address internal constant TIMELOCK = address(0x7173);
    address internal constant RECIPIENT = address(0xFEE);
    address internal constant TOKEN_A = address(0xA1);
    address internal constant TOKEN_B = address(0xB1);
    uint256 internal constant M = 1;

    IParameterStore internal store;

    function setUp() public {
        MockMarketRegistry registry = new MockMarketRegistry();
        ParameterStoreLogics memory l = ParameterStoreLogics({
            tighten: address(new ParameterStoreTightenLogic(TIMELOCK, address(registry), 12, false)),
            loosen: address(new ParameterStoreLoosenLogic(TIMELOCK, address(registry), 12, false)),
            listing: address(new ParameterStoreListingLogic(TIMELOCK, address(registry), 12, false)),
            adminOracle: address(new ParameterStoreAdminOracleLogic(TIMELOCK, address(registry), 12, false)),
            adminRisk: address(new ParameterStoreAdminRiskLogic(TIMELOCK, address(registry), 12, false))
        });
        ParameterStore impl = new ParameterStore(TIMELOCK, address(registry), 12, false, l);
        GlobalParams memory g;
        g.cachedWindow = 3600;
        g.disagreementPauseMax = 3600;
        g.usdBandLow = 0.9e8;
        g.usdBandHigh = 1.02e8;
        g.graceDuration = 1800;
        g.graceHealthFactor = 0.95e18;
        g.maxFlashFeeBps = 10;
        g.avanaFeeShareBps = 2000;
        g.feeRecipient = RECIPIENT;
        g.feedAgreementMarginBps = 50;
        g.gateRecoverySeconds = 1800;
        g.maxShortfallBps = 1000;
        store = IParameterStore(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(IParameterStoreAdmin.initialize, (TIMELOCK, g, 0, 10_000))
                )
            )
        );
        MockIntegration integration = new MockIntegration();
        integration.set(false, true, false, ShapeKind.FullPool);
        Market memory m;
        m.integration = address(integration);
        m.pool = address(new MockPool());
        m.tokens = new address[](2);
        (m.tokens[0], m.tokens[1]) = (TOKEN_A, TOKEN_B);
        m.tokenDecimals = new uint8[](2);
        m.lpOracle = address(new MockLPOracle());
        m.status = MarketStatus.Registered;
        registry.setMarket(M, m);
        address[] memory none = new address[](0);
        registry.setToken(TOKEN_A, none, none, none);
        registry.setToken(TOKEN_B, none, none, none);
        vm.startPrank(TIMELOCK);
        store.setTokenCollateralFactorBps(TOKEN_A, 7800);
        store.setTokenCollateralFactorBps(TOKEN_B, 7500);
        MarketParams memory p;
        p.consistencyToleranceBps = 50;
        p.slippageAllowanceBps = 100;
        p.slippageAllowanceMinBps = 30;
        p.poolRiskFactor = 4000;
        p.minPledgeUsd = 10e8;
        store.setInitialMarketParams(M, p);
        store.setInitialMarketCaps(M, 5_000_000e8, 500_000e8, 1e8);
        vm.stopPrank();
    }

    function _asTimelock(
        bytes memory data
    ) internal returns (bool ok) {
        vm.prank(TIMELOCK);
        (ok,) = address(store).call(data);
    }

    // PROP-042 verifies: REQ-PSTORE-005, REQ-CONFIG-051, INV-047, Q-230
    function check_PROP_042_tightenMinPledgeOnlyRaises(
        uint256 value
    ) public {
        uint256 before = store.minPledgeUsd(M);
        bool ok = _asTimelock(abi.encodeCall(IParameterStoreTighten.tightenMinPledgeUsd, (M, value)));
        assert(ok == (value > before && value <= 100_000e8));
        assert(store.minPledgeUsd(M) == (ok ? value : before));
    }

    // PROP-042 verifies: REQ-PSTORE-005, Q-230
    function check_PROP_042_loosenMinPledgeOnlyLowers(
        uint256 value
    ) public {
        uint256 before = store.minPledgeUsd(M);
        bool ok = _asTimelock(abi.encodeCall(IParameterStoreLoosen.loosenMinPledgeUsd, (M, value)));
        assert(ok == (value < before));
        assert(store.minPledgeUsd(M) == (ok ? value : before));
        assert(store.minPledgeUsd(M) <= 100_000e8);
    }

    // PROP-042 verifies: REQ-PSTORE-031, REQ-CONFIG-050, REQ-CONFIG-051, Q-398
    function check_PROP_042_tightenHardHealthFloor(
        uint256 value
    ) public {
        bool ok = _asTimelock(abi.encodeCall(IParameterStoreTighten.tightenHardHealthFloor, (M, value)));
        assert(ok == (value >= 1e18 && value <= 1.25e18));
        assert(store.hardHealthFloor(M) == (ok ? value : 0));
    }

    // PROP-042 verifies: REQ-CONFIG-052, REQ-PSTORE-015, INV-047
    function check_PROP_042_tightenSlippageStaysAboveFloor(
        uint16 value
    ) public {
        bool ok = _asTimelock(abi.encodeCall(IParameterStoreTighten.tightenSlippageAllowanceBps, (M, value)));
        assert(ok == (value < 100 && value >= 30));
        uint16 stored = store.getMarketParams(M).slippageAllowanceBps;
        assert(stored == (ok ? value : 100));
        assert(stored >= store.slippageAllowanceMinBps(M));
    }

    // PROP-042 verifies: REQ-CONFIG-052, SPEC-GOV-009, INV-047
    function check_PROP_042_tightenConsistencyStaysAboveMinimum(
        uint16 value
    ) public {
        bool ok = _asTimelock(abi.encodeCall(IParameterStoreTighten.tightenConsistencyToleranceBps, (M, value)));
        assert(ok == (value < 50 && value >= 10));
        assert(store.getMarketParams(M).consistencyToleranceBps >= store.consistencyToleranceMinBps());
    }

    // PROP-042 verifies: REQ-RISK-042, REQ-RISK-044
    function check_PROP_042_tightenCapsOnlyLower(
        uint256 cap,
        uint256 slice
    ) public {
        bool okSlice = _asTimelock(abi.encodeCall(IParameterStoreTighten.tightenTopUpSliceUsd, (M, slice)));
        assert(okSlice == (slice < 500_000e8));
        uint256 s = store.topUpSliceUsd(M);
        bool okCap = _asTimelock(abi.encodeCall(IParameterStoreTighten.tightenMarketUsdCap, (M, cap)));
        assert(okCap == (cap < 5_000_000e8 && cap != 0 && cap >= s));
        assert(store.topUpSliceUsd(M) <= store.marketUsdCap(M));
    }

    // PROP-042 verifies: REQ-PSTORE-030, REQ-PSTORE-018, REQ-PSTORE-024, Q-399
    function check_PROP_042_tightenChainScalars(
        uint64 gate,
        uint16 shortfall,
        uint16 flash,
        uint16 share
    ) public {
        assert(
            _asTimelock(abi.encodeCall(IParameterStoreBreakers.tightenGateRecoverySeconds, (gate)))
                == (gate > 1800 && gate <= 7200)
        );
        assert(store.gateRecoverySeconds() >= 600 && store.gateRecoverySeconds() <= 7200);
        assert(
            _asTimelock(abi.encodeCall(IParameterStoreLiquidation.tightenMaxShortfallBps, (shortfall)))
                == (shortfall < 1000)
        );
        assert(_asTimelock(abi.encodeCall(IParameterStoreAdmin.tightenMaxFlashFeeBps, (flash))) == (flash < 10));
        assert(
            _asTimelock(abi.encodeCall(IParameterStoreTighten.tightenPoolShareMaxBps, (share)))
                == (share < 10_000 && share != 0)
        );
        assert(store.poolShareMaxBps() > 0 && store.poolShareMaxBps() <= 10_000);
    }

    // PROP-042 verifies: REQ-CONFIG-052, SPEC-GOV-012, INV-047
    function check_PROP_042_graceStaysInsideLivenessBounds(
        uint32 duration,
        uint256 hf
    ) public {
        bool okD = _asTimelock(abi.encodeCall(IParameterStoreAdmin.setGraceDuration, (duration)));
        assert(okD == (duration <= 7200));
        bool okH = _asTimelock(abi.encodeCall(IParameterStoreAdmin.setGraceHealthFactor, (hf)));
        assert(okH == (hf >= 0.9e18 && hf < 1e18));
        assert(store.graceDuration() <= store.graceDurationMax());
        assert(store.graceHealthFactor() >= store.graceHealthFactorMin() && store.graceHealthFactor() < 1e18);
    }
}
