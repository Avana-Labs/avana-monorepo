// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAccessManagerOps} from "../../script/deploy/lib/AccessOperations.sol";
import {AvanaAccess} from "../../script/deploy/lib/AvanaAccess.sol";
import {AaveGovernanceExecutorOwnedStandIn} from "../../script/deploy/local/AaveGovernanceExecutorOwnedStandIn.sol";
import {IFirstLossReserve} from "../../src/coverage/first-loss-reserve/IFirstLossReserve.sol";
import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Oracle} from "../../src/interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IRiskModule} from "../../src/policy/risk-module/IRiskModule.sol";
import {BandMath} from "../../src/policy/risk-module/libraries/BandMath.sol";
import {IVaultToken} from "../../src/vault-token/IVaultToken.sol";
import {AaveV4Fixture} from "../utils/fixtures/AaveV4Fixture.sol";
import {ClPoolFixture, ClTestToken, IClPool} from "../utils/fixtures/ClPoolFixture.sol";
import {
    CoverageHubSpokeConfig,
    CoverageInterestRateData,
    ICoverageHubConfigurator
} from "../utils/fixtures/CoverageHubFixture.sol";
import {MockDebtAsset} from "../utils/mocks/MockDebtAsset.sol";

/// @notice An 8-decimal Chainlink-style feed the AaveOracle (`latestAnswer`) and the LPOracle (`latestRoundData`) read.
contract DeployTestFeed {
    int256 public latestAnswer;

    constructor(
        int256 answer
    ) {
        latestAnswer = answer;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, latestAnswer, block.timestamp, block.timestamp, 1);
    }
}

/// @notice The Spoke configurator calls of the "06 done" setup.
interface IDeployTestSpokeConfigurator {
    struct ReserveConfig {
        uint24 collateralRisk;
        bool paused;
        bool frozen;
        bool borrowable;
        bool receiveSharesEnabled;
    }

    struct DynamicReserveConfig {
        uint16 collateralFactor;
        uint32 maxLiquidationBonus;
        uint16 liquidationFee;
    }

    struct LiquidationConfig {
        uint128 targetHealthFactor;
        uint64 healthFactorForMaxBonus;
        uint16 liquidationBonusFactor;
    }

    function addReserve(
        address spoke,
        address hub,
        uint256 assetId,
        address priceSource,
        ReserveConfig calldata config,
        DynamicReserveConfig calldata dynamicConfig
    ) external returns (uint256);

    function updateLiquidationConfig(
        address spoke,
        LiquidationConfig calldata config
    ) external;
}

/// @notice The `run()` every deploy script exposes.
interface IDeployStep {
    function run() external;
}

/// @title DeployScriptsIntegrationTest
/// @notice The step-9 deploy scripts end to end on a local chain: the real Aave V4 (pinned build) with its governance
/// executor stand-in, real Uniswap v3 pools, and every Avana step from `00-factories` to `09-execute-listing-activate`
/// in order, run as `script/deploy/step.sh` runs them on anvil (the operations scheduled as the governance Safe and
/// executed once the governance delay has passed, the Aave AIPs run through the executor).
/// @dev Runs in the test's own chain by default and on a fork of a local anvil node with `AVANA_DEPLOY_TEST_RPC`.
/// The scripts read a config this test writes to `deployments-local/deploy-test/` and write their outputs next to
/// it. Aave's side of `06-aave-deployment-aip` (GHO on the Hub, the Lend and CDP Spokes, the credit line) is set up
/// directly: 06 runs on Aave's config engine, which the fixture does not deploy. Script contracts exceed EIP-170, so
/// their runtime code is placed with `vm.etch`.
contract DeployScriptsIntegrationTest is AaveV4Fixture, ClPoolFixture {
    string internal constant NETWORK = "deploy-test";
    string internal constant DIR = "deployments-local/deploy-test";
    uint40 internal constant GHO_DRAW_CAP = 1_000_000;
    uint256 internal constant COVERAGE_RATIO_BPS = 1000;

    address internal deployer = makeAddr("deployer");
    address internal controller = makeAddr("payloadsController");
    address internal tokenMinter = makeAddr("tokenMinter");
    address internal riskSteward = makeAddr("riskSteward");

    AaveGovernanceExecutorOwnedStandIn internal executor;
    address internal nfpm;
    MockDebtAsset internal gho;
    uint256 internal ghoAssetId;
    ClTestToken internal usdc;
    ClTestToken internal usdt;
    ClTestToken internal dai;
    IClPool internal stablePool;
    IClPool internal daiPool;
    DeployTestFeed internal usdFeed;

    function setUp() public {
        // `AVANA_DEPLOY_TEST_RPC=http://127.0.0.1:8545` runs the same flow on a fork of a local anvil node.
        string memory rpc = vm.envOr("AVANA_DEPLOY_TEST_RPC", string(""));
        if (bytes(rpc).length != 0) vm.createSelectFork(rpc);
        executor = new AaveGovernanceExecutorOwnedStandIn(controller);
        aaveDao = address(executor);
        _deployAaveV4();
        _deployWorld();
        _aaveDeploymentDone();
        string memory root = string.concat(vm.projectRoot(), "/", DIR);
        if (vm.exists(root)) vm.removeDir(root, true);
        vm.createDir(root, true);
        vm.writeFile(string.concat(root, "/config.json"), _config());
        vm.setEnv("AVANA_NETWORK", NETWORK);
        vm.setEnv("AVANA_CONFIG", string.concat(DIR, "/config.json"));
        vm.setEnv("AVANA_DEPLOYER", vm.toString(deployer));
        vm.setEnv("AVANA_SCHEDULE", "true");
    }

    function test_deployScriptsListEveryPoolAsTwoActiveMarkets() public {
        _runSteps();
        string memory avana = vm.readFile(_out("avana"));
        IAccessManagerOps manager = IAccessManagerOps(vm.parseJsonAddress(avana, ".accessManager"));
        IRiskModule rm = IRiskModule(vm.parseJsonAddressArray(avana, ".riskModules")[0]);
        address adapter = vm.parseJsonAddressArray(avana, ".aaveAdapters")[0];
        address module = vm.parseJsonAddressArray(avana, ".liquidationModules")[0];
        assertEq(rm.LIQUIDATION_MODULE(), module, "RiskModule names the LiquidationModule");
        assertEq(rm.LP_VAULT(), vm.parseJsonAddressArray(avana, ".lpVaults")[0], "RiskModule names the LPVault");
        assertTrue(vm.parseJsonAddressArray(avana, ".flashloanRepays")[0].code.length != 0, "FlashloanRepay deployed");

        _checkAccess(manager, rm);
        _checkCoverage(rm);
        address[2] memory pools = [address(stablePool), address(daiPool)];
        uint16[2] memory ltvs = [uint16(9000), uint16(8500)];
        for (uint256 i = 0; i < 2; ++i) {
            _checkPool(rm, manager, adapter, module, pools[i], ltvs[i]);
        }
        assertEq(vm.parseJsonUintArray(vm.readFile(_out("markets")), ".marketIds").length, 4, "four markets recorded");
    }

    // ─── Steps ───

    function _runSteps() private {
        _run("00_Factories.s.sol:Factories");
        _run("03_DeployAvana.s.sol:DeployAvana");
        vm.setEnv("AVANA_COVERAGE_STEP", "deploy");
        _run("07_DeployFirstLossReserves.s.sol:DeployFirstLossReserves");
        _run("08_AaveLossLayersPayload.s.sol:AaveLossLayersPayload");
        vm.setEnv("AVANA_COVERAGE_STEP", "fund");
        _run("07_DeployFirstLossReserves.s.sol:DeployFirstLossReserves");
        _governed("setup", "listing-setup");
        _governed("markets", "listing-markets");
        vm.setEnv("AVANA_LISTING_STEP", "vault-tokens");
        _run("09_ListMarkets.s.sol:ListMarkets");
        _run("10_AaveListingPayload.s.sol:AaveListingPayload");
        _governed("activate", "listing-activate");
    }

    /// @dev A `09_ListMarkets` step that schedules an operation, then `05_ExecuteOperations` once it is ready.
    function _governed(
        string memory step,
        string memory operation
    ) private {
        vm.setEnv("AVANA_LISTING_STEP", step);
        _run("09_ListMarkets.s.sol:ListMarkets");
        vm.warp(block.timestamp + NORMAL_DELAY + 1);
        vm.roll(block.number + 1);
        vm.setEnv("AVANA_OPERATIONS", operation);
        _run("05_ExecuteOperations.s.sol:ExecuteOperations");
    }

    function _run(
        string memory artifact
    ) private {
        address at = makeAddr(artifact);
        vm.etch(at, vm.getDeployedCode(artifact));
        // On a fork a contract placed during the test reaches the cheatcodes only once allowed.
        vm.allowCheatcodes(at);
        IDeployStep(at).run();
    }

    function _out(
        string memory file
    ) private view returns (string memory) {
        return string.concat(vm.projectRoot(), "/", DIR, "/", file, ".json");
    }

    // ─── Checks ───

    function _checkAccess(
        IAccessManagerOps manager,
        IRiskModule rm
    ) private view {
        (bool deployerAdmin,) = manager.hasRole(AvanaRoles.ADMIN_ROLE, deployer);
        assertFalse(deployerAdmin, "the deployer renounced the admin role");
        (bool daoAdmin,) = manager.hasRole(AvanaRoles.ADMIN_ROLE, address(executor));
        assertTrue(daoAdmin, "the DAO is the manager's admin");
        (bool gov, uint32 govDelay) = manager.hasRole(AvanaRoles.GOVERNANCE_ROLE, governanceMultisig);
        assertTrue(gov, "the Safe holds the governance role");
        assertEq(govDelay, NORMAL_DELAY, "governance delay");
        (bool tighten, uint32 tightenDelay) = manager.hasRole(AvanaRoles.TIGHTEN_ROLE, riskSteward);
        assertTrue(tighten && tightenDelay == 0, "the risk steward tightens at once");
        assertEq(
            manager.getTargetFunctionRole(address(rm), IRiskModule.listPool.selector),
            AvanaRoles.GOVERNANCE_ROLE,
            "listPool takes the governance role"
        );
        (bool steward,) = manager.canCall(riskSteward, address(rm), IRiskModule.listPool.selector);
        assertFalse(steward, "the risk steward cannot list");
    }

    function _checkCoverage(
        IRiskModule rm
    ) private view {
        string memory coverage = vm.readFile(_out("coverage"));
        address flr = vm.parseJsonAddressArray(coverage, ".avanaLayers")[0];
        address offset = vm.parseJsonAddressArray(coverage, ".daoOffsets")[0];
        assertEq(IFirstLossReserve(offset).FIRST_LOSS_LAYER(), flr, "the DAO offset stands behind Avana's layer");
        assertTrue(IFirstLossReserve(flr).isAllowedSpoke(aave.cdpSpoke), "the CDP Spoke is allowed");
        assertGe(IFirstLossReserve(flr).fundedBalance(), IFirstLossReserve(flr).minimum(), "funded to its minimum");
        IAccessManagerOps aaveManager = IAccessManagerOps(aave.accessManager);
        (bool member, uint32 delay) = aaveManager.hasRole(503, address(executor));
        assertTrue(member, "the executor holds the withdraw role");
        assertEq(delay, WITHDRAW_DELAY, "withdraw executes 14 days after scheduling");
        assertEq(aaveManager.getTargetFunctionRole(flr, IFirstLossReserve.withdraw.selector), 503, "withdraw role");
        (bool eliminator,) = aaveManager.hasRole(HUB_DEFICIT_ELIMINATOR_ROLE, flr);
        assertTrue(eliminator, "the layer eliminates deficits");

        uint256 debtReserve = IAaveV4Spoke(aave.cdpSpoke).getReserveId(aave.hub, ghoAssetId);
        assertEq(rm.getDebtReserve(aave.cdpSpoke, debtReserve).firstLossReserve, flr, "debt reserve names its layer");
        assertTrue(IAaveV4Spoke(aave.cdpSpoke).getReserveConfig(debtReserve).borrowable, "GHO borrowable");
        rm.checkBorrow(aave.cdpSpoke, debtReserve);
    }

    function _checkPool(
        IRiskModule rm,
        IAccessManagerOps manager,
        address adapter,
        address module,
        address pool,
        uint16 ltv
    ) private view {
        bytes32 id = bytes32(uint256(uint160(pool)));
        IRiskModule.PoolMarkets memory pm = rm.marketsOf(id);
        IRiskModule.Market memory full = rm.getMarket(pm.fullRange);
        IRiskModule.Market memory custom = rm.getMarket(pm.customRange);
        int24 spacing = IClPool(pool).tickSpacing();
        (int24 fullLower, int24 fullUpper) = BandMath.fullRange(spacing);
        assertEq(full.bandLower, fullLower, "Full range: lowest usable tick");
        assertEq(full.bandUpper, fullUpper, "Full range: highest usable tick");
        assertEq(uint8(full.kind), uint8(IRiskModule.MarketKind.FullRange));
        assertEq(uint8(custom.kind), uint8(IRiskModule.MarketKind.CustomRange));
        // Stable Spoke width: 101 ticks below and 100 above the listing tick (about ±1%).
        assertApproxEqAbs(int256(custom.bandUpper) - int256(custom.bandLower), 201, 2 * uint256(int256(spacing)));
        assertEq(full.ltvBps, ltv, "LTV: the lower of the two tokens'");
        assertEq(custom.ltvBps, ltv, "both markets carry the same LTV");
        assertEq(rm.routeOf(id, full.bandLower, full.bandUpper), pm.fullRange, "full-range ticks route to Full");
        assertEq(rm.routeOf(id, custom.bandLower, custom.bandUpper), pm.customRange, "band ticks route to Custom");
        _checkMarket(full, manager, adapter, module);
        _checkMarket(custom, manager, adapter, module);
        assertTrue(
            IAaveV4Spoke(aave.cdpSpoke).getReserve(full.reserveId).underlying == full.vaultToken,
            "Full range reserve holds its vault token"
        );
        assertEq(AvanaAccess.coreRole(1, AvanaAccess.CORE_ADAPTER), 102);
    }

    function _checkMarket(
        IRiskModule.Market memory m,
        IAccessManagerOps manager,
        address adapter,
        address module
    ) private view {
        assertTrue(m.active, "market active");
        assertEq(IVaultToken(m.vaultToken).liquidationModule(), module, "vault token names the module");
        assertEq(IVaultToken(m.vaultToken).hub(), aave.hub, "vault token names the Hub");
        assertEq(
            IAaveV4Oracle(IAaveV4Spoke(aave.cdpSpoke).ORACLE()).getReserveSource(m.reserveId),
            m.lpOracle,
            "the reserve is priced by the LPOracle"
        );
        (bool mint,) = manager.canCall(adapter, m.vaultToken, IVaultToken.mint.selector);
        (bool adapterBurn,) = manager.canCall(adapter, m.vaultToken, IVaultToken.burn.selector);
        (bool moduleBurn,) = manager.canCall(module, m.vaultToken, IVaultToken.burn.selector);
        (bool moduleMint,) = manager.canCall(module, m.vaultToken, IVaultToken.mint.selector);
        assertTrue(mint && adapterBurn && moduleBurn, "adapter mints and burns, module burns");
        assertFalse(moduleMint, "the module cannot mint");
    }

    // ─── World ───

    /// @dev Real Uniswap v3: USDC/USDT and DAI/USDC at 0.01%, both at $1, and the NonfungiblePositionManager.
    function _deployWorld() private {
        _deployFactory();
        usdc = new ClTestToken("USDC", 6);
        usdt = new ClTestToken("USDT", 6);
        dai = new ClTestToken("DAI", 18);
        stablePool = _pool(usdc, usdt);
        daiPool = _pool(dai, usdc);
        address at = makeAddr("NonfungiblePositionManager");
        vm.etch(
            at,
            bytes.concat(
                vm.getCode("out-univ3-periphery/NonfungiblePositionManager.sol/NonfungiblePositionManager.json"),
                abi.encode(address(factory), makeAddr("WETH9"), address(0))
            )
        );
        (bool ok, bytes memory runtime) = at.call("");
        require(ok && runtime.length != 0, "NonfungiblePositionManager constructor");
        vm.etch(at, runtime);
        nfpm = at;
        usdFeed = new DeployTestFeed(1e8);
        gho = new MockDebtAsset("Gho Token", "GHO", 18);
    }

    function _pool(
        ClTestToken a,
        ClTestToken b
    ) private returns (IClPool) {
        (ClTestToken t0, ClTestToken t1) = address(a) < address(b) ? (a, b) : (b, a);
        return _createPool(t0, t1, 100, 1e8, 1e8, 1, 1e18);
    }

    /// @dev What `06-aave-deployment-aip` leaves: GHO on the Hub, supplied through the Lend Spoke and drawn by the CDP
    /// Spoke (its reserve not borrowable yet), the CDP Spoke's liquidation configuration and a credit line.
    function _aaveDeploymentDone() private {
        IAaveV4Hub hub = IAaveV4Hub(aave.hub);
        uint40 maxCap = hub.MAX_ALLOWED_SPOKE_CAP();
        uint24 maxRp = hub.MAX_RISK_PREMIUM_THRESHOLD();
        ICoverageHubConfigurator hc = ICoverageHubConfigurator(aave.hubConfigurator);
        IDeployTestSpokeConfigurator sc = IDeployTestSpokeConfigurator(aave.spokeConfigurator);
        vm.startPrank(aaveDao);
        ghoAssetId = hc.addAssetWithDecimals(
            aave.hub,
            address(gho),
            18,
            aave.treasurySpoke,
            0,
            aave.irStrategy,
            abi.encode(CoverageInterestRateData(9000, 0, 400, 6000))
        );
        hc.addSpoke(aave.hub, aave.lendSpoke, ghoAssetId, CoverageHubSpokeConfig(maxCap, 0, maxRp, true, false));
        hc.addSpoke(aave.hub, aave.cdpSpoke, ghoAssetId, CoverageHubSpokeConfig(0, GHO_DRAW_CAP, maxRp, true, false));
        sc.addReserve(
            aave.lendSpoke,
            aave.hub,
            ghoAssetId,
            address(usdFeed),
            IDeployTestSpokeConfigurator.ReserveConfig(0, false, false, true, false),
            IDeployTestSpokeConfigurator.DynamicReserveConfig(0, 10_000, 0)
        );
        sc.addReserve(
            aave.cdpSpoke,
            aave.hub,
            ghoAssetId,
            address(usdFeed),
            IDeployTestSpokeConfigurator.ReserveConfig(0, false, false, false, false),
            IDeployTestSpokeConfigurator.DynamicReserveConfig(0, 10_000, 0)
        );
        sc.updateLiquidationConfig(aave.cdpSpoke, IDeployTestSpokeConfigurator.LiquidationConfig(1.1e18, 0.95e18, 5000));
        vm.stopPrank();
        gho.mint(aave.hub, 10_000_000e18);
        vm.prank(aave.lendSpoke);
        hub.add(ghoAssetId, 10_000_000e18);
    }

    // ─── Config ───

    function _config() private returns (string memory) {
        return string.concat(
            string.concat(
                '{"network":"',
                NETWORK,
                '","chainId":',
                vm.toString(block.chainid),
                ',"release":"v0.1.0-local","governance":',
                _governance(),
                ',"aaveLocal":',
                _aaveLocal(),
                ',"aave":',
                _aave()
            ),
            string.concat(
                ',"parameters":',
                _parameters(),
                ',"keepers":[',
                _q(keeper),
                '],"operatorHelpers":[],"integrations":[',
                _integration(),
                '],"aavePayload":',
                _aavePayload(),
                ',"coverage":{"funder":',
                _q(avanaLabs),
                '},"listing":',
                _listing(),
                "}"
            )
        );
    }

    function _q(
        address a
    ) private pure returns (string memory) {
        return string.concat('"', vm.toString(a), '"');
    }

    function _governance() private view returns (string memory) {
        return string.concat(
            '{"governanceSafe":',
            _q(governanceMultisig),
            ',"emergencyGuardian":',
            _q(emergencyGuardian),
            ',"aaveProtocolGuardian":',
            _q(aaveGuardian),
            ',"aaveGovernanceExecutor":',
            _q(address(executor)),
            ',"jointConfigSafe":',
            _q(riskSteward),
            "}"
        );
    }

    function _aaveLocal() private view returns (string memory) {
        return string.concat('{"aaveDao":', _q(address(executor)), ',"payloadsController":', _q(controller), "}");
    }

    function _aave() private returns (string memory) {
        return string.concat(
            '{"accessManager":',
            _q(aave.accessManager),
            ',"governanceExecutor":',
            _q(address(executor)),
            ',"hubConfigurator":',
            _q(aave.hubConfigurator),
            ',"spokeConfigurator":',
            _q(aave.spokeConfigurator),
            ',"treasurySpoke":',
            _q(aave.treasurySpoke),
            ',"v3Pool":',
            _q(makeAddr("aaveV3Pool")),
            ',"hubs":[{"label":"stable","tier":1,"hub":',
            _q(aave.hub),
            '}],"irStrategies":{"stable":',
            _q(aave.irStrategy),
            '},"spokes":{"cdpStable":',
            _q(aave.cdpSpoke),
            ',"lendStable":',
            _q(aave.lendSpoke),
            "}}"
        );
    }

    function _parameters() private view returns (string memory) {
        return string.concat(
            '{"timelockNormalDelay":',
            vm.toString(NORMAL_DELAY),
            ',"coverageRatioBps":',
            vm.toString(COVERAGE_RATIO_BPS),
            ',"globals":{"avanaFeeShareBps":2000,"feeRecipient":',
            _q(feeRecipient),
            "}}"
        );
    }

    function _integration() private view returns (string memory) {
        return string.concat(
            '{"integrationId":1,"kind":"uniswap-v3","positionManagers":[',
            _q(nfpm),
            '],"factories":[',
            _q(address(factory)),
            "]}"
        );
    }

    function _aavePayload() private view returns (string memory) {
        return string.concat(
            '{"tokenMinter":',
            _q(tokenMinter),
            ',"hubs":[{"label":"stable","lendSpoke":"lendStable","cdpSpokes":["cdpStable"]}],',
            '"debtAssets":[{"symbol":"GHO","decimals":18,"coverageMinimum":100000,"offsetMinimum":75000,"token":',
            _q(address(gho)),
            '}],"lossLayerRoles":{"coverageRole":500,"reserveAdminRole":501,"withdrawRole":503,"coverageCaller":',
            _q(coverageCaller),
            "}}"
        );
    }

    function _listing() private view returns (string memory) {
        return string.concat(
            '{"spokes":[{"label":"cdpStable","hub":"stable","integrationId":1,"tier":1,"spoke":',
            _q(aave.cdpSpoke),
            '}],"debtAssets":[{"symbol":"GHO","address":',
            _q(address(gho)),
            '}],"debtReserves":[{"spoke":"cdpStable","symbol":"GHO"}],"tokens":[',
            _token("USDC", address(usdc), 9000),
            ",",
            _token("USDT", address(usdt), 9000),
            ",",
            _token("DAI", address(dai), 8500),
            '],"markets":[',
            _market("uni-USDC-USDT-100", "USDC-USDT-100"),
            ",",
            _market("uni-DAI-USDC-100", "DAI-USDC-100"),
            '],"pools":{"USDC-USDT-100":',
            _q(address(stablePool)),
            ',"DAI-USDC-100":',
            _q(address(daiPool)),
            "}}"
        );
    }

    function _token(
        string memory symbol,
        address token,
        uint256 ltv
    ) private view returns (string memory) {
        return string.concat(
            '{"symbol":"',
            symbol,
            '","isUsdStable":true,"collateralFactorBps":',
            vm.toString(ltv),
            ',"address":',
            _q(token),
            ',"feeds":{"primary":',
            _q(address(usdFeed)),
            "}}"
        );
    }

    function _market(
        string memory name,
        string memory pool
    ) private pure returns (string memory) {
        return string.concat(
            '{"name":"',
            name,
            '","integrationId":1,"spoke":"cdpStable","pool":"',
            pool,
            '","maxLiquidationBonus":10500,"marketUsdCap":5000000}'
        );
    }
}
