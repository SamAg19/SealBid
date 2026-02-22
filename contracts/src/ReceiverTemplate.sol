// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IReceiver} from "./interfaces/IReceiver.sol";

/// @title ReceiverTemplate
/// @notice Abstract base contract for receiving signed reports from the Chainlink KeystoneForwarder.
/// @dev Inherit from this contract and implement `_processReport(metadata, report)`.
///      The forwarder address is immutable — set at deployment, cannot be changed.
///      Use `_decodeMetadata` inside `_processReport` to extract workflow identity
///      (workflowId, workflowName, workflowOwner) for dispatch or validation.
abstract contract ReceiverTemplate is IReceiver, ERC165, Ownable {
    error ReceiverTemplate__InvalidForwarderAddress();
    error ReceiverTemplate__NotForwarder();

    /// @notice The Chainlink KeystoneForwarder address authorised to call onReport.
    address public immutable i_forwarder;

    event ForwarderSet(address indexed forwarder);

    /// @param _forwarderAddress The KeystoneForwarder contract address (cannot be address(0)).
    constructor(address _forwarderAddress) Ownable(msg.sender) {
        if (_forwarderAddress == address(0)) {
            revert ReceiverTemplate__InvalidForwarderAddress();
        }
        i_forwarder = _forwarderAddress;
        emit ForwarderSet(_forwarderAddress);
    }

    /// @inheritdoc IReceiver
    /// @dev Validates the caller is the trusted KeystoneForwarder, then dispatches to _processReport.
    function onReport(bytes calldata metadata, bytes calldata report) external override {
        if (msg.sender != i_forwarder) {
            revert ReceiverTemplate__NotForwarder();
        }
        _processReport(metadata, report);
    }

    /// @notice Implement this function with your contract's business logic.
    /// @dev Use `_decodeMetadata(metadata)` to extract workflowName for dispatch.
    /// @param metadata The metadata bytes encoded by the Forwarder (workflowId, workflowName, workflowOwner).
    /// @param report The ABI-encoded report payload from the workflow.
    function _processReport(bytes calldata metadata, bytes calldata report) internal virtual;

    /// @notice Decodes the metadata bytes passed to onReport.
    /// @param metadata Encoded as abi.encodePacked(bytes32 workflowId, bytes10 workflowName, address workflowOwner).
    /// @return workflowId   The unique identifier of the workflow.
    /// @return workflowName The workflow name, SHA256-hashed and truncated to bytes10.
    /// @return workflowOwner The address of the workflow owner.
    function _decodeMetadata(bytes calldata metadata)
        internal
        pure
        returns (bytes32 workflowId, bytes10 workflowName, address workflowOwner)
    {
        assembly {
            workflowId    := calldataload(metadata.offset)
            workflowName  := calldataload(add(metadata.offset, 32))
            workflowOwner := shr(mul(12, 8), calldataload(add(metadata.offset, 42)))
        }
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC165, IERC165)
        returns (bool)
    {
        return interfaceId == type(IReceiver).interfaceId || super.supportsInterface(interfaceId);
    }
}
