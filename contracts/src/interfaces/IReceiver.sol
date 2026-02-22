// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IReceiver - receives keystone reports
/// @notice Implementations must support the IReceiver interface through ERC165.
interface IReceiver is IERC165 {
    /// @notice Handles incoming keystone reports from the Chainlink KeystoneForwarder.
    /// @param metadata Report's metadata (workflowId, workflowName, workflowOwner).
    /// @param report Workflow report payload.
    function onReport(bytes calldata metadata, bytes calldata report) external;
}
