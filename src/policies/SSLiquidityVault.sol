// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.15;

// Import system dependencies
import {LENDRv1} from "src/modules/LENDR/LENDR.v1.sol";
import {MINTRv1} from "src/modules/MINTR/MINTR.v1.sol";
import {ROLESv1, RolesConsumer} from "src/modules/ROLES/OlympusRoles.sol";
import "src/Kernel.sol";

// Import internal dependencies
import {ReentrancyGuard} from "solmate/utils/ReentrancyGuard.sol";

// Import external dependencies
import {AggregatorV3Interface} from "src/interfaces/AggregatorV2V3Interface.sol";
import {IVault, JoinPoolRequest, ExitPoolRequest} from "src/interfaces/IBalancerVault.sol";
import {IBasePool} from "src/interfaces/IBasePool.sol";

// Import types
import {ERC20} from "solmate/tokens/ERC20.sol";

/// @title Olympus Single-Sided Liquidity Vault
contract SSLiquidityVault is Policy, ReentrancyGuard, RolesConsumer {
    // ========= ERRORS ========= //

    error SSLiquidityVault_InvalidConstruction();

    // ========= STATE ========= //

    // Modules
    LENDRv1 public LENDR;
    MINTRv1 public MINTR;

    // Tokens
    ERC20 public ohm;
    ERC20 public steth;

    // Balancer Vault
    IVault public vault;

    // Liquidity Pool
    IBasePool public stethOhmPool; // stETH/OHM Balancer pool

    // Price Feeds
    AggregatorV3Interface public ohmEthPriceFeed; // OHM/ETH price feed
    AggregatorV3Interface public ethUsdPriceFeed; // ETH/USD price feed
    AggregatorV3Interface public stethUsdPriceFeed; // stETH/USD price feed

    // User State
    mapping(address => uint256) public stethDeposits; // User stETH deposits
    mapping(address => uint256) public ohmDebtOutstanding; // OHM debt outstanding
    mapping(address => uint256) public lpPositions; // User LP positions

    //============================================================================================//
    //                                      POLICY SETUP                                          //
    //============================================================================================//

    constructor(
        Kernel kernel_,
        address ohm_,
        address steth_,
        address vault_,
        address stethOhmPool_,
        address ohmEthPriceFeed_,
        address ethUsdPriceFeed_,
        address stethUsdPriceFeed_
    ) Policy(kernel_) {
        if (
            address(kernel_) == address(0) ||
            ohm_ == address(0) ||
            steth_ == address(0) ||
            stethOhmPool_ == address(0) ||
            ohmEthPriceFeed_ == address(0) ||
            ethUsdPriceFeed_ == address(0) ||
            stethUsdPriceFeed_ == address(0)
        ) revert SSLiquidityVault_InvalidConstruction();

        // Set tokens
        ohm = ERC20(ohm_);
        steth = ERC20(steth_);

        // Set Balancer vault
        vault = IVault(vault_);

        // Set liquidity pool
        stethOhmPool = IBasePool(stethOhmPool_);

        // Set price feeds
        ohmEthPriceFeed = AggregatorV3Interface(ohmEthPriceFeed_);
        ethUsdPriceFeed = AggregatorV3Interface(ethUsdPriceFeed_);
        stethUsdPriceFeed = AggregatorV3Interface(stethUsdPriceFeed_);
    }

    /// @inheritdoc Policy
    function configureDependencies() external override returns (Keycode[] memory dependencies) {
        dependencies = new Keycode[](3);
        dependencies[0] = toKeycode("LENDR");
        dependencies[1] = toKeycode("MINTR");
        dependencies[2] = toKeycode("ROLES");

        LENDR = LENDRv1(getModuleAddress(dependencies[0]));
        MINTR = MINTRv1(getModuleAddress(dependencies[1]));
        ROLES = ROLESv1(getModuleAddress(dependencies[2]));
    }

    /// @inheritdoc Policy
    function requestPermissions()
        external
        view
        override
        returns (Permissions[] memory permissions)
    {
        permissions = new Permissions[](6);
        permissions[0] = Permissions(MINTR.KEYCODE(), MINTR.mintOhm.selector);
        permissions[1] = Permissions(MINTR.KEYCODE(), MINTR.burnOhm.selector);
        permissions[2] = Permissions(MINTR.KEYCODE(), MINTR.increaseMintApproval.selector);
        permissions[3] = Permissions(MINTR.KEYCODE(), MINTR.decreaseMintApproval.selector);
        permissions[4] = Permissions(LENDR.KEYCODE(), LENDR.borrow.selector);
        permissions[5] = Permissions(LENDR.KEYCODE(), LENDR.repay.selector);
    }

    //============================================================================================//
    //                                       CORE FUNCTIONS                                       //
    //============================================================================================//

    /// @dev    This needs to be nonReentrant since the contract only knows the amount of LP tokens it
    //          receives after an external interaction with the Balancer pool
    function depositAndLP(uint256 stethAmount_) external nonReentrant returns (uint256 amountOut) {
        // Calculate how much OHM the user needs to borrow
        uint256 ohmToBorrow = _valueCollateral(stethAmount_);

        // Update state about user's deposits and borrows
        stethDeposits[msg.sender] += stethAmount_;
        ohmDebtOutstanding[msg.sender] += ohmToBorrow;

        // Take stETH from user
        steth.transferFrom(msg.sender, address(this), stethAmount_);

        // Borrow OHM
        LENDR.borrow(ohmToBorrow);
        MINTR.mintOhm(address(this), ohmToBorrow);

        // OHM-stETH BPT Before
        uint256 bptBefore = ERC20(address(stethOhmPool)).balanceOf(address(this));

        address[] memory assets = new address[](2);
        assets[0] = address(ohm);
        assets[1] = address(steth);

        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[0] = ohmToBorrow;
        maxAmountsIn[1] = stethAmount_;

        // Join Balancer pool
        JoinPoolRequest memory joinPoolRequest = JoinPoolRequest({
            assets: assets,
            maxAmountsIn: maxAmountsIn,
            userData: abi.encode(1, [ohmToBorrow, stethAmount_], 0),
            fromInternalBalance: false
        });
        vault.joinPool(stethOhmPool.getPoolId(), address(this), address(this), joinPoolRequest);

        // OHM-stETH BPT After
        uint256 bptAfter = ERC20(address(stethOhmPool)).balanceOf(address(this));
        amountOut = bptAfter - bptBefore;

        lpPositions[msg.sender] += amountOut;
    }

    function unwindAndRepay(uint256 lpAmount_) external nonReentrant returns (uint256) {
        lpPositions[msg.sender] -= lpAmount_;

        uint256 expectedOhmAmount; // TODO
        uint256 expectedStethAmount; // TODO

        // OHM and stETH Before
        uint256 ohmBefore = ohm.balanceOf(address(this));
        uint256 stethBefore = steth.balanceOf(address(this));

        address[] memory assets = new address[](2);
        assets[0] = address(ohm);
        assets[1] = address(steth);

        uint256[] memory minAmountsOut = new uint256[](2);
        minAmountsOut[0] = expectedOhmAmount;
        minAmountsOut[1] = expectedStethAmount;

        // Withdraw stETH from Balancer pool
        ExitPoolRequest memory exitPoolRequest = ExitPoolRequest({
            assets: assets,
            minAmountsOut: minAmountsOut,
            userData: abi.encode(1, lpAmount_),
            toInternalBalance: false
        });
        vault.exitPool(
            stethOhmPool.getPoolId(),
            address(this),
            payable(address(this)),
            exitPoolRequest
        );

        uint256 ohmReceived = ohm.balanceOf(address(this)) - ohmBefore;
        uint256 stethReceived = steth.balanceOf(address(this)) - stethBefore;

        MINTR.burnOhm(address(this), ohmReceived);
        steth.transfer(msg.sender, stethReceived);

        return stethReceived;
    }

    //============================================================================================//
    //                                     INTERNAL FUNCTIONS                                     //
    //============================================================================================//

    function _valueCollateral(uint256 amount_) internal view returns (uint256) {
        (, int256 stethPrice_, , , ) = stethUsdPriceFeed.latestRoundData();
        (, int256 ohmPrice_, , , ) = ohmEthPriceFeed.latestRoundData();
        (, int256 ethPrice_, , , ) = ethUsdPriceFeed.latestRoundData();

        uint256 ohmUsd = uint256((ohmPrice_ * ethPrice_) / 1e18);

        return (amount_ * uint256(stethPrice_)) / ohmUsd;
    }
}
