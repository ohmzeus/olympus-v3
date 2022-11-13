// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.15;

//import {ILayerZeroReceiver} from './interfaces/external/ILayerZeroReciever.sol';
import {ILayerZeroEndpoint} from "./interfaces/external/ILayerZeroEndpoint.sol";

import "src/Kernel.sol";

/// @notice Message bus defining interface for cross-chain communications.
/// @dev Uses LayerZero as communication protocol.
contract OlympusTransmitter is Module {
    enum MessageType {
        TRANSFER,
        GONS
    }

    struct ChainInfo {
        uint256 chainId;
        address busAddr;
    }

    /// @notice LayerZero endpoint
    ILayerZeroEndpoint immutable endpoint;

    /// @notice Address to send gas refunds to. Initialized to deployer.
    address payable public refundAddress;

    ChainInfo[] public chains;

    /*//////////////////////////////////////////////////////////////
                            MODULE INTERFACE
    //////////////////////////////////////////////////////////////*/

    constructor(ILayerZeroEndpoint endpoint_, address payable refundAddr_) {
        endpoint = endpoint_;
        refundAddress = refundAddr_;
    }

    /// @inheritdoc Module
    function KEYCODE() public pure override returns (Keycode) {
        return toKeycode("CCXMT");
    }

    /// @inheritdoc Module
    function VERSION() external pure override returns (uint8 major, uint8 minor) {
        return (1, 0);
    }

    /*//////////////////////////////////////////////////////////////
                               CORE LOGIC
    //////////////////////////////////////////////////////////////*/

    function setRefundAddress(address payable newRefundAddr_) external {
        refundAddress = newRefundAddr_;
    }

    function addChain(uint256 chainId_, address busAddr_) external {
        chains.push(ChainInfo({chainId: chainId_, busAddr: busAddr_}));
    }

    /// @notice Send gons information to all other chains after rebase
    function transmitGons(uint256 gons_) external payable override {
        bytes memory payload = abi.encode(MessageType.GONS, abi.encode(gons_));

        for (uint256 i; i < chains.length; ++i) {
            ChainInfo memory chain = chains[i];

            endpoint.send(
                uint16(chain.chainId),
                abi.encode(chain.busAddr),
                payload,
                refundAddress,
                address(0),
                bytes("")
            );
        }
    }

    // TODO
    function transmitGlobalSupply() external payable override {}

    // TODO Send information needed to mint OHM on another chain
    function transmitTokenTransfer() external payable override {}

    /// @notice Define messages that can be received from other chains.
    function lzReceive(
        uint16 srcChainId_,
        bytes calldata srcAddress_,
        uint64 nonce_,
        bytes calldata payload_
    ) external override {
        if (msg.sender != address(endpoint)) revert CallerMustBeLZEndpoint();

        (MessageType msgType, bytes memory payload) = abi.decode(payload_, (MessageType, bytes));

        if (srcChainId_ == 1) {
            // Proxy logic
        } else {
            // Master logic
            if (msgType == MessageType.TRANSFER) {
                // TODO execute x-chain transfer
            } else if (msgType == MessageType.GONS) {}
        }
    }
}
