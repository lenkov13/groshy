// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IModule.sol";
import "../interfaces/IModuleRegistry.sol";
import "../interfaces/IGToken.sol";

/// @title ModuleRegistry — ACL and hook router for the GroshY protocol
/// @notice Tracks registered modules and their roles. Module registration is timelocked
///         (48h by default) except during the initial one-time setup call.
contract ModuleRegistry is IModuleRegistry, Ownable {
    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    struct ModuleInfo {
        bytes32 moduleType;
        ModuleRole role;
        bool active;
        uint256 registeredAt;
    }

    struct PendingRegistration {
        ModuleRole role;
        HookType[] hooks;
        uint256 scheduledAt;
        bool exists;
    }

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    IGToken public immutable gtoken;

    mapping(address => ModuleInfo) public modules;
    mapping(address => address[]) public modulesByRole; // role index → address list (role cast to uint8 used as key via helper)
    mapping(address => address[]) internal _modulesByRoleInternal;

    // role enum → module list
    mapping(ModuleRole => address[]) public moduleListByRole;

    // hookType → ordered module addresses
    mapping(HookType => address[]) internal hookModules;

    // pending timelock registrations
    mapping(address => PendingRegistration) public pendingRegistrations;

    uint256 public timelockDelay; // seconds, default 48h
    bool public initialSetupDone;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event ModuleRegistered(address indexed module, bytes32 moduleType, ModuleRole role);
    event ModuleDeregistered(address indexed module);
    event RegistrationScheduled(address indexed module, uint256 executeAfter);
    event HookOrderSet(HookType indexed hookType, address[] modules);
    event TimelockDelayUpdated(uint256 oldDelay, uint256 newDelay);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error AlreadyRegistered();
    error NotRegistered();
    error TimelockNotElapsed();
    error NoPendingRegistration();
    error InitialSetupAlreadyDone();
    error InvalidModule();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(address gtoken_, uint256 timelockDelay_, address owner_) Ownable(owner_) {
        gtoken = IGToken(gtoken_);
        timelockDelay = timelockDelay_ == 0 ? 172_800 : timelockDelay_;
    }

    // -------------------------------------------------------------------------
    // IModuleRegistry
    // -------------------------------------------------------------------------

    function isRegistered(address module, ModuleRole role) external view override returns (bool) {
        return modules[module].active && modules[module].role == role;
    }

    function isRegisteredAny(address module) external view override returns (bool) {
        return modules[module].active;
    }

    function getHookModules(HookType hookType) external view override returns (address[] memory) {
        return hookModules[hookType];
    }

    // -------------------------------------------------------------------------
    // Registration — with timelock
    // -------------------------------------------------------------------------

    /// @notice Schedule a module registration (subject to timelock)
    function scheduleRegistration(
        address module,
        ModuleRole role,
        HookType[] calldata hooks
    ) external onlyOwner {
        if (modules[module].active) revert AlreadyRegistered();
        if (IModule(module).moduleType() == bytes32(0)) revert InvalidModule();

        pendingRegistrations[module] = PendingRegistration({
            role: role,
            hooks: hooks,
            scheduledAt: block.timestamp,
            exists: true
        });

        emit RegistrationScheduled(module, block.timestamp + timelockDelay);
    }

    /// @notice Execute a scheduled registration after the timelock has elapsed
    function executeRegistration(address module) external onlyOwner {
        PendingRegistration storage pending = pendingRegistrations[module];
        if (!pending.exists) revert NoPendingRegistration();
        if (block.timestamp < pending.scheduledAt + timelockDelay) revert TimelockNotElapsed();
        if (modules[module].active) revert AlreadyRegistered();

        _register(module, pending.role, pending.hooks);
        delete pendingRegistrations[module];
    }

    /// @notice One-time initial setup: register all core modules without timelock.
    ///         Must be called immediately after deployment. Cannot be called again.
    function initialSetup(
        address emission,
        ModuleRole emissionRole,
        HookType[] calldata emissionHooks,
        address reserve,
        HookType[] calldata reserveHooks,
        address credit,
        HookType[] calldata creditHooks,
        address exit_,
        HookType[] calldata exitHooks,
        address policy,
        HookType[] calldata policyHooks
    ) external onlyOwner {
        if (initialSetupDone) revert InitialSetupAlreadyDone();
        initialSetupDone = true;

        if (emission != address(0)) _register(emission, emissionRole, emissionHooks);
        if (reserve != address(0)) _register(reserve, ModuleRole.RESERVE, reserveHooks);
        if (credit != address(0)) _register(credit, ModuleRole.CREDIT, creditHooks);
        if (exit_ != address(0)) _register(exit_, ModuleRole.EXIT, exitHooks);
        if (policy != address(0)) _register(policy, ModuleRole.POLICY, policyHooks);
    }

    // -------------------------------------------------------------------------
    // Deregistration
    // -------------------------------------------------------------------------

    function deregisterModule(address module) external onlyOwner {
        if (!modules[module].active) revert NotRegistered();

        ModuleRole role = modules[module].role;
        modules[module].active = false;

        // Remove from role list
        address[] storage roleList = moduleListByRole[role];
        for (uint256 i = 0; i < roleList.length; i++) {
            if (roleList[i] == module) {
                roleList[i] = roleList[roleList.length - 1];
                roleList.pop();
                break;
            }
        }

        // Remove from all hook lists
        for (uint8 h = 0; h <= uint8(HookType.AFTER_TRANSFER); h++) {
            HookType ht = HookType(h);
            address[] storage hList = hookModules[ht];
            for (uint256 i = 0; i < hList.length; i++) {
                if (hList[i] == module) {
                    hList[i] = hList[hList.length - 1];
                    hList.pop();
                    break;
                }
            }
        }

        emit ModuleDeregistered(module);
    }

    // -------------------------------------------------------------------------
    // Hook order
    // -------------------------------------------------------------------------

    /// @notice Set the execution order for a specific hook type (replaces current order)
    function setHookOrder(HookType hookType, address[] calldata ordered) external onlyOwner {
        // Validate all addresses are registered modules
        for (uint256 i = 0; i < ordered.length; i++) {
            require(modules[ordered[i]].active, "ModuleRegistry: not a registered module");
        }
        hookModules[hookType] = ordered;
        emit HookOrderSet(hookType, ordered);
    }

    // -------------------------------------------------------------------------
    // Emergency
    // -------------------------------------------------------------------------

    /// @notice Emergency pause a module — immediate, no timelock
    function emergencyPause(address module) external onlyOwner {
        // Calls pause() on the module if it supports it
        (bool success,) = module.call(abi.encodeWithSignature("pause()"));
        require(success, "ModuleRegistry: pause failed");
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    function setTimelockDelay(uint256 newDelay) external onlyOwner {
        emit TimelockDelayUpdated(timelockDelay, newDelay);
        timelockDelay = newDelay;
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function getModulesByRole(ModuleRole role) external view returns (address[] memory) {
        return moduleListByRole[role];
    }

    function getModuleInfo(address module) external view returns (ModuleInfo memory) {
        return modules[module];
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    function _register(address module, ModuleRole role, HookType[] memory hooks) internal {
        modules[module] = ModuleInfo({
            moduleType: IModule(module).moduleType(),
            role: role,
            active: true,
            registeredAt: block.timestamp
        });
        moduleListByRole[role].push(module);

        for (uint256 i = 0; i < hooks.length; i++) {
            hookModules[hooks[i]].push(module);
        }

        emit ModuleRegistered(module, IModule(module).moduleType(), role);
    }
}
