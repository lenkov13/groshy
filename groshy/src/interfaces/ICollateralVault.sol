// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Interface for the collateral vault (used by CreditModule for collateral locking)
interface ICollateralVault {
    /// @notice Lock collateral on behalf of a user (called by CreditModule)
    function lockCollateral(address user, address asset, uint256 amount) external;

    /// @notice Release locked collateral and send to recipient (called by CreditModule)
    function releaseCollateral(address borrower, address asset, uint256 amount, address to) external;

    /// @notice Returns the USD value of an asset amount (18 decimals)
    function getAssetValueUSD(address asset, uint256 amount) external view returns (uint256);
}
