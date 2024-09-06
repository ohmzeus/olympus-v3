// SPDX-License-Identifier: Unlicense
pragma solidity >=0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {UserFactory} from "test/lib/UserFactory.sol";

import {BondFixedTermSDA} from "test/lib/bonds/BondFixedTermSDA.sol";
import {BondAggregator} from "test/lib/bonds/BondAggregator.sol";
import {BondFixedTermTeller} from "test/lib/bonds/BondFixedTermTeller.sol";
import {RolesAuthority, Authority as SolmateAuthority} from "solmate/auth/authorities/RolesAuthority.sol";

import {MockERC20, ERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockERC4626, ERC4626} from "solmate/test/utils/mocks/MockERC4626.sol";
import {MockPrice} from "test/mocks/MockPrice.sol";
import {MockOhm} from "test/mocks/MockOhm.sol";
import {MockClearinghouse} from "test/mocks/MockClearinghouse.sol";

import {IBondSDA} from "interfaces/IBondSDA.sol";
import {IBondAggregator} from "interfaces/IBondAggregator.sol";

import {FullMath} from "libraries/FullMath.sol";

import "src/Kernel.sol";
import {OlympusRange} from "modules/RANGE/OlympusRange.sol";
import {OlympusTreasury} from "modules/TRSRY/OlympusTreasury.sol";
import {OlympusMinter} from "modules/MINTR/OlympusMinter.sol";
import {OlympusRoles} from "modules/ROLES/OlympusRoles.sol";
import {RolesAdmin} from "policies/RolesAdmin.sol";
import {Protocoloop} from "policies/ProtocoLoop.sol";
import {Operator} from "policies/Operator.sol";
import {BondCallback} from "policies/BondCallback.sol";

// solhint-disable-next-line max-states-count
contract ProtocoLoopTest is Test {
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
    BondFixedTermSDA internal auctioneer;
    MockOhm internal ohm;
    MockERC20 internal reserve;
    MockERC4626 internal wrappedReserve;

    Kernel internal kernel;
    MockPrice internal PRICE;
    OlympusRange internal RANGE;
    OlympusTreasury internal TRSRY;
    OlympusMinter internal MINTR;
    OlympusRoles internal ROLES;

    MockClearinghouse internal clearinghouse;
    Protocoloop internal protocoloop;
    RolesAdmin internal rolesAdmin;
    BondCallback internal callback; // only used by operator, not by protocoloop
    Operator internal operator;

    uint256 initialReserves = 105_000_000e18;
    uint256 initialConversionRate = 1_05e16;
    uint256 initialPrincipalReceivables = 100_000_000e18;
    uint256 initialYield = 50_000e18 + ((initialPrincipalReceivables * 5) / 1000) / 52;

    function setUp() public {
        vm.warp(51 * 365 * 24 * 60 * 60); // Set timestamp at roughly Jan 1, 2021 (51 years since Unix epoch)
        userCreator = new UserFactory();
        {
            /// Deploy bond system to test against
            address[] memory users = userCreator.create(5);
            alice = users[0];
            bob = users[1];
            guardian = users[2];
            policy = users[3];
            heart = users[4];
            auth = new RolesAuthority(guardian, SolmateAuthority(address(0)));

            /// Deploy the bond system
            aggregator = new BondAggregator(guardian, auth);
            teller = new BondFixedTermTeller(guardian, aggregator, guardian, auth);
            auctioneer = new BondFixedTermSDA(teller, aggregator, guardian, auth);

            /// Register auctioneer on the bond system
            vm.prank(guardian);
            aggregator.registerAuctioneer(auctioneer);
        }

        {
            /// Deploy mock tokens
            ohm = new MockOhm("Olympus", "OHM", 9);
            reserve = new MockERC20("Reserve", "RSV", 18);
            wrappedReserve = new MockERC4626(reserve, "wrappedReserve", "sRSV");
        }

        {
            /// Deploy kernel
            kernel = new Kernel(); // this contract will be the executor

            /// Deploy modules (some mocks)
            PRICE = new MockPrice(kernel, uint48(8 hours), 10 * 1e18);
            RANGE = new OlympusRange(
                kernel,
                ERC20(ohm),
                ERC20(reserve),
                uint256(100),
                [uint256(2000), uint256(2500)],
                [uint256(2000), uint256(2500)]
            );
            TRSRY = new OlympusTreasury(kernel);
            MINTR = new OlympusMinter(kernel, address(ohm));
            ROLES = new OlympusRoles(kernel);

            /// Configure mocks
            PRICE.setMovingAverage(10 * 1e18);
            PRICE.setLastPrice(10 * 1e18);
            PRICE.setDecimals(18);
            PRICE.setLastTime(uint48(block.timestamp));
        }

        {
            // Deploy mock clearinghouse
            clearinghouse = new MockClearinghouse(address(reserve), address(wrappedReserve));

            /// Deploy bond callback
            callback = new BondCallback(kernel, IBondAggregator(address(aggregator)), ohm);

            /// Deploy operator
            operator = new Operator(
                kernel,
                IBondSDA(address(auctioneer)),
                callback,
                [address(ohm), address(reserve), address(wrappedReserve)],
                [
                    uint32(2000), // cushionFactor
                    uint32(5 days), // duration
                    uint32(100_000), // debtBuffer
                    uint32(1 hours), // depositInterval
                    uint32(1000), // reserveFactor
                    uint32(1 hours), // regenWait
                    uint32(5), // regenThreshold
                    uint32(7) // regenObserve
                    // uint32(8 hours) // observationFrequency
                ]
            );

            /// Deploy protocol loop
            protocoloop = new Protocoloop(
                kernel,
                address(ohm),
                address(reserve),
                address(wrappedReserve),
                address(teller),
                address(auctioneer),
                address(clearinghouse),
                initialReserves,
                initialConversionRate,
                initialYield
            );

            /// Deploy ROLES administrator
            rolesAdmin = new RolesAdmin(kernel);
        }

        {
            /// Initialize system and kernel

            /// Install modules
            kernel.executeAction(Actions.InstallModule, address(PRICE));
            kernel.executeAction(Actions.InstallModule, address(RANGE));
            kernel.executeAction(Actions.InstallModule, address(TRSRY));
            kernel.executeAction(Actions.InstallModule, address(MINTR));
            kernel.executeAction(Actions.InstallModule, address(ROLES));

            /// Approve policies
            kernel.executeAction(Actions.ActivatePolicy, address(protocoloop));
            kernel.executeAction(Actions.ActivatePolicy, address(callback));
            kernel.executeAction(Actions.ActivatePolicy, address(operator));
            kernel.executeAction(Actions.ActivatePolicy, address(rolesAdmin));
        }
        {
            /// Configure access control

            /// Protocoloop ROLES
            rolesAdmin.grantRole("heart", address(heart));
            rolesAdmin.grantRole("loop_daddy", guardian);

            /// Operator ROLES
            rolesAdmin.grantRole("operator_admin", address(guardian));
        }

        // Mint tokens to users, clearinghouse, and TRSRY for testing
        uint256 testOhm = 1_000_000 * 1e9;
        uint256 testReserve = 1_000_000 * 1e18;

        ohm.mint(alice, testOhm * 20);

        reserve.mint(address(TRSRY), testReserve * 80);
        reserve.mint(address(clearinghouse), testReserve * 20);

        // Deposit TRSRY reserves into wrappedReserve
        vm.startPrank(address(TRSRY));
        reserve.approve(address(wrappedReserve), testReserve * 80);
        wrappedReserve.deposit(testReserve * 80, address(TRSRY));
        vm.stopPrank();

        // Deposit clearinghouse reserves into wrappedReserve
        vm.startPrank(address(clearinghouse));
        reserve.approve(address(wrappedReserve), testReserve * 20);
        wrappedReserve.deposit(testReserve * 20, address(clearinghouse));
        vm.stopPrank();

        // Mint additional reserve to the wrapped reserve to hit the initial conversion rate
        reserve.mint(address(wrappedReserve), 5 * testReserve);

        // Approve the bond teller for the tokens to swap
        vm.prank(alice);
        ohm.approve(address(teller), testOhm * 20);

        // Initialise the operator so that the range prices are set
        vm.prank(guardian);
        operator.initialize();

        // Set principal receivables for the clearinghouse
        clearinghouse.setPrincipalReceivables(uint256(100_000_000e18));
    }

    function _mintYield() internal {
        // Get the balance of reserves in the wrappedReserve contract
        uint256 wrappedReserveBalance = wrappedReserve.totalAssets();

        // Calculate the yield to mint (0.01%)
        uint256 yield = wrappedReserveBalance / 10000;

        // Mint the yield
        reserve.mint(address(wrappedReserve), yield);
    }

    // test cases
    // [X] setup (contructor + configureDependencies)
    //   [X] addresses are set correctly
    //   [X] initial reserve balance is set correctly
    //   [X] initial conversion rate is set correctly
    //   [X] initial yield is set correctly
    //   [X] epoch is set correctly
    // [X] endEpoch
    //   [X] when contract is shutdown
    //     [X] nothing happens
    //   [X] when contract is not shutdown
    //     [X] when epoch is not divisible by 3
    //       [X] nothing happens
    //     [X] when epoch is divisible by 3
    //       [X] when epoch == epochLength
    //         [X] The yield earned on the wrapped reserves over the past 21 epochs is withdrawn from the TRSRY (affecting the balanceInDai and bidAmount)
    //         [X] OHM in the contract is burned and reserves are added at the backing rate
    //         [X] a new bond market is created with correct bid amount
    //       [X] when epoch != epochLength
    //         [X] OHM in the contract is burned and reserves are added at the backing rate
    //         [X] a new bond market is created with correct bid amount
    // [X] adjustNextYield
    // [X] shutdown
    // [X] getNextYield
    // [X] getReserveBalance

    function test_setup() public {
        // addresses are set correctly
        assertEq(address(protocoloop.ohm()), address(ohm));
        assertEq(address(protocoloop.dai()), address(reserve));
        assertEq(address(protocoloop.sdai()), address(wrappedReserve));
        assertEq(address(protocoloop.teller()), address(teller));
        assertEq(address(protocoloop.auctioneer()), address(auctioneer));

        // initial reserve balance is set correctly
        assertEq(protocoloop.lastReserveBalance(), initialReserves);
        assertEq(protocoloop.getReserveBalance(), initialReserves);

        // initial conversion rate is set correctly
        assertEq(protocoloop.lastConversionRate(), initialConversionRate);
        assertEq((wrappedReserve.totalAssets() * 1e18) / wrappedReserve.totalSupply(), 1_05e16);

        // initial yield is set correctly
        assertEq(protocoloop.nextYield(), initialYield);

        // epoch is set correctly
        assertEq(protocoloop.epoch(), 20);
    }

    function test_endEpoch_firstCall() public {
        // Mint yield to the wrappedReserve
        _mintYield();

        // Get the ID of the next bond market from the aggregator
        uint256 nextBondMarketId = aggregator.marketCounter();

        // Cache the TRSRY sDAI balance
        uint256 trsryBalance = wrappedReserve.balanceOf(address(TRSRY));

        vm.prank(heart);
        protocoloop.endEpoch();

        // Check that the initial yield was withdrawn from the TRSRY
        assertEq(
            wrappedReserve.balanceOf(address(TRSRY)),
            trsryBalance - wrappedReserve.previewWithdraw(initialYield)
        );

        // Check that the protocoloop contract has the correct reserve balance
        assertEq(reserve.balanceOf(address(protocoloop)), initialYield / 7);
        assertEq(
            wrappedReserve.balanceOf(address(protocoloop)),
            wrappedReserve.previewDeposit(initialYield - initialYield / 7)
        );

        // Check that the bond market was created
        assertEq(aggregator.marketCounter(), nextBondMarketId + 1);

        // Check that the market params are correct
        {
            uint256 marketPrice = auctioneer.marketPrice(nextBondMarketId);
            (
                address owner,
                ERC20 payoutToken,
                ERC20 quoteToken,
                address callbackAddr,
                bool isCapacityInQuote,
                uint256 capacity,
                ,
                uint256 minPrice,
                uint256 maxPayout,
                ,
                ,
                uint256 scale
            ) = auctioneer.markets(nextBondMarketId);

            assertEq(owner, address(protocoloop));
            assertEq(address(payoutToken), address(reserve));
            assertEq(address(quoteToken), address(ohm));
            assertEq(callbackAddr, address(0));
            assertEq(isCapacityInQuote, false);
            assertEq(capacity, uint256(initialYield) / 7);
            assertEq(maxPayout, capacity / 6);

            assertEq(scale, 10 ** uint8(36 + 18 - 9 + 0));
            assertEq(
                marketPrice,
                ((uint256(1e36) / 10e18) * 10 ** uint8(36 + 1)) / 10 ** uint8(18 + 1)
            );
            assertEq(
                minPrice,
                (((uint256(1e36) / ((10e18 * 120e16) / 1e18))) * 10 ** uint8(36 + 1)) /
                    10 ** uint8(18 + 1)
            );
        }

        // Check that the epoch has been incremented
        assertEq(protocoloop.epoch(), 0);
    }

    function test_endEpoch_isShutdown() public {
        // Shutdown the protocoloop contract
        vm.prank(guardian);
        protocoloop.shutdown(new ERC20[](0));

        // Mint yield to the wrappedReserve
        _mintYield();

        // Get the ID of the next bond market from the aggregator
        uint256 nextBondMarketId = aggregator.marketCounter();

        // Cache the TRSRY sDAI balance
        uint256 trsryBalance = wrappedReserve.balanceOf(address(TRSRY));

        vm.prank(heart);
        protocoloop.endEpoch();

        // Check that the initial yield was not withdrawn from the treasury
        assertEq(wrappedReserve.balanceOf(address(TRSRY)), trsryBalance);

        // Check that the protocoloop contract has not received any funds
        assertEq(reserve.balanceOf(address(protocoloop)), 0);
        assertEq(wrappedReserve.balanceOf(address(protocoloop)), 0);

        // Check that the bond market was not created
        assertEq(aggregator.marketCounter(), nextBondMarketId);
    }

    function test_endEpoch_notDivisBy3() public {
        // Mint yield to the wrappedReserve
        _mintYield();

        // Make the initial call to get the epoch counter to reset
        vm.prank(heart);
        protocoloop.endEpoch();

        // Mint yield to the wrappedReserve
        _mintYield();

        // Get the ID of the next bond market from the aggregator
        uint256 nextBondMarketId = aggregator.marketCounter();

        // Cache the TRSRY sDAI balance
        uint256 trsryBalance = wrappedReserve.balanceOf(address(TRSRY));

        // Cache the protocoloop contract reserve balance
        uint256 protocoloopReserveBalance = reserve.balanceOf(address(protocoloop));
        uint256 protocoloopWrappedReserveBalance = wrappedReserve.balanceOf(address(protocoloop));

        // Call end epoch again
        vm.prank(heart);
        protocoloop.endEpoch();

        // Check that a new bond market was not created
        assertEq(aggregator.marketCounter(), nextBondMarketId);

        // Check that the treasury balance has not changed
        assertEq(wrappedReserve.balanceOf(address(TRSRY)), trsryBalance);

        // Check that the protocoloop contract reserve balance has not changed
        assertEq(reserve.balanceOf(address(protocoloop)), protocoloopReserveBalance);
        assertEq(wrappedReserve.balanceOf(address(protocoloop)), protocoloopWrappedReserveBalance);

        // Check that the epoch has been incremented
        assertEq(protocoloop.epoch(), 1);
    }

    function test_endEpoch_divisBy3_notEpochLength() public {
        // Mint yield to the wrappedReserve
        _mintYield();

        // Make the initial call to get the epoch counter to reset
        vm.prank(heart);
        protocoloop.endEpoch();

        // Call end epoch twice to setup our test
        vm.prank(heart);
        protocoloop.endEpoch();
        vm.prank(heart);
        protocoloop.endEpoch();

        // Confirm that the epoch is 2
        assertEq(protocoloop.epoch(), 2);

        // Cache the protocoloop contract reserve balance before any bonds are issued
        uint256 protocoloopReserveBalance = reserve.balanceOf(address(protocoloop));
        uint256 protocoloopWrappedReserveBalance = wrappedReserve.balanceOf(address(protocoloop));

        // Purchase a bond from the existing bond market
        // So that there is some OHM in the contract to burn
        vm.prank(alice);
        (uint256 bondPayout, ) = teller.purchase(alice, address(0), 0, 100e9, 0);

        // Confirm that the protocoloop balance is updated with the bond payout
        assertEq(reserve.balanceOf(address(protocoloop)), protocoloopReserveBalance - bondPayout);
        protocoloopReserveBalance -= bondPayout;

        // Warp forward a day so that the initial bond market ends
        vm.warp(block.timestamp + 1 days);

        // Mint yield to the wrappedReserve
        _mintYield();

        // Get the ID of the next bond market from the aggregator
        uint256 nextBondMarketId = aggregator.marketCounter();

        // Cache the TRSRY sDAI balance
        uint256 trsryBalance = wrappedReserve.balanceOf(address(TRSRY));

        // Cache the OHM balance in the protocoloop contract
        uint256 protocoloopOhmBalance = ohm.balanceOf(address(protocoloop));
        assertEq(protocoloopOhmBalance, 100e9);

        // Call end epoch again
        vm.prank(heart);
        protocoloop.endEpoch();

        // Check that a new bond market was created
        assertEq(aggregator.marketCounter(), nextBondMarketId + 1);

        // Check that the protocoloop contract burned the OHM
        assertEq(ohm.balanceOf(address(protocoloop)), 0);

        // Check that the treasury balance has changed by the amount of backing withdrawn for the burnt OHM
        uint256 daiFromBurnedOhm = 100e9 * protocoloop.backingPerToken();
        assertEq(
            wrappedReserve.balanceOf(address(TRSRY)),
            trsryBalance - wrappedReserve.previewWithdraw(daiFromBurnedOhm)
        );

        // Check that the balance of the protocoloop contract has changed correctly
        uint256 expectedBidAmount = (protocoloopReserveBalance +
            wrappedReserve.previewRedeem(protocoloopWrappedReserveBalance) +
            daiFromBurnedOhm) / 6;

        // Check that the protocoloop contract reserve balances have changed correctly
        assertEq(reserve.balanceOf(address(protocoloop)), expectedBidAmount);
        assertGe(
            wrappedReserve.balanceOf(address(protocoloop)),
            protocoloopWrappedReserveBalance - wrappedReserve.previewWithdraw(expectedBidAmount)
        );

        // Confirm that the bond market has the correct configuration
        {
            uint256 marketPrice = auctioneer.marketPrice(nextBondMarketId);
            (
                ,
                ,
                ,
                ,
                ,
                uint256 capacity,
                ,
                uint256 minPrice,
                uint256 maxPayout,
                ,
                ,
                uint256 scale
            ) = auctioneer.markets(nextBondMarketId);

            assertEq(capacity, expectedBidAmount);
            assertEq(maxPayout, capacity / 6);

            assertEq(scale, 10 ** uint8(36 + 18 - 9 + 0));
            assertEq(
                marketPrice,
                ((uint256(1e36) / 10e18) * 10 ** uint8(36 + 1)) / 10 ** uint8(18 + 1)
            );
            assertEq(
                minPrice,
                (((uint256(1e36) / ((10e18 * 120e16) / 1e18))) * 10 ** uint8(36 + 1)) /
                    10 ** uint8(18 + 1)
            );
        }
    }

    // error ROLES_RequireRole(bytes32 role_);

    function test_adjustNextYield() public {
        // Mint yield to the wrappedReserve
        _mintYield();

        // Call endEpoch to set the next yield
        vm.prank(heart);
        protocoloop.endEpoch();

        // Get the next yield value
        uint256 nextYield = protocoloop.nextYield();

        // Try to call adjustNextYield with an invalid caller
        // Expect it to fail
        vm.expectRevert(
            abi.encodeWithSignature("ROLES_RequireRole(bytes32)", bytes32("loop_daddy"))
        );
        vm.prank(alice);
        protocoloop.adjustNextYield(nextYield);

        // Call adjustNextYield with a value that is too high
        // Expect it to fail
        uint256 newNextYield = (nextYield * 12) / 10;

        vm.expectRevert(abi.encodePacked("Too much increase"));
        vm.prank(guardian);
        protocoloop.adjustNextYield(newNextYield);

        // Call adjustNextYield with a value greater than the current yield but only by 10%
        // Expect it to succeed
        newNextYield = (nextYield * 11) / 10;
        vm.prank(guardian);
        protocoloop.adjustNextYield(newNextYield);

        // Check that the next yield has been adjusted
        assertEq(protocoloop.nextYield(), newNextYield);

        // Call adjustNextYield with a value that is lower than the current yield
        // Expect it to succeed
        newNextYield = (newNextYield * 9) / 10;
        vm.prank(guardian);
        protocoloop.adjustNextYield(newNextYield);

        // Check that the next yield has been adjusted
        assertEq(protocoloop.nextYield(), newNextYield);

        // Call adjustNextYield with a value of zero next yield
        // Expect it to succeed
        vm.prank(guardian);
        protocoloop.adjustNextYield(0);

        // Check that the next yield has been adjusted
        assertEq(protocoloop.nextYield(), 0);
    }

    function test_shutdown() public {
        // Try to call shutdown as an invalid caller
        // Expect it to fail
        vm.expectRevert(
            abi.encodeWithSignature("ROLES_RequireRole(bytes32)", bytes32("loop_daddy"))
        );
        vm.prank(alice);
        protocoloop.shutdown(new ERC20[](0));

        // Mint yield
        _mintYield();

        // Call endEpoch initially to get tokens into the contract
        vm.prank(heart);
        protocoloop.endEpoch();

        // Cache the protocoloop contract reserve balances
        uint256 protocoloopReserveBalance = reserve.balanceOf(address(protocoloop));
        uint256 protocoloopWrappedReserveBalance = wrappedReserve.balanceOf(address(protocoloop));

        // Cache the treasury balances of the reserve tokens
        uint256 trsryReserveBalance = reserve.balanceOf(address(TRSRY));
        uint256 trsryWrappedReserveBalance = wrappedReserve.balanceOf(address(TRSRY));

        // Setup array of tokens to extract
        ERC20[] memory tokens = new ERC20[](2);
        tokens[0] = reserve;
        tokens[1] = wrappedReserve;

        // Call shutdown with an invalid caller
        // Expect it to fail
        vm.expectRevert(
            abi.encodeWithSignature("ROLES_RequireRole(bytes32)", bytes32("loop_daddy"))
        );
        vm.prank(bob);
        protocoloop.shutdown(tokens);

        // Call shutdown with a valid caller
        // Expect it to succeed
        vm.prank(guardian);
        protocoloop.shutdown(tokens);

        // Check that the contract is shutdown
        assertEq(protocoloop.isShutdown(), true);

        // Check that the protocoloop contract reserve balances have been transferred to the TRSRY
        assertEq(reserve.balanceOf(address(protocoloop)), 0);
        assertEq(wrappedReserve.balanceOf(address(protocoloop)), 0);
        assertEq(
            reserve.balanceOf(address(TRSRY)),
            trsryReserveBalance + protocoloopReserveBalance
        );
        assertEq(
            wrappedReserve.balanceOf(address(TRSRY)),
            trsryWrappedReserveBalance + protocoloopWrappedReserveBalance
        );
    }

    function test_getReserveBalance() public {
        // Mint yield
        _mintYield();

        // Call endEpoch initially to get tokens into the contract
        vm.prank(heart);
        protocoloop.endEpoch();

        // Cache yield earning balances in the clearinghouse and treasury
        uint256 clearinghouseWrappedReserveBalance = wrappedReserve.balanceOf(
            address(clearinghouse)
        );
        uint256 trsryWrappedReserveBalance = wrappedReserve.balanceOf(address(TRSRY));

        // Calculate the expected yield earning reserve balance, in reserves
        uint256 expectedYieldEarningReserveBalance = wrappedReserve.previewRedeem(
            clearinghouseWrappedReserveBalance + trsryWrappedReserveBalance
        );

        // Confirm the view function matches
        assertEq(protocoloop.getReserveBalance(), expectedYieldEarningReserveBalance);
    }

    function test_getNextYield() public {
        // Mint yield
        _mintYield();

        // Call endEpoch initially to get tokens into the contract
        vm.prank(heart);
        protocoloop.endEpoch();

        // Get the "last values" from the protocoloop contract
        uint256 lastReserveBalance = protocoloop.lastReserveBalance();
        uint256 lastConversionRate = protocoloop.lastConversionRate();

        // Get the principal receivables from the clearinghouse
        uint256 principalReceivables = clearinghouse.principalReceivables();

        // Mint additional yield to the wrappedReserve
        _mintYield();

        // Calculate the expected next yield
        uint256 expectedNextYield = lastReserveBalance /
            10000 +
            (principalReceivables * 5) /
            1000 /
            52;

        // Confirm the view function matches
        assertEq(protocoloop.getNextYield(), expectedNextYield);
    }
}
