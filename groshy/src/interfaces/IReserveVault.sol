// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Interface for the reserve vault (R_min enforcement, circuit breaker)
interface IReserveVault {
    /// @notice Minimum reserve ratio in basis points (e.g. 2000 = 20%)
    function rMinBPS() external view returns (uint16);

    /// @notice Total USDC held in reserve
    function totalAssets() external view returns (uint256);

    /// @notice Reserve ratio as basis points: reserve * 10_000 / totalSupply
    function getCapitalBPS() external view returns (uint256);

    /// @notice Record an emergency EP loan (increases obligations)
    function recordEPLoan(uint256 amount) external;

    /// @notice Reduce tracked EP loan balance on repayment
    function repayEPLoan(uint256 amount) external;

    /// @notice Send reserve asset to user (called by ExitModule)
    function withdrawReserve(address to, uint256 amount) external;

    /// @notice Deposit reserve asset (pull from msg.sender)
    function depositReserve(uint256 amount) external;

    /// @notice Address of the reserve asset (USDC)
    function asset() external view returns (address);
}
