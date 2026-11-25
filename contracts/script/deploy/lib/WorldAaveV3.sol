// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DeployBase} from "./DeployBase.sol";

/// @dev ABI copies of Aave V3 origin v3.7.0 `src/deployments/interfaces/IMarketReportTypes.sol` (the batch constructors
/// and reports), field for field.
struct AaveV3Roles {
    address marketOwner;
    address poolAdmin;
    address emergencyAdmin;
}

struct AaveV3MarketConfig {
    address networkBaseTokenPriceInUsdProxyAggregator;
    address marketReferenceCurrencyPriceInUsdProxyAggregator;
    string marketId;
    uint8 oracleDecimals;
    uint256 providerId;
    bytes32 salt;
    address wrappedNativeToken;
    uint128 flashLoanPremium;
    address incentivesProxy;
    address treasury;
}

struct AaveV3MarketReport {
    address poolAddressesProviderRegistry;
    address poolAddressesProvider;
    address poolProxy;
    address poolImplementation;
    address poolConfiguratorProxy;
    address poolConfiguratorImplementation;
    address protocolDataProvider;
    address aaveOracle;
    address defaultInterestRateStrategy;
    address aclManager;
    address treasury;
    address treasuryImplementation;
    address wrappedTokenGateway;
    address walletBalanceProvider;
    address uiIncentiveDataProvider;
    address uiPoolDataProvider;
    address l2Encoder;
    address aToken;
    address variableDebtToken;
    address emissionManager;
    address rewardsControllerImplementation;
    address rewardsControllerProxy;
    address configEngine;
    address transparentProxyFactory;
    address staticATokenFactoryImplementation;
    address staticATokenFactoryProxy;
    address staticATokenImplementation;
    address dustBin;
    address emptyImplementation;
}

struct AaveV3InitialReport {
    address poolAddressesProvider;
    address interestRateStrategy;
    address poolAddressesProviderRegistry;
}

struct AaveV3PoolReport {
    address poolImplementation;
    address poolConfiguratorImplementation;
}

struct AaveV3PeripheryReport {
    address aaveOracle;
    address treasury;
    address treasuryImplementation;
    address emissionManager;
    address rewardsControllerImplementation;
    address emptyImplementation;
    address dustBin;
}

struct AaveV3SetupReport {
    address poolProxy;
    address poolConfiguratorProxy;
    address rewardsControllerProxy;
    address aclManager;
}

struct AaveV3TokensReport {
    address aToken;
    address variableDebtToken;
}

struct AaveV3GettersReportTwo {
    address wrappedTokenGateway;
    address l2Encoder;
    address protocolDataProvider;
}

/// @dev `ConfiguratorInputTypes.InitReserveInput` and `IDefaultInterestRateStrategyV2.InterestRateData` (bps).
struct AaveV3InitReserveInput {
    address aTokenImpl;
    address variableDebtTokenImpl;
    address underlyingAsset;
    string aTokenName;
    string aTokenSymbol;
    string variableDebtTokenName;
    string variableDebtTokenSymbol;
    bytes params;
    bytes interestRateData;
}

struct AaveV3InterestRateData {
    uint16 optimalUsageRatio;
    uint32 baseVariableBorrowRate;
    uint32 variableRateSlope1;
    uint32 variableRateSlope2;
}

interface IAaveV3SetupBatch {
    function getInitialReport() external view returns (AaveV3InitialReport memory);
    function setupAaveV3Market(
        AaveV3Roles memory roles,
        AaveV3MarketConfig memory config,
        address poolImplementation,
        address poolConfiguratorImplementation,
        address aaveOracle,
        address rewardsControllerImplementation
    ) external returns (AaveV3SetupReport memory);
    function setProtocolDataProvider(
        address protocolDataProvider
    ) external;
    function transferMarketOwnership(
        AaveV3Roles memory roles
    ) external;
    function setMarketReport(
        AaveV3MarketReport memory report
    ) external;
}

interface IAaveV3PoolBatch {
    function getPoolReport() external view returns (AaveV3PoolReport memory);
}

interface IAaveV3PeripheryBatch {
    function getPeripheryReport() external view returns (AaveV3PeripheryReport memory);
}

interface IAaveV3TokensBatch {
    function getTokensReport() external view returns (AaveV3TokensReport memory);
}

interface IAaveV3GettersBatchTwo {
    function getGettersReportTwo() external view returns (AaveV3GettersReportTwo memory);
}

interface IAaveV3Configurator {
    function initReserves(
        AaveV3InitReserveInput[] calldata input
    ) external;
    function setReserveFlashLoaning(
        address asset,
        bool enabled
    ) external;
}

interface IAaveV3OracleAdmin {
    function setAssetSources(
        address[] calldata assets,
        address[] calldata sources
    ) external;
    function getAssetPrice(
        address asset
    ) external view returns (uint256);
}

interface IAaveV3ACLAdmin {
    function addPoolAdmin(
        address admin
    ) external;
    function removePoolAdmin(
        address admin
    ) external;
    function addEmergencyAdmin(
        address admin
    ) external;
    function removeEmergencyAdmin(
        address admin
    ) external;
    function grantRole(
        bytes32 role,
        address account
    ) external;
    function renounceRole(
        bytes32 role,
        address account
    ) external;
    function hasRole(
        bytes32 role,
        address account
    ) external view returns (bool);
    function isPoolAdmin(
        address admin
    ) external view returns (bool);
    function isEmergencyAdmin(
        address admin
    ) external view returns (bool);
}

interface IAaveV3ProviderAdmin {
    function setACLAdmin(
        address newAclAdmin
    ) external;
    function getACLAdmin() external view returns (address);
}

interface IOwnableTransfer {
    function transferOwnership(
        address newOwner
    ) external;
    function owner() external view returns (address);
}

interface IAaveV3PoolSupply {
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;
    function getReserveAToken(
        address asset
    ) external view returns (address);
    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128);
}

/// @title WorldAaveV3
/// @notice The Aave V3 market of a test network, from Aave V3 origin v3.7.0 (cff15de, `aave-v3` profile), deployed the
/// way `AaveV3BatchOrchestration.deployAaveV3` does: the logic libraries (BorrowLogic first, then FlashLoanLogic linked
/// to it, LiquidationLogic, PoolLogic and SupplyLogic, the split of `AaveV3LibrariesBatch1` and `AaveV3LibrariesBatch2`,
/// deployed with CREATE because those batches deploy through the Safe singleton CREATE2 factory, which anvil lacks),
/// then the setup batch (PoolAddressesProvider, registry, `DefaultReserveInterestRateStrategyV2`), the pool batch
/// (`PoolInstance` linked to the five libraries, `PoolConfiguratorInstance`), the periphery batch (`AaveOracle` with USD
/// as base currency at 8 decimals, Collector treasury, EmissionManager and RewardsController), the market setup
/// (Pool and PoolConfigurator proxies, ACLManager, flash-loan premium), the protocol data provider and the aToken and
/// variable-debt-token implementations.
/// @dev Every world token is then listed through `PoolConfigurator.initReserves` with its aToken and variable debt token,
/// its `AaveOracle` source set to its primary OCR2 feed (`EACAggregatorProxy`), flash loans enabled and liquidity
/// supplied from the deployer, so the Pool lends real liquidity through `flashLoan`. The deployer holds every market
/// role while it lists, then hands the market to the network's Aave DAO account (`aaveLocal.aaveDao`, the account of
/// Aave V4's admin roles): pool admin, emergency admin and ACL admin, ownership of the PoolAddressesProvider, its
/// registry and the EmissionManager; the deployer keeps none of them. Step 06 grants `FLASH_BORROWER` as that account,
/// as the AIP does on Ethereum and Base. The Collector (treasury) stays administered by the deployer: no reserve factor
/// is set, so it never receives anything. The UI data providers, the
/// configuration engine and the static aToken factory of the full orchestration are not deployed: nothing on a test
/// network reads them.
abstract contract WorldAaveV3 is DeployBase {
    string internal constant AAVE_V3_OUT = "out-aave-v3";
    string internal constant AAVE_V3_LOGIC =
        "dependencies/aave-v3-origin-3.7.0/src/contracts/protocol/libraries/logic/";
    /// @notice Aave V3's flash-loan premium on Ethereum: 5 bps.
    uint128 internal constant AAVE_V3_FLASH_PREMIUM_BPS = 5;

    AaveV3MarketReport internal aaveV3;

    function _aaveV3Market(
        address owner,
        address wethUsdFeed
    ) internal {
        AaveV3Roles memory roles = AaveV3Roles(owner, owner, owner);
        AaveV3MarketConfig memory config = AaveV3MarketConfig({
            networkBaseTokenPriceInUsdProxyAggregator: wethUsdFeed,
            marketReferenceCurrencyPriceInUsdProxyAggregator: wethUsdFeed,
            marketId: "Avana Test Network Aave V3 Market",
            oracleDecimals: 8,
            providerId: 8080,
            salt: bytes32(0),
            wrappedNativeToken: address(0),
            flashLoanPremium: AAVE_V3_FLASH_PREMIUM_BPS,
            incentivesProxy: address(0),
            treasury: address(0)
        });
        address setup = _aaveV3Implementations(owner, roles, config);
        AaveV3SetupReport memory market = IAaveV3SetupBatch(setup)
            .setupAaveV3Market(
                roles,
                config,
                aaveV3.poolImplementation,
                aaveV3.poolConfiguratorImplementation,
                aaveV3.aaveOracle,
                aaveV3.rewardsControllerImplementation
            );
        aaveV3.poolProxy = market.poolProxy;
        aaveV3.poolConfiguratorProxy = market.poolConfiguratorProxy;
        aaveV3.rewardsControllerProxy = market.rewardsControllerProxy;
        aaveV3.aclManager = market.aclManager;
        address gettersBatch = _deploy(
            "AaveV3GettersBatchTwo",
            bytes.concat(
                _aaveV3Code("AaveV3GettersBatchTwo.sol", "AaveV3GettersBatchTwo"),
                abi.encode(market.poolProxy, owner, address(0), aaveV3.poolAddressesProvider, false)
            )
        );
        aaveV3.protocolDataProvider = IAaveV3GettersBatchTwo(gettersBatch).getGettersReportTwo().protocolDataProvider;
        IAaveV3SetupBatch(setup).setProtocolDataProvider(aaveV3.protocolDataProvider);
        IAaveV3SetupBatch(setup).transferMarketOwnership(roles);
        address tokensBatch = _deploy(
            "AaveV3TokensBatch",
            bytes.concat(
                _aaveV3Code("AaveV3TokensBatch.sol", "AaveV3TokensBatch"),
                abi.encode(market.poolProxy, market.rewardsControllerProxy, aaveV3.treasury)
            )
        );
        AaveV3TokensReport memory tokensImpl = IAaveV3TokensBatch(tokensBatch).getTokensReport();
        aaveV3.aToken = tokensImpl.aToken;
        aaveV3.variableDebtToken = tokensImpl.variableDebtToken;
        IAaveV3SetupBatch(setup).setMarketReport(aaveV3);
        require(
            IAaveV3PoolSupply(market.poolProxy).FLASHLOAN_PREMIUM_TOTAL() == AAVE_V3_FLASH_PREMIUM_BPS,
            "Aave V3 flash premium not set"
        );
    }

    /// @notice The setup batch (owned by `owner`, the script's sender), the libraries, the pool batch and the periphery
    /// batch; their reports go into `aaveV3`.
    function _aaveV3Implementations(
        address owner,
        AaveV3Roles memory roles,
        AaveV3MarketConfig memory config
    ) private returns (address setup) {
        AaveV3MarketReport memory none;
        setup = _deploy(
            "AaveV3SetupBatch",
            bytes.concat(
                _aaveV3Code("AaveV3SetupBatch.sol", "AaveV3SetupBatch"), abi.encode(owner, roles, config, none)
            )
        );
        AaveV3InitialReport memory initial = IAaveV3SetupBatch(setup).getInitialReport();
        aaveV3.poolAddressesProvider = initial.poolAddressesProvider;
        aaveV3.poolAddressesProviderRegistry = initial.poolAddressesProviderRegistry;
        aaveV3.defaultInterestRateStrategy = initial.interestRateStrategy;
        address poolBatch = _deploy(
            "AaveV3PoolBatch",
            bytes.concat(
                _artifactLinked(
                    AAVE_V3_OUT, "AaveV3PoolBatch.sol", "AaveV3PoolBatch", _aaveV3LibraryNames(), _aaveV3Libraries()
                ),
                abi.encode(initial.poolAddressesProvider, initial.interestRateStrategy)
            )
        );
        AaveV3PoolReport memory pool = IAaveV3PoolBatch(poolBatch).getPoolReport();
        aaveV3.poolImplementation = pool.poolImplementation;
        aaveV3.poolConfiguratorImplementation = pool.poolConfiguratorImplementation;
        address peripheryBatch = _deploy(
            "AaveV3PeripheryBatch",
            bytes.concat(
                _aaveV3Code("AaveV3PeripheryBatch.sol", "AaveV3PeripheryBatch"),
                abi.encode(owner, config, initial.poolAddressesProvider, setup)
            )
        );
        AaveV3PeripheryReport memory periphery = IAaveV3PeripheryBatch(peripheryBatch).getPeripheryReport();
        aaveV3.aaveOracle = periphery.aaveOracle;
        aaveV3.treasury = periphery.treasury;
        aaveV3.treasuryImplementation = periphery.treasuryImplementation;
        aaveV3.emissionManager = periphery.emissionManager;
        aaveV3.rewardsControllerImplementation = periphery.rewardsControllerImplementation;
        aaveV3.emptyImplementation = periphery.emptyImplementation;
        aaveV3.dustBin = periphery.dustBin;
    }

    /// @notice Lists `asset` on the Aave V3 market: aToken and variable debt token, the default rate strategy (80 %
    /// optimal usage, 0 % base, 4 % and 60 % slopes, as Aave's stablecoin reserves), its oracle source and flash loans.
    function _aaveV3List(
        address asset,
        string memory symbol,
        address feed
    ) internal {
        AaveV3InitReserveInput[] memory input = new AaveV3InitReserveInput[](1);
        input[0] = AaveV3InitReserveInput({
            aTokenImpl: aaveV3.aToken,
            variableDebtTokenImpl: aaveV3.variableDebtToken,
            underlyingAsset: asset,
            aTokenName: string.concat("Aave Test ", symbol),
            aTokenSymbol: string.concat("aTest", symbol),
            variableDebtTokenName: string.concat("Aave Test Variable Debt ", symbol),
            variableDebtTokenSymbol: string.concat("variableDebtTest", symbol),
            params: "",
            interestRateData: abi.encode(AaveV3InterestRateData(8000, 0, 400, 6000))
        });
        IAaveV3Configurator(aaveV3.poolConfiguratorProxy).initReserves(input);
        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = asset;
        sources[0] = feed;
        IAaveV3OracleAdmin(aaveV3.aaveOracle).setAssetSources(assets, sources);
        require(IAaveV3OracleAdmin(aaveV3.aaveOracle).getAssetPrice(asset) != 0, "Aave V3 oracle: no price");
        IAaveV3Configurator(aaveV3.poolConfiguratorProxy).setReserveFlashLoaning(asset, true);
    }

    /// @notice Hands every market role and ownership from the deployer (`me`) to `dao` and checks that `me` keeps none.
    function _aaveV3HandOver(
        address me,
        address dao
    ) internal {
        IAaveV3ACLAdmin acl = IAaveV3ACLAdmin(aaveV3.aclManager);
        acl.addPoolAdmin(dao);
        acl.addEmergencyAdmin(dao);
        acl.grantRole(bytes32(0), dao);
        IAaveV3ProviderAdmin(aaveV3.poolAddressesProvider).setACLAdmin(dao);
        IOwnableTransfer(aaveV3.emissionManager).transferOwnership(dao);
        IOwnableTransfer(aaveV3.poolAddressesProvider).transferOwnership(dao);
        IOwnableTransfer(aaveV3.poolAddressesProviderRegistry).transferOwnership(dao);
        if (me != dao) {
            acl.removePoolAdmin(me);
            acl.removeEmergencyAdmin(me);
            acl.renounceRole(bytes32(0), me);
        }
        require(
            acl.hasRole(bytes32(0), dao) && acl.isPoolAdmin(dao) && acl.isEmergencyAdmin(dao)
                && IAaveV3ProviderAdmin(aaveV3.poolAddressesProvider).getACLAdmin() == dao
                && IOwnableTransfer(aaveV3.poolAddressesProvider).owner() == dao
                && IOwnableTransfer(aaveV3.poolAddressesProviderRegistry).owner() == dao
                && IOwnableTransfer(aaveV3.emissionManager).owner() == dao,
            "Aave V3 market not handed to the DAO"
        );
        require(
            me == dao || (!acl.hasRole(bytes32(0), me) && !acl.isPoolAdmin(me) && !acl.isEmergencyAdmin(me)),
            "deployer kept an Aave V3 role"
        );
    }

    /// @notice Supplies `amount` of `asset` (already approved to the Pool) from the deployer.
    function _aaveV3Supply(
        address asset,
        uint256 amount,
        address onBehalfOf
    ) internal returns (address aToken) {
        IAaveV3PoolSupply(aaveV3.poolProxy).supply(asset, amount, onBehalfOf, 0);
        aToken = IAaveV3PoolSupply(aaveV3.poolProxy).getReserveAToken(asset);
    }

    /// @notice The five external logic libraries `PoolInstance` links, in the order of `_aaveV3LibraryNames`.
    function _aaveV3Libraries() private returns (address[] memory libs) {
        libs = new address[](5);
        // AaveV3LibrariesBatch1: BorrowLogic, which FlashLoanLogic links.
        libs[0] = _deploy("AaveV3BorrowLogic", _aaveV3Code("BorrowLogic.sol", "BorrowLogic"));
        // AaveV3LibrariesBatch2: the other four, FlashLoanLogic linked to BorrowLogic.
        string[] memory borrow = new string[](1);
        address[] memory borrowAt = new address[](1);
        borrow[0] = _aaveV3LibraryNames()[0];
        borrowAt[0] = libs[0];
        libs[1] = _deploy(
            "AaveV3FlashLoanLogic",
            _artifactLinked(AAVE_V3_OUT, "FlashLoanLogic.sol", "FlashLoanLogic", borrow, borrowAt)
        );
        libs[2] = _deploy("AaveV3LiquidationLogic", _aaveV3Code("LiquidationLogic.sol", "LiquidationLogic"));
        libs[3] = _deploy("AaveV3PoolLogic", _aaveV3Code("PoolLogic.sol", "PoolLogic"));
        libs[4] = _deploy("AaveV3SupplyLogic", _aaveV3Code("SupplyLogic.sol", "SupplyLogic"));
    }

    function _aaveV3LibraryNames() private pure returns (string[] memory names) {
        names = new string[](5);
        names[0] = string.concat(AAVE_V3_LOGIC, "BorrowLogic.sol:BorrowLogic");
        names[1] = string.concat(AAVE_V3_LOGIC, "FlashLoanLogic.sol:FlashLoanLogic");
        names[2] = string.concat(AAVE_V3_LOGIC, "LiquidationLogic.sol:LiquidationLogic");
        names[3] = string.concat(AAVE_V3_LOGIC, "PoolLogic.sol:PoolLogic");
        names[4] = string.concat(AAVE_V3_LOGIC, "SupplyLogic.sol:SupplyLogic");
    }

    function _aaveV3Code(
        string memory file,
        string memory name
    ) private view returns (bytes memory) {
        return _artifactIn(AAVE_V3_OUT, file, name);
    }
}
