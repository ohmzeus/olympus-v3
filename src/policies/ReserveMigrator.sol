// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.15;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";

import "src/Kernel.sol";
import {RolesConsumer, ROLESv1} from "modules/ROLES/OlympusRoles.sol";
import {TRSRYv1} from "modules/TRSRY/TRSRY.v1.sol";

interface IDaiUsds {
    function daiToUsds(address usr, uint256 wad) external;
}

contract ReserveMigrator is Policy, RolesConsumer {
    // ========== ERRORS ========== //

    error ReserveMigrator_InvalidParams();
    error ReserveMigrator_BadMigration();

    // ========== EVENTS ========== //

    event MigratedReserves(address indexed from, address indexed to, uint256 amount);

    // ========== STATE VARIABLES ========== //

    // Modules
    TRSRYv1 internal TRSRY;

    // Reserves to migrate
    ERC20 public immutable from;
    ERC4626 public immutable sFrom;
    ERC20 public immutable to;
    ERC4626 public immutable sTo;

    // Migration contract
    IDaiUsds public migrator;

    // ========== SETUP ========== //

    constructor(
        Kernel kernel_,
        address from_,
        address sFrom_,
        address to_,
        address sTo_,
        address migrator_
    ) Policy(kernel_) {
        // Confirm the ERC20 tokens are not null
        if (from_ == address(0) || to_ == address(0) || migrator_ == address(0))
            revert ReserveMigrator_InvalidParams();

        from = ERC20(from_);
        sFrom = ERC4626(sFrom_);
        to = ERC20(to_);
        sTo = ERC4626(sTo_);
        migrator = IDaiUsds(migrator_);
    }

    function configureDependencies() external override returns (Keycode[] memory dependencies) {
        dependencies = new Keycode[](2);
        dependencies[0] = toKeycode("TRSRY");
        dependencies[1] = toKeycode("ROLES");

        TRSRY = TRSRYv1(getModuleAddress(dependencies[0]));
        ROLES = ROLESv1(getModuleAddress(dependencies[1]));

        (uint8 TRSRY_MAJOR, ) = TRSRY.VERSION();
        (uint8 ROLES_MAJOR, ) = ROLES.VERSION();

        // Ensure Modules are using the expected major version.
        // Modules should be sorted in alphabetical order.
        bytes memory expected = abi.encode([1, 1]);
        if (ROLES_MAJOR != 1 || TRSRY_MAJOR != 1) revert Policy_WrongModuleVersion(expected);
    }

    function requestPermissions()
        external
        view
        override
        returns (Permissions[] memory permissions)
    {
        Keycode TRSRY_KEYCODE = TRSRY.KEYCODE();

        permissions = new Permissions[](2);
        permissions[0] = Permissions(TRSRY_KEYCODE, TRSRY.withdrawReserves.selector);
        permissions[1] = Permissions(TRSRY_KEYCODE, TRSRY.increaseWithdrawApproval.selector);
    }

    // ========== MIGRATE RESERVES ========== //

    // TODO determine if we need a threshold value that the reserves must exceed before migrating
    function migrate() external {
        // Get the from and sFrom balances from the TRSRY
        // Note: we want actual token balances, not "reserveBalances" that include debt.
        uint256 fromBalance = from.balanceOf(address(TRSRY));
        uint256 sFromBalance = sFrom.balanceOf(address(TRSRY));

        // Withdraw the reserves from the TRSRY
        uint256 total;
        if (fromBalance > 0) {
            // Increase withdrawal approval and withdraw the reserves from the TRSRY
            TRSRY.increaseWithdrawApproval(address(this), from, fromBalance);
            TRSRY.withdrawReserves(address(this), from, fromBalance);
            total += fromBalance;
        }

        if (sFromBalance > 0) {
            // Increase withdrawal approval and withdraw the wrapped reserves from the TRSRY
            TRSRY.increaseWithdrawApproval(address(this), sFrom, sFromBalance);
            TRSRY.withdrawReserves(address(this), sFrom, sFromBalance);

            // Unwrap the reserves
            uint256 received = sFrom.redeem(sFromBalance, address(this), address(this));
            total += received;
        }

        // If the total is greater than 0, migrate the reserves
        if (total > 0) {
            // Approve the migrator for the total amount of from reserves
            from.approve(address(migrator), total);

            // Cache the balance of the to token
            uint256 toBalance = to.balanceOf(address(this));

            // Migrate the reserves
            migrator.daiToUsds(address(this), total);

            uint256 newToBalance = to.balanceOf(address(this));

            // Confirm that the to balance has increased by at least the total amount
            if (newToBalance < toBalance + total) revert ReserveMigrator_BadMigration();

            // Wrap the to reserves and deposit them into the TRSRY
            sTo.deposit(newToBalance, address(TRSRY));

            // Emit event
            emit MigratedReserves(address(from), address(to), total);
        }
    }
}
