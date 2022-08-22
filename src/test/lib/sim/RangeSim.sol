// SPDX-License-Identifier: Unlicense
pragma solidity >=0.8.0;

import {Vm} from "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";

import {BondFixedTermCDA} from "test/lib/bonds/BondFixedTermCDA.sol";
import {BondAggregator} from "test/lib/bonds/BondAggregator.sol";
import {BondFixedTermTeller} from "test/lib/bonds/BondFixedTermTeller.sol";
import {RolesAuthority, Authority} from "solmate/auth/authorities/RolesAuthority.sol";

import "src/Kernel.sol";
import {OlympusPrice} from "modules/PRICE.sol";
import {OlympusRange} from "modules/RANGE.sol";
import {OlympusTreasury} from "modules/TRSRY.sol";
import {OlympusMinter} from "modules/MINTR.sol";
import {OlympusInstructions} from "modules/INSTR.sol";
import {OlympusVotes} from "modules/VOTES.sol";

import {Operator} from "policies/Operator.sol";
import {OlympusHeart} from "policies/Heart.sol";
import {BondCallback} from "policies/BondCallback.sol";
import {OlympusPriceConfig} from "policies/PriceConfig.sol";
import {MockPriceFeed} from "test/mocks/MockPriceFeed.sol";

import {TransferHelper} from "libraries/TransferHelper.sol";
import {FullMath} from "libraries/FullMath.sol";

library SimIO {
    Vm internal constant vm = Vm(address(bytes20(uint160(uint256(keccak256("hevm cheat code"))))));

    // Some fancy math to convert a uint into a string, courtesy of Provable Things.
    // Updated to work with solc 0.8.0.
    // https://github.com/provable-things/ethereum-api/blob/master/provableAPI_0.6.sol
    function _uint2bstr(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) {
            return "0";
        }
        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - (_i / 10) * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return bstr;
    }

    function _loadData(
        string memory script,
        string memory query,
        string memory path
    ) internal returns (bytes memory response) {
        string[] memory inputs = new string[](3);
        inputs[0] = "sh";
        inputs[1] = "-c";
        inputs[2] = string(
            bytes.concat(
                "./src/test/lib/sim/",
                bytes(script),
                " ",
                bytes(query),
                " ",
                bytes(path),
                ""
            )
        );
        bytes memory response = vm.ffi(inputs);
    }

    struct Params {
        uint32 key;
        uint32 maxLiqRatio;
        uint32 reserveFactor;
        uint32 cushionFactor;
        uint32 wallSpread;
        uint32 cushionSpread;
    }

    function getSimParams(uint32 seed) external returns (Params[] memory params) {
        string memory script = "loadParams.sh";
        string memory query = string(
            bytes.concat(
                "'[.[] | { key: tonumber(.key | lstrtrim(\"",
                _uint2bstr(uint256(seed)),
                "\")), maxLiqRatio: tonumber(.maxLiqRatio) * 10000, reserveFactor: tonumber(.askFactor) * 10000, cushionFactor: tonumber(.cushionFactor) * 10000, wallSpread: tonumber(.wall) * 10000, cushionSpread: tonumber(.cushion) * 10000 }]'",
                ""
            )
        );
        string memory path = "./src/test/sim/params.json";
        bytes memory res = loadData(query, path);
        params = abi.decode(res, Params[]);
    }

    struct Netflow {
        uint32 key;
        int256 netflow;
    }

    function getNetflows(uint32 seed) external returns (Netflow[] memory netflows) {
        string memory script = "loadNetflows.sh";
        string memory query = string(
            bytes.concat(
                "'[.[] | { key: tonumber(.key | lstrtrim(\"",
                _uint2bstr(uint256(seed)),
                "\")), netflow: tonumber(.netflow) }]'",
                ""
            )
        );
        string memory path = "./src/test/sim/netflows.json";
        bytes memory res = loadData(query, path);
        netflows = abi.decode(res, Netflow[]);
    }

    // TODO work with R&D to get all the data they need out
    struct Result {
        uint32 key;
        uint32 epoch;
        uint256 marketCap;
        uint256 price;
        uint256 reserves;
        uint256 liqRatio;
        uint256 supply;
    }

    function writeSimResults(uint32 seed, Result[] memory results) external {
        bytes memory data = "[";
        uint256 len = results.length;
        for (uint256 i; i < len; ) {
            if (i > 0) {
                data = bytes.concat(data, ",");
            }
            data = bytes.concat(
                data,
                "{seed: ",
                _uint2bstr(uint256(seed)),
                ", key: ",
                _uint2bstr(uint256(results[i].key)),
                ", epoch: ",
                _uint2bstr(uint256(results[i].epoch)),
                ", marketCap: ",
                _uint2bstr(results[i].marketCap),
                ", price: ",
                _uint2bstr(results[i].price),
                ", reserves: ",
                _uint2bstr(results[i].reserves),
                ", liqRatio: ",
                _uint2bstr(results[i].liqRatio),
                ", supply: ",
                _uint2bstr(results[i].supply),
                "}"
            );
            unchecked {
                i++;
            }
        }
        data = bytes.concat(data, "]");
        vm.writeFile("./src/test/sim/results.json", string(data));
    }
}

abstract contract RangeSim is Test {
    /* ========== RANGE SYSTEM CONTRACTS ========== */

    Kernel public kernel;
    OlympusPrice public price;
    OlympusRange public range;
    OlympusTreasury public treasury;
    OlympusMinter public minter;
    Operator public operator;
    BondCallback public bondCallback;
    Heart public heart;

    mapping(uint32 => SimIO.Params) internal params; // map of sim keys to sim params
    mapping(uint32 => mapping(uint32 => int256)) internal netflows; // map of sim keys to epochs to netflows
    mapping(uint32 => mapping(uint32 => SimIO.Result)) internal results; // map of sim keys to epochs to results

    /* ========== EXTERNAL CONTRACTS  ========== */

    using FullMath for uint256;

    UserFactory public userCreator;
    address internal alice;
    address internal bob;
    address internal guardian;
    address internal policy;
    address internal heart;

    RolesAuthority internal auth;
    BondAggregator internal aggregator;
    BondFixedTermTeller internal teller;
    BondFixedTermCDA internal auctioneer;
    MockOhm internal ohm;
    MockERC20 internal reserve;

    /* ========== SETUP ========== */

    /// @dev Determines which data is pulled from the input files and allows writing results to compare against the same seed.
    function SEED() internal pure virtual returns (uint32);

    /// @dev Number of sims to perform with the seed. It should match the number of keys.
    function KEYS() internal pure virtual returns (uint32);

    /// @dev Number of epochs to run each simulation for.
    function EPOCHS() internal pure virtual returns (uint32);

    function setUp() public {
        // Deploy dependencies and setup users for simulation

        vm.warp(51 * 365 * 24 * 60 * 60); // Set timestamp at roughly Jan 1, 2021 (51 years since Unix epoch)
        userCreator = new UserFactory();
        {
            // Deploy bond system
            address[] memory users = userCreator.create(5);
            alice = users[0];
            bob = users[1];
            guardian = users[2];
            policy = users[3];
            heart = users[4];
            auth = new RolesAuthority(guardian, SolmateAuthority(address(0)));

            // Deploy the bond system
            aggregator = new BondAggregator(guardian, auth);
            teller = new BondFixedTermTeller(guardian, aggregator, guardian, auth);
            auctioneer = new BondFixedTermCDA(teller, aggregator, guardian, auth);

            // Register auctioneer on the bond system
            vm.prank(guardian);
            aggregator.registerAuctioneer(auctioneer);
        }

        {
            // Deploy mock tokens
            ohm = new MockOhm("Olympus", "OHM", 9);
            reserve = new MockERC20("Reserve", "RSV", 18);
        }

        {
            // Deploy liquidity pool
            // TODO
        }

        {
            // Load sim data
            SimIO.Params[] memory paramArray = SimIO.getSimParams(SEED());
            uint256 paramLen = paramArray.length;
            for (uint256 i; i < paramLen; ) {
                params[paramArray[i].key] = paramArray[i];
                unchecked {
                    i++;
                }
            }

            // Load netflows data
            SimIO.Netflow[] memory netflowArray = SimIO.getNetflows(SEED());
            uint256 netflowLen = netflowArray.length;
            for (uint256 j; j < netflowLen; ) {
                netflows[netflowArray[j].key][netflowArray[j].epoch] = netflowArray[j].netflow;
                unchecked {
                    j++;
                }
            }
        }
    }

    // struct PriceParams {
    //     uint48 frequency;
    //     uint48 duration;
    //     uint256 startPrice; // TODO: Need to determine what units to provide in
    // }

    // struct OperatorParams {
    //     uint32 cushionFactor;
    //     uint32 cushionDuration;
    //     uint32 cushionDebtBuffer;
    //     uint32 cushionDepositInterval;
    //     uint32 reserveFactor;
    //     uint32 regenWait;
    //     uint32 regenThreshold;
    //     uint32 regenObserve;
    // }

    // struct ReserveParams {
    //     uint256 startReserves; // total start reserves
    //     uint32 reservesInLiquidity; // percent with 2 decimals, i.e. 100 = 1%.
    // }

    // struct RangeParams {
    //     OperatorParams operatorParams;
    //     PriceParams priceParams;
    //     ReserveParams reserveParams;
    // }

    function rangeSetup(uint32 key) public {
        // Deploy the range system with the simulation parameters

        // Get the simulation parameters
        SimIO.Params memory _params = params[key];

        {
            /// Deploy kernel
            kernel = new Kernel(); // this contract will be the executor

            /// Deploy modules (some mocks)
            price = new MockPrice(kernel, uint48(8 hours));
            range = new OlympusRange(
                kernel,
                [ERC20(ohm), ERC20(reserve)],
                [uint256(100), uint256(1000), uint256(2000)]
            );
            treasury = new OlympusTreasury(kernel);
            minter = new OlympusMinter(kernel, address(ohm));

            /// Configure mocks
            price.setMovingAverage(100 * 1e18);
            price.setLastPrice(100 * 1e18);
            price.setDecimals(18);
        }

        {
            /// Deploy bond callback
            callback = new BondCallback(kernel, IBondAggregator(address(aggregator)), ohm);

            /// Deploy operator
            operator = new Operator(
                kernel,
                IBondAuctioneer(address(auctioneer)),
                callback,
                [ERC20(ohm), ERC20(reserve)],
                [
                    uint32(2000), // cushionFactor
                    uint32(5 days), // duration
                    uint32(100_000), // debtBuffer
                    uint32(1 hours), // depositInterval
                    uint32(1000), // reserveFactor
                    uint32(1 hours), // regenWait
                    uint32(5), // regenThreshold
                    uint32(7) // regenObserve
                ]
            );

            /// Registor operator to create bond markets with a callback
            vm.prank(guardian);
            auctioneer.setCallbackAuthStatus(address(operator), true);
        }

        {
            /// Initialize system and kernel

            /// Install modules
            kernel.executeAction(Actions.InstallModule, address(price));
            kernel.executeAction(Actions.InstallModule, address(range));
            kernel.executeAction(Actions.InstallModule, address(treasury));
            kernel.executeAction(Actions.InstallModule, address(minter));

            /// Approve policies
            kernel.executeAction(Actions.ActivatePolicy, address(operator));
            kernel.executeAction(Actions.ActivatePolicy, address(callback));
        }
        {
            /// Configure access control

            /// Operator roles
            kernel.grantRole(toRole("operator_operate"), address(heart));
            kernel.grantRole(toRole("operator_operate"), guardian);
            kernel.grantRole(toRole("operator_reporter"), address(callback));
            kernel.grantRole(toRole("operator_policy"), policy);
            kernel.grantRole(toRole("operator_admin"), guardian);

            /// Bond callback roles
            kernel.grantRole(toRole("callback_whitelist"), address(operator));
            kernel.grantRole(toRole("callback_whitelist"), guardian);
            kernel.grantRole(toRole("callback_admin"), guardian);
        }

        /// Set operator on the callback
        vm.prank(guardian);
        callback.setOperator(operator);

        // Mint tokens to users and treasury for testing
        uint256 testOhm = 1_000_000 * 1e9;
        uint256 testReserve = 1_000_000 * 1e18;

        ohm.mint(alice, testOhm * 20);
        reserve.mint(alice, testReserve * 20);

        reserve.mint(address(treasury), testReserve * 100);

        // Approve the operator and bond teller for the tokens to swap
        vm.prank(alice);
        ohm.approve(address(operator), testOhm * 20);
        vm.prank(alice);
        reserve.approve(address(operator), testReserve * 20);

        vm.prank(alice);
        ohm.approve(address(teller), testOhm * 20);
        vm.prank(alice);
        reserve.approve(address(teller), testReserve * 20);
    }

    /* ========== SIMULATION HELPER FUNCTIONS ========== */
    function getRebasePercent(uint32 key) internal view returns (uint256) {
        // Implement the current reward rate framework based on supply
    }

    /// @dev Simulating rebases by minting OHM to the market account (at 80% rate) and the liquidity pool
    function rebase(uint32 key) internal {
        perc = getRebasePercent(key);

        // Mint OHM to the market account
        vm.startPrank(address(minter));
        ohm.mint(market, (((ohm.balanceOf(market) * 8) / 10) * perc) / 10000);

        // Mint OHM to the liquidity pool and sync the balances
        (, uint256[] memory balances, ) = vault.getPoolTokens(pool.getPoolId());

        ohm.mint(pool, (balances[0] * perc) / 10000); // TODO Need to use the proper balancer method for getting a pool balance
        vm.stopPrank();

        // Sync the pool balances
        pool.sync(); // TODO Need to use the proper balancer method for syncing a pool
    }

    /// Putting these structs here as placeholders until I create 0.8.0 versions of the balancer pool and vault interface
    /// Idea is to deploy a pool on testnet with minimal liquidity and then fork testnet for the local sims since balancer is deployed there
    enum SwapKind {
        GIVEN_IN,
        GIVEN_OUT
    }

    struct BatchSwapStep {
        bytes32 poolId;
        uint256 assetInIndex;
        uint256 assetOutIndex;
        uint256 amount;
        bytes userData;
    }

    struct FundManagement {
        address sender;
        bool fromInternalBalance;
        address payable recipient;
        bool toInternalBalance;
    }

    enum Variable {
        PAIR_PRICE,
        BPT_PRICE,
        INVARIANT
    }

    /// @notice Creates a convenient abstraction on the balancer interface for single swaps between OHM and Reserve
    /// @param sender Account to send the swap from and receive the amount out
    /// @param reserveIn Whether the reserve token is being sent in (true) or received from (false) the swap
    /// @param amount Amount of reserves to get in or out
    /// @dev Ensure tokens are approved on the balancer vault already to avoid allowance errors
    function swap(
        address sender,
        bool reserveIn,
        uint256 amount
    ) internal {
        // Create structs for balancer swap
        FundsManagement memory funds = FundsManagement(sender, false, sender, false);

        if (reserveIn) {
            int256 amountIn = int256(amount);

            BatchSwapStep memory swapStep = BatchSwapStep(pool.getPoolId(), 1, 0, amount, bytes(0));

            BatchSwapStep[] memory steps = new BatchSwapStep[](1);
            steps[0] = swapStep;

            IAssets[] memory assets = new IAssets[](2);
            assets[0] = IAsset(ohm);
            assets[1] = IAsset(reserve);

            // Get amount need to be sent in to get amount of reserves out
            vm.prank(sender);
            (int256 ohmDelta, ) = vault.queryBatchSwap(SwapKind.GIVEN_IN, steps, assets, funds);
            int256 amountOut = (ohmDelta * -9) / 10; // reduce by 10% for slippage

            // Set limits: amount going in must be positive and amount going out should be negative
            int256[] memory limits = new int256[](2);
            limits[0] = amountOut;
            limits[1] = amountIn;

            vm.prank(sender);
            vault.batchSwap(
                SwapKind.GIVEN_IN,
                steps,
                assets,
                funds,
                limits,
                block.timestamp + 1 days
            );
        } else {
            int256 amountOut = int256(amount) * int256(-1);

            BatchSwapStep memory swapStep = BatchSwapStep(pool.getPoolId(), 0, 1, amount, bytes(0));

            BatchSwapStep[] memory steps = new BatchSwapStep[](1);
            steps[0] = swapStep;

            IAssets[] memory assets = new IAssets[](2);
            assets[0] = IAsset(ohm);
            assets[1] = IAsset(reserve);

            // Get amount need to be sent in to get amount of reserves out
            vm.prank(sender);
            (int256 ohmDelta, ) = vault.queryBatchSwap(SwapKind.GIVEN_OUT, steps, assets, funds);
            int256 amountIn = (ohmDelta * 11) / 10; // add 10% for slippage

            // In the case where we are selling OHM, it will need to minted before swapping
            address minter = address(clones[key].minter);
            vm.prank(minter);
            ohm.mint(sender, amountIn);

            int256[] memory limits = new int256[](2);
            limits[0] = amountIn;
            limits[1] = amountOut;

            vm.prank(sender);
            vault.batchSwap(
                SwapKind.GIVEN_OUT,
                steps,
                assets,
                funds,
                limits,
                block.timestamp + 1 days
            );
        }
    }

    function rebalanceLiquidity(uint32 key) internal {
        // Get current liquidity ratio
        address treasury = address(clones[key].treasury);

        uint256 reservesInTreasury = reserve.balanceOf(treasury);
        uint256 reservesInLiquidity = reserve.balanceOf(liquidityPool); // TODO - need to change. won't work with balancer since all tokens in vault
        uint256 reservesInTotal = reservesInTreasury + reservesInLiquidity;

        uint32 liquidityRatio = uint32((reservesInLiquidity * 1e4) / reservesInTotal);

        // Get the target ratio
        uint32 targetRatio = uint32(params[key].maxLiquidityRatio);

        // Compare ratios and calculate swap amount
        // If ratio is too low, sell reserves into the liquidity pool
        // If ratio is too high, buy reserves from the liquidity pool
        // Currently just doing one big atomic swap

        if (liquidityRatio < targetRatio) {
            // Sell reserves into the liquidity pool
            uint256 amountIn = (reservesInTotal * targetRatio) / 1e4 - reservesInLiquidity;
            swap(treasury, true, amountIn);
        } else if (liquidityRatio > targetRatio) {
            // Buy reserves from the liquidity pool
            uint256 amountOut = reservesInLiquidity - (reservesInTotal * targetRatio) / 1e4;
            swap(treasury, false, amountOut);
        }
    }

    /* ========== SIMULATION LOGIC ========== */
    function simulate(uint32 key) internal {
        // Deploy a RBS clone for the key
        rangeSetup(key);

        // Initialize variables for tracking status
        uint32 lastRebalance;
        uint32 epochs = EPOCHS();
        SimIO.Result memory result;

        // Run simulation
        for (uint32 e; e < epochs; ) {
            // 1. Perform rebase
            rebase(key);

            // 2. Update price feed

            // 3. RBS Operations triggered

            // 4. Implement net flows

            // 5. Rebalance liquidity if enough epochs have passed
            if (e > lastRebalance + REBALANCE_INTERVAL) {
                rebalanceLiquidity(key);
                lastRebalance = e;
            }

            // 6. Store results
        }
    }
}
