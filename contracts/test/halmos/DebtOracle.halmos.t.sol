// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {DebtOracle} from "../../src/oracle/debt-oracle/DebtOracle.sol";
import {IDebtOracleErrors} from "../../src/oracle/debt-oracle/IDebtOracleErrors.sol";
import {DebtOracleInitParams} from "../../src/oracle/debt-oracle/types/DebtOracleInitParams.sol";
import {DebtPriceView} from "../../src/oracle/debt-oracle/types/DebtPriceView.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {SecondSource} from "../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../src/types/SecondSourceKind.sol";
import {DebtRegistryMock, DebtStoreMock} from "../utils/mocks/DebtOracleConfigMocks.sol";
import {MockAggregator} from "../utils/mocks/MockAggregator.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

/// @title DebtOracleHalmosTest
/// @notice Symbolic checks of the real DebtOracle behind its proxy, over one-leg primary and alternate routes with
/// symbolic answers within 40 bits (every value the listing bounds admit): the served debt price by state (`SPEC-ORC-018`),
/// the stress rise clamped to [100, 5,000] bps, the served timestamp and legs of the route actually served during a
/// disagreement (`SPEC-ORC-012`, `SPEC-ORC-015`), the restricted setter and the admin-role rule.
/// @dev The only revert any view may produce is `InsufficientGas`; Halmos models `gasleft()` symbolically, so each
/// check accepts that revert and asserts on every other path.
contract DebtOracleHalmosTest is Test {
    address internal constant TIMELOCK = address(0x7111);
    address internal constant ASSET = address(0x7201);
    uint256 internal constant T0 = 1_762_650_000;
    uint256 internal constant A = 99_990_000;

    DebtOracle internal oracle;
    DebtRegistryMock internal reg;
    DebtStoreMock internal store;
    MockAggregator internal primary;
    MockAggregator internal alternate;

    function setUp() public {
        vm.warp(T0);
        primary = new MockAggregator(8, int256(A), T0 - 100);
        alternate = new MockAggregator(8, int256(A), T0 - 100);
        MockAggregator second = new MockAggregator(8, int256(A), T0 - 100);
        reg = new DebtRegistryMock();
        store = new DebtStoreMock();
        address[] memory p = new address[](1);
        address[] memory b = new address[](1);
        p[0] = address(primary);
        b[0] = address(alternate);
        reg.list(ASSET, p, b, p);
        store.setFeed(address(primary), 8, 0, 1e12, 86_400, 1800);
        store.setFeed(address(alternate), 8, 0, 1e12, 86_400, 1800);
        store.setFeed(address(second), 8, 0, 1e12, 86_400, 1800);
        store.setTolerance(ASSET, 225);
        store.setStressRise(ASSET, 500);
        store.setSecondSource(
            ASSET,
            SecondSource({
                kind: SecondSourceKind.OracleNetwork,
                source: address(second),
                poolRef: bytes32(0),
                maxAge: 88_200,
                twapWindow: 0,
                toleranceBps: 100
            })
        );
        DebtOracle impl = new DebtOracle(TIMELOCK);
        DebtOracleInitParams memory params = DebtOracleInitParams({
            timelock: TIMELOCK,
            asset: ASSET,
            marketRegistry: address(reg),
            parameterStore: address(store),
            description: "USDC / USD",
            pokeMinGas: 600_000
        });
        oracle = DebtOracle(address(new ERC1967Proxy(address(impl), abi.encodeCall(DebtOracle.initialize, (params)))));
    }

    function _onlyGasRevert(
        bytes memory err
    ) internal pure {
        assert(bytes4(err) == IDebtOracleErrors.InsufficientGas.selector);
    }

    // PROP-074 verifies: SPEC-ORC-018, REQ-ORACLE-093, REQ-ORACLE-005, REQ-ORACLE-008, INV-087, Q-247
    // Sources: 5.2 PROP-074 (DebtOracle half: served >= 1, >= A unless Live, max(p, b, A) in a disagreement), with the
    // alternate at the accepted price and the primary symbolic. Both routes symbolic at once exceeds the run budget;
    // DebtOracleFuzzTest.testFuzz_TEST_219_servedByStateBothRoutes checks that case at 10,000 runs.
    function check_PROP_074_servedDebtPriceAgainstFixedAlternate(
        uint40 pAnswer
    ) public {
        _servedByState(pAnswer, uint40(A));
    }

    // PROP-074 verifies: SPEC-ORC-018, REQ-ORACLE-093, REQ-ORACLE-005, REQ-ORACLE-006, INV-087
    // Sources: the same property with the primary at the accepted price and the alternate symbolic
    function check_PROP_074_servedDebtPriceAgainstFixedPrimary(
        uint40 bAnswer
    ) public {
        _servedByState(uint40(A), bAnswer);
    }

    function _servedByState(
        uint40 pAnswer,
        uint40 bAnswer
    ) internal {
        primary.push(int256(uint256(pAnswer)), T0);
        alternate.push(int256(uint256(bAnswer)), T0);
        uint256 p = pAnswer;
        uint256 b = bAnswer;
        bool pValid = p > 0 && p < 1e12;
        bool bValid = b > 0 && b < 1e12;
        uint256 expected;
        bool live = true;
        if (pValid && bValid) {
            (uint256 lo, uint256 hi) = p < b ? (p, b) : (b, p);
            if ((hi - lo) * 10_000 <= 225 * lo) {
                expected = p;
            } else {
                live = false;
                expected = hi > A ? hi : A;
            }
        } else if (pValid) {
            expected = p;
        } else if (bValid) {
            expected = b;
        } else {
            live = false;
            expected = A;
        }
        try oracle.latestAnswer() returns (int256 served) {
            assert(served >= 1);
            assert(uint256(served) == expected);
            if (!live) assert(uint256(served) >= A);
        } catch (bytes memory err) {
            _onlyGasRevert(err);
        }
    }

    // PROP-074 verifies: SPEC-ORC-018, REQ-ORACLE-093, REQ-ORACLE-092, INV-087
    // Sources: review DO-03: for every stress rise the store returns, the Expired price is
    // ceil(A x (1e4 + min(max(delta, 100), 5,000)) / 1e4), never above 1.5 x A + 1.
    function check_PROP_074_expiredStressRiseClamped(
        uint16 delta
    ) public {
        store.setStressRise(ASSET, delta);
        vm.warp(T0 + 200_000);
        uint256 d = delta < 100 ? 100 : (delta > 5000 ? 5000 : uint256(delta));
        try oracle.latestAnswer() returns (int256 served) {
            assert(uint256(served) == (A * (10_000 + d) + 9999) / 10_000);
            assert(uint256(served) <= (A * 3) / 2 + 1);
        } catch (bytes memory err) {
            _onlyGasRevert(err);
        }
    }

    // PROP-074 verifies: SPEC-ORC-012, SPEC-ORC-015, SPEC-ORC-018, REQ-ORACLE-093
    // Sources: review DO-01, with the alternate symbolic and the primary at A: a disagreement serves the larger route
    // with its own timestamp and legs.
    function check_PROP_074_driftingTimestampFollowsAlternate(
        uint40 bAnswer
    ) public {
        _driftTimestamps(uint40(A), bAnswer);
    }

    // PROP-074 verifies: SPEC-ORC-012, SPEC-ORC-015, SPEC-ORC-018, REQ-ORACLE-093
    // Sources: review DO-01, with the primary symbolic and the alternate at 0.95: the primary's timestamp when it is
    // served, the accepted timestamp and no legs when A is.
    function check_PROP_074_driftingTimestampFollowsPrimaryOrAccepted(
        uint40 pAnswer
    ) public {
        _driftTimestamps(pAnswer, 95_000_000);
    }

    /// @dev Primary at `T0 - 80`, alternate at `T0 - 50`, accepted `A` at `T0 - 100`.
    function _driftTimestamps(
        uint40 pAnswer,
        uint40 bAnswer
    ) internal {
        primary.push(int256(uint256(pAnswer)), T0 - 80);
        alternate.push(int256(uint256(bAnswer)), T0 - 50);
        try oracle.getPriceState() returns (DebtPriceView memory v) {
            if (v.state == PriceState.Drifting) {
                uint256 p = pAnswer;
                uint256 b = bAnswer;
                uint256 hi = p > b ? p : b;
                if (A > hi) {
                    assert(v.servedUpdatedAt == T0 - 100);
                    assert(v.legFeeds[0] == address(0));
                    assert(v.borrowPriceMaxAge == 0 && v.liquidationPriceMaxAge == 0);
                } else if (b > p) {
                    assert(v.servedUpdatedAt == T0 - 50);
                    assert(v.legFeeds[0] == address(alternate));
                } else {
                    assert(v.servedUpdatedAt == T0 - 80);
                    assert(v.legFeeds[0] == address(primary));
                }
            }
        } catch (bytes memory err) {
            _onlyGasRevert(err);
        }
    }

    // PROP-034 verifies: REQ-ORACLE-098, REQ-ORACLE-038, Q-226, Q-228
    // Sources: 5.2 PROP-034 (debtSetPokeMinGasNeedsApplicationAdmin)
    function check_PROP_034_setPokeMinGasNeedsApplicationAdmin(
        address caller,
        uint32 value
    ) public {
        vm.prank(caller);
        try oracle.setPokeMinGas(value) {
            assert(caller == TIMELOCK);
            assert(value >= 600_000 && value <= 2_000_000);
            assert(oracle.pokeMinGas() == value);
        } catch {
            assert(oracle.pokeMinGas() == 600_000);
        }
    }

    // PROP-070 verifies: REQ-ORACLE-097, INV-084, Q-259
    // Sources: 5.2 PROP-070 (adminRolesOnlyTimelock, preserved by grantRole)
    function check_PROP_070_adminRolesOnlyTimelock(
        address caller,
        bytes32 role,
        address account
    ) public {
        vm.prank(caller);
        try oracle.grantRole(role, account) {} catch {}
        bytes32 admin = AvanaRoles.APPLICATION_ADMIN;
        assert(!oracle.hasRole(bytes32(0), account) || account == TIMELOCK);
        assert(!oracle.hasRole(admin, account) || account == TIMELOCK);
    }
}
