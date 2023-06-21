// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.15;

import {AggregatorV2V3Interface} from "interfaces/AggregatorV2V3Interface.sol";
import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

// Bond Protocol
import {IBondAggregator} from "interfaces/IBondAggregator.sol";
import {IBondSDA} from "interfaces/IBondSDA.sol";
import {IBondTeller} from "interfaces/IBondTeller.sol";

// Balancer
import {IVault, IBasePool, IBalancerHelper} from "policies/BoostedLiquidity/interfaces/IBalancer.sol";

// Aura
import {IAuraBooster, IAuraRewardPool, IAuraMiningLib} from "policies/BoostedLiquidity/interfaces/IAura.sol";

import "src/Kernel.sol";
import {OlympusPrice} from "modules/PRICE/OlympusPrice.sol";
import {OlympusRange} from "modules/RANGE/OlympusRange.sol";
import {OlympusTreasury} from "modules/TRSRY/OlympusTreasury.sol";
import {OlympusMinter} from "modules/MINTR/OlympusMinter.sol";
import {OlympusInstructions} from "modules/INSTR/OlympusInstructions.sol";
import {OlympusRoles} from "modules/ROLES/OlympusRoles.sol";
import {OlympusBoostedLiquidityRegistry} from "modules/BLREG/OlympusBoostedLiquidityRegistry.sol";

import {Operator} from "policies/Operator.sol";
import {OlympusHeart} from "policies/Heart.sol";
import {BondCallback} from "policies/BondCallback.sol";
import {OlympusPriceConfig} from "policies/PriceConfig.sol";
import {RolesAdmin} from "policies/RolesAdmin.sol";
import {TreasuryCustodian} from "policies/TreasuryCustodian.sol";
import {Distributor} from "policies/Distributor.sol";
import {Emergency} from "policies/Emergency.sol";
import {BondManager} from "policies/BondManager.sol";
import {Burner} from "policies/Burner.sol";
import {BLVaultManagerLido} from "policies/BoostedLiquidity/BLVaultManagerLido.sol";
import {BLVaultLido} from "policies/BoostedLiquidity/BLVaultLido.sol";
import {BLVaultManagerLusd} from "policies/BoostedLiquidity/BLVaultManagerLusd.sol";
import {BLVaultLusd} from "policies/BoostedLiquidity/BLVaultLusd.sol";

import {IBLVaultManagerLido} from "policies/BoostedLiquidity/interfaces/IBLVaultManagerLido.sol";
import {IBLVaultManager} from "policies/BoostedLiquidity/interfaces/IBLVaultManager.sol";

import {MockPriceFeed} from "test/mocks/MockPriceFeed.sol";
import {MockAuraBooster, MockAuraRewardPool, MockAuraMiningLib, MockAuraVirtualRewardPool, MockAuraStashToken} from "test/mocks/AuraMocks.sol";
import {MockBalancerPool, MockVault} from "test/mocks/BalancerMocks.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {Faucet} from "test/mocks/Faucet.sol";

import {TransferHelper} from "libraries/TransferHelper.sol";

/// @notice Script to deploy and initialize the Olympus system
/// @dev    The address that this script is broadcast from must have write access to the contracts being configured
contract OlympusDeploy is Script {
    using stdJson for string;
    using TransferHelper for ERC20;
    Kernel public kernel;

    /// Modules
    OlympusPrice public PRICE;
    OlympusRange public RANGE;
    OlympusTreasury public TRSRY;
    OlympusMinter public MINTR;
    OlympusInstructions public INSTR;
    OlympusRoles public ROLES;
    OlympusBoostedLiquidityRegistry public BLREG;

    /// Policies
    Operator public operator;
    OlympusHeart public heart;
    BondCallback public callback;
    OlympusPriceConfig public priceConfig;
    RolesAdmin public rolesAdmin;
    TreasuryCustodian public treasuryCustodian;
    Distributor public distributor;
    Emergency public emergency;
    BondManager public bondManager;
    Burner public burner;
    BLVaultManagerLido public lidoVaultManager;
    BLVaultLido public lidoVault;
    BLVaultManagerLusd public lusdVaultManager;
    BLVaultLusd public lusdVault;

    /// Construction variables

    /// Token addresses
    ERC20 public ohm;
    ERC20 public reserve;
    ERC20 public wsteth;
    ERC20 public lusd;
    ERC20 public aura;
    ERC20 public bal;

    /// Bond system addresses
    IBondSDA public bondAuctioneer;
    IBondSDA public bondFixedExpiryAuctioneer;
    IBondTeller public bondFixedExpiryTeller;
    IBondAggregator public bondAggregator;

    /// Chainlink price feed addresses
    AggregatorV2V3Interface public ohmEthPriceFeed;
    AggregatorV2V3Interface public reserveEthPriceFeed;
    AggregatorV2V3Interface public ethUsdPriceFeed;
    AggregatorV2V3Interface public stethUsdPriceFeed;
    AggregatorV2V3Interface public lusdUsdPriceFeed;

    /// External contracts
    address public staking;
    address public gnosisEasyAuction;

    /// Balancer Contracts
    IVault public balancerVault;
    IBalancerHelper public balancerHelper;
    IBasePool public ohmWstethPool;
    IBasePool public ohmLusdPool;

    /// Aura Contracts
    IAuraBooster public auraBooster;
    IAuraMiningLib public auraMiningLib;
    IAuraRewardPool public ohmWstethRewardsPool;
    IAuraRewardPool public ohmLusdRewardsPool;

    // Deploy system storage
    mapping(string => bytes4) public selectorMap;
    mapping(string => bytes) public argsMap;
    string[] public deployments;
    mapping(string => address) public deployedTo;

    function _setUp(string calldata chain_) internal {
        // Setup contract -> selector mappings
        selectorMap["OlympusPrice"] = this._deployPrice.selector;
        selectorMap["OlympusRange"] = this._deployRange.selector;
        selectorMap["OlympusTreasury"] = this._deployTreasury.selector;
        selectorMap["OlympusMinter"] = this._deployMinter.selector;
        selectorMap["OlympusRoles"] = this._deployRoles.selector;
        selectorMap["OlympusBoostedLiquidityRegistry"] = this._deployBoostedLiquidityRegistry.selector;
        selectorMap["Operator"] = this._deployOperator.selector;
        selectorMap["OlympusHeart"] = this._deployHeart.selector;
        selectorMap["BondCallback"] = this._deployBondCallback.selector;
        selectorMap["OlympusPriceConfig"] = this._deployPriceConfig.selector;
        selectorMap["RolesAdmin"] = this._deployRolesAdmin.selector;
        selectorMap["TreasuryCustodian"] = this._deployTreasuryCustodian.selector;
        selectorMap["Distributor"] = this._deployDistributor.selector;
        selectorMap["Emergency"] = this._deployEmergency.selector;
        selectorMap["BondManager"] = this._deployBondManager.selector;
        selectorMap["Burner"] = this._deployBurner.selector;
        selectorMap["BLVaultLido"] = this._deployBLVaultLido.selector;
        selectorMap["BLVaultManagerLido"] = this._deployBLVaultManagerLido.selector;
        selectorMap["BLVaultLusd"] = this._deployBLVaultLusd.selector;
        selectorMap["BLVaultManagerLusd"] = this._deployBLVaultManagerLusd.selector;

        // Load environment addresses
        string memory env = vm.readFile("./src/scripts/env.json");

        // Non-bophades contracts
        ohm = ERC20(env.readAddress(string.concat(".", chain_, ".olympus.legacy.OHM")));
        reserve = ERC20(env.readAddress(string.concat(".", chain_, ".external.tokens.DAI")));
        wsteth = ERC20(env.readAddress(string.concat(".", chain_, ".external.tokens.WSTETH")));
        lusd = ERC20(env.readAddress(string.concat(".", chain_, ".external.tokens.LUSD")));
        aura = ERC20(env.readAddress(string.concat(".", chain_, ".external.tokens.AURA")));
        bal = ERC20(env.readAddress(string.concat(".", chain_, ".external.tokens.BAL")));
        bondAuctioneer = IBondSDA(env.readAddress(string.concat(".", chain_, ".external.bond-protocol.BondFixedTermAuctioneer")));
        bondFixedExpiryAuctioneer = IBondSDA(env.readAddress(string.concat(".", chain_, ".external.bond-protocol.BondFixedExpiryAuctioneer")));
        bondFixedExpiryTeller = IBondTeller(env.readAddress(string.concat(".", chain_, ".external.bond-protocol.BondFixedExpiryTeller")));
        bondAggregator = IBondAggregator(env.readAddress(string.concat(".", chain_, ".external.bond-protocol.BondAggregator")));
        ohmEthPriceFeed = AggregatorV2V3Interface(env.readAddress(string.concat(".", chain_, ".external.chainlink.ohmEthPriceFeed")));
        reserveEthPriceFeed = AggregatorV2V3Interface(env.readAddress(string.concat(".", chain_, ".external.chainlink.daiEthPriceFeed")));
        ethUsdPriceFeed = AggregatorV2V3Interface(env.readAddress(string.concat(".", chain_, ".external.chainlink.ethUsdPriceFeed")));
        stethUsdPriceFeed = AggregatorV2V3Interface(env.readAddress(string.concat(".", chain_, ".external.chainlink.stethUsdPriceFeed")));
        lusdUsdPriceFeed = AggregatorV2V3Interface(env.readAddress(string.concat(".", chain_, ".external.chainlink.lusdUsdPriceFeed")));
        staking = env.readAddress(string.concat(".", chain_, ".olympus.legacy.Staking"));
        gnosisEasyAuction = env.readAddress(string.concat(".", chain_, ".external.gnosis.EasyAuction"));
        balancerVault = IVault(env.readAddress(string.concat(".", chain_, ".external.balancer.BalancerVault")));
        balancerHelper = IBalancerHelper(env.readAddress(string.concat(".", chain_, ".external.balancer.BalancerHelper")));
        ohmWstethPool = IBasePool(env.readAddress(string.concat(".", chain_, ".external.balancer.OhmWstethPool")));
        ohmLusdPool = IBasePool(env.readAddress(string.concat(".", chain_, ".external.balancer.OhmLusdPool"))); // Populated from: https://github.com/BalancerMaxis/multisig-ops/pull/252
        auraBooster = IAuraBooster(env.readAddress(string.concat(".", chain_, ".external.aura.AuraBooster")));
        auraMiningLib = IAuraMiningLib(env.readAddress(string.concat(".", chain_, ".external.aura.AuraMiningLib")));
        ohmWstethRewardsPool = IAuraRewardPool(env.readAddress(string.concat(".", chain_, ".external.aura.OhmWstethRewardsPool")));
        ohmLusdRewardsPool = IAuraRewardPool(env.readAddress(string.concat(".", chain_, ".external.aura.OhmLusdRewardsPool")));

        // Bophades contracts
        kernel = Kernel(env.readAddress(string.concat(".", chain_, ".olympus.Kernel")));
        PRICE = OlympusPrice(env.readAddress(string.concat(".", chain_, ".olympus.modules.OlympusPrice")));
        RANGE = OlympusRange(env.readAddress(string.concat(".", chain_, ".olympus.modules.OlympusRange")));
        TRSRY = OlympusTreasury(env.readAddress(string.concat(".", chain_, ".olympus.modules.OlympusTreasury")));
        MINTR = OlympusMinter(env.readAddress(string.concat(".", chain_, ".olympus.modules.OlympusMinter")));
        INSTR = OlympusInstructions(env.readAddress(string.concat(".", chain_, ".olympus.modules.OlympusInstructions")));
        ROLES = OlympusRoles(env.readAddress(string.concat(".", chain_, ".olympus.modules.OlympusRoles")));
        BLREG = OlympusBoostedLiquidityRegistry(env.readAddress(string.concat(".", chain_, ".olympus.modules.OlympusBoostedLiquidityRegistry")));
        operator = Operator(env.readAddress(string.concat(".", chain_, ".olympus.policies.Operator")));
        heart = OlympusHeart(env.readAddress(string.concat(".", chain_, ".olympus.policies.OlympusHeart")));
        callback = BondCallback(env.readAddress(string.concat(".", chain_, ".olympus.policies.BondCallback")));
        priceConfig = OlympusPriceConfig(env.readAddress(string.concat(".", chain_, ".olympus.policies.OlympusPriceConfig")));
        rolesAdmin = RolesAdmin(env.readAddress(string.concat(".", chain_, ".olympus.policies.RolesAdmin")));
        treasuryCustodian = TreasuryCustodian(env.readAddress(string.concat(".", chain_, ".olympus.policies.TreasuryCustodian")));
        distributor = Distributor(env.readAddress(string.concat(".", chain_, ".olympus.policies.Distributor")));
        emergency = Emergency(env.readAddress(string.concat(".", chain_, ".olympus.policies.Emergency")));
        bondManager = BondManager(env.readAddress(string.concat(".", chain_, ".olympus.policies.BondManager")));
        burner = Burner(env.readAddress(string.concat(".", chain_, ".olympus.policies.Burner")));
        lidoVaultManager = BLVaultManagerLido(env.readAddress(string.concat(".", chain_, ".olympus.policies.BLVaultManagerLido")));
        lidoVault = BLVaultLido(env.readAddress(string.concat(".", chain_, ".olympus.policies.BLVaultLido")));
        lusdVaultManager = BLVaultManagerLusd(env.readAddress(string.concat(".", chain_, ".olympus.policies.BLVaultManagerLusd")));
        lusdVault = BLVaultLusd(env.readAddress(string.concat(".", chain_, ".olympus.policies.BLVaultLusd")));

        // Load deployment data
        string memory data = vm.readFile("./src/scripts/deploy.json");

        // Parse deployment sequence and names
        string[] memory names = abi.decode(data.parseRaw(".sequence..name"), (string[]));
        uint256 len = names.length;

        // Iterate through deployment sequence and set deployment args
        for (uint256 i = 0; i < len; i++) {
            string memory name = names[i];
            deployments.push(name);
            console2.log("Deploying", name);

            // Parse and store args if not kernel
            // Note: constructor args need to be provided in alphabetical order
            // due to changes with forge-std or a struct needs to be used
            if (keccak256(bytes(name)) != keccak256(bytes("Kernel"))) {
                argsMap[name] = data.parseRaw(string.concat(".sequence[?(@.name == '",name,"')].args"));
            }
           
        }

    }

    /// @dev Installs, upgrades, activations, and deactivations as well as access control settings must be done via olymsig batches since DAO MS is multisig executor on mainnet
    /// @dev If we can get multisig batch functionality in foundry, then we can add to these scripts
    // function _installModule(Module module_) internal {
    //     // Check if module is installed on the kernel and determine which type of install to use
    //     vm.startBroadcast();
    //     if (address(kernel.getModuleForKeycode(module_.KEYCODE())) != address(0)) {
    //         kernel.executeAction(Actions.UpgradeModule, address(module_));
    //     } else {
    //         kernel.executeAction(Actions.InstallModule, address(module_));
    //     }
    //     vm.stopBroadcast();
    // }

    // function _activatePolicy(Policy policy_) internal {
    //     // Check if policy is activated on the kernel and determine which type of activation to use
    //     vm.broadcast();
    //     kernel.executeAction(Actions.ActivatePolicy, address(policy_));
    // }

    function deploy(string calldata chain_, address guardian_, address policy_, address emergency_) external {
        // Setup
        _setUp(chain_);

        // Check that deployments is not empty
        uint256 len = deployments.length;
        require(len > 0, "No deployments");

        // If kernel to be deployed, then it should be first (not included in contract -> selector mappings so it will error out if not first)
        bool deployKernel = keccak256(bytes(deployments[0])) == keccak256(bytes("Kernel"));
        if (deployKernel) {
            vm.broadcast();
            kernel = new Kernel();
            console2.log("Kernel deployed at:", address(kernel));
        }

        // Iterate through deployments
        for (uint256 i = deployKernel ? 1 : 0; i < len; i++) {
            // Get deploy script selector and deploy args from contract name
            string memory name = deployments[i];
            bytes4 selector = selectorMap[name];
            bytes memory args = argsMap[name];

            // Call the deploy function for the contract
            (bool success, bytes memory data) = address(this).call(abi.encodeWithSelector(selector, args));
            require(success, string.concat("Failed to deploy ", deployments[i]));

            // Store the deployed contract address for logging
            deployedTo[name] = abi.decode(data, (address));
        }

        // Save deployments to file
        _saveDeployment(chain_);
    }

    // ========== DEPLOYMENT FUNCTIONS ========== //

    // Module deployment functions
    function _deployPrice(bytes memory args) public returns (address) {
        // Decode arguments for Price module
        (
            uint48 ohmEthUpdateThreshold_,
            uint48 reserveEthUpdateThreshold_,
            uint48 observationFrequency_,
            uint48 movingAverageDuration_,
            uint256 minimumTargetPrice_
        ) = abi.decode(args, (uint48, uint48, uint48, uint48, uint256));

        // Deploy Price module
        vm.broadcast();
        PRICE = new OlympusPrice(
            kernel,
            ohmEthPriceFeed,
            ohmEthUpdateThreshold_,
            reserveEthPriceFeed,
            reserveEthUpdateThreshold_,
            observationFrequency_,
            movingAverageDuration_,
            minimumTargetPrice_
        );
        console2.log("Price deployed at:", address(PRICE));

        return address(PRICE);
    }

    function _deployRange(bytes memory args) public returns (address) {
        // Decode arguments for Range module
        (
            uint256 thresholdFactor,
            uint256 cushionSpread,
            uint256 wallSpread
        ) = abi.decode(args, (uint256, uint256, uint256));

        // Deploy Range module
        vm.broadcast();
        RANGE = new OlympusRange(kernel, ohm, reserve, thresholdFactor, cushionSpread, wallSpread);
        console2.log("Range deployed at:", address(RANGE));

        return address(RANGE);
    }

    function _deployTreasury(bytes memory args) public returns (address) {
        // No additional arguments for Treasury module

        // Deploy Treasury module
        vm.broadcast();
        TRSRY = new OlympusTreasury(kernel);
        console2.log("Treasury deployed at:", address(TRSRY));

        return address(TRSRY);
    }

    function _deployMinter(bytes memory args) public returns (address) {
        // Only args are contracts in the environment

        // Deploy Minter module
        vm.broadcast();
        MINTR = new OlympusMinter(kernel, address(ohm));
        console2.log("Minter deployed at:", address(MINTR));

        return address(MINTR);
    }

    function _deployRoles(bytes memory args) public returns (address) {
        // No additional arguments for Roles module

        // Deploy Roles module
        vm.broadcast();
        ROLES = new OlympusRoles(kernel);
        console2.log("Roles deployed at:", address(ROLES));

        return address(ROLES);
    }

    function _deployBoostedLiquidityRegistry(bytes memory args) public returns (address) {
        // No additional arguments for OlympusBoostedLiquidityRegistry module

        // Deploy OlympusBoostedLiquidityRegistry module
        vm.broadcast();
        BLREG = new OlympusBoostedLiquidityRegistry(kernel);
        console2.log("BLREG deployed at:", address(BLREG));

        return address(BLREG);
    }

    // Policy deployment functions
    function _deployOperator(bytes memory args) public returns (address) {
        // Decode arguments for Operator policy
        // Must use a dynamic array to parse correctly since the json lib defaults to this
        uint32[] memory configParams_ = abi.decode(args, (uint32[]));
        uint32[8] memory configParams = [
            configParams_[0],
            configParams_[1],
            configParams_[2],
            configParams_[3],
            configParams_[4],
            configParams_[5],
            configParams_[6],
            configParams_[7]
        ];

        // Deploy Operator policy
        vm.broadcast();
        operator = new Operator(
            kernel,
            bondAuctioneer,
            callback,
            [ohm, reserve],
            configParams
        );
        console2.log("Operator deployed at:", address(operator));

        return address(operator);
    }

    function _deployBondCallback(bytes memory args) public returns (address) {
        // No additional arguments for BondCallback policy

        // Deploy BondCallback policy
        vm.broadcast();
        callback = new BondCallback(kernel, bondAggregator, ohm);
        console2.log("BondCallback deployed at:", address(callback));

        return address(callback);
    }

    function _deployHeart(bytes memory args) public returns (address) {
        // Decode arguments for OlympusHeart policy
        (uint48 auctionDuration, uint256 maxReward) = abi.decode(args, (uint48, uint256));

        // Deploy OlympusHeart policy
        vm.broadcast();
        heart = new OlympusHeart(kernel, operator, ohm, maxReward, auctionDuration);
        console2.log("OlympusHeart deployed at:", address(heart));

        return address(heart);
    }

    function _deployPriceConfig(bytes memory args) public returns (address) {
        // No additional arguments for PriceConfig policy

        // Deploy PriceConfig policy
        vm.broadcast();
        priceConfig = new OlympusPriceConfig(kernel);
        console2.log("PriceConfig deployed at:", address(priceConfig));

        return address(priceConfig);
    }

    function _deployRolesAdmin(bytes memory args) public returns (address) {
        // No additional arguments for RolesAdmin policy

        // Deploy RolesAdmin policy
        vm.broadcast();
        rolesAdmin = new RolesAdmin(kernel);
        console2.log("RolesAdmin deployed at:", address(rolesAdmin));

        return address(rolesAdmin);
    }

    function _deployTreasuryCustodian(bytes memory args) public returns (address) {
        // No additional arguments for TreasuryCustodian policy

        // Deploy TreasuryCustodian policy
        vm.broadcast();
        treasuryCustodian = new TreasuryCustodian(kernel);
        console2.log("TreasuryCustodian deployed at:", address(treasuryCustodian));

        return address(treasuryCustodian);
    }

    function _deployDistributor(bytes memory args) public returns (address) {
        // Decode arguments for Distributor policy
        uint256 initialRate = abi.decode(args, (uint256));

        // Deploy Distributor policy
        vm.broadcast();
        distributor = new Distributor(kernel, address(ohm), staking, initialRate);
        console2.log("Distributor deployed at:", address(distributor));

        return address(distributor);
    }

    function _deployEmergency(bytes memory args) public returns (address) {
        // No additional arguments for Emergency policy

        // Deploy Emergency policy
        vm.broadcast();
        emergency = new Emergency(kernel);
        console2.log("Emergency deployed at:", address(emergency));

        return address(emergency);
    }

    function _deployBondManager(bytes memory args) public returns(address) {

        // Deploy BondManager policy
        vm.broadcast();
        bondManager = new BondManager(kernel, address(bondFixedExpiryAuctioneer), address(bondFixedExpiryTeller), gnosisEasyAuction, address(ohm));
        console2.log("BondManager deployed at:", address(bondManager));

        return address(bondManager);
    }

    function _deployBurner(bytes memory args) public returns (address) {
        // No additional arguments for Burner policy

        // Deploy Burner policy
        vm.broadcast();
        burner = new Burner(kernel, ohm);
        console2.log("Burner deployed at:", address(burner));

        return address(burner);
    }

    function _deployBLVaultLido(bytes memory args) public returns (address) {
        // No additional arguments for BLVaultLido policy

        // Deploy BLVaultLido policy
        vm.broadcast();
        lidoVault = new BLVaultLido();
        console2.log("BLVaultLido deployed at:", address(lidoVault));

        return address(lidoVault);
    }

    function _deployBLVaultLusd(bytes memory args) public returns (address) {
        // No additional arguments for BLVaultLusd policy

        // Deploy BLVaultLusd policy
        vm.broadcast();
        lusdVault = new BLVaultLusd();
        console2.log("BLVaultLusd deployed at:", address(lusdVault));

        return address(lusdVault);
    }

    // deploy.json was not being parsed correctly, so I had to hardcode most of the deployment arguments
    function _deployBLVaultManagerLido(bytes memory args) public returns (address) {
        // Decode arguments for BLVaultManagerLusd policy
        (uint256 auraPid, uint48 ohmEthFeedUpdateThreshold, uint48 ethUsdFeedUpdateThreshold, uint48 stethUsdFeedUpdateThreshold) = abi.decode(args, (uint256, uint48, uint48, uint48));

        console2.log("ohm", address(ohm));
        console2.log("wsteth", address(wsteth));
        console2.log("aura", address(aura));
        console2.log("bal", address(bal));
        console2.log("balancerVault", address(balancerVault));
        console2.log("ohmWstethPool", address(ohmWstethPool));
        console2.log("balancerHelper", address(balancerHelper));
        console2.log("auraBooster", address(auraBooster));
        console2.log("ohmWstethRewardsPool", address(ohmWstethRewardsPool));
        console2.log("ohmEthPriceFeed", address(ohmEthPriceFeed));
        console2.log("ethUsdPriceFeed", address(ethUsdPriceFeed));
        console2.log("stethUsdPriceFeed", address(stethUsdPriceFeed));
        console2.log("BLV Lido implementation", address(lidoVault));

        // Create TokenData object
        IBLVaultManagerLido.TokenData memory tokenData = IBLVaultManagerLido.TokenData({
            ohm: address(ohm),
            pairToken: address(wsteth),
            aura: address(aura),
            bal: address(bal)
        });

        // Create BalancerData object
        IBLVaultManagerLido.BalancerData memory balancerData = IBLVaultManagerLido.BalancerData({
            vault: address(balancerVault),
            liquidityPool: address(ohmWstethPool),
            balancerHelper: address(balancerHelper)
        });

        // Create AuraData object
        IBLVaultManagerLido.AuraData memory auraData = IBLVaultManagerLido.AuraData({
            pid: auraPid,
            auraBooster: address(auraBooster),
            auraRewardPool: address(ohmWstethRewardsPool)
        });

        // Create OracleFeed objects
        IBLVaultManagerLido.OracleFeed memory ohmEthPriceFeedData = IBLVaultManagerLido.OracleFeed({
            feed: ohmEthPriceFeed,
            updateThreshold: ohmEthFeedUpdateThreshold
        });

        IBLVaultManagerLido.OracleFeed memory ethUsdPriceFeedData = IBLVaultManagerLido.OracleFeed({
            feed: ethUsdPriceFeed,
            updateThreshold: ethUsdFeedUpdateThreshold
        });

        IBLVaultManagerLido.OracleFeed memory stethUsdPriceFeedData = IBLVaultManagerLido.OracleFeed({
            feed: stethUsdPriceFeed,
            updateThreshold: stethUsdFeedUpdateThreshold
        });

        console2.log("pid: ", auraData.pid);
        console2.log("OHM update threshold: ", ohmEthPriceFeedData.updateThreshold);
        console2.log("ETH update threshold: ", ethUsdPriceFeedData.updateThreshold);
        console2.log("stETH update threshold: ", stethUsdPriceFeedData.updateThreshold);


        // Deploy BLVaultManagerLido policy
        vm.broadcast();
        lidoVaultManager = new BLVaultManagerLido(
            kernel,
            tokenData,
            balancerData,
            auraData,
            address(auraMiningLib),
            ohmEthPriceFeedData,
            ethUsdPriceFeedData,
            stethUsdPriceFeedData,
            address(lidoVault),
            476_000e9, // 476_000e9
            uint64(0), // fee
            uint48(1 days) // withdrawal delay
        );
        console2.log("BLVaultManagerLido deployed at:", address(lidoVaultManager));

        return address(lidoVaultManager);
    }

    // deploy.json was not being parsed correctly, so I had to hardcode most of the deployment arguments
    function _deployBLVaultManagerLusd(bytes memory args) public returns (address) {
        // Decode arguments for BLVaultManagerLusd policy
        (uint256 auraPid, uint48 ohmEthFeedUpdateThreshold, uint48 ethUsdFeedUpdateThreshold, uint48 lusdUsdFeedUpdateThreshold) = abi.decode(args, (uint256, uint48, uint48, uint48));

        console2.log("ohm", address(ohm));
        console2.log("lusd", address(lusd));
        console2.log("aura", address(aura));
        console2.log("bal", address(bal));
        console2.log("balancerVault", address(balancerVault));
        console2.log("ohmLusdPool", address(ohmLusdPool));
        console2.log("balancerHelper", address(balancerHelper));
        console2.log("auraBooster", address(auraBooster));
        console2.log("ohmLusdRewardsPool", address(ohmLusdRewardsPool));
        console2.log("ohmEthPriceFeed", address(ohmEthPriceFeed));
        console2.log("ethUsdPriceFeed", address(ethUsdPriceFeed));
        console2.log("lusdUsdPriceFeed", address(lusdUsdPriceFeed));
        console2.log("BLV LUSD implementation", address(lusdVault));

        // Create TokenData object
        IBLVaultManager.TokenData memory tokenData = IBLVaultManager.TokenData({
            ohm: address(ohm),
            pairToken: address(lusd),
            aura: address(aura),
            bal: address(bal)
        });

        // Create BalancerData object
        IBLVaultManager.BalancerData memory balancerData = IBLVaultManager.BalancerData({
            vault: address(balancerVault),
            liquidityPool: address(ohmLusdPool),
            balancerHelper: address(balancerHelper)
        });

        // Create AuraData object
        IBLVaultManager.AuraData memory auraData = IBLVaultManager.AuraData({
            pid: auraPid,
            auraBooster: address(auraBooster),
            auraRewardPool: address(ohmLusdRewardsPool) // determined by calling poolInfo(auraPid) on the booster contract
        });

        // Create OracleFeed objects
        IBLVaultManager.OracleFeed memory ohmEthPriceFeedData = IBLVaultManager.OracleFeed({
            feed: ohmEthPriceFeed,
            updateThreshold: ohmEthFeedUpdateThreshold
        });

        IBLVaultManager.OracleFeed memory ethUsdPriceFeedData = IBLVaultManager.OracleFeed({
            feed: ethUsdPriceFeed,
            updateThreshold: ethUsdFeedUpdateThreshold
        });

        IBLVaultManager.OracleFeed memory lusdUsdPriceFeedData = IBLVaultManager.OracleFeed({
            feed: lusdUsdPriceFeed,
            updateThreshold: lusdUsdFeedUpdateThreshold
        });

        console2.log("pid: ", auraData.pid);
        console2.log("OHM update threshold: ", ohmEthPriceFeedData.updateThreshold);
        console2.log("ETH update threshold: ", ethUsdPriceFeedData.updateThreshold);
        console2.log("LUSD update threshold: ", lusdUsdPriceFeedData.updateThreshold);


        // Deploy BLVaultManagerLusd policy
        vm.broadcast();
        lusdVaultManager = new BLVaultManagerLusd(
            kernel,
            tokenData,
            balancerData,
            auraData,
            address(auraMiningLib),
            ohmEthPriceFeedData,
            ethUsdPriceFeedData,
            lusdUsdPriceFeedData,
            address(lusdVault),
            // 2500000 cap/$10.84 = 230,627.3062730627 OHM
            230_627e9, // max OHM minted
            uint64(500), // fee // 10_000 = 1 = 100%, 500 / 1e4 = 0.05 = 5%
            uint48(1 days) // withdrawal delay
        );
        console2.log("BLVaultManagerLusd deployed at:", address(lusdVaultManager));

        return address(lusdVaultManager);
    }

    /// @dev Verifies that the environment variable addresses were set correctly following deployment
    /// @dev Should be called prior to verifyAndPushAuth()
    function verifyKernelInstallation() external {
        kernel = Kernel(vm.envAddress("KERNEL"));

        /// Modules
        PRICE = OlympusPrice(vm.envAddress("PRICE"));
        RANGE = OlympusRange(vm.envAddress("RANGE"));
        TRSRY = OlympusTreasury(vm.envAddress("TRSRY"));
        MINTR = OlympusMinter(vm.envAddress("MINTR"));
        ROLES = OlympusRoles(vm.envAddress("ROLES"));

        /// Policies
        operator = Operator(vm.envAddress("OPERATOR"));
        heart = OlympusHeart(vm.envAddress("HEART"));
        callback = BondCallback(vm.envAddress("CALLBACK"));
        priceConfig = OlympusPriceConfig(vm.envAddress("PRICECONFIG"));
        rolesAdmin = RolesAdmin(vm.envAddress("ROLESADMIN"));
        treasuryCustodian = TreasuryCustodian(vm.envAddress("TRSRYCUSTODIAN"));
        distributor = Distributor(vm.envAddress("DISTRIBUTOR"));
        emergency = Emergency(vm.envAddress("EMERGENCY"));

        /// Check that Modules are installed
        /// PRICE
        Module priceModule = kernel.getModuleForKeycode(toKeycode("PRICE"));
        Keycode priceKeycode = kernel.getKeycodeForModule(PRICE);
        require(priceModule == PRICE);
        require(fromKeycode(priceKeycode) == "PRICE");

        /// RANGE
        Module rangeModule = kernel.getModuleForKeycode(toKeycode("RANGE"));
        Keycode rangeKeycode = kernel.getKeycodeForModule(RANGE);
        require(rangeModule == RANGE);
        require(fromKeycode(rangeKeycode) == "RANGE");

        /// TRSRY
        Module trsryModule = kernel.getModuleForKeycode(toKeycode("TRSRY"));
        Keycode trsryKeycode = kernel.getKeycodeForModule(TRSRY);
        require(trsryModule == TRSRY);
        require(fromKeycode(trsryKeycode) == "TRSRY");

        /// MINTR
        Module mintrModule = kernel.getModuleForKeycode(toKeycode("MINTR"));
        Keycode mintrKeycode = kernel.getKeycodeForModule(MINTR);
        require(mintrModule == MINTR);
        require(fromKeycode(mintrKeycode) == "MINTR");

        /// ROLES
        Module rolesModule = kernel.getModuleForKeycode(toKeycode("ROLES"));
        Keycode rolesKeycode = kernel.getKeycodeForModule(ROLES);
        require(rolesModule == ROLES);
        require(fromKeycode(rolesKeycode) == "ROLES");

        /// Policies
        require(kernel.isPolicyActive(operator));
        require(kernel.isPolicyActive(heart));
        require(kernel.isPolicyActive(callback));
        require(kernel.isPolicyActive(priceConfig));
        require(kernel.isPolicyActive(rolesAdmin));
        require(kernel.isPolicyActive(treasuryCustodian));
        require(kernel.isPolicyActive(distributor));
        require(kernel.isPolicyActive(emergency));
    }

    /// @dev Should be called by the deployer address after deployment
    function verifyAndPushAuth(address guardian_, address policy_, address emergency_) external {
        ROLES = OlympusRoles(vm.envAddress("ROLES"));
        heart = OlympusHeart(vm.envAddress("HEART"));
        callback = BondCallback(vm.envAddress("CALLBACK"));
        operator = Operator(vm.envAddress("OPERATOR"));
        rolesAdmin = RolesAdmin(vm.envAddress("ROLESADMIN"));
        kernel = Kernel(vm.envAddress("KERNEL"));

        /// Operator Roles
        require(ROLES.hasRole(address(heart), "operator_operate"));
        require(ROLES.hasRole(guardian_, "operator_operate"));
        require(ROLES.hasRole(address(callback), "operator_reporter"));
        require(ROLES.hasRole(policy_, "operator_policy"));
        require(ROLES.hasRole(guardian_, "operator_admin"));

        /// Callback Roles
        require(ROLES.hasRole(address(operator), "callback_whitelist"));
        require(ROLES.hasRole(policy_, "callback_whitelist"));
        require(ROLES.hasRole(guardian_, "callback_admin"));

        /// Heart Roles
        require(ROLES.hasRole(policy_, "heart_admin"));

        /// PriceConfig Roles
        require(ROLES.hasRole(guardian_, "price_admin"));
        require(ROLES.hasRole(policy_, "price_admin"));

        /// TreasuryCustodian Roles
        require(ROLES.hasRole(guardian_, "custodian"));

        /// Distributor Roles
        require(ROLES.hasRole(policy_, "distributor_admin"));

        /// Emergency Roles
        require(ROLES.hasRole(emergency_, "emergency_shutdown"));
        require(ROLES.hasRole(guardian_, "emergency_restart"));


        /// Push rolesAdmin and Executor
        vm.startBroadcast();
        rolesAdmin.pushNewAdmin(guardian_);
        kernel.executeAction(Actions.ChangeExecutor, guardian_);
        vm.stopBroadcast();
    }

    /// @dev Should be called by the deployer address after deployment
    function verifyAuth(address guardian_, address policy_, address emergency_) external {
        ROLES = OlympusRoles(vm.envAddress("ROLES"));
        heart = OlympusHeart(vm.envAddress("HEART"));
        callback = BondCallback(vm.envAddress("CALLBACK"));
        operator = Operator(vm.envAddress("OPERATOR"));
        rolesAdmin = RolesAdmin(vm.envAddress("ROLESADMIN"));
        kernel = Kernel(vm.envAddress("KERNEL"));
        bondManager = BondManager(vm.envAddress("BONDMANAGER"));
        burner = Burner(vm.envAddress("BURNER"));

        /// Operator Roles
        require(ROLES.hasRole(address(heart), "operator_operate"));
        require(ROLES.hasRole(guardian_, "operator_operate"));
        require(ROLES.hasRole(address(callback), "operator_reporter"));
        require(ROLES.hasRole(policy_, "operator_policy"));
        require(ROLES.hasRole(guardian_, "operator_admin"));

        /// Callback Roles
        require(ROLES.hasRole(address(operator), "callback_whitelist"));
        require(ROLES.hasRole(policy_, "callback_whitelist"));
        require(ROLES.hasRole(guardian_, "callback_admin"));

        /// Heart Roles
        require(ROLES.hasRole(policy_, "heart_admin"));

        /// PriceConfig Roles
        require(ROLES.hasRole(guardian_, "price_admin"));
        require(ROLES.hasRole(policy_, "price_admin"));

        /// TreasuryCustodian Roles
        require(ROLES.hasRole(guardian_, "custodian"));

        /// Distributor Roles
        require(ROLES.hasRole(policy_, "distributor_admin"));

        /// Emergency Roles
        require(ROLES.hasRole(emergency_, "emergency_shutdown"));
        require(ROLES.hasRole(guardian_, "emergency_restart"));

        /// BondManager Roles
        require(ROLES.hasRole(policy_, "bondmanager_admin"));

        /// Burner Roles
        require(ROLES.hasRole(guardian_, "burner_admin"));
    }

    function _saveDeployment(string memory chain_) internal {
        // Create file path
        string memory file = string.concat("./deployments/", ".", chain_, "-", vm.toString(block.timestamp), ".json");

        // Write deployment info to file in JSON format
        vm.writeLine(file, "{");
        
        // Iterate through the contracts that were deployed and write their addresses to the file
        uint256 len = deployments.length;
        for (uint256 i; i < len; ++i) {
            vm.writeLine(
                file,
                string.concat('"', deployments[i], '": "', vm.toString(deployedTo[deployments[i]]), '",')
            );
        }
        vm.writeLine(file, "}");
    }
}

/// @notice Deploys mock Balancer and Aura contracts for testing on Goerli
contract DependencyDeployLido is Script {
    using stdJson for string;

    // MockPriceFeed public ohmEthPriceFeed;
    // MockPriceFeed public reserveEthPriceFeed;
    ERC20 public bal;
    ERC20 public aura;
    ERC20 public ldo;
    MockAuraStashToken public ldoStash;

    IBasePool public ohmWstethPool;
    MockAuraBooster public auraBooster;
    MockAuraMiningLib public auraMiningLib;
    MockAuraRewardPool public ohmWstethRewardPool;
    MockAuraVirtualRewardPool public ohmWstethExtraRewardPool;

    function deploy(string calldata chain_) external {
        // Load environment addresses
        string memory env = vm.readFile("./src/scripts/env.json");
        bal = ERC20(env.readAddress(string.concat(".", chain_, ".external.tokens.BAL")));
        aura = ERC20(env.readAddress(string.concat(".", chain_, ".external.tokens.AURA")));
        ldo = ERC20(env.readAddress(string.concat(".", chain_, ".external.tokens.LDO")));
        ohmWstethPool = IBasePool(env.readAddress(string.concat(".", chain_, ".external.balancer.OhmWstethPool")));

        vm.startBroadcast();

        // Deploy the mock tokens
        // bal = new MockERC20("Balancer", "BAL", 18);
        // console2.log("BAL deployed to:", address(bal));

        // aura = new MockERC20("Aura", "AURA", 18);
        // console2.log("AURA deployed to:", address(aura));

        // ldo = new MockERC20("Lido", "LDO", 18);
        // console2.log("LDO deployed to:", address(ldo));

        // Deploy the Aura Reward Pools for OHM-wstETH
        ohmWstethRewardPool = new MockAuraRewardPool(
            address(ohmWstethPool), // Goerli OHM-wstETH LP
            address(bal), // Goerli BAL
            address(aura) // Goerli AURA
        );
        console2.log("OHM-WSTETH Reward Pool deployed to:", address(ohmWstethRewardPool));

        // Deploy the extra rewards pool
        ldoStash = new MockAuraStashToken("Lido-Stash", "LDOSTASH", 18, address(ldo));
        console2.log("Lido Stash deployed to:", address(ldoStash));

        ohmWstethExtraRewardPool = new MockAuraVirtualRewardPool(
            address(ohmWstethPool), // Goerli OHM-wstETH LP
            address(ldoStash)
        );
        console2.log("OHM-WSTETH Extra Reward Pool deployed to:", address(ohmWstethExtraRewardPool));

        ohmWstethRewardPool.addExtraReward(address(ohmWstethExtraRewardPool));
        console2.log("Added OHM-WSTETH Extra Reward Pool to OHM-WSTETH Reward Pool");

        // Deploy Aura Booster
        auraBooster = new MockAuraBooster(address(ohmWstethRewardPool));
        console2.log("Aura Booster deployed to:", address(auraBooster));

        // Deploy the Aura Mining Library
        // auraMiningLib = new MockAuraMiningLib();
        // console2.log("Aura Mining Library deployed to:", address(auraMiningLib));

        // // Deploy the price feeds
        // ohmEthPriceFeed = new MockPriceFeed();
        // console2.log("OHM-ETH Price Feed deployed to:", address(ohmEthPriceFeed));
        // reserveEthPriceFeed = new MockPriceFeed();
        // console2.log("RESERVE-ETH Price Feed deployed to:", address(reserveEthPriceFeed));

        // // Set the decimals of the price feeds
        // ohmEthPriceFeed.setDecimals(18);
        // reserveEthPriceFeed.setDecimals(18);

        vm.stopBroadcast();
    }
}

contract DependencyDeployLusd is Script {
    using stdJson for string;

    ERC20 public bal;
    ERC20 public aura;
    ERC20 public ldo;
    ERC20 public lusd;

    MockAuraBooster public auraBooster;

    MockPriceFeed public lusdUsdPriceFeed;
    IBasePool public ohmLusdPool;
    MockAuraRewardPool public ohmLusdRewardPool;

    MockAuraMiningLib public auraMiningLib;

    function deploy(string calldata chain_) external {
        // Load environment addresses
        string memory env = vm.readFile("./src/scripts/env.json");
        bal = ERC20(env.readAddress(string.concat(".", chain_, ".external.tokens.BAL")));
        aura = ERC20(env.readAddress(string.concat(".", chain_, ".external.tokens.AURA")));
        ldo = ERC20(env.readAddress(string.concat(".", chain_, ".external.tokens.LDO")));
        lusd = ERC20(env.readAddress(string.concat(".", chain_, ".external.tokens.LUSD"))); // Requires the address of LUSD to be less than the address of OHM, in order to reflect the conditions on mainnet
        ohmLusdPool = IBasePool(env.readAddress(string.concat(".", chain_, ".external.balancer.OhmLusdPool"))); // Real pool, deployed separately as it's a little more complicated
        auraBooster = MockAuraBooster(env.readAddress(string.concat(".", chain_, ".external.aura.AuraBooster"))); // Requires DependencyDeployLido to be run first

        vm.startBroadcast();

        // Deploy the LUSD price feed
        lusdUsdPriceFeed = new MockPriceFeed();
        lusdUsdPriceFeed.setDecimals(8);
        lusdUsdPriceFeed.setLatestAnswer(1e8);
        lusdUsdPriceFeed.setRoundId(1);
        lusdUsdPriceFeed.setAnsweredInRound(1);
        lusdUsdPriceFeed.setTimestamp(block.timestamp); // Will be good for 1 year from now
        console2.log("LUSD-USD Price Feed deployed to:", address(lusdUsdPriceFeed));

        // Deploy the Aura Reward Pools for OHM-LUSD
        ohmLusdRewardPool = new MockAuraRewardPool(
            address(ohmLusdPool), // OHM-LUSD LP
            address(bal), // BAL
            address(aura) // AURA
        );
        console2.log("OHM-LUSD LP reward pool deployed to: ", address(ohmLusdRewardPool));

        // Add the pool to the aura booster
        auraBooster.addPool(address(ohmLusdRewardPool));
        console2.log("Added ohmLusdRewardPool to Aura Booster");

        vm.stopBroadcast();
    }
}