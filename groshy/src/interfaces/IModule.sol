// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Base interface every GroshY module must implement.
/// Hooks are called by GToken on mint/burn/transfer events.
interface IModule {
    /// @notice Returns a unique identifier for this module type
    function moduleType() external pure returns (bytes32);

    /// @notice Called before GToken.mint() — revert to block the mint
    function beforeMint(address to, uint256 amount) external;

    /// @notice Called after GToken.mint() completes (best-effort, no revert)
    function afterMint(address to, uint256 amount) external;

    /// @notice Called before GToken.burn() — revert to block the burn
    function beforeBurn(address from, uint256 amount) external;

    /// @notice Called after GToken.burn() completes (best-effort, no revert)
    function afterBurn(address from, uint256 amount) external;

    /// @notice Called after every GToken transfer (best-effort, no revert)
    function afterTransfer(address from, address to, uint256 amount) external;

    /// @notice Pause the module (called by ModuleRegistry.emergencyPause)
    function pause() external;
}
