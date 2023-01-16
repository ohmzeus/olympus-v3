// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.15;

// Import system dependencies
import "src/Kernel.sol";
import {BaseLiquidityAMO} from "policies/lending/abstracts/BaseLiquidityAMO.sol";

// Import external dependencies
import {AggregatorV3Interface} from "src/interfaces/AggregatorV2V3Interface.sol";
import {JoinPoolRequest, ExitPoolRequest, IVault, IBasePool} from "policies/lending/interfaces/IBalancer.sol";
import {IAuraBooster, IAuraRewardPool} from "policies/lending/interfaces/IAura.sol";

// Import types
import {ERC20} from "solmate/tokens/ERC20.sol";

/// @title Olympus Single-Sided stETH Liquidity AMO
contract StethLiquidityAMO is BaseLiquidityAMO {
    // ========= DATA STRUCTURES ========= //

    struct OracleFeed {
        AggregatorV3Interface feed;
        uint48 updateThreshold;
    }

    struct AuraPool {
        uint256 pid;
        IAuraBooster booster;
        IAuraRewardPool rewardsPool;
    }

    // ========= STATE ========= //

    // Balancer Contracts
    IVault public vault;

    // Aura Pool Info
    AuraPool public auraPool;

    // Price Feeds
    OracleFeed public ohmEthPriceFeed;
    OracleFeed public ethUsdPriceFeed;
    OracleFeed public stethUsdPriceFeed;

    //============================================================================================//
    //                                      POLICY SETUP                                          //
    //============================================================================================//

    constructor(
        Kernel kernel_,
        address ohm_,
        address steth_,
        address vault_,
        address liquidityPool_,
        OracleFeed memory ohmEthPriceFeed_,
        OracleFeed memory ethUsdPriceFeed_,
        OracleFeed memory stethUsdPriceFeed_,
        AuraPool memory auraPool_
    ) BaseLiquidityAMO(kernel_, ohm_, steth_, liquidityPool_) {
        // Set Balancer vault
        vault = IVault(vault_);

        // Set price feeds
        ohmEthPriceFeed = ohmEthPriceFeed_;
        ethUsdPriceFeed = ethUsdPriceFeed_;
        stethUsdPriceFeed = stethUsdPriceFeed_;

        // Set Aura pool info
        auraPool = auraPool_;
    }

    //============================================================================================//
    //                                      ADMIN FUNCTIONS                                       //
    //============================================================================================//

    function changeUpdateThresholds(
        uint48 ohmEthPriceFeedUpdateThreshold_,
        uint48 ethUsdPriceFeedUpdateThreshold_,
        uint48 stethUsdPriceFeedUpdateThreshold_
    ) external onlyRole("liquidityamo_admin") {
        ohmEthPriceFeed.updateThreshold = ohmEthPriceFeedUpdateThreshold_;
        ethUsdPriceFeed.updateThreshold = ethUsdPriceFeedUpdateThreshold_;
        stethUsdPriceFeed.updateThreshold = stethUsdPriceFeedUpdateThreshold_;
    }

    //============================================================================================//
    //                                     INTERNAL FUNCTIONS                                     //
    //============================================================================================//

    function _valueCollateral(uint256 amount_) internal view override returns (uint256) {
        uint256 ohmPrice = _validatePrice(
            address(ohmEthPriceFeed.feed),
            uint256(ohmEthPriceFeed.updateThreshold)
        );
        uint256 ethPrice = _validatePrice(
            address(ethUsdPriceFeed.feed),
            uint256(ethUsdPriceFeed.updateThreshold)
        );
        uint256 stethPrice = _validatePrice(
            address(stethUsdPriceFeed.feed),
            uint256(stethUsdPriceFeed.updateThreshold)
        );

        uint256 ohmUsd = uint256((ohmPrice * ethPrice) / 1e18);

        return (amount_ * ohmUsd) / (uint256(stethPrice) * 1e9);
    }

    function _getPoolPrice() internal view override returns (uint256) {
        (, uint256[] memory balances_, ) = vault.getPoolTokens(
            IBasePool(liquidityPool).getPoolId()
        );

        // In Balancer pools the tokens are listed in alphabetical order (numbers before letters)
        // OHM is listed first, stETH is listed second so this calculates OHM/stETH which is then
        // used to compare against the oracle calculation OHM/stETH price
        return (balances_[0] * 1e18) / balances_[1];
    }

    function _getPoolOhmShare() internal view override returns (uint256) {
        // Cast pool address from abstract to Balancer Base Pool
        IBasePool pool = IBasePool(liquidityPool);

        (, uint256[] memory balances_, ) = vault.getPoolTokens(pool.getPoolId());
        uint256 bptTotalSupply = pool.totalSupply();

        if (totalLP == 0) return 0;
        else return (balances_[0] * totalLP) / bptTotalSupply;
    }

    function _deposit(
        uint256 ohmAmount_,
        uint256 pairAmount_,
        uint256 minLpAmount_
    ) internal override returns (uint256) {
        // Cast pool address from abstract to Balancer Base Pool
        IBasePool pool = IBasePool(liquidityPool);

        // OHM-stETH BPT before
        uint256 bptBefore = pool.balanceOf(address(this));

        // Build join pool request
        address[] memory assets = new address[](2);
        assets[0] = address(ohm);
        assets[1] = address(pairToken);

        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[0] = ohmAmount_;
        maxAmountsIn[1] = pairAmount_;

        JoinPoolRequest memory joinPoolRequest = JoinPoolRequest({
            assets: assets,
            maxAmountsIn: maxAmountsIn,
            userData: abi.encode(1, maxAmountsIn, minLpAmount_),
            fromInternalBalance: false
        });

        // Join Balancer pool
        ohm.approve(address(vault), ohmAmount_);
        pairToken.approve(address(vault), pairAmount_);
        vault.joinPool(pool.getPoolId(), address(this), address(this), joinPoolRequest);

        // OHM-PAIR BPT after
        uint256 lpAmountOut = pool.balanceOf(address(this)) - bptBefore;

        // Stake into Aura
        pool.approve(address(auraPool.booster), lpAmountOut);
        auraPool.booster.deposit(auraPool.pid, lpAmountOut, true);

        return lpAmountOut;
    }

    function _withdraw(uint256 lpAmount_, uint256[] calldata minTokenAmounts_)
        internal
        override
        returns (uint256, uint256)
    {
        // Cast pool adress from abstract to Balancer Base Pool
        IBasePool pool = IBasePool(liquidityPool);

        // OHM and pair token amounts before
        uint256 ohmBefore = ohm.balanceOf(address(this));
        uint256 pairTokenBefore = pairToken.balanceOf(address(this));

        // Build exit pool request
        address[] memory assets = new address[](2);
        assets[0] = address(ohm);
        assets[1] = address(pairToken);

        ExitPoolRequest memory exitPoolRequest = ExitPoolRequest({
            assets: assets,
            minAmountsOut: minTokenAmounts_,
            userData: abi.encode(1, lpAmount_),
            toInternalBalance: false
        });

        // Unstake from Aura
        auraPool.rewardsPool.withdrawAndUnwrap(lpAmount_, false);

        // Exit Balancer pool
        pool.approve(address(vault), lpAmount_);
        vault.exitPool(pool.getPoolId(), address(this), payable(address(this)), exitPoolRequest);

        // OHM and pair token amounts received
        uint256 ohmReceived = ohm.balanceOf(address(this)) - ohmBefore;
        uint256 pairTokenReceived = pairToken.balanceOf(address(this)) - pairTokenBefore;

        return (ohmReceived, pairTokenReceived);
    }

    function _accumulateExternalRewards() internal override returns (uint256[] memory) {
        uint256 numExternalRewards = externalRewardTokens.length;
        uint256[] memory balancesBefore = new uint256[](numExternalRewards);
        for (uint256 i; i < numExternalRewards; ) {
            balancesBefore[i] = ERC20(externalRewardTokens[i].token).balanceOf(address(this));

            unchecked {
                ++i;
            }
        }

        auraPool.rewardsPool.getReward(address(this), true);

        uint256[] memory rewards = new uint256[](numExternalRewards);
        for (uint256 i; i < numExternalRewards; ) {
            rewards[i] =
                ERC20(externalRewardTokens[i].token).balanceOf(address(this)) -
                balancesBefore[i];

            unchecked {
                ++i;
            }
        }
        return rewards;
    }
}
