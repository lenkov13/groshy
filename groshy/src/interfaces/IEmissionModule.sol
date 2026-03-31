// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IModule.sol";

enum EmissionType { COLLATERAL, MUTUAL_CREDIT, ADMIN }

/// @notice Interface for GROSH emission modules (CollateralVault, CreditLedger)
interface IEmissionModule is IModule {
    /// @notice Total value backing the circulating GROSH supply (18 decimals, USD)
    function totalBacking() external view returns (uint256);

    /// @notice Collateral ratio: backing / totalSupply * 1e18
    function collateralRatio() external view returns (uint256);

    /// @notice The emission type implemented by this module
    function emissionType() external pure returns (EmissionType);
}
