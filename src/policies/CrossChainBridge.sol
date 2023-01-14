// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.15;

import {NonblockingLzApp, ILayerZeroEndpoint} from "layer-zero/lzApp/NonblockingLzApp.sol";

import {ReentrancyGuard} from "solmate/utils/ReentrancyGuard.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

import {TransferHelper} from "libraries/TransferHelper.sol";

import {RolesConsumer} from "modules/ROLES/OlympusRoles.sol";
import {ROLESv1} from "modules/ROLES/ROLES.v1.sol";
import {MINTRv1} from "modules/MINTR/MINTR.v1.sol";

import "src/Kernel.sol";

/*
NOTES:
- How to set Owner to the bridge_admin role?
*/

/// @notice Message bridge for cross-chain OHM transfers.
/// @dev Uses LayerZero as communication protocol.
/// @dev Each chain needs to `setTrustedRemoteAddress` for each remote address
///      it intends to receive from.
contract CrossChainBridge is Policy, RolesConsumer, NonblockingLzApp {
    error InsufficientAmount();
    error CallerMustBeLZEndpoint();

    event OffchainTransferred(address sender_, uint256 amount_, uint16 dstChain_);
    event OffchainReceived(address receiver_, uint256 amount_, uint16 srcChain_);
    event ChainStatusUpdated(uint16 chainId_, bool isValid_);

    // Modules
    MINTRv1 public MINTR;

    mapping(uint16 => bool) public validChains;

    ERC20 ohm;

    //============================================================================================//
    //                                      POLICY SETUP                                          //
    //============================================================================================//

    constructor(
        Kernel kernel_,
        address endpoint_
    ) Policy(kernel_) NonblockingLzApp(endpoint_) {}

    /// @inheritdoc Policy
    function configureDependencies() external override returns (Keycode[] memory dependencies) {
        dependencies = new Keycode[](2);
        dependencies[0] = toKeycode("MINTR");
        dependencies[1] = toKeycode("ROLES");

        MINTR = MINTRv1(getModuleAddress(dependencies[0]));
        ROLES = ROLESv1(getModuleAddress(dependencies[1]));

        ohm = ERC20(address(MINTR.ohm()));
    }

    /// @inheritdoc Policy
    function requestPermissions()
        external
        view
        override
        returns (Permissions[] memory permissions)
    {
        permissions = new Permissions[](4);
        permissions[0] = Permissions(MINTR.KEYCODE(), MINTR.mintOhm.selector);
        permissions[1] = Permissions(MINTR.KEYCODE(), MINTR.burnOhm.selector);
        permissions[2] = Permissions(MINTR.KEYCODE(), MINTR.increaseMintApproval.selector);
        permissions[3] = Permissions(MINTR.KEYCODE(), MINTR.decreaseMintApproval.selector);
    }

    //============================================================================================//
    //                                       CORE FUNCTIONS                                       //
    //============================================================================================//

    // TODO can replace nonblockingLzApp by forking only what is necessary into this contract

    // TODO Send information needed to mint OHM on another chain
    function sendOhm(address to_, uint256 amount_, uint16 dstChainId_) external payable {
        if (ohm.balanceOf(msg.sender) < amount_) revert InsufficientAmount();

        bytes memory payload = abi.encode(to_, amount_);

        MINTR.burnOhm(msg.sender, amount_);

        _lzSend(
            dstChainId_,
            payload,
            payable(msg.sender),
            address(0x0),
            bytes(""),
            msg.value
        );

        emit OffchainTransferred(msg.sender, amount_, dstChainId_);
    }

    // TODO receives info to mint to a user's wallet
    function _nonblockingLzReceive(
        uint16 srcChainId_,
        bytes memory srcAddress_,
        uint64 nonce_,
        bytes memory payload_
    ) internal override {
        if (msg.sender != address(lzEndpoint)) revert CallerMustBeLZEndpoint();

        (address to, uint256 amount) = abi.decode(payload_, (address, uint256));

        MINTR.increaseMintApproval(address(this), amount);
        MINTR.mintOhm(to, amount);
        
        emit OffchainReceived(to, amount, srcChainId_);
    }

    // TODO must be called by a `bridge_admin` to be able to set lzApp configuration
    function becomeOwner() external onlyRole("bridge_admin") {
        _transferOwnership(msg.sender);
    }
}
