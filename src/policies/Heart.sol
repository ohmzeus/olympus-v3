// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.11;

import {ReentrancyGuard} from "solmate/utils/ReentrancyGuard.sol";
import {Auth, Authority} from "solmate/auth/Auth.sol";

import {IHeart} from "./interfaces/IHeart.sol";
import {IOperator} from "./interfaces/IOperator.sol";

import {OlympusPrice} from "../modules/PRICE.sol";

import {Kernel, Policy} from "../Kernel.sol";

import {TransferHelper} from "libraries/TransferHelper.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

/// @title  Olympus Heart
/// @notice Olympus Heart (Policy) Contract
/// @dev    The Olympus Heart contract provides keeper rewards to call the heart beat function which fuels
///         Olympus market operations. The Heart orchestrates state updates in the correct order to ensure
///         market operations use up to date information.
/// @author Oighty, Zeus, indigo
contract Heart is IHeart, Policy, ReentrancyGuard, Auth {
    using TransferHelper for ERC20;

    /* ========== ERRORS =========== */
    error Heart_OutOfCycle();
    error Heart_BeatStopped();
    error Heart_BeatFailed();
    error Heart_InvalidParams();

    /* ========== EVENTS =========== */

    event Beat(uint256 timestamp);
    event RewardTokenUpdated(ERC20 token);

    /* ========== STATE VARIABLES ========== */

    /// @notice Status of the Heart, false = stopped, true = beating
    bool public active;

    /// @notice Timestamp of the last beat (UTC, in seconds)
    uint256 public lastBeat;

    /// @notice Heart beat frequency, in seconds
    uint256 public frequency;

    /// @notice Reward for beating the Heart (in reward token decimals)
    uint256 public reward;

    /// @notice Reward token address that users are sent for beating the Heart
    ERC20 public rewardToken;

    /// Modules
    OlympusPrice internal PRICE;

    /// Policies
    IOperator internal _operator;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        Kernel kernel_,
        IOperator operator_,
        uint256 frequency_,
        ERC20 rewardToken_,
        uint256 reward_
    ) Policy(kernel_) Auth(address(kernel_), Authority(address(0))) {
        _operator = operator_;

        active = true;
        lastBeat = block.timestamp;
        frequency = frequency_;
        rewardToken = rewardToken_;
        reward = reward_;
    }

    /* ========== FRAMEWORK CONFIGURATION ========== */
    function configureReads() external override {
        PRICE = OlympusPrice(getModuleAddress("PRICE"));
        setAuthority(Authority(getModuleAddress("AUTHR")));
    }

    function requestWrites()
        external
        view
        override
        onlyKernel
        returns (bytes5[] memory permissions)
    {
        permissions = new bytes5[](1);
        permissions[0] = "PRICE";
    }

    /* ========== KEEPER FUNCTIONS ========== */

    /// @inheritdoc IHeart
    function beat() external nonReentrant {
        if (!active) revert Heart_BeatStopped();
        if (block.timestamp < lastBeat + frequency) revert Heart_OutOfCycle();

        /// Update the moving average on the Price module
        PRICE.updateMovingAverage();

        /// Trigger price range update and market operations
        _operator.operate();

        /// Update the last beat timestamp
        lastBeat = block.timestamp;

        /// Issue reward to sender
        _issueReward(msg.sender);

        /// Emit event
        emit Beat(block.timestamp);
    }

    /* ========== INTERNAL FUNCTIONS ========== */
    function _issueReward(address to_) internal {
        rewardToken.safeTransfer(to_, reward);
    }

    /* ========== ADMIN FUNCTIONS ========== */

    /// @inheritdoc IHeart
    function resetBeat() external requiresAuth {
        lastBeat = block.timestamp - frequency;
    }

    /// @inheritdoc IHeart
    function toggleBeat() external requiresAuth {
        active = !active;
    }

    /// @inheritdoc IHeart
    function setReward(uint256 reward_) external requiresAuth {
        reward = reward_;
    }

    /// @inheritdoc IHeart
    function setRewardToken(ERC20 token_) external requiresAuth {
        rewardToken = token_;
        emit RewardTokenUpdated(token_);
    }

    /// @inheritdoc IHeart
    function withdrawUnspentRewards(ERC20 token_) external requiresAuth {
        token_.safeTransfer(msg.sender, token_.balanceOf(address(this)));
    }

    /// @inheritdoc IHeart
    function setFrequency(uint256 frequency_) external requiresAuth {
        if (frequency_ < 1 hours) revert Heart_InvalidParams();
        frequency = frequency_;
    }
}
