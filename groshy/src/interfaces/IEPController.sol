// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Interface for the Emission Protocol controller (on-chain central bank)
interface IEPController {
    /// @notice Returns the current effective key rate in basis points (accounts for signalled changes)
    function getCurrentRate() external view returns (uint256);

    /// @notice Returns the target rate in basis points
    function rTargetBPS() external view returns (uint256);
}
