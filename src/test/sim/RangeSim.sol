// SPDX-License-Identifier: Unlicense
pragma solidity >=0.8.0;

import {Vm} from "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {MockERC20, ERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockOhm} from "test/mocks/MockOhm.sol";
import {UserFactory} from "test/lib/UserFactory.sol";

import {BondFixedTermCDA} from "test/lib/bonds/BondFixedTermCDA.sol";
import {BondAggregator} from "test/lib/bonds/BondAggregator.sol";
import {BondFixedTermTeller} from "test/lib/bonds/BondFixedTermTeller.sol";
import {RolesAuthority, Authority} from "solmate/auth/authorities/RolesAuthority.sol";

import {IBondAuctioneer} from "interfaces/IBondAuctioneer.sol";
import {IBondAggregator} from "interfaces/IBondAggregator.sol";

import {ZuniswapV2Factory} from "test/lib/zuniswapv2/ZuniswapV2Factory.sol";
import {ZuniswapV2Pair} from "test/lib/zuniswapv2/ZuniswapV2Pair.sol";
import {ZuniswapV2Library} from "test/lib/zuniswapv2/ZuniswapV2Library.sol";
import {ZuniswapV2Router} from "test/lib/zuniswapv2/ZuniswapV2Router.sol";
import {MathLibrary} from "test/lib/zuniswapv2/libraries/Math.sol";

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
                "./src/test/sim/shell/",
                bytes(script),
                " ",
                bytes(query),
                " ",
                bytes(path),
                ""
            )
        );
        response = vm.ffi(inputs);
    }

    struct Params {
        uint32 key;
        uint32 maxLiqRatio;
        uint32 reserveFactor;
        uint32 cushionFactor;
        uint32 wallSpread;
        uint32 cushionSpread;
    }

    function loadParams(uint32 seed) external returns (Params[] memory params) {
        string memory script = "loadParams.sh";
        string memory query = string(
            bytes.concat(
                "'.[] | { key: (.key | ltrimstr(\"",
                bytes(vm.toString(uint256(seed))),
                "_\") | tonumber), maxLiqRatio: ((.maxLiqRatio | tonumber) * 10000), reserveFactor: ((.askFactor | tonumber) * 10000), cushionFactor: ((.cushionFactor | tonumber) * 10000), wallSpread: ((.wall | tonumber) * 10000), cushionSpread: ((.cushion | tonumber) * 10000) }'",
                ""
            )
        );
        console2.log(query);
        string memory path = "./src/test/sim/in/params.json";
        bytes memory res = _loadData(script, query, path);
        params = abi.decode(res, (Params[]));
    }

    struct Netflow {
        uint32 key;
        uint32 epoch;
        int256 netflow;
    }

    function loadNetflows(uint32 seed) external returns (Netflow[] memory netflows) {
        string memory script = "loadNetflows.sh";
        string memory query = string(
            bytes.concat(
                "'.[] | { key: (.key | ltrimstr(\"",
                bytes(vm.toString(uint256(seed))),
                "_\") | tonumber), netflow: (.netflow | tonumber) }'",
                ""
            )
        );
        string memory path = "./src/test/sim/in/netflows.json";
        bytes memory res = _loadData(script, query, path);
        netflows = abi.decode(res, (Netflow[]));
    }

    // TODO work with R&D to get all the data they need out
    struct Result {
        uint32 epoch;
        bool rebalanced;
        uint256 marketCap;
        uint256 price;
        uint256 reserves;
        uint256 liqRatio;
        uint256 supply;
    }

    function writeResults(
        uint32 seed,
        uint32 key,
        Result[] memory results
    ) external {
        bytes memory data = "[";
        uint256 len = results.length;
        for (uint256 i; i < len; ) {
            if (i > 0) {
                data = bytes.concat(data, ",");
            }
            data = bytes.concat(
                data,
                "{seed: ",
                bytes(vm.toString(uint256(seed))),
                ", key: ",
                bytes(vm.toString(uint256(key))),
                ", epoch: ",
                bytes(vm.toString(uint256(results[i].epoch))),
                ", marketCap: ",
                bytes(vm.toString(results[i].marketCap)),
                ", price: ",
                bytes(vm.toString(results[i].price)),
                ", reserves: ",
                bytes(vm.toString(results[i].reserves)),
                ", liqRatio: ",
                bytes(vm.toString(results[i].liqRatio)),
                ", supply: ",
                bytes(vm.toString(results[i].supply)),
                "}"
            );
            unchecked {
                i++;
            }
        }
        data = bytes.concat(data, "]");
        string memory path = string(
            bytes.concat(
                "./src/test/sim/out/results-",
                bytes(vm.toString(uint256(seed))),
                "-",
                bytes(vm.toString(uint256(key))),
                ".json",
                ""
            )
        );
        vm.writeFile(path, string(data));
    }
}

abstract contract RangeSim is Test {
    using FullMath for uint256;

    /* ========== RANGE SYSTEM CONTRACTS ========== */

    Kernel public kernel;
    OlympusPrice public price;
    OlympusRange public range;
    OlympusTreasury public treasury;
    OlympusMinter public minter;
    Operator public operator;
    BondCallback public callback;
    OlympusHeart public heart;
    OlympusPriceConfig public priceConfig;

    mapping(uint32 => SimIO.Params) internal params; // map of sim keys to sim params
    mapping(uint32 => mapping(uint32 => int256)) internal netflows; // map of sim keys to epochs to netflows

    /* ========== EXTERNAL CONTRACTS  ========== */

    UserFactory public userCreator;
    address internal market;
    address internal guardian;
    address internal policy;

    RolesAuthority internal auth;
    BondAggregator internal aggregator;
    BondFixedTermTeller internal teller;
    BondFixedTermCDA internal auctioneer;
    MockOhm internal ohm;
    MockERC20 internal reserve;
    ZuniswapV2Factory internal lpFactory;
    ZuniswapV2Pair internal pool;
    ZuniswapV2Router internal router;
    MockPriceFeed internal ohmEthPriceFeed;
    MockPriceFeed internal reserveEthPriceFeed;

    /* ========== SIMULATION VARIABLES ========== */

    /// @notice Determines which data is pulled from the input files and allows writing results to compare against the same seed.
    /// @dev This is set dynamically by the test generator.
    function SEED() internal pure virtual returns (uint32);

    /// @dev Set the below variables in sim .config file.

    /// @notice Number of sims to perform with the seed. It should match the number of keys.
    uint32 internal KEYS;

    /// @notice Number of epochs to run each simulation for.
    uint32 internal EPOCHS;

    /// @notice Duration of an epoch in seconds (real-time)
    uint32 internal EPOCH_DURATION;

    /// @notice Number of epochs between rebalancing the liquidity pool
    uint32 internal REBALANCE_FREQUENCY;

    /* ========== SETUP ========== */

    function setUp() public {
        // Deploy dependencies and setup users for simulation

        // Set timestamp at roughly Jan 1, 2021 (51 years since Unix epoch) to avoid weird time issues
        vm.warp(51 * 365 * 24 * 60 * 60);

        // Set simulation variables from environment
        KEYS = uint32(vm.envUint("KEYS"));
        EPOCHS = uint32(vm.envUint("EPOCHS"));
        EPOCH_DURATION = uint32(vm.envUint("EPOCH_DURATION"));
        REBALANCE_FREQUENCY = uint32(vm.envUint("REBALANCE_FREQUENCY"));

        // Create accounts for sim
        userCreator = new UserFactory();
        address[] memory users = userCreator.create(3);
        market = users[0];
        guardian = users[1];
        policy = users[2];

        {
            // Deploy bond system

            auth = new RolesAuthority(guardian, Authority(address(0)));

            // Deploy the bond system
            aggregator = new BondAggregator(guardian, auth);
            teller = new BondFixedTermTeller(guardian, aggregator, guardian, auth);
            auctioneer = new BondFixedTermCDA(teller, aggregator, guardian, auth);

            // Register auctioneer on the bond system
            vm.prank(guardian);
            aggregator.registerAuctioneer(auctioneer);
        }

        {
            // Deploy mock tokens and price feeds
            ohm = new MockOhm("Olympus", "OHM", 9);
            reserve = new MockERC20("Reserve", "RSV", 18);

            ohmEthPriceFeed = new MockPriceFeed();
            ohmEthPriceFeed.setDecimals(18);

            reserveEthPriceFeed = new MockPriceFeed();
            reserveEthPriceFeed.setDecimals(18);

            // Initialize price feeds

            // Set reserveEthPriceFeed to $1000 constant for the sim, changes will be reflected in the ohmEthPriceFeed
            reserveEthPriceFeed.setLatestAnswer(int256(1e15));
            reserveEthPriceFeed.setTimestamp(block.timestamp);

            // ohmEthPriceFeed is the price passed in to the sim, divided by 1000
            ohmEthPriceFeed.setLatestAnswer(int256(vm.envUint("PRICE") / 1e3));
            ohmEthPriceFeed.setTimestamp(block.timestamp);
        }

        {
            // Deploy ZuniswapV2 and Liquidity Pool
            lpFactory = new ZuniswapV2Factory();
            router = new ZuniswapV2Router(address(lpFactory));

            address poolAddress = lpFactory.createPair(address(reserve), address(ohm));
            pool = ZuniswapV2Pair(poolAddress);
        }

        {
            // Load sim data
            SimIO.Params[] memory paramArray = SimIO.loadParams(SEED());
            uint256 paramLen = paramArray.length;
            console2.log(paramLen);
            for (uint256 i; i < paramLen; ) {
                params[paramArray[i].key] = paramArray[i];
                unchecked {
                    i++;
                }
            }

            // // Load netflows data
            // SimIO.Netflow[] memory netflowArray = SimIO.loadNetflows(SEED());
            // uint256 netflowLen = netflowArray.length;
            // for (uint256 j; j < netflowLen; ) {
            //     netflows[netflowArray[j].key][netflowArray[j].epoch] = netflowArray[j].netflow;
            //     unchecked {
            //         j++;
            //     }
            // }
        }
    }

    function rangeSetup(uint32 key) public {
        // Deploy the range system with the simulation parameters

        // Get the simulation parameters
        SimIO.Params memory _params = params[key];

        {
            /// Deploy kernel
            kernel = new Kernel(); // this contract will be the executor

            /// Deploy modules
            price = new OlympusPrice(
                kernel,
                ohmEthPriceFeed,
                reserveEthPriceFeed,
                uint48(vm.envUint("EPOCH_DURATION")),
                uint48(vm.envUint("MA_DURATION"))
            );
            range = new OlympusRange(
                kernel,
                [ERC20(ohm), ERC20(reserve)],
                [
                    vm.envUint("THRESHOLD_FACTOR"),
                    uint256(_params.cushionSpread),
                    uint256(_params.wallSpread)
                ]
            );
            treasury = new OlympusTreasury(kernel);
            minter = new OlympusMinter(kernel, address(ohm));
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
                    _params.cushionFactor, // cushionFactor
                    uint32(vm.envUint("CUSHION_DURATION")), // duration
                    uint32(vm.envUint("CUSHION_DEBT_BUFFER")), // debtBuffer
                    uint32(vm.envUint("CUSHION_DEPOSIT_INTERVAL")), // depositInterval
                    uint32(_params.reserveFactor), // reserveFactor
                    uint32(vm.envUint("REGEN_WAIT")), // regenWait
                    uint32(vm.envUint("REGEN_THRESHOLD")), // regenThreshold
                    uint32(vm.envUint("REGEN_OBSERVE")) // regenObserve
                ]
            );

            // Deploy PriceConfig
            priceConfig = new OlympusPriceConfig(kernel);

            // Deploy Heart
            heart = new OlympusHeart(
                kernel,
                operator,
                reserve,
                uint256(0) // no keeper rewards for sim
            );
        }

        {
            // Initialize kernel

            // Install modules
            kernel.executeAction(Actions.InstallModule, address(price));
            kernel.executeAction(Actions.InstallModule, address(range));
            kernel.executeAction(Actions.InstallModule, address(treasury));
            kernel.executeAction(Actions.InstallModule, address(minter));

            // Approve policies
            kernel.executeAction(Actions.ActivatePolicy, address(operator));
            kernel.executeAction(Actions.ActivatePolicy, address(callback));
            kernel.executeAction(Actions.ActivatePolicy, address(heart));
            kernel.executeAction(Actions.ActivatePolicy, address(priceConfig));
        }
        {
            // Configure access control

            // Operator roles
            kernel.grantRole(toRole("operator_operate"), address(heart));
            kernel.grantRole(toRole("operator_operate"), guardian);
            kernel.grantRole(toRole("operator_reporter"), address(callback));
            kernel.grantRole(toRole("operator_policy"), policy);
            kernel.grantRole(toRole("operator_admin"), guardian);

            // Bond callback roles
            kernel.grantRole(toRole("callback_whitelist"), address(operator));
            kernel.grantRole(toRole("callback_whitelist"), guardian);
            kernel.grantRole(toRole("callback_admin"), guardian);

            // Heart roles
            kernel.grantRole(toRole("heart_admin"), guardian);

            // PriceConfig roles
            kernel.grantRole(toRole("price_admin"), guardian);
        }

        {
            // Initialize the system

            // Initialize the price module
            uint256 obs = vm.envUint("MA_DURATION") / vm.envUint("EPOCH_DURATION");
            uint256[] memory priceData = new uint256[](obs);
            uint256 movingAverage = vm.envUint("MOVING_AVERAGE");
            for (uint256 i; i < obs; ) {
                priceData[i] = movingAverage;
                unchecked {
                    i++;
                }
            }

            vm.startPrank(guardian);
            priceConfig.initialize(priceData, uint48(block.timestamp));

            // Set operator on the callback
            callback.setOperator(operator);

            // Initialize Operator
            operator.initialize();

            vm.stopPrank();
        }

        {
            // Set initial supply and liquidity balances
            uint256 initialSupply = vm.envUint("SUPPLY");
            uint256 liquidityReserves = vm.envUint("LIQUIDITY");
            uint256 treasuryReserves = vm.envUint("RESERVES");
            uint256 initialPrice = vm.envUint("INITIAL_PRICE");

            // Mint reserves + reserve liquidity to treasury
            reserve.mint(address(treasury), treasuryReserves + liquidityReserves);

            // Mint equivalent OHM to treasury for to provide as liquidity
            uint256 liquidityOhm = liquidityReserves.mulDiv(initialPrice * 1e9, 1e18 * 1e18);
            ohm.mint(address(treasury), liquidityOhm);

            // Approve the liquidity pool for both tokens and deposit
            vm.startPrank(address(treasury));
            ohm.approve(address(router), type(uint256).max);
            reserve.approve(address(router), type(uint256).max);
            router.addLiquidity(
                address(reserve),
                address(ohm),
                liquidityReserves,
                liquidityOhm,
                liquidityReserves,
                liquidityOhm,
                address(treasury)
            );
            vm.stopPrank();

            // Get the difference between initial supply and OHM in LP, mint to the market
            uint256 supplyDiff = initialSupply - liquidityOhm;
            ohm.mint(market, supplyDiff);

            // Mint large amount of reserves to the market
            reserve.mint(market, 100_000_000_000 * 1e18);

            // Approve the Operator, Teller, and Router for the market with both tokens
            vm.startPrank(market);
            ohm.approve(address(operator), type(uint256).max);
            reserve.approve(address(operator), type(uint256).max);
            ohm.approve(address(teller), type(uint256).max);
            reserve.approve(address(teller), type(uint256).max);
            ohm.approve(address(router), type(uint256).max);
            reserve.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
    }

    /* ========== SIMULATION HELPER FUNCTIONS ========== */
    /// @notice Returns the rebase percent per epoch based on supply as a percentage with 4 decimals. i.e. 10000 = 1%.
    /// @dev Values are based on the minimum value for each tier as defined in OIP-18.
    function getRebasePercent() internal view returns (uint256) {
        // Implement the current reward rate framework based on supply
        uint256 supply = ohm.totalSupply();
        if (supply < 1_000_000 * 1e9) {
            return 3058;
        } else if (supply < 10_000_000 * 1e9) {
            return 1587;
        } else if (supply < 100_000_000 * 1e9) {
            return 1183;
        } else if (supply < 1_000_000_000 * 1e9) {
            return 458;
        } else if (supply < 10_000_000_000 * 1e9) {
            return 148;
        } else if (supply < 100_000_000_000 * 1e9) {
            return 39;
        } else if (supply < 1_000_000_000_000 * 1e9) {
            return 19;
        } else {
            return 9;
        }
    }

    /// @dev Simulating rebases by minting OHM to the market account (at 80% rate) and the liquidity pool
    function rebase() internal {
        uint256 perc = getRebasePercent();

        // Mint OHM to the market account
        vm.startPrank(address(minter));
        ohm.mint(market, (((ohm.balanceOf(market) * 8) / 10) * perc) / 1e6);

        // Mint OHM to the liquidity pool and sync the balances
        uint256 poolBalance = ohm.balanceOf(address(pool));

        ohm.mint(address(pool), (poolBalance * perc) / 1e6);
        vm.stopPrank();

        // Sync the pool balance
        pool.sync();
    }

    function updatePrice() internal {
        // Get current pool price
        uint256 currentPrice = poolPrice();

        // Set new price on feeds and update timestamps
        ohmEthPriceFeed.setLatestAnswer(int256(currentPrice / 1e3));
        ohmEthPriceFeed.setTimestamp(block.timestamp);
        reserveEthPriceFeed.setTimestamp(block.timestamp);
    }

    /// @notice Creates a convenient abstraction on the balancer interface for single swaps between OHM and Reserve
    /// @param sender Account to send the swap from and receive the amount out
    /// @param reserveIn Whether the reserve token is being sent in (true) or received from (false) the swap
    /// @param amount Amount of reserves to get in or out (based on reserveIn)
    /// @dev Ensure tokens are approved on the balancer vault already to avoid allowance errors
    function swap(
        address sender,
        bool reserveIn,
        uint256 amount
    ) internal {
        if (reserveIn) {
            // Swap exact amount of reserves in for amount of OHM we can receive
            // Create path to swap
            address[] memory path = new address[](2);
            path[0] = address(reserve);
            path[1] = address(ohm);

            /// Get amount out for the reserves to swap
            uint256[] memory minAmountsOut = ZuniswapV2Library.getAmountsOut(
                address(lpFactory),
                amount,
                path
            );

            // Execute swap
            vm.prank(market);
            router.swapExactTokensForTokens(amount, minAmountsOut[0], path, sender);
        } else {
            // Swap amount of ohm for exact amount of reserves out
            // Create path to swap
            address[] memory path = new address[](2);
            path[0] = address(ohm);
            path[1] = address(reserve);

            uint256[] memory maxAmountsIn = ZuniswapV2Library.getAmountsIn(
                address(lpFactory),
                amount,
                path
            );

            // Execute swap
            vm.prank(market);
            router.swapTokensForExactTokens(amount, maxAmountsIn[0], path, sender);
        }

        /// Update price feeds after each swap
        updatePrice();
    }

    /// @notice Returns the price of the token implied by the liquidity pool
    function poolPrice() public view returns (uint256) {
        (uint256 reserve0, uint256 reserve1, ) = pool.getReserves();
        return reserve0.mulDiv(1e18 * 1e9, reserve1 * 1e18);
    }

    /// @notice Returns the amount of token in to swap on the liquidity pool to move the price to a target value
    /// @dev based on the UniswapV2LiquidityMathLibrary.computeProfitMaximizingTrade() function: https://github.com/Uniswap/v2-periphery/blob/0335e8f7e1bd1e8d8329fd300aea2ef2f36dd19f/contracts/libraries/UniswapV2LiquidityMathLibrary.sol#L17
    function amountToTargetPrice(ERC20 tokenIn, uint256 targetPrice)
        internal
        view
        returns (uint256 amountIn)
    {
        (uint256 reserve0, uint256 reserve1, ) = pool.getReserves();
        uint256 currentPrice = reserve0.mulDiv(1e18 * 1e9, reserve1 * 1e18);
        uint256 invariant = reserve0 * reserve1;

        uint256 rightSide;
        if (tokenIn == reserve) {
            rightSide = (reserve0 * 1000) / 997;
        } else {
            rightSide = (reserve1 * 1000) / 997;
            currentPrice = 1e36 / currentPrice;
            targetPrice = 1e36 / targetPrice;
        }

        uint256 leftSide = MathLibrary.sqrt(
            (invariant * 1000).mulDiv(currentPrice, targetPrice * 997)
        );

        amountIn = leftSide - rightSide;
    }

    function rebalanceLiquidity(uint32 key) internal {
        // Get current liquidity ratio
        uint256 reservesInTreasury = reserve.balanceOf(address(treasury));
        uint256 reservesInLiquidity = reserve.balanceOf(address(pool));
        uint256 reservesInTotal = reservesInTreasury + reservesInLiquidity;

        uint32 liquidityRatio = uint32((reservesInLiquidity * 1e4) / reservesInTotal);

        // Get the target ratio
        uint32 targetRatio = uint32(params[key].maxLiqRatio);

        // Compare ratios and calculate swap amount
        // If ratio is too low, sell reserves into the liquidity pool
        // If ratio is too high, buy reserves from the liquidity pool
        // Currently just doing one big atomic swap

        if (liquidityRatio < targetRatio) {
            // Sell reserves into the liquidity pool
            uint256 amountIn = (reservesInTotal * targetRatio) / 1e4 - reservesInLiquidity;
            swap(address(treasury), true, amountIn);
        } else if (liquidityRatio > targetRatio) {
            // Buy reserves from the liquidity pool
            uint256 amountOut = reservesInLiquidity - (reservesInTotal * targetRatio) / 1e4;
            swap(address(treasury), false, amountOut);
        }
    }

    function marketAction(uint32 key, uint32 epoch) internal {
        // Get the net flow for the key and epoch combination
        int256 netflow = netflows[key][epoch];

        if (netflow == 0) return; // If netflow is 0, no action is needed

        // Positive flows mean reserves are flowing in, negative flows mean reserves are flowing out
        bool reserveIn = netflow > 0;
        uint256 flow = reserveIn ? uint256(netflow) : uint256(-1 * netflow);

        // Handle branching scenarios

        // If reserves are flowing in (market is buying OHM)
        if (reserveIn) {
            uint256 wallPrice = range.price(true, true);
            uint256 cushionPrice = range.price(false, true);

            while (flow > 0) {
                // Check if the RBS side is active, if not, swap all flow into the liquidity pool
                if (range.active(true)) {
                    // Check price against the upper wall and cushion
                    uint256 currentPrice = price.getCurrentPrice();
                    uint256 oracleScale = 10**(price.decimals());

                    // If the market price is above the wall price, swap at the wall up to its capacity
                    if (currentPrice >= wallPrice) {
                        uint256 capacity = range.capacity(true); // Capacity is in OHM units
                        uint256 capacityInReserve = capacity.mulDiv(
                            wallPrice * 1e18,
                            oracleScale * 1e9
                        ); // Convert capacity to reserves to compare with flow
                        if (flow > capacityInReserve) {
                            // If flow is greater than capacity, swap the capacity at the wall
                            uint256 minAmountOut = operator.getAmountOut(
                                reserve,
                                capacityInReserve
                            );
                            vm.prank(market);
                            operator.swap(reserve, capacityInReserve, minAmountOut);
                            flow -= capacity;
                        } else {
                            // If flow is less than capacity, swap the flow at the wall
                            uint256 minAmountOut = operator.getAmountOut(reserve, flow);
                            vm.prank(market);
                            operator.swap(reserve, flow, minAmountOut);
                            flow = 0;
                        }
                    } else if (currentPrice >= cushionPrice) {
                        // Bond against the cushion until it's not a good deal
                        // We assume there is a cushion here since these actions are taking place right after an epoch update
                        uint256 id = range.market(true);
                        uint256 bondScale = aggregator.marketScale(id);
                        uint256 oracleScale = 10**(price.decimals());
                        while (
                            currentPrice >=
                            aggregator.marketPrice(id).mulDiv(oracleScale, bondScale)
                        ) {
                            uint256 maxBond = aggregator.maxAmountAccepted(id, address(treasury));
                            if (maxBond > flow) {
                                uint256 minAmountOut = aggregator.payoutFor(
                                    id,
                                    flow,
                                    address(treasury)
                                );
                                vm.prank(market);
                                teller.purchase(market, address(treasury), id, flow, minAmountOut);
                                flow = 0;
                                break;
                            } else {
                                uint256 minAmountOut = aggregator.payoutFor(
                                    id,
                                    maxBond,
                                    address(treasury)
                                );
                                vm.prank(market);
                                teller.purchase(
                                    market,
                                    address(treasury),
                                    id,
                                    maxBond,
                                    minAmountOut
                                );
                                flow -= maxBond;
                            }
                        }

                        // If there is some flow remaining, swap it in the liquidity pool up to the wall price
                        if (flow > 0) {
                            // Get amount that can swapped in the liquidity pool to push price to wall price
                            uint256 maxSwap = amountToTargetPrice(reserve, wallPrice);
                            if (flow > maxSwap) {
                                // Swap the max amount in the liquidity pool
                                swap(market, true, maxSwap);
                                flow -= maxSwap;
                            } else {
                                // Swap the flow in the liquidity pool
                                swap(market, true, flow);
                                flow = 0;
                            }
                        }
                    } else {
                        // If the market price is below the cushion price, swap into the liquidity pool up to the cushion price
                        // Get amount that can swapped in the liquidity pool to push price to wall price
                        uint256 maxSwap = amountToTargetPrice(reserve, cushionPrice);
                        if (flow > maxSwap) {
                            // Swap the max amount in the liquidity pool
                            swap(market, true, maxSwap);
                            flow -= maxSwap;
                        } else {
                            // Swap the flow in the liquidity pool
                            swap(market, true, flow);
                            flow = 0;
                        }
                    }
                } else {
                    // If the RBS side is not active, swap all flow into the liquidity pool
                    swap(market, true, flow);
                    flow = 0;
                }
            }
        } else {
            // If reserves are flowing out (market is selling OHM)
            uint256 wallPrice = range.price(true, false);
            uint256 cushionPrice = range.price(false, false);

            while (flow > 0) {
                // Check if the RBS side is active, if not, swap all flow into the liquidity pool
                if (range.active(false)) {
                    // Check price against the upper wall and cushion
                    uint256 currentPrice = price.getCurrentPrice();
                    uint256 oracleScale = 10**(price.decimals());

                    // If the market price is below the wall price, swap at the wall up to its capacity
                    if (currentPrice <= wallPrice) {
                        uint256 capacity = range.capacity(false); // Lower side capacity is in reserves
                        if (flow > capacity) {
                            // If flow is greater than capacity, swap the capacity at the wall
                            uint256 amountIn = capacity.mulDiv(oracleScale * 1e9, wallPrice * 1e18); // Convert to OHM units
                            uint256 minAmountOut = operator.getAmountOut(ohm, amountIn);
                            vm.prank(market);
                            operator.swap(ohm, amountIn, minAmountOut);
                            flow -= capacity;
                        } else {
                            // If flow is less than capacity, swap the flow at the wall
                            uint256 amountIn = flow.mulDiv(oracleScale * 1e9, wallPrice * 1e18); // Convert to OHM units
                            uint256 minAmountOut = operator.getAmountOut(ohm, amountIn);
                            vm.prank(market);
                            operator.swap(ohm, amountIn, minAmountOut);
                            flow = 0;
                        }
                    } else if (currentPrice <= cushionPrice) {
                        // Bond against the cushion until it's not a good deal
                        // We assume there is a cushion here since these actions are taking place right after an epoch update
                        uint256 id = range.market(false);
                        uint256 bondScale = aggregator.marketScale(id);
                        while (
                            currentPrice >=
                            10**(price.decimals() * 2) /
                                aggregator.marketPrice(id).mulDiv(oracleScale, bondScale)
                        ) {
                            (, , , , , uint256 maxPayout) = auctioneer.getMarketInfoForPurchase(id); // in reserve units
                            uint256 bondPrice = aggregator.marketPrice(id);
                            if (maxPayout > flow) {
                                uint256 amountIn = flow.mulDiv(bondPrice, bondScale); // convert to OHM units
                                uint256 minAmountOut = aggregator.payoutFor(
                                    id,
                                    flow,
                                    address(treasury)
                                );
                                vm.prank(market);
                                teller.purchase(
                                    market,
                                    address(treasury),
                                    id,
                                    amountIn,
                                    minAmountOut
                                );
                                flow = 0;
                                break;
                            } else {
                                uint256 amountIn = maxPayout.mulDiv(bondPrice, bondScale); // convert to OHM units
                                uint256 minAmountOut = aggregator.payoutFor(
                                    id,
                                    amountIn,
                                    address(treasury)
                                );
                                vm.prank(market);
                                teller.purchase(
                                    market,
                                    address(treasury),
                                    id,
                                    amountIn,
                                    minAmountOut
                                );
                                flow -= maxPayout;
                            }
                        }

                        // If there is some flow remaining, swap it in the liquidity pool up to the wall price
                        if (flow > 0) {
                            // Get amount that can swapped in the liquidity pool to push price to wall price
                            uint256 maxSwap = amountToTargetPrice(ohm, wallPrice);
                            if (flow > maxSwap) {
                                // Swap the max amount in the liquidity pool
                                swap(market, false, maxSwap);
                                flow -= maxSwap;
                            } else {
                                // Swap the flow in the liquidity pool
                                swap(market, false, flow);
                                flow = 0;
                            }
                        }
                    } else {
                        // If the market price is below the cushion price, swap into the liquidity pool up to the cushion price
                        // Get amount that can swapped in the liquidity pool to push price to wall price
                        uint256 maxSwap = amountToTargetPrice(ohm, cushionPrice);
                        if (flow > maxSwap) {
                            // Swap the max amount in the liquidity pool
                            swap(market, false, maxSwap);
                            flow -= maxSwap;
                        } else {
                            // Swap the flow in the liquidity pool
                            swap(market, false, flow);
                            flow = 0;
                        }
                    }
                } else {
                    // If the RBS side is not active, swap all flow into the liquidity pool
                    swap(market, false, flow);
                    flow = 0;
                }
            }
        }
    }

    function getResult(uint32 epoch, bool rebalanced)
        internal
        view
        returns (SimIO.Result memory result)
    {
        // Retrieve data from the contracts on current status
        uint256 supply = ohm.totalSupply();
        uint256 lastPrice = price.getLastPrice();
        uint256 marketCap = (supply * lastPrice) / 1e9;
        uint256 reservesInTreasury = reserve.balanceOf(address(treasury));
        uint256 reservesInLiquidity = reserve.balanceOf(address(pool));
        uint256 reservesInTotal = reservesInTreasury + reservesInLiquidity;
        uint256 liquidityRatio = uint256((reservesInLiquidity * 1e4) / reservesInTotal);

        // Create result struct
        result = SimIO.Result(
            epoch,
            rebalanced,
            marketCap,
            lastPrice,
            reservesInTotal,
            liquidityRatio,
            supply
        );
    }

    /* ========== SIMULATION LOGIC ========== */
    function simulate(uint32 key) internal {
        // Deploy a RBS clone for the key
        rangeSetup(key);

        // Initialize variables for tracking status
        uint32 lastRebalance;
        uint32 epochs = EPOCHS; // cache
        uint32 duration = EPOCH_DURATION; // cache
        uint32 rebalance_frequency = REBALANCE_FREQUENCY; // cache
        SimIO.Result[] memory results = new SimIO.Result[](epochs);

        // Run simulation
        for (uint32 e; e < epochs; ) {
            // 0. Warp time forward
            vm.warp(block.timestamp + duration);

            // 1. Perform rebase
            rebase();

            // 2. Update price and moving average data from LP pool
            updatePrice();

            // 3. RBS Operations triggered
            heart.beat();

            // 4. Implement market actions for net flows
            marketAction(key, e);

            // 5. Rebalance liquidity if enough epochs have passed
            // 6. Store results for output
            if (e > lastRebalance + rebalance_frequency) {
                rebalanceLiquidity(key);
                lastRebalance = e;
                results[e] = getResult(e, true);
            } else {
                results[e] = getResult(e, false);
            }

            unchecked {
                e++;
            }
        }

        // Write results to output file
        SimIO.writeResults(SEED(), key, results);
    }
}
