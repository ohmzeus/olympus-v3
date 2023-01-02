// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.15;

import {Test, stdError} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {UserFactory} from "test/lib/UserFactory.sol";

import {FullMath} from "libraries/FullMath.sol";

import {MockERC20, ERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockPriceFeed} from "test/mocks/MockPriceFeed.sol";
import {MockVault} from "test/mocks/MockVault.sol";
import {MockBalancerPool} from "test/mocks/MockBalancerPool.sol";

import {OlympusMinter, OHM} from "modules/MINTR/OlympusMinter.sol";
import {OlympusRoles, ROLESv1} from "modules/ROLES/OlympusRoles.sol";
import {RolesAdmin} from "policies/RolesAdmin.sol";
import {StethLiquidityAMO} from "policies/lending/StethLiquidityAMO.sol";

import "src/Kernel.sol";

contract MockOhm is ERC20 {
    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals
    ) ERC20(_name, _symbol, _decimals) {}

    function mint(address to, uint256 value) public virtual {
        _mint(to, value);
    }

    function burnFrom(address from, uint256 value) public virtual {
        _burn(from, value);
    }
}

// solhint-disable-next-line max-states-count
contract StethLiquidityAMOTest is Test {
    using FullMath for uint256;

    UserFactory public userCreator;
    address internal alice;
    address public godmode;

    MockOhm internal ohm;
    MockERC20 internal steth;
    MockERC20 internal reward;
    MockERC20 internal reward2;

    MockPriceFeed internal ohmEthPriceFeed;
    MockPriceFeed internal ethUsdPriceFeed;
    MockPriceFeed internal stethUsdPriceFeed;

    MockVault internal vault;
    MockBalancerPool internal liquidityPool;

    Kernel internal kernel;
    OlympusMinter internal minter;
    OlympusRoles internal roles;

    RolesAdmin internal rolesAdmin;
    StethLiquidityAMO internal liquidityAMO;

    uint256 internal constant STETH_AMOUNT = 1e18;
    uint256[] internal minTokenAmounts_ = [1e7, 1e18];

    function setUp() public {
        {
            // Deploy mock users
            userCreator = new UserFactory();
            address[] memory users = userCreator.create(1);
            alice = users[0];
        }

        {
            // Deploy mock tokens
            ohm = new MockOhm("Olympus", "OHM", 9);
            steth = new MockERC20("Staked ETH", "stETH", 18);
            reward = new MockERC20("Reward Token", "REWARD", 18);
            reward2 = new MockERC20("Reward Token 2", "REWARD2", 18);
        }

        {
            // Deploy mock price feeds
            ohmEthPriceFeed = new MockPriceFeed();
            ethUsdPriceFeed = new MockPriceFeed();
            stethUsdPriceFeed = new MockPriceFeed();

            ohmEthPriceFeed.setDecimals(18);
            ethUsdPriceFeed.setDecimals(18);
            stethUsdPriceFeed.setDecimals(18);

            ohmEthPriceFeed.setLatestAnswer(1e16); // 0.01 ETH
            ethUsdPriceFeed.setLatestAnswer(1e21); // 1000 USD
            stethUsdPriceFeed.setLatestAnswer(1e21); // 1000 USD
        }

        {
            // Deploy mock Balancer contracts
            liquidityPool = new MockBalancerPool();
            vault = new MockVault(address(liquidityPool), address(ohm), address(steth));
            vault.setPoolAmounts(1e7, 1e18);
        }

        {
            // Deploy kernel
            kernel = new Kernel();

            // Deploy modules
            minter = new OlympusMinter(kernel, address(ohm));
            roles = new OlympusRoles(kernel);
        }

        {
            // Deploy roles admin
            rolesAdmin = new RolesAdmin(kernel);

            // Deploy stETH Single Sided Liquidity Vault
            liquidityAMO = new StethLiquidityAMO(
                kernel,
                address(ohm),
                address(steth),
                address(vault),
                address(liquidityPool),
                address(ohmEthPriceFeed),
                address(ethUsdPriceFeed),
                address(stethUsdPriceFeed)
            );
        }

        {
            // Initialize system and kernel

            // Initialize modules
            kernel.executeAction(Actions.InstallModule, address(minter));
            kernel.executeAction(Actions.InstallModule, address(roles));

            // Approve policies
            kernel.executeAction(Actions.ActivatePolicy, address(rolesAdmin));
            kernel.executeAction(Actions.ActivatePolicy, address(liquidityAMO));
        }

        {
            // Set roles
            rolesAdmin.grantRole("liquidityamo_admin", address(this));
        }

        {
            // Set price variation threshold to 10%
            liquidityAMO.setThreshold(100);

            // Add reward token
            liquidityAMO.addRewardToken(address(reward), 1e18, block.timestamp); // 1 REWARD token per second

            reward.mint(address(liquidityAMO), 1e23);
        }

        {
            // Mint stETH to alice
            steth.mint(alice, STETH_AMOUNT);

            // Approve AMO to spend alice's stETH
            vm.prank(alice);
            steth.approve(address(liquidityAMO), STETH_AMOUNT);
        }
    }

    /// [X]  deposit
    ///     [X]  Can be accessed by anyone
    ///     [X]  Increases user's stETH deposit
    ///     [X]  Correctly values stETH in terms of OHM
    ///     [X]  Transfers stETH from user
    ///     [X]  Deposits stETH and OHM into Balancer LP
    ///     [X]  Updates user's tracked LP position

    function testCorrectness_depositCanBeCalledByAnyone(address user_) public {
        vm.assume(user_ != address(0));
        steth.mint(user_, 1e18);
        vm.startPrank(user_);
        steth.approve(address(liquidityAMO), 1e18);
        liquidityAMO.deposit(1e18, 1e18);
        vm.stopPrank();
    }

    function testCorrectness_depositIncreasesUserStethDeposit() public {
        vm.prank(alice);
        liquidityAMO.deposit(STETH_AMOUNT, 1e18);

        assertEq(liquidityAMO.pairTokenDeposits(alice), STETH_AMOUNT);
    }

    function testCorrectness_depositCorrectlyValuesSteth() public {
        vm.prank(alice);
        liquidityAMO.deposit(1e11, 1e18);

        assertEq(ohm.balanceOf(address(vault)), 1);
    }

    function testCorrectness_depositTransfersStethFromUser() public {
        vm.prank(alice);
        liquidityAMO.deposit(STETH_AMOUNT, 1e18);

        assertEq(steth.balanceOf(alice), 0);
    }

    function testCorrectness_depositDepositsStethAndOhmToVault() public {
        vm.prank(alice);
        liquidityAMO.deposit(STETH_AMOUNT, 1e18);

        assertEq(steth.balanceOf(address(vault)), STETH_AMOUNT);
        assertEq(ohm.balanceOf(address(vault)), STETH_AMOUNT / 1e11);
    }

    function testCorrectness_depositUpdatesUserTrackedLpPosition() public {
        vm.prank(alice);
        liquidityAMO.deposit(STETH_AMOUNT, 1e18);

        assertTrue(liquidityAMO.lpPositions(alice) > 0);
    }

    /// [X]  withdraw
    ///     [X]  Can be accessed by anyone
    ///     [X]  Fails if pool and oracle prices differ substantially
    ///     [X]  Fails if user has no LP position
    ///     [X]  Removes stETH and OHM from Balancer LP
    ///     [X]  Decreases user's stETH deposit value
    ///     [X]  Updates user's reward debts for reward tokens
    ///     [X]  Burns received OHM
    ///     [X]  Transfers stETH to user

    function _withdrawSetUp() internal {
        vm.prank(alice);
        liquidityAMO.deposit(STETH_AMOUNT, 1e18);
    }

    function testCorrectness_withdrawCanBeCalledByAnyone(address user_) public {
        vm.assume(user_ != address(0));
        steth.mint(user_, 1e18);

        // Setup with deposit
        vm.startPrank(user_);
        steth.approve(address(liquidityAMO), 1e18);
        liquidityAMO.deposit(1e18, 1e18);

        // Withdraw
        liquidityAMO.withdraw(1e18, minTokenAmounts_);
        vm.stopPrank();
    }

    function testCorrectness_withdrawFailsIfPricesDiffer() public {
        // Setup
        _withdrawSetUp();

        // Set pool price
        vault.setPoolAmounts(1e7, 10e18);

        bytes memory err = abi.encodeWithSignature("LiquidityAMO_PoolImbalanced()");
        vm.expectRevert(err);

        // Attempt withdrawal
        vm.prank(alice);
        liquidityAMO.withdraw(1e18, minTokenAmounts_);

        // Set pool price
        vault.setPoolAmounts(1e9, 10e18);

        // Expect revert again
        vm.expectRevert(err);

        // Attempt withdrawal
        vm.prank(alice);
        liquidityAMO.withdraw(1e18, minTokenAmounts_);
    }

    function testCorrectness_withdrawFailsIfUserHasNoLpPosition() public {
        // Expect revert
        vm.expectRevert(stdError.arithmeticError);

        // Attempt withdrawal
        vm.prank(alice);
        liquidityAMO.withdraw(1e18, minTokenAmounts_);
    }

    function testCorrectness_withdrawRemovesStethAndOhmFromVault() public {
        // Setup
        _withdrawSetUp();

        // Verify initial state
        assertEq(steth.balanceOf(address(vault)), STETH_AMOUNT);
        assertEq(ohm.balanceOf(address(vault)), STETH_AMOUNT / 1e11);

        // Withdraw
        vm.prank(alice);
        liquidityAMO.withdraw(1e18, minTokenAmounts_);

        // Verify end state
        assertEq(steth.balanceOf(address(vault)), 0);
        assertEq(ohm.balanceOf(address(vault)), 0);
    }

    function testCorrectness_withdrawDecreasesUserStethDeposit() public {
        // Setup
        _withdrawSetUp();

        // Verify initial state
        assertEq(liquidityAMO.pairTokenDeposits(alice), STETH_AMOUNT);

        // Withdraw
        vm.prank(alice);
        liquidityAMO.withdraw(1e18, minTokenAmounts_);

        // Verify end state
        assertEq(liquidityAMO.pairTokenDeposits(alice), 0);
    }

    function testCorrectness_withdrawUpdatesRewardDebt() public {
        // Setup
        _withdrawSetUp();

        // Withdraw
        vm.prank(alice);
        liquidityAMO.withdraw(1e18, minTokenAmounts_);

        // Verify end state
        assertEq(liquidityAMO.userRewardDebts(alice, address(reward)), 0);
    }

    function testCorrectness_withdrawBurnsOhm() public {
        // Setup
        _withdrawSetUp();

        // Verify initial state
        assertEq(ohm.balanceOf(address(vault)), STETH_AMOUNT / 1e11);

        // Withdraw
        vm.prank(alice);
        liquidityAMO.withdraw(1e18, minTokenAmounts_);

        // Verify end state
        assertEq(ohm.balanceOf(address(liquidityAMO)), 0);
    }

    function testCorrectness_withdrawReturnsStethToUser() public {
        // Setup
        _withdrawSetUp();

        // Verify initial state
        assertEq(steth.balanceOf(alice), 0);

        // Withdraw
        vm.prank(alice);
        liquidityAMO.withdraw(1e18, minTokenAmounts_);

        // Verify end state
        assertEq(steth.balanceOf(alice), 1e18);
    }

    /// [X]  withdrawAndClaim
    ///     [X]  Can be accessed by anyone
    ///     [X]  Fails if pool and oracle prices differ substantially
    ///     [X]  Claims rewards
    ///     [X]  Returns correct rewards with multiple users
    ///     [X]  Fails if user has no LP positions
    ///     [X]  Removes stETH and OHM from Balancer LP
    ///     [X]  Decreases user's stETH deposit value
    ///     [X]  Updates user's reward debts for reward tokens
    ///     [X]  Burns received OHM
    ///     [X]  Transfers stETH to user

    function _withdrawAndClaimSetUp() internal {
        _withdrawSetUp();
        vm.warp(block.timestamp + 10); // Increase time 10 seconds so there are rewards
    }

    function testCorrectness_withdrawAndClaimCanBeCalledByAnyone(address user_) public {
        vm.assume(user_ != address(0));
        steth.mint(user_, 1e18);

        // Setup with deposit
        vm.startPrank(user_);
        steth.approve(address(liquidityAMO), 1e18);
        liquidityAMO.deposit(1e18, 1e18);

        // Withdraw and claim
        liquidityAMO.withdrawAndClaim(1e18, minTokenAmounts_);
        vm.stopPrank();
    }

    function testCorrectness_withdrawAndClaimFailsIfPricesDiffer() public {
        // Setup
        _withdrawAndClaimSetUp();

        // Set pool price
        vault.setPoolAmounts(1e7, 10e18);

        bytes memory err = abi.encodeWithSignature("LiquidityAMO_PoolImbalanced()");
        vm.expectRevert(err);

        // Attempt withdrawal
        vm.prank(alice);
        liquidityAMO.withdrawAndClaim(1e18, minTokenAmounts_);

        // Set pool price
        vault.setPoolAmounts(1e9, 10e18);

        // Expect revert again
        vm.expectRevert(err);

        // Attempt withdrawal
        vm.prank(alice);
        liquidityAMO.withdrawAndClaim(1e18, minTokenAmounts_);
    }

    function testCorrectness_withdrawAndClaimClaimsRewards() public {
        // Setup
        _withdrawAndClaimSetUp();

        // Verify initial state
        assertEq(reward.balanceOf(alice), 0);

        // Withdraw and claim
        vm.prank(alice);
        liquidityAMO.withdrawAndClaim(1e18, minTokenAmounts_);

        // Verify end state
        assertEq(reward.balanceOf(alice), 10e18);
    }

    function testCorrectness_withdrawAndClaimsReturnsCorrectRewardsMultiUser(address user_) public {
        vm.assume(user_ != address(0) && user_ != alice);

        // Setup
        _withdrawAndClaimSetUp();

        // Add second depositor
        vm.startPrank(user_);
        steth.mint(user_, 1e18);
        steth.approve(address(liquidityAMO), 1e18);
        liquidityAMO.deposit(1e18, 1e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 10); // Increase time by 10 seconds

        // Alice's rewards should be 15 REWARD tokens
        // 10 for the first 10 blocks and 5 for the second 10 blocks
        // Verify initial state
        assertEq(reward.balanceOf(alice), 0);

        // Withdraw and claim
        vm.prank(alice);
        liquidityAMO.withdrawAndClaim(1e18, minTokenAmounts_);

        // Verify end state
        assertEq(reward.balanceOf(alice), 15e18);
    }

    function testCorrectness_withdrawAndClaimFailsIfUserHasNoLpPosition() public {
        // Expect revert
        vm.expectRevert(stdError.arithmeticError);

        // Attempt withdrawal
        vm.prank(alice);
        liquidityAMO.withdrawAndClaim(1e18, minTokenAmounts_);
    }

    function testCorrectness_withdrawAndClaimRemovesStethAndOhmFromVault() public {
        // Setup
        _withdrawAndClaimSetUp();

        // Verify initial state
        assertEq(steth.balanceOf(address(vault)), STETH_AMOUNT);
        assertEq(ohm.balanceOf(address(vault)), STETH_AMOUNT / 1e11);

        // Withdraw and claim
        vm.prank(alice);
        liquidityAMO.withdrawAndClaim(1e18, minTokenAmounts_);

        // Verify end state
        assertEq(steth.balanceOf(address(vault)), 0);
        assertEq(ohm.balanceOf(address(vault)), 0);
    }

    function testCorrectness_withdrawAndClaimDecreasesUserStethDeposit() public {
        // Setup
        _withdrawAndClaimSetUp();

        // Verify initial state
        assertEq(liquidityAMO.pairTokenDeposits(alice), STETH_AMOUNT);

        // Withdraw and claim
        vm.prank(alice);
        liquidityAMO.withdrawAndClaim(1e18, minTokenAmounts_);

        // Verify end state
        assertEq(liquidityAMO.pairTokenDeposits(alice), 0);
    }

    function testCorrectness_withdrawAndClaimUpdatesRewardDebt() public {
        // Setup
        _withdrawAndClaimSetUp();

        // Withdraw and claim
        vm.prank(alice);
        liquidityAMO.withdrawAndClaim(1e18, minTokenAmounts_);

        // Verify end state
        assertEq(liquidityAMO.userRewardDebts(alice, address(reward)), 0);
    }

    function testCorrectness_withdrawAndClaimBurnsOhm() public {
        // Setup
        _withdrawAndClaimSetUp();

        // Verify initial state
        assertEq(ohm.balanceOf(address(vault)), STETH_AMOUNT / 1e11);

        // Withdraw and claim
        vm.prank(alice);
        liquidityAMO.withdrawAndClaim(1e18, minTokenAmounts_);

        // Verify end state
        assertEq(ohm.balanceOf(address(liquidityAMO)), 0);
    }

    function testCorrectness_withdrawAndClaimTransfersStethToUser() public {
        // Setup
        _withdrawAndClaimSetUp();

        // Verify initial state
        assertEq(steth.balanceOf(alice), 0);

        // Withdraw and claim
        vm.prank(alice);
        liquidityAMO.withdrawAndClaim(1e18, minTokenAmounts_);

        // Verify end state
        assertEq(steth.balanceOf(alice), 1e18);
    }

    /// [X]  claimRewards
    ///     [X]  Can be accessed by anyone
    ///     [X]  Returns correct amount of rewards for one token and one user
    ///     [X]  Returns correct amount of rewards for one token and multiple users
    ///     [X]  Returns correct amount of rewards for multiple tokens and multiple users

    function _claimRewardsAddToken() internal {
        // Add reward token
        liquidityAMO.addRewardToken(address(reward2), 1e18, block.timestamp); // 1 REWARD2 token per second
        reward2.mint(address(liquidityAMO), 1e23);
    }

    function testCorrectness_claimRewardsCanBeAccessedByAnyone() public {
        // Setup
        _withdrawAndClaimSetUp();

        // Claim rewards
        vm.prank(alice);
        liquidityAMO.claimRewards();
    }

    function testCorrectness_claimRewardsOneTokenOneUser() public {
        // Setup
        _withdrawAndClaimSetUp();

        // Verify initial state
        assertEq(reward.balanceOf(alice), 0);

        // Claim rewards
        vm.prank(alice);
        liquidityAMO.claimRewards();

        // Verify end state
        assertEq(reward.balanceOf(alice), 10e18);
    }

    function testCorrectness_claimRewardsOneTokenMultipleUsers(address user_) public {
        vm.assume(user_ != address(0) && user_ != alice && user_ != address(liquidityAMO));

        // Setup
        _withdrawAndClaimSetUp();

        // Add second depositor
        vm.startPrank(user_);
        steth.mint(user_, 1e18);
        steth.approve(address(liquidityAMO), 1e18);
        liquidityAMO.deposit(1e18, 1e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 10); // Increase time by 10 seconds

        // Alice's rewards should be 15 REWARD tokens
        // 10 for the first 10 blocks and 5 for the second 10 blocks
        // User's rewards should be 5 REWARD tokens
        // Verify initial state
        assertEq(reward.balanceOf(alice), 0);
        assertEq(reward.balanceOf(user_), 0);

        // Claim Alice's rewards
        vm.prank(alice);
        liquidityAMO.claimRewards();

        // Verify end state
        assertEq(reward.balanceOf(alice), 15e18);
        assertEq(liquidityAMO.rewardsForToken(0, user_), 5e18);
    }

    function testCorrectness_claimRewardsMultipleTokensMultipleUsers(address user_) public {
        vm.assume(user_ != address(0) && user_ != alice && user_ != address(liquidityAMO));

        // Setup
        _withdrawAndClaimSetUp();
        _claimRewardsAddToken();

        // Add second depositor
        vm.startPrank(user_);
        steth.mint(user_, 1e18);
        steth.approve(address(liquidityAMO), 1e18);
        liquidityAMO.deposit(1e18, 1e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 10); // Increase time by 10 seconds

        // Alice's rewards should be 15 REWARD tokens and 5 REWARD2 token
        // User's rewards should be 5 REWARD tokens and 5 REWARD2 tokens
        // Verify initial state
        assertEq(reward.balanceOf(alice), 0);
        assertEq(reward2.balanceOf(alice), 0);
        assertEq(reward.balanceOf(user_), 0);
        assertEq(reward2.balanceOf(user_), 0);

        // Claim Alice's rewards
        vm.prank(alice);
        liquidityAMO.claimRewards();

        // Verify end state
        assertEq(reward.balanceOf(alice), 15e18);
        assertEq(reward2.balanceOf(alice), 5e18);
        assertEq(liquidityAMO.rewardsForToken(0, user_), 5e18);
        assertEq(liquidityAMO.rewardsForToken(1, user_), 5e18);
    }

    // ========= VIEW TESTS ========= //

    /// [X]  rewardsForToken
    /// [X]  getOhmEmissions

    function testCorrectness_rewardsForToken(address user_) public {
        vm.assume(user_ != address(0) && user_ != alice && user_ != address(liquidityAMO));

        // Setup
        _withdrawAndClaimSetUp();
        _claimRewardsAddToken();

        // Add second depositor
        vm.startPrank(user_);
        steth.mint(user_, 1e18);
        steth.approve(address(liquidityAMO), 1e18);
        liquidityAMO.deposit(1e18, 1e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 10); // Increase time by 10 seconds

        // Alice's rewards should be 15 REWARD tokens and 5 REWARD2 token
        // User's rewards should be 5 REWARD tokens and 5 REWARD2 tokens
        assertEq(liquidityAMO.rewardsForToken(0, alice), 15e18);
        assertEq(liquidityAMO.rewardsForToken(1, alice), 5e18);
        assertEq(liquidityAMO.rewardsForToken(0, user_), 5e18);
        assertEq(liquidityAMO.rewardsForToken(1, user_), 5e18);
    }

    function testCorrectness_getOhmEmissions() public {
        // Setup
        _withdrawSetUp();

        // Verify initial state
        (uint256 emissions, uint256 removals) = liquidityAMO.getOhmEmissions();
        assertEq(emissions, 0);
        assertEq(removals, 0);

        // Pools change in price
        vault.setPoolAmounts(2e7, 1e18);
        ohmEthPriceFeed.setLatestAnswer(2e16);

        // Verify end state
        (emissions, removals) = liquidityAMO.getOhmEmissions();
        assertEq(emissions, 0);
        assertEq(removals, 1e7);
    }

    // ========= ADMIN TESTS ========= //

    /// [X]  addRewardToken
    ///     [X]  Can only be called by admin
    ///     [X]  Adds reward token correctly

    function testCorrectness_addRewardTokenCanOnlyBeCalledByAdmin(address user_) public {
        vm.assume(user_ != address(this));

        bytes memory err = abi.encodeWithSelector(
            ROLESv1.ROLES_RequireRole.selector,
            bytes32("liquidityamo_admin")
        );
        vm.expectRevert(err);

        vm.prank(user_);
        liquidityAMO.addRewardToken(address(reward), 1e18, block.timestamp);
    }

    function testCorrectness_addRewardTokenCorrectlyAddsToken() public {
        // Add reward token
        liquidityAMO.addRewardToken(address(reward2), 1e18, block.timestamp); // 1 REWARD2 token per second

        // Verify state
        (
            address token,
            uint256 rewardsPerSecond,
            ,
            uint256 accumulatedRewardsPerShare
        ) = liquidityAMO.rewardTokens(1);
        assertEq(token, address(reward2));
        assertEq(rewardsPerSecond, 1e18);
        assertEq(accumulatedRewardsPerShare, 0);
    }

    /// [X]  setThreshold
    ///     [X]  Can only be called by admin
    ///     [X]  Sets threshold correctly

    function testCorrectness_setThresholdCanOnlyBeCalledByAdmin(address user_) public {
        vm.assume(user_ != address(this));

        bytes memory err = abi.encodeWithSelector(
            ROLESv1.ROLES_RequireRole.selector,
            bytes32("liquidityamo_admin")
        );
        vm.expectRevert(err);

        vm.prank(user_);
        liquidityAMO.setThreshold(200);
    }

    function testCorrectness_setThresholdCorrectlySetsThreshold() public {
        // Set threshold
        liquidityAMO.setThreshold(200);

        // Verify state
        assertEq(liquidityAMO.THRESHOLD(), 200);
    }

    /// [X]  setFee
    ///     [X]  Can only be called by admin
    ///     [X]  Sets fee correctly

    function testCorrectness_setFeeCanOnlyBeCalledByAdmin(address user_) public {
        vm.assume(user_ != address(this));

        bytes memory err = abi.encodeWithSelector(
            ROLESv1.ROLES_RequireRole.selector,
            bytes32("liquidityamo_admin")
        );
        vm.expectRevert(err);

        vm.prank(user_);
        liquidityAMO.setFee(10);
    }

    function testCorrectness_setFeeCorrectlySetsFee() public {
        // Set fee
        liquidityAMO.setFee(10);

        // Verify state
        assertEq(liquidityAMO.FEE(), 10);
    }
}
