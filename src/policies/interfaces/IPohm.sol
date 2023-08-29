// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.0;

interface IPohm {
    // ========= ERRORS ========= //

    error POHM_NoClaim();
    error POHM_AlreadyHasClaim();
    error POHM_NoWalletChange();
    error POHM_AllocationLimitViolation();
    error POHM_ClaimMoreThanVested();
    error POHM_ClaimMoreThanMax();

    // ========= EVENTS ========= //

    event Claim(address indexed account, uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 amount);

    // ========= DATA STRUCTURES ========= //

    struct Term {
        uint256 percent; // PRECISION = 1_000_000 (i.e. 5000 = 0.5%)
        uint256 gClaimed; // Rebase agnostic # of tokens claimed
        uint256 max; // Maximum nominal OHM amount claimable
    }

    //============================================================================================//
    //                                       CORE FUNCTIONS                                       //
    //============================================================================================//

    /// @notice Claims vested OHM by exchanging DAI
    /// @param  to_ Address to send OHM to
    /// @param  amount_ Amount of OHM to claim
    function claim(address to_, uint256 amount_) external;

    //============================================================================================//
    //                                   MANAGEMENT FUNCTIONS                                     //
    //============================================================================================//

    /// @notice Transfers a portion of a user's claim to another address
    /// @param  to_ Address to send claim to
    /// @param  amount_ Amount of claim to send. Represents a chunk of the user's "percent" value in their terms
    function transfer(address to_, uint256 amount_) external;

    /// @notice Pushes entirety of a user's claim to a new address
    /// @param  newAddress_ Address to send claim to
    function pushWalletChange(address newAddress_) external;

    /// @notice Pulls a queued wallet change
    /// @param  oldAddress_ Address to pull change from
    function pullWalletChange(address oldAddress_) external;

    //============================================================================================//
    //                                       VIEW FUNCTIONS                                       //
    //============================================================================================//

    /// @notice Calculates the current amount a user is eligible to redeem
    /// @param account_ The account to check the redeemable amount for
    /// @return uint256 The amount of OHM the account can redeem
    function redeemableFor(address account_) external view returns (uint256);

    /// @notice Returns a calculation of OHM circulating supply to be used to determine vested positions
    /// @return uint256 OHM circulating supply
    function getCirculatingSupply() external view returns (uint256);

    /// @notice Calculates the effective amount of OHM claimed taking into consideration rebasing since claim
    /// @param account_ The account to check the claim for
    /// @return uint256 The amount of OHM the account has claimed
    function getAccountClaimed(address account_) external returns (uint256);

    //============================================================================================//
    //                                       ADMIN FUNCTIONS                                      //
    //============================================================================================//

    /// @notice Migrates claim data from old pOHM contracts to this one
    /// @notice Can only be called by the pohm_admin role
    /// @param  accounts_ Array of accounts to migrate
    function migrate(address[] calldata accounts_) external;

    /// @notice Sets the claim terms for an account
    /// @notice Can only be called by the pohm_admin role
    /// @param  account_ The account to set the terms for
    /// @param  percent_ The percent of the circulating supply the account is entitled to
    /// @param  gClaimed_ The amount of gOHM the account has claimed
    /// @param  max_ The maximum amount of OHM the account can claim
    function setTerms(address account_, uint256 percent_, uint256 gClaimed_, uint256 max_) external;
}

interface IPreviousPohm {
    function terms(address account_) external view returns (IPohm.Term memory);
}
