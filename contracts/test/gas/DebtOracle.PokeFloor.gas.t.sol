// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IDebtOracle} from "../../src/oracle/debt-oracle/IDebtOracle.sol";
import {DebtOracleInitParams} from "../../src/oracle/debt-oracle/types/DebtOracleInitParams.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {GasCalibration} from "../utils/GasCalibration.sol";
import {LPOracleGasFixture} from "../utils/fixtures/LPOracleGasFixture.sol";
import {OcrAggregatorMock} from "../utils/mocks/ChainlinkCostMocks.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice `POKE_MIN_GAS_FLOOR` of the DebtOracle (600,000, `REQ-ORACLE-038`, `SPEC-ORC-023`) measured on its
/// worst-case poke, in the setting of the LPOracle floor benchmark (`LPOracleGasFixture`): USDC as the debt asset, both
/// of its routes on two legs (the standby in the primary slot, the two-leg alternate), every leg an EACAggregatorProxy
/// over an OCR2 aggregator whose round is the first of a new phase after a gap longer than its feed age and the cached
/// window, so every recovery lookup is taken through the previous phase and the poke starts the grace period, and an
/// oracle-network second source; every account and slot cold. The implementation's own entry check is lowered to 1 in
/// storage, so the measured minimum is the poke's: the smallest entry gas at which it completes, which the floor must
/// cover so a poke at `pokeMinGas` never fails one of its reads for want of gas.
/// forge-config: default.isolate = false
contract DebtOraclePokeFloorGasTest is LPOracleGasFixture, GasCalibration {
    /// @notice `DebtOracleStorage.POKE_MIN_GAS_FLOOR_VALUE`.
    uint256 internal constant DEBT_POKE_MIN_GAS_FLOOR = 600_000;
    /// @dev ERC-7201 slot of `avana.storage.DebtOracle` (`DebtOracleStorage`).
    bytes32 internal constant DEBT_ORACLE_SLOT = 0x5df50d85f2e1cf43c7e32c2711fc5766191be64ab3bc12b0ee03012ed4ae9e00;
    /// @dev Word of the layout holding `routeVersion | lastState | lastRoute | pokeMinGas | ...` and the bit offset of
    /// `pokeMinGas` in it.
    uint256 internal constant POKE_MIN_GAS_WORD = 14;
    uint256 internal constant POKE_MIN_GAS_SHIFT = 80;

    IDebtOracle internal debtOracle;

    function setUp() public {
        _setUpGas(false, FLOOR);
        gasRegistry.useStandby(usdc, RouteSlot.Primary);
        IDebtOracle impl = IDebtOracle(deployCode("DebtOracle.sol:DebtOracle", abi.encode(address(timelock))));
        DebtOracleInitParams memory p = DebtOracleInitParams({
            timelock: address(timelock),
            asset: usdc,
            marketRegistry: address(registry),
            parameterStore: address(store),
            description: "USDC / USD",
            pokeMinGas: uint32(DEBT_POKE_MIN_GAS_FLOOR)
        });
        debtOracle = IDebtOracle(address(new ERC1967Proxy(address(impl), abi.encodeCall(IDebtOracle.initialize, (p)))));
        _lowerEntryCheck();
        assertEq(uint8(debtOracle.poke()), uint8(PriceState.Live), "a first accepted price and its seen rounds");
        // Every leg of both routes goes silent for longer than its feed age and the cached window, then publishes the
        // first round of a new phase.
        vm.warp(block.timestamp + MAX_AGE + store.cachedWindow() + 10_000);
        vm.roll(block.number + 1);
        uint256 at = block.timestamp - 60;
        uint8[4] memory routeLegs = [1, 2, 6, 7];
        for (uint256 i = 0; i < routeLegs.length; ++i) {
            uint256 leg = routeLegs[i];
            OcrAggregatorMock fresh = new OcrAggregatorMock(
                OcrAggregatorMock(legs[leg].aggregator()).decimals(),
                OcrAggregatorMock(legs[leg].aggregator()).minAnswer(),
                OcrAggregatorMock(legs[leg].aggregator()).maxAnswer()
            );
            fresh.setRound(leg == 2 || leg == 7 ? int192(4000e8) : int192(2.5e14), uint32(at));
            legs[leg].newPhase(fresh);
        }
        _round(10, 1e8, at);
    }

    /// @dev Sets the stored `pokeMinGas` to 1 (checked to hold the initialized 600,000 first).
    function _lowerEntryCheck() internal {
        bytes32 slot = bytes32(uint256(DEBT_ORACLE_SLOT) + POKE_MIN_GAS_WORD);
        uint256 word = uint256(vm.load(address(debtOracle), slot));
        assertEq((word >> POKE_MIN_GAS_SHIFT) & type(uint32).max, DEBT_POKE_MIN_GAS_FLOOR, "pokeMinGas slot");
        word &= ~(uint256(type(uint32).max) << POKE_MIN_GAS_SHIFT);
        vm.store(address(debtOracle), slot, bytes32(word | (uint256(1) << POKE_MIN_GAS_SHIFT)));
        assertEq(debtOracle.pokeMinGas(), 1, "entry check lowered");
    }

    /// @dev Smallest entry gas in `(lo, hi]` at which the poke completes, every touched account cold at each attempt.
    function _minimum(
        address[] memory accounts,
        uint256 lo,
        uint256 hi
    ) internal returns (uint256) {
        uint256 snap = vm.snapshotState();
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            _coolAll(accounts);
            (bool ok,) = address(debtOracle).call{gas: mid}(abi.encodeCall(IDebtOracle.poke, ()));
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid;
        }
        return hi;
    }

    // TEST-042 verifies: REQ-ORACLE-038, REQ-ORACLE-102, SPEC-ORC-023, REQ-ORACLE-089
    /// @notice The worst-case DebtOracle poke completes below `POKE_MIN_GAS_FLOOR`.
    function test_TEST_042_worstCaseDebtOraclePokeWithinFloor() public {
        bytes memory data = abi.encodeCall(IDebtOracle.poke, ());
        address[] memory accounts = _touched(address(this), address(debtOracle), data);
        uint256 minimum = _minimum(accounts, 50_000, 3_000_000);
        uint256 used = _coldGas(address(this), address(debtOracle), data);
        uint64 recoveredAt = _recoveredAt();
        emit log_named_uint("DebtOracle W_poke (cold, ample gas)", used);
        emit log_named_uint("DebtOracle: smallest entry gas at which poke completes", minimum);
        emit log_named_uint("POKE_MIN_GAS_FLOOR", DEBT_POKE_MIN_GAS_FLOOR);
        vm.snapshotValue("PokeFloor", "DebtOracle_worstCase_used", used);
        vm.snapshotValue("PokeFloor", "DebtOracle_worstCase_minimumEntryGas", minimum);
        assertGt(recoveredAt, 0, "the poke took the recovery path and started the grace period");
        assertLe(minimum, DEBT_POKE_MIN_GAS_FLOOR, "POKE_MIN_GAS_FLOOR covers the worst-case poke");
    }

    function _recoveredAt() internal view returns (uint64) {
        uint256 word = uint256(vm.load(address(debtOracle), bytes32(uint256(DEBT_ORACLE_SLOT) + 5)));
        // `failedSince` (8 bytes), `disagreeSince` (8), `expiredLatched` (1), then `recoveredAt`.
        return uint64(word >> 136);
    }
}
