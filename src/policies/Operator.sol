// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {ReentrancyGuard} from "solmate/utils/ReentrancyGuard.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {Auth, Authority} from "solmate/auth/Auth.sol";

import {IOperator} from "./interfaces/IOperator.sol";
import {IBondAuctioneer} from "interfaces/IBondAuctioneer.sol";
import {IBondCallback} from "interfaces/IBondCallback.sol";

import {OlympusTreasury} from "modules/TRSRY.sol";
import {OlympusMinter} from "modules/MINTR.sol";
import {OlympusPrice} from "modules/PRICE.sol";
import {OlympusRange} from "modules/RANGE.sol";
import {OlympusAuthority} from "modules/AUTHR.sol";

import {Kernel, Policy} from "../Kernel.sol";

import {TransferHelper} from "libraries/TransferHelper.sol";
import {FullMath} from "libraries/FullMath.sol";

/// @title  Olympus Range Operator
/// @notice Olympus Range Operator (Policy) Contract
/// @dev    The Olympus Range Operator performs market operations to enforce OlympusDAO's OHM price range
///         guidance policies against a specific reserve asset. The Operator is maintained by a keeper-triggered
///         function on the Olympus Heart contract, which orchestrates state updates in the correct order to ensure
///         market operations use up to date information. When the price of OHM against the reserve asset exceeds
///         the cushion spread, the Operator deploys bond markets to support the price. The Operator also offers
///         zero slippage swaps at prices dictated by the wall spread from the moving average. These market operations
///         are performed up to a specific capacity before the market must stabilize to regenerate the capacity.
contract Operator is IOperator, Policy, ReentrancyGuard, Auth {
    using TransferHelper for ERC20;
    using FullMath for uint256;

    /* ========== ERRORS =========== */

    error Operator_InvalidParams();
    error Operator_InsufficientCapacity();
    error Operator_WallDown();
    error Operator_AlreadyInitialized();
    error Operator_NotInitialized();

    /* ========== EVENTS =========== */
    event Swap(ERC20 tokenIn_, uint256 amountIn_, uint256 amountOut_);

    /* ========== STATE VARIABLES ========== */

    /// Operator variables, defined in the interface on the external getter functions
    Status internal _status;
    Config internal _config;

    /// @notice    Whether the Operator has been initialized
    bool public initialized;

    /// Modules
    OlympusPrice internal PRICE;
    OlympusRange internal RANGE;
    OlympusTreasury internal TRSRY;
    OlympusMinter internal MINTR;

    /// External contracts
    /// @notice     Auctioneer contract used for cushion bond market deployments
    IBondAuctioneer public auctioneer;
    /// @notice     Callback contract used for cushion bond market payouts
    IBondCallback public callback;

    /// Tokens
    /// @notice     OHM token contract
    ERC20 public immutable ohm;
    /// @notice     Reserve token contract
    ERC20 public immutable reserve;

    /// Constants
    uint32 public constant FACTOR_SCALE = 1e4;

    /* ========== CONSTRUCTOR ========== */
    constructor(
        Kernel kernel_,
        IBondAuctioneer auctioneer_,
        IBondCallback callback_,
        ERC20[2] memory tokens_, // [ohm, reserve]
        uint32[8] memory configParams // [cushionFactor, cushionDuration, cushionDebtBuffer, cushionDepositInterval, reserveFactor, regenWait, regenThreshold, regenObserve]
    ) Policy(kernel_) Auth(address(kernel_), Authority(address(0))) {
        auctioneer = auctioneer_;
        callback = callback_;
        ohm = tokens_[0];
        reserve = tokens_[1];

        Regen memory regen = Regen({
            count: configParams[5],
            lastRegen: uint48(block.timestamp),
            nextObservation: uint32(0),
            observations: new bool[](configParams[5])
        });

        _config = Config({
            cushionFactor: configParams[0],
            cushionDuration: configParams[1],
            cushionDebtBuffer: configParams[2],
            cushionDepositInterval: configParams[3],
            reserveFactor: configParams[4],
            regenWait: configParams[5],
            regenThreshold: configParams[6],
            regenObserve: configParams[7]
        });

        _status = Status({low: regen, high: regen});
    }

    /* ========== FRAMEWORK CONFIGURATION ========== */
    /// @inheritdoc Policy
    function configureReads() public override onlyKernel {
        PRICE = OlympusPrice(getModuleAddress("PRICE"));
        RANGE = OlympusRange(getModuleAddress("RANGE"));
        TRSRY = OlympusTreasury(getModuleAddress("TRSRY"));
        MINTR = OlympusMinter(getModuleAddress("MINTR"));
        setAuthority(Authority(getModuleAddress("AUTHR")));
    }

    /// @inheritdoc Policy
    function requestRoles()
        external
        view
        override
        onlyKernel
        returns (Kernel.Role[] memory roles)
    {
        roles = new Kernel.Role[](4);
        roles[0] = RANGE.OPERATOR();
        roles[1] = TRSRY.BANKER();
        roles[2] = MINTR.MINTER();
        roles[3] = MINTR.BURNER();
    }

    /* ========== HEART FUNCTIONS ========== */
    /// @inheritdoc IOperator
    function operate() external override requiresAuth {
        /// Revert if not initialized
        if (!initialized) revert Operator_NotInitialized();

        /// Update the prices for the range, save new regen observations, and update capacities based on bond market activity
        _updateRangePrices();
        _addObservation();
        _updateCapacity(true, 0);
        _updateCapacity(false, 0);

        /// Load range data and cache the status struct
        OlympusRange.Range memory range = RANGE.range();
        Status memory status_ = _status;
        Config memory config_ = _config;

        /// Check if walls can regenerate capacity
        if (
            uint48(block.timestamp) >=
            range.high.lastActive + uint48(config_.regenWait) &&
            status_.high.count >= config_.regenThreshold
        ) {
            _regenerate(true);
        }
        if (
            uint48(block.timestamp) >=
            range.low.lastActive + uint48(config_.regenWait) &&
            status_.low.count >= config_.regenThreshold
        ) {
            _regenerate(false);
        }

        /// Get latest price
        /// See note in addObservation() for more details
        uint256 currentPrice = PRICE.getLastPrice();

        /// Check if the cushion bond markets are active
        /// if so, determine if it should stay open or close
        /// if not, check if a new one should be opened
        if (range.low.active)
            if (auctioneer.isLive(range.low.market)) {
                /// if active, check if the price is back above the cushion
                /// or if the price is below the wall
                /// if so, close the market
                if (
                    currentPrice > range.cushion.low.price ||
                    currentPrice < range.wall.low.price
                ) {
                    _deactivate(false);
                }
            } else {
                /// if not active, check if the price is below the cushion
                /// if so, open a new bond market
                if (
                    currentPrice < range.cushion.low.price &&
                    currentPrice > range.wall.low.price
                ) {
                    _activate(false);
                }
            }
        if (range.high.active) {
            if (auctioneer.isLive(range.high.market)) {
                /// if active, check if the price is back under the cushion
                /// or if the price is above the wall
                /// if so, close the market
                if (
                    currentPrice < range.cushion.high.price ||
                    currentPrice > range.wall.high.price
                ) {
                    _deactivate(true);
                }
            } else {
                /// if not active, check if the price is above the cushion
                /// if so, open a new bond market
                if (
                    currentPrice > range.cushion.high.price &&
                    currentPrice < range.wall.high.price
                ) {
                    _activate(true);
                }
            }
        }
    }

    /* ========== OPEN MARKET OPERATIONS (WALL) ========== */
    /// @inheritdoc IOperator
    function swap(ERC20 tokenIn_, uint256 amountIn_)
        external
        override
        nonReentrant
        returns (uint256 amountOut)
    {
        if (tokenIn_ == ohm) {
            /// Revert if lower wall is inactive
            if (!RANGE.active(false)) revert Operator_WallDown();

            /// Calculate amount out (checks for sufficient capacity)
            amountOut = getAmountOut(tokenIn_, amountIn_);

            /// Decrement wall capacity
            _updateCapacity(false, amountOut);

            /// If wall is down after swap, deactive the cushion as well
            _checkCushion(false);

            /// Burn OHM
            MINTR.burnOhm(msg.sender, amountIn_);

            /// Withdraw and transfer reserve to sender
            TRSRY.withdrawReserves(msg.sender, reserve, amountOut);
        } else if (tokenIn_ == reserve) {
            /// Revert if lower wall is inactive
            if (!RANGE.active(true)) revert Operator_WallDown();

            /// Calculate amount out (checks for sufficient capacity)
            amountOut = getAmountOut(tokenIn_, amountIn_);

            /// Decrement wall capacity
            _updateCapacity(true, amountIn_);

            /// If wall is down after swap, deactive the cushion as well
            _checkCushion(true);

            /// Transfer reserves to treasury
            reserve.safeTransferFrom(msg.sender, address(TRSRY), amountIn_);

            /// Mint OHM to sender
            MINTR.mintOhm(msg.sender, amountOut);
        } else {
            revert Operator_InvalidParams();
        }
    }

    /* ========== BOND MARKET OPERATIONS (CUSHION) ========== */
    /// @notice      Activate a cushion by deploying a bond market
    /// @param high_ Whether the cushion is for the high or low side of the range (true = high, false = low)
    function _activate(bool high_) internal {
        OlympusRange.Range memory range = RANGE.range();

        if (high_) {
            /// Calculate scaleAdjustment for bond market
            int8 priceDecimals = _getPriceDecimals(range.cushion.high.price);
            int8 scaleAdjustment = int8(ohm.decimals()) -
                int8(reserve.decimals()) -
                (priceDecimals / 2);

            /// Calculate scale with scale adjustment and format prices for bond market
            uint8 oracleDecimals = PRICE.decimals();
            uint256 scale = 10 **
                uint8(
                    36 +
                        scaleAdjustment +
                        int8(reserve.decimals()) -
                        int8(ohm.decimals()) +
                        priceDecimals
                );

            uint256 initialPrice = range.wall.high.price.mulDiv(
                scale,
                10**oracleDecimals
            );
            uint256 minimumPrice = range.cushion.high.price.mulDiv(
                scale,
                10**oracleDecimals
            );

            /// Cache config struct to avoid multiple SLOADs
            Config memory config_ = _config;

            /// Calculate market capacity from the cushion factor
            uint256 marketCapacity = range.high.capacity.mulDiv(
                config_.cushionFactor,
                FACTOR_SCALE
            );

            /// Create new bond market to buy the reserve with OHM
            IBondAuctioneer.MarketParams memory params = IBondAuctioneer
                .MarketParams({
                    payoutToken: ohm,
                    quoteToken: reserve,
                    callbackAddr: address(callback),
                    capacityInQuote: true,
                    capacity: marketCapacity,
                    formattedInitialPrice: initialPrice,
                    formattedMinimumPrice: minimumPrice,
                    debtBuffer: config_.cushionDebtBuffer,
                    vesting: uint48(0), // Instant swaps
                    conclusion: uint48(
                        block.timestamp + config_.cushionDuration
                    ),
                    depositInterval: config_.cushionDepositInterval,
                    scaleAdjustment: scaleAdjustment
                });

            uint256 market = auctioneer.createMarket(params);

            /// Whitelist the bond market on the callback
            callback.whitelist(address(auctioneer.getTeller()), market);

            /// Update the market information on the range module
            RANGE.updateMarket(true, market, marketCapacity);
        } else {
            /// Calculate inverse prices from the oracle feed for the low side
            uint8 oracleDecimals = PRICE.decimals();
            uint256 invCushionPrice = 10**(oracleDecimals * 2) /
                range.cushion.low.price;
            uint256 invWallPrice = 10**(oracleDecimals * 2) /
                range.wall.low.price;

            /// Calculate scaleAdjustment for bond market
            int8 priceDecimals = _getPriceDecimals(invCushionPrice);
            int8 scaleAdjustment = int8(reserve.decimals()) -
                int8(ohm.decimals()) -
                (priceDecimals / 2);

            /// Calculate scale with scale adjustment and format prices for bond market
            uint256 scale = 10 **
                uint8(
                    36 +
                        scaleAdjustment +
                        int8(ohm.decimals()) -
                        int8(reserve.decimals()) +
                        priceDecimals
                );

            uint256 initialPrice = invWallPrice.mulDiv(
                scale,
                10**oracleDecimals
            );
            uint256 minimumPrice = invCushionPrice.mulDiv(
                scale,
                10**oracleDecimals
            );

            /// Cache config struct to avoid multiple SLOADs
            Config memory config_ = _config;

            /// Calculate market capacity from the cushion factor
            uint256 marketCapacity = range.low.capacity.mulDiv(
                config_.cushionFactor,
                FACTOR_SCALE
            );

            /// Create new bond market to buy OHM with the reserve
            IBondAuctioneer.MarketParams memory params = IBondAuctioneer
                .MarketParams({
                    payoutToken: reserve,
                    quoteToken: ohm,
                    callbackAddr: address(callback),
                    capacityInQuote: true,
                    capacity: marketCapacity,
                    formattedInitialPrice: initialPrice,
                    formattedMinimumPrice: minimumPrice,
                    debtBuffer: config_.cushionDebtBuffer,
                    vesting: uint48(0), // Instant swaps
                    conclusion: uint48(
                        block.timestamp + config_.cushionDuration
                    ),
                    depositInterval: config_.cushionDepositInterval,
                    scaleAdjustment: scaleAdjustment
                });

            uint256 market = auctioneer.createMarket(params);

            /// Whitelist the bond market on the callback
            callback.whitelist(address(auctioneer.getTeller()), market);

            /// Update the market information on the range module
            RANGE.updateMarket(false, market, marketCapacity);
        }
    }

    /// @notice      Deactivate a cushion by closing a bond market (if it is active)
    /// @param high_ Whether the cushion is for the high or low side of the range (true = high, false = low)
    function _deactivate(bool high_) internal {
        uint256 market = RANGE.market(high_);
        if (auctioneer.isLive(market)) {
            auctioneer.closeMarket(market);
            RANGE.updateMarket(high_, type(uint256).max, 0);
        }
    }

    /// @notice         Helper function to calculate number of price decimals based on the value returned from the price feed.
    /// @param price_   The price to calculate the number of decimals for
    /// @return         The number of decimals
    function _getPriceDecimals(uint256 price_) internal view returns (int8) {
        int8 decimals;
        while (price_ > 10) {
            price_ = price_ / 10;
            decimals++;
        }

        /// Subtract the stated decimals from the calculated decimals to get the relative price decimals.
        /// Required to do it this way vs. normalizing at the beginning since price decimals can be negative.
        return decimals - int8(PRICE.decimals());
    }

    /* ========== OPERATOR CONFIGURATION ========== */
    /// @inheritdoc IOperator
    function setSpreads(uint256 cushionSpread_, uint256 wallSpread_)
        external
        requiresAuth
    {
        /// Set spreads on the range module
        RANGE.setSpreads(cushionSpread_, wallSpread_);

        /// Update range prices (wall and cushion)
        _updateRangePrices();
    }

    /// @inheritdoc IOperator
    function setThresholdFactor(uint256 thresholdFactor_)
        external
        requiresAuth
    {
        /// Set threshold factor on the range module
        RANGE.setThresholdFactor(thresholdFactor_);
    }

    /// @inheritdoc IOperator
    function setCushionFactor(uint32 cushionFactor_) external requiresAuth {
        /// Confirm factor is within allowed values
        if (cushionFactor_ > 10000 || cushionFactor_ < 100)
            revert Operator_InvalidParams();

        /// Set factor
        _config.cushionFactor = cushionFactor_;
    }

    /// @inheritdoc IOperator
    function setCushionParams(
        uint32 duration_,
        uint32 debtBuffer_,
        uint32 depositInterval_
    ) external requiresAuth {
        /// Confirm values are valid
        if (duration_ > uint256(7 days) || duration_ < uint256(1 hours))
            revert Operator_InvalidParams(); // TODO validate these bounds for duration
        if (debtBuffer_ < uint32(10_000)) revert Operator_InvalidParams();
        if (depositInterval_ < uint32(1 hours) || depositInterval_ > duration_)
            revert Operator_InvalidParams();

        /// Update values
        _config.cushionDuration = duration_;
        _config.cushionDebtBuffer = debtBuffer_;
        _config.cushionDepositInterval = depositInterval_;
    }

    /// @inheritdoc IOperator
    function setReserveFactor(uint32 reserveFactor_) external requiresAuth {
        /// Confirm factor is within allowed values
        if (reserveFactor_ > 10000 || reserveFactor_ < 100)
            revert Operator_InvalidParams();

        /// Set factor
        _config.reserveFactor = reserveFactor_;
    }

    /// @inheritdoc IOperator
    function setRegenParams(
        uint32 wait_,
        uint32 threshold_,
        uint32 observe_
    ) external requiresAuth {
        /// Confirm regen parameters are within allowed values
        if (wait_ < 1 hours || threshold_ > observe_)
            revert Operator_InvalidParams();

        /// Set regen params
        _config.regenWait = wait_;
        _config.regenThreshold = threshold_;
        _config.regenObserve = observe_;
    }

    /// @inheritdoc IOperator
    function setBondContracts(
        IBondAuctioneer auctioneer_,
        IBondCallback callback_
    ) external requiresAuth {
        if (
            address(auctioneer_) == address(0) ||
            address(callback_) == address(0)
        ) revert Operator_InvalidParams();
        /// Set contracts
        auctioneer = auctioneer_;
        callback = callback_;
    }

    /// @inheritdoc IOperator
    function initialize() external requiresAuth {
        /// Can only call once
        if (initialized) revert Operator_AlreadyInitialized();

        /// Update range prices (wall and cushion)
        _updateRangePrices();

        /// Regenerate sides
        _regenerate(true);
        _regenerate(false);

        /// Set initialized flag
        initialized = true;
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /// @notice          Update the capacity on the RANGE module.
    /// @param high_     Whether to update the high side or low side capacity (true = high, false = low).
    /// @param reduceBy_ The amount to reduce the capacity by (OHM tokens for high side, Reserve tokens for low side).
    function _updateCapacity(bool high_, uint256 reduceBy_) internal {
        /// Get the market for the side
        uint256 market = RANGE.market(high_);

        /// Initialize update variables, decrement capacity if a reduceBy amount is provided
        uint256 capacity = RANGE.capacity(high_) - reduceBy_;
        uint256 marketCapacity;

        /// If the market is active, adjust capacity and market capacity
        if (auctioneer.isLive(market)) {
            /// Get current market capacity
            marketCapacity = auctioneer.currentCapacity(market);

            /// Reduce capacity by the amount of capacity the market has expended sicne the last update
            capacity -= RANGE.lastMarketCapacity(high_) - marketCapacity;
        }

        /// Update capacities on the range module for the wall and market
        RANGE.updateCapacity(high_, capacity, marketCapacity);
    }

    /// @notice Update the prices on the RANGE module
    function _updateRangePrices() internal {
        /// Get latest moving average from the price module
        uint256 movingAverage = PRICE.getMovingAverage();

        /// Update the prices on the range module
        RANGE.updatePrices(movingAverage);
    }

    /// @notice Add an observation to the regeneration status variables for each side
    function _addObservation() internal {
        /// Get latest moving average from the price module
        uint256 movingAverage = PRICE.getMovingAverage();

        /// Get latest price
        /// TODO determine if this should use the last price from the MA or recalculate the current price, ideally last price is ok since it should have been just updated and should include check against secondary?
        /// Current price is guaranteed to be up to date, but may be a bad value if not checked?
        uint256 currentPrice = PRICE.getLastPrice();

        /// Store observations and update counts for regeneration

        /// Update low side regen status with a new observation
        /// Observation is positive if the current price is greater than the MA
        uint32 observe = _config.regenObserve;
        Regen memory regen = _status.low;
        if (currentPrice >= movingAverage) {
            if (!regen.observations[regen.nextObservation]) {
                _status.low.observations[regen.nextObservation] = true;
                _status.low.count++;
            }
        } else {
            if (regen.observations[regen.nextObservation]) {
                _status.low.observations[regen.nextObservation] = false;
                _status.low.count--;
            }
        }
        _status.low.nextObservation = (regen.nextObservation + 1) % observe;

        /// Update high side regen status with a new observation
        /// Observation is positive if the current price is less than the MA
        regen = _status.high;
        if (currentPrice <= movingAverage) {
            if (!regen.observations[regen.nextObservation]) {
                _status.high.observations[regen.nextObservation] = true;
                _status.high.count++;
            }
        } else {
            if (regen.observations[regen.nextObservation]) {
                _status.high.observations[regen.nextObservation] = false;
                _status.high.count--;
            }
        }
        _status.high.nextObservation = (regen.nextObservation + 1) % observe;
    }

    /// @notice      Regenerate the wall for a side
    /// @param high_ Whether to regenerate the high side or low side (true = high, false = low)
    function _regenerate(bool high_) internal {
        if (high_) {
            /// Reset the regeneration data for the side
            _status.high.count = uint32(0);
            _status.high.observations = new bool[](_config.regenObserve);
            _status.high.nextObservation = uint32(0);
            _status.high.lastRegen = uint48(block.timestamp);

            /// Calculate capacity
            uint256 capacity = fullCapacity(true);

            /// Regenerate the side with the capacity
            RANGE.regenerate(true, capacity);
        } else {
            /// Reset the regeneration data for the side
            _status.low.count = uint32(0);
            _status.low.observations = new bool[](_config.regenObserve);
            _status.low.nextObservation = uint32(0);
            _status.low.lastRegen = uint48(block.timestamp);

            /// Calculate capacity
            uint256 capacity = fullCapacity(false);

            /// Regenerate the side with the capacity
            RANGE.regenerate(false, capacity);
        }
    }

    /// @notice      Takes down cushions (if active) when a wall is taken down
    /// @param high_ Whether to check the high side or low side cushion (true = high, false = low)
    function _checkCushion(bool high_) internal {
        /// Check if the wall is down, if so ensure the cushion is also down
        if (!RANGE.active(high_)) {
            uint256 market = RANGE.market(high_);
            if (auctioneer.isLive(market)) {
                _deactivate(high_);
            }
        }
    }

    /* ========== VIEW FUNCTIONS ========== */
    /// @inheritdoc IOperator
    function getAmountOut(ERC20 tokenIn_, uint256 amountIn_)
        public
        view
        returns (uint256)
    {
        if (tokenIn_ == ohm) {
            /// Calculate amount out
            uint256 amountOut = amountIn_
                .mulDiv(10**reserve.decimals(), 10**ohm.decimals())
                .mulDiv(RANGE.price(true, false), 10**PRICE.decimals());

            /// Revert if amount out exceeds capacity
            if (amountOut > RANGE.capacity(false))
                revert Operator_InsufficientCapacity();

            return amountOut;
        } else {
            /// Calculate amount out
            uint256 amountOut = amountIn_
                .mulDiv(10**ohm.decimals(), 10**reserve.decimals())
                .mulDiv(10**PRICE.decimals(), RANGE.price(true, true));

            /// Revert if amount in exceeds capacity
            if (amountOut > RANGE.capacity(true))
                revert Operator_InsufficientCapacity();

            return amountOut;
        }
    }

    /// @inheritdoc IOperator
    function fullCapacity(bool high_) public view override returns (uint256) {
        uint256 reservesInTreasury = TRSRY.getReserveBalance(reserve);
        uint256 capacity = (reservesInTreasury * _config.reserveFactor) /
            FACTOR_SCALE;
        if (high_) {
            capacity = capacity
                .mulDiv(10**PRICE.decimals(), RANGE.price(true, true))
                .mulDiv(FACTOR_SCALE + RANGE.spread(true) * 2, FACTOR_SCALE);
        }
        return capacity;
    }

    /// @inheritdoc IOperator
    function status() external view override returns (Status memory) {
        return _status;
    }

    /// @inheritdoc IOperator
    function config() external view override returns (Config memory) {
        return _config;
    }
}
