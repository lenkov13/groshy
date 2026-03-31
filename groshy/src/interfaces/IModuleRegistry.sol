// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

enum ModuleRole { EMISSION, RESERVE, CREDIT, EXIT, POLICY, CLEARING }
enum HookType { BEFORE_MINT, AFTER_MINT, BEFORE_BURN, AFTER_BURN, AFTER_TRANSFER }

/// @notice Interface for the GroshY module registry and access control layer
interface IModuleRegistry {
    /// @notice Returns true if module is registered with the given role
    function isRegistered(address module, ModuleRole role) external view returns (bool);

    /// @notice Returns true if module is registered with any role
    function isRegisteredAny(address module) external view returns (bool);

    /// @notice Returns the ordered list of modules for a given hook type
    function getHookModules(HookType hookType) external view returns (address[] memory);
}
