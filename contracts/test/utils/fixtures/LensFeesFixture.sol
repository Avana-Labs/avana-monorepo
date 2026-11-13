// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {BackingRecord} from "../../../src/custody/collateralization/types/BackingRecord.sol";
import {ILens} from "../../../src/lens/lens/ILens.sol";
import {Lens} from "../../../src/lens/lens/Lens.sol";
import {MarketStatus} from "../../../src/policy/market-registry/types/MarketStatus.sol";
import {Market} from "../../../src/types/Market.sol";
import {PositionShape} from "../../../src/types/PositionShape.sol";
import {ShapeKind} from "../../../src/types/ShapeKind.sol";
import {AaveAdapterLensMock} from "../mocks/AaveAdapterLensMock.sol";
import {LensRegistryMock} from "../mocks/LensMocks.sol";
import {SlipstreamIntegrationFixture} from "./SlipstreamIntegrationFixture.sol";
import {UniswapV3IntegrationFixture} from "./UniswapV3IntegrationFixture.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Collateralization's record list of one account-market, settable, for `getAccountFees`.
contract LensRecordsStub {
    mapping(address => bytes32[]) internal _keys;

    function setRecords(
        address proxy,
        bytes32[] calldata keys
    ) external {
        _keys[proxy] = keys;
    }

    function getAccountRecords(
        address proxy,
        address,
        uint256,
        uint256
    ) external view returns (uint256[] memory ids, BackingRecord[] memory records) {
        bytes32[] memory keys = _keys[proxy];
        ids = new uint256[](keys.length);
        records = new BackingRecord[](keys.length);
        for (uint256 i = 0; i < keys.length; ++i) {
            ids[i] = i + 1;
            records[i].positionKey = keys[i];
            records[i].proxy = proxy;
        }
    }
}

/// @notice Deploys the Lens (nine modules and the entry point) over a stand-in MarketRegistry with one market bound
/// to a real concentrated-liquidity LPVault; the AaveAdapter and Collateralization addresses get the Lens stand-ins.
library LensFeesDeploy {
    Vm internal constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev The nine modules are deployed from their artifacts: they compile with the Lens's via-IR settings, which a
    /// test that also compiles a concentrated-liquidity LPVault (its own optimizer settings) cannot import.
    function deploy(
        address[9] memory c
    ) internal returns (ILens lens) {
        address[9] memory m;
        m[0] = _create("LensAccountModule.sol:LensAccountModule", abi.encode(c));
        m[1] = _create("LensMarketModule.sol:LensMarketModule", abi.encode(c));
        m[2] = _create("LensPriceModule.sol:LensPriceModule", abi.encode(c));
        m[3] = _create("LensLiquidationModule.sol:LensLiquidationModule", abi.encode(c, address(0xA5)));
        m[4] = _create("LensRiskModule.sol:LensRiskModule", abi.encode(c));
        m[5] = _create("LensPreviewModule.sol:LensPreviewModule", abi.encode(c));
        m[6] = _create("LensMarketsModule.sol:LensMarketsModule", abi.encode(c));
        m[7] = _create("LensPositionsModule.sol:LensPositionsModule", abi.encode(c));
        m[8] = _create("LensSpeedModule.sol:LensSpeedModule", abi.encode(c));
        lens = ILens(address(new Lens(m)));
    }

    function _create(
        string memory artifact,
        bytes memory args
    ) private returns (address a) {
        bytes memory code = abi.encodePacked(VM.getCode(artifact), args);
        assembly ("memory-safe") {
            a := create(0, add(code, 0x20), mload(code))
        }
        require(a != address(0), "module deployment");
    }

    /// @notice A market of `integration` on `pool` with `tokens` in pool order and a placeholder vault token.
    function market(
        address integration,
        uint32 integrationId,
        address pool,
        address token0,
        address token1,
        int24 lower,
        int24 upper
    ) internal view returns (Market memory mk) {
        mk.tokens = new address[](2);
        (mk.tokens[0], mk.tokens[1]) = (token0, token1);
        mk.tokenDecimals = new uint8[](2);
        (mk.tokenDecimals[0], mk.tokenDecimals[1]) = (6, 6);
        (mk.chainId, mk.integrationId, mk.integration, mk.pool) =
        (uint64(block.chainid), integrationId, integration, pool);
        mk.shape = PositionShape(ShapeKind.TickRange, lower, upper);
        (mk.vaultToken, mk.spoke, mk.status) = (address(0x7777), address(0x5509E), MarketStatus.Active);
    }

    /// @notice Puts the Lens stand-ins at the AaveAdapter and Collateralization addresses.
    function etchStandIns(
        address adapter,
        address coll
    ) internal {
        VM.etch(adapter, address(new AaveAdapterLensMock()).code);
        VM.etch(coll, address(new LensRecordsStub()).code);
    }
}

/// @title LensFeesV3Fixture
/// @notice The Uniswap v3 LPVault suite's world (real LPVault, mock NFPM, factory and pools with fee growth) with the
/// Lens over it: market 1 (`[-50, 50]` of the 0.05 % pool) is listed in a stand-in MarketRegistry, and the NFPM runs
/// the canonical fee update.
abstract contract LensFeesV3Fixture is UniswapV3IntegrationFixture {
    ILens internal lens;
    LensRegistryMock internal reg;

    function setUp() public virtual override {
        super.setUp();
        reg = new LensRegistryMock();
        reg.setMarket(
            M1,
            LensFeesDeploy.market(
                address(vault), INTEGRATION, address(pool500), pool500.token0(), pool500.token1(), M1_LOWER, M1_UPPER
            )
        );
        LensFeesDeploy.etchStandIns(adapter, coll);
        lens = LensFeesDeploy.deploy(
            [
                coll,
                makeAddr("proxyManager"),
                adapter,
                address(lock),
                address(reg),
                registry,
                registry,
                lpVaultSwap,
                coll
            ]
        );
        nfpm.setTrackFees(true);
    }
}

/// @title LensFeesSlipstreamFixture
/// @notice The Slipstream LPVault suite's world with the Lens over it: market 1 (`[-50, 50]` of the generation-2 pool
/// of spacing 1) is listed in a stand-in MarketRegistry, and every generation's position manager runs the canonical fee
/// update.
abstract contract LensFeesSlipstreamFixture is SlipstreamIntegrationFixture {
    ILens internal lens;
    LensRegistryMock internal reg;

    function setUp() public virtual override {
        super.setUp();
        reg = new LensRegistryMock();
        reg.setMarket(
            M1,
            LensFeesDeploy.market(
                address(vault), INTEGRATION, address(pool1), pool1.token0(), pool1.token1(), M1_LOWER, M1_UPPER
            )
        );
        LensFeesDeploy.etchStandIns(adapter, coll);
        lens = LensFeesDeploy.deploy(
            [
                coll,
                makeAddr("proxyManager"),
                adapter,
                address(lock),
                address(reg),
                registry,
                registry,
                lpVaultSwap,
                coll
            ]
        );
        for (uint256 g = 0; g < 4; ++g) {
            npms[g].setTrackFees(true);
        }
    }
}
