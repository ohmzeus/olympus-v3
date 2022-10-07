// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.0;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {IBondSDA} from "interfaces/IBondSDA.sol";
import {IBondCallback} from "interfaces/IBondCallback.sol";

interface IOperator {
    /* ========== STRUCTS =========== */

    /// @notice Configuration variables for the Operator
    struct Config {
        uint32 cushionFactor; // percent of capacity to be used for a single cushion deployment, assumes 2 decimals (i.e. 1000 = 10%)
        uint32 cushionDuration; // duration of a single cushion deployment in seconds
        uint32 cushionDebtBuffer; // Percentage over the initial debt to allow the market to accumulate at any one time. Percent with 3 decimals, e.g. 1_000 = 1 %. See IBondSDA for more info.
        uint32 cushionDepositInterval; // Target frequency of deposits. Determines max payout of the bond market. See IBondSDA for more info.
        uint32 reserveFactor; // percent of reserves in treasury to be used for a single wall, assumes 2 decimals (i.e. 1000 = 10%)
        uint32 regenWait; // minimum duration to wait to reinstate a wall in seconds
        uint32 regenThreshold; // number of price points on other side of moving average to reinstate a wall
        uint32 regenObserve; // number of price points to observe to determine regeneration
    }

    /// @notice Combines regeneration status for low and high sides of the range
    struct Status {
        Regen low; // regeneration status for the low side of the range
        Regen high; // regeneration status for the high side of the range
    }

    /// @notice Tracks status of when a specific side of the range can be regenerated by the Operator
    struct Regen {
        uint32 count; // current number of price points that count towards regeneration
        uint48 lastRegen; // timestamp of the last regeneration
        uint32 nextObservation; // index of the next observation in the observations array
        bool[] observations; // individual observations: true = price on other side of average, false = price on same side of average
    }

    /* ========== CORE FUNCTIONS ========== */

    /// @notice Executes market operations logic.
    /// @notice Access restricted
    /// @dev    This function is triggered by a keeper on the Heart contract.
    function operate() external;

    /* ========== OPEN MARKET OPERATIONS (WALL) ========== */

    /// @notice Swap at the current wall prices
    /// @param  tokenIn_ - Token to swap into the wall
    ///         - OHM: swap at the low wall price for Reserve
    ///         - Reserve: swap at the high wall price for OHM
    /// @param  amountIn_ - Amount of tokenIn to swap
    /// @param  minAmountOut_ - Minimum amount of opposite token to receive
    /// @return amountOut - Amount of opposite token received
    function swap(
        ERC20 tokenIn_,
        uint256 amountIn_,
        uint256 minAmountOut_
    ) external returns (uint256 amountOut);

    /// @notice Returns the amount to be received from a swap
    /// @param  tokenIn_ - Token to swap into the wall
    ///         - If OHM: swap at the low wall price for Reserve
    ///         - If Reserve: swap at the high wall price for OHM
    /// @param  amountIn_ - Amount of tokenIn to swap
    /// @return Amount of opposite token received
    function getAmountOut(ERC20 tokenIn_, uint256 amountIn_) external view returns (uint256);

    /* ========== ADMIN FUNCTIONS ========== */

    /// @notice Set the wall and cushion spreads
    /// @notice Access restricted
    /// @dev    Interface for externally setting these values on the RANGE module
    /// @param  cushionSpread_ - Percent spread to set the cushions at above/below the moving average, assumes 2 decimals (i.e. 1000 = 10%)
    /// @param  wallSpread_ - Percent spread to set the walls at above/below the moving average, assumes 2 decimals (i.e. 1000 = 10%)
    function setSpreads(uint256 cushionSpread_, uint256 wallSpread_) external;

    /// @notice Set the threshold factor for when a wall is considered "down"
    /// @notice Access restricted
    /// @dev    Interface for externally setting this value on the RANGE module
    /// @param  thresholdFactor_ - Percent of capacity that the wall should close below, assumes 2 decimals (i.e. 1000 = 10%)
    function setThresholdFactor(uint256 thresholdFactor_) external;

    /// @notice Set the cushion factor
    /// @notice Access restricted
    /// @param  cushionFactor_ - Percent of wall capacity that the operator will deploy in the cushion, assumes 2 decimals (i.e. 1000 = 10%)
    function setCushionFactor(uint32 cushionFactor_) external;

    /// @notice Set the parameters used to deploy cushion bond markets
    /// @notice Access restricted
    /// @param  duration_ - Duration of cushion bond markets in seconds
    /// @param  debtBuffer_ - Percentage over the initial debt to allow the market to accumulate at any one time. Percent with 3 decimals, e.g. 1_000 = 1 %. See IBondSDA for more info.
    /// @param  depositInterval_ - Target frequency of deposits in seconds. Determines max payout of the bond market. See IBondSDA for more info.
    function setCushionParams(
        uint32 duration_,
        uint32 debtBuffer_,
        uint32 depositInterval_
    ) external;

    /// @notice Set the reserve factor
    /// @notice Access restricted
    /// @param  reserveFactor_ - Percent of treasury reserves to deploy as capacity for market operations, assumes 2 decimals (i.e. 1000 = 10%)
    function setReserveFactor(uint32 reserveFactor_) external;

    /// @notice Set the wall regeneration parameters
    /// @notice Access restricted
    /// @param  wait_ - Minimum duration to wait to reinstate a wall in seconds
    /// @param  threshold_ - Number of price points on other side of moving average to reinstate a wall
    /// @param  observe_ - Number of price points to observe to determine regeneration
    /// @dev    We must see Threshold number of price points that meet our criteria within the last Observe number of price points to regenerate a wall.
    function setRegenParams(
        uint32 wait_,
        uint32 threshold_,
        uint32 observe_
    ) external;

    /// @notice Set the contracts that the Operator deploys bond markets with.
    /// @notice Access restricted
    /// @param  auctioneer_ - Address of the bond auctioneer to use.
    /// @param  callback_ - Address of the callback to use.
    function setBondContracts(IBondSDA auctioneer_, IBondCallback callback_) external;

    /// @notice Initialize the Operator to begin market operations
    /// @notice Access restricted
    /// @notice Can only be called once
    /// @dev    This function executes actions required to start operations that cannot be done prior to the Operator policy being approved by the Kernel.
    function initialize() external;

    /// @notice Regenerate the wall for a side
    /// @notice Access restricted
    /// @param  high_ Whether to regenerate the high side or low side (true = high, false = low)
    /// @dev    This function is an escape hatch to trigger out of cycle regenerations and may be useful when doing migrations of Treasury funds
    function regenerate(bool high_) external;

    /// @notice Deactivate the Operator
    /// @notice Access restricted
    /// @dev    Emergency pause function for the Operator. Prevents market operations from occurring.
    function deactivate() external;

    /// @notice Activate the Operator
    /// @notice Access restricted
    /// @dev    Restart function for the Operator after a pause.
    function activate() external;

    /// @notice Manually close a cushion bond market
    /// @notice Access restricted
    /// @param  high_ Whether to deactivate the high or low side cushion (true = high, false = low)
    /// @dev    Emergency shutdown function for Cushions
    function deactivateCushion(bool high_) external;

    /* ========== VIEW FUNCTIONS ========== */

    /// @notice Returns the full capacity of the specified wall (if it was regenerated now)
    /// @dev    Calculates the capacity to deploy for a wall based on the amount of reserves owned by the treasury and the reserve factor.
    /// @param  high_ - Whether to return the full capacity for the high or low wall
    function fullCapacity(bool high_) external view returns (uint256);

    /// @notice Returns the status variable of the Operator as a Status struct
    function status() external view returns (Status memory);

    /// @notice Returns the config variable of the Operator as a Config struct
    function config() external view returns (Config memory);
}
