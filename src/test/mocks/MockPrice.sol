// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.13;

import { MockERC20, ERC20 } from "solmate/test/utils/mocks/MockERC20.sol";
import { Kernel, Module } from "src/Kernel.sol";

/**
 * @notice Mock implementation of Price to use for testing
 */
contract MockPrice is Module {
    Role public constant KEEPER = Role.wrap("PRICE_Keeper");
    Role public constant GUARDIAN = Role.wrap("PRICE_Guardian");

    uint256 public movingAverage;
    uint256 public lastPrice;
    uint256 public currentPrice;
    uint8 public decimals;
    bool public result;
    uint48 public observationFrequency;

    error Price_CustomError();

    constructor(Kernel kernel_, uint48 observationFrequency_) Module(kernel_) {
        result = true;
        observationFrequency = observationFrequency_;
    }

    /* ========== FRAMEWORK CONFIGURATION ========== */
    function KEYCODE() public pure override returns (Keycode) {
        return toKeycode("PRICE");
    }

    function ROLES() public pure override returns (Role[] memory roles) {
        roles = new Role[](2);
        roles[0] = KEEPER;
        roles[1] = GUARDIAN;
    }

    /* ========== HEART FUNCTIONS ========== */
    function updateMovingAverage() external view {
        if (!result) revert Price_CustomError();
    }

    function setResult(bool result_) external {
        result = result_;
    }

    /* ========== POLICY FUNCTIONS ========== */
    function initialize(uint256[] memory startObservations_, uint48 lastObservationTime_)
        external
    {}

    function changeMovingAverageDuration(uint48 movingAverageDuration_) external {}

    function changeObservationFrequency(uint48 observationFrequency_) external {
        observationFrequency = observationFrequency_;
    }

    /* ========== VIEW FUNCTIONS ========== */
    function getMovingAverage() external view returns (uint256) {
        return movingAverage;
    }

    function getLastPrice() external view returns (uint256) {
        return lastPrice;
    }

    function getCurrentPrice() external view returns (uint256) {
        return currentPrice;
    }

    /* ========== TESTING FUNCTIONS ========== */
    function setMovingAverage(uint256 movingAverage_) external {
        movingAverage = movingAverage_;
    }

    function setLastPrice(uint256 lastPrice_) external {
        lastPrice = lastPrice_;
    }

    function setCurrentPrice(uint256 currentPrice_) external {
        currentPrice = currentPrice_;
    }

    function setDecimals(uint8 decimals_) external {
        decimals = decimals_;
    }
}
