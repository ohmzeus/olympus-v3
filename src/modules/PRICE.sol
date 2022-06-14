// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.11;

import {AggregatorV2V3Interface} from "interfaces/AggregatorV2V3Interface.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {Kernel, Module} from "../Kernel.sol";

import {FullMath} from "libraries/FullMath.sol";

contract OlympusPrice is Module {
    using FullMath for uint256;

    /* ========== ERRORS =========== */

    error Price_InvalidParams();
    error Price_NotInitialized();
    error Price_AlreadyInitialized();

    /* ========== EVENTS =========== */
    event NewObservation(uint256 timestamp, uint256 price);

    /* ========== STATE VARIABLES ========== */

    /// TODO add secondary check on TWAP

    /// Moving Average
    AggregatorV2V3Interface internal _ohmEthPriceFeed;
    AggregatorV2V3Interface internal _reserveEthPriceFeed;
    uint8 internal _ohmEthDecimals;
    uint8 internal _reserveEthDecimals;
    uint8 internal _decimals;
    uint256[] public observations;
    uint256 public movingAverage;
    uint48 public observationFrequency;
    uint48 public numObservations;
    uint48 public movingAverageDuration;
    uint48 public lastObservationTime;
    bool public initialized;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        Kernel kernel_,
        AggregatorV2V3Interface ohmEthPriceFeed_,
        AggregatorV2V3Interface reserveEthPriceFeed_,
        uint48 observationFrequency_,
        uint48 movingAverageDuration_
    ) Module(kernel_) {
        /// @dev Moving Average Duration should be divislble by Observation Frequency to get a whole number of observations
        if (movingAverageDuration_ % observationFrequency_ != 0)
            revert Price_InvalidParams();

        /// Set parameters and calculate number of observations
        _ohmEthPriceFeed = ohmEthPriceFeed_;
        _ohmEthDecimals = _ohmEthPriceFeed.decimals();

        _reserveEthPriceFeed = reserveEthPriceFeed_;
        _reserveEthDecimals = _reserveEthPriceFeed.decimals();

        _decimals = 18;

        observationFrequency = observationFrequency_;
        movingAverageDuration = movingAverageDuration_;

        numObservations = movingAverageDuration_ / observationFrequency_;

        /// Store blank observations array
        observations = new uint256[](numObservations);
    }

    /* ========== FRAMEWORK CONFIGURATION ========== */
    function KEYCODE() public pure override returns (bytes5) {
        return "PRICE";
    }

    /* ========== POLICY FUNCTIONS ========== */
    function updateMovingAverage() external onlyPermittedPolicies {
        /// TODO determine if this should be opened up (don't want to conflict with heart beat and have that fail)

        /// Revert if not initialized
        if (!initialized) revert Price_NotInitialized();

        /// Get earliest observation in window
        uint256 earliestPrice = observations[
            (observations.length - numObservations)
        ];

        /// Get current price
        uint256 currentPrice = getCurrentPrice();

        /// Calculate new moving average
        if (currentPrice > earliestPrice) {
            movingAverage += (currentPrice - earliestPrice) / numObservations;
        } else {
            movingAverage -= (earliestPrice - currentPrice) / numObservations;
        }

        /// Push new observation into storage
        observations.push(currentPrice);

        /// Emit event
        emit NewObservation(block.timestamp, currentPrice);

        // lastObservationTime = currentTime;
    }

    /* ========== VIEW FUNCTIONS ========== */

    function getCurrentPrice() public view returns (uint256) {
        /// Revert if not initialized
        if (!initialized) revert Price_NotInitialized();

        /// Get prices from feeds
        uint256 ohmEthPrice;
        uint256 reserveEthPrice;
        {
            int256 ohmEthPriceInt = _ohmEthPriceFeed.latestAnswer();
            ohmEthPrice = uint256(ohmEthPriceInt);

            int256 reserveEthPriceInt = _reserveEthPriceFeed.latestAnswer();
            reserveEthPrice = uint256(reserveEthPriceInt);
        }

        /// Convert to OHM/RESERVE price
        uint256 currentPrice = ohmEthPrice.mulDiv(
            10**(_decimals + _reserveEthDecimals),
            reserveEthPrice * 10**(_ohmEthDecimals)
        );

        return currentPrice;
    }

    function getLastPrice() external view returns (uint256) {
        /// Revert if not initialized
        if (!initialized) revert Price_NotInitialized();
        return observations[observations.length - 1];
    }

    function getMovingAverage() external view returns (uint256) {
        /// Revert if not initialized
        if (!initialized) revert Price_NotInitialized();
        return movingAverage;
    }

    function getDecimals() external view returns (uint8) {
        return _decimals;
    }

    /* ========== ADMIN FUNCTIONS ========== */

    function initialize(
        uint256[] memory startObservations_,
        uint48 lastObservationTime_
    ) external onlyPermittedPolicies {
        /// Revert if already initialized
        if (initialized) revert Price_AlreadyInitialized();

        /// Check that the number of start observations matches the number expected
        if (
            startObservations_.length != numObservations ||
            lastObservationTime_ > uint48(block.timestamp)
        ) revert Price_InvalidParams();

        /// Push start observations into storage and total up observations
        uint256 total;
        for (uint256 i = 0; i < numObservations; i++) {
            total += startObservations_[i];
            observations[i] = startObservations_[i];
        }

        /// Set moving average, last observation time, and initialized flag
        movingAverage = total / numObservations;
        lastObservationTime = lastObservationTime_;
        initialized = true;
    }

    /// @dev Setting the window to a larger number of observations than the current window will clear
    ///      the data in the current window and require the initialize function to be called again.
    ///      Ensure that you have saved the existing data and can re-populate before calling this
    ///      function with a number of observations larger than have been recorded.
    function changeMovingAverageDuration(uint48 movingAverageDuration_)
        external
        onlyPermittedPolicies
    {
        /// Moving Average Duration should be divisible by Observation Frequency to get a whole number of observations
        if (
            movingAverageDuration_ == 0 ||
            movingAverageDuration_ % observationFrequency != 0
        ) revert Price_InvalidParams();

        /// Calculate the new number of observations
        uint256 newObservations = uint256(
            movingAverageDuration_ / observationFrequency
        );
        uint256 obsLength = observations.length;

        /// If the number of new observations is greater than the number of observations stored,
        /// the array will need to be reinitialized.
        /// Otherwise, keep the existing array and calculate the new moving average.
        if (newObservations > obsLength) {
            /// Store blank observations array of new size
            observations = new uint256[](newObservations);

            /// Set initialized to false
            initialized = false;
        } else {
            /// Update moving average
            uint256 startIdx = obsLength - newObservations;
            uint256 newMovingAverage;
            for (uint256 i; i < newObservations; ++i) {
                newMovingAverage += observations[startIdx + i];
            }
            movingAverage = newMovingAverage / newObservations;
        }

        /// Set parameters and number of observations
        movingAverageDuration = movingAverageDuration_;
        numObservations = uint48(newObservations);
    }

    function changeObservationFrequency(uint48 observationFrequency_)
        external
        onlyPermittedPolicies
    {
        /// Moving Average Duration should be divisible by Observation Frequency to get a whole number of observations
        if (
            observationFrequency_ == 0 ||
            movingAverageDuration % observationFrequency_ != 0
        ) revert Price_InvalidParams();

        /// Calculate the new number of observations
        uint256 newObservations = uint256(
            movingAverageDuration / observationFrequency_
        );

        /// Since the old observations will not be taken at the right intervals,
        /// the observations array will need to be reinitialized.
        /// Although, there are a handful of situations that could be handled
        /// (e.g. clean multiples of the old frequency),
        /// it is easier to do so off-chain and reinitialize the array.

        /// Store blank observations array of new size
        observations = new uint256[](newObservations);

        /// Set initialized to false
        initialized = false;

        /// Set parameters and number of observations
        observationFrequency = observationFrequency_;
        numObservations = uint48(newObservations);
    }
}
