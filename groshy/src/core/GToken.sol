// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../interfaces/IModule.sol";
import "../interfaces/IModuleRegistry.sol";

/// @title GToken — the GROSH ERC-20 token
/// @notice Minting and burning is controlled by registered modules.
///         All registered modules are called via the hook system on every mint/burn/transfer.
contract GToken is ERC20, ERC20Permit, Ownable, Pausable {
    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    IModuleRegistry public registry;

    /// @notice Maximum total supply (0 = unlimited)
    uint256 public maxSupply;

    /// @notice Gas cap per individual hook call (prevents a single bad module from bricking the system)
    uint256 public hookGasLimit;

    /// @notice Separate flag to pause transfers without pausing the whole token
    bool public transfersPaused;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event Mint(address indexed to, uint256 amount);
    event Burn(address indexed from, uint256 amount);
    event HookExecuted(HookType indexed hookType, address indexed module, bool success);
    event RegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event HookGasLimitUpdated(uint256 oldLimit, uint256 newLimit);
    event MaxSupplyUpdated(uint256 oldMax, uint256 newMax);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error NotEmissionOrCreditModule();
    error NotRegisteredModule();
    error HookReverted(address module);
    error MaxSupplyExceeded();
    error TransfersPaused();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @param name_        Token name (e.g. "GroshY")
    /// @param symbol_      Token symbol (e.g. "GRSH")
    /// @param maxSupply_   Max mintable supply (0 = unlimited)
    /// @param hookGasLimit_ Gas limit per hook call (default: 200_000)
    /// @param owner_       Initial owner (Gnosis Safe recommended)
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 maxSupply_,
        uint256 hookGasLimit_,
        address owner_
    ) ERC20(name_, symbol_) ERC20Permit(name_) Ownable(owner_) {
        maxSupply = maxSupply_;
        hookGasLimit = hookGasLimit_ == 0 ? 200_000 : hookGasLimit_;
    }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyEmissionOrCredit() {
        if (address(registry) != address(0)) {
            bool isEmission = registry.isRegistered(msg.sender, ModuleRole.EMISSION);
            bool isCredit = registry.isRegistered(msg.sender, ModuleRole.CREDIT);
            if (!isEmission && !isCredit) revert NotEmissionOrCreditModule();
        } else {
            // Before registry is set, only owner can mint (useful during initial setup)
            if (msg.sender != owner()) revert NotEmissionOrCreditModule();
        }
        _;
    }

    modifier onlyRegisteredModule() {
        if (address(registry) != address(0)) {
            if (!registry.isRegisteredAny(msg.sender)) revert NotRegisteredModule();
        } else {
            if (msg.sender != owner()) revert NotRegisteredModule();
        }
        _;
    }

    // -------------------------------------------------------------------------
    // Mint / Burn
    // -------------------------------------------------------------------------

    /// @notice Mint GROSH. Only callable by registered EMISSION or CREDIT modules.
    /// @dev Executes BEFORE_MINT hooks (reverts if any fail), mints, then AFTER_MINT hooks (best-effort).
    function mint(address to, uint256 amount) external whenNotPaused onlyEmissionOrCredit {
        if (maxSupply != 0 && totalSupply() + amount > maxSupply) revert MaxSupplyExceeded();

        _executeHooks(HookType.BEFORE_MINT, address(0), to, amount, true);
        _mint(to, amount);
        _executeHooks(HookType.AFTER_MINT, address(0), to, amount, false);

        emit Mint(to, amount);
    }

    /// @notice Burn GROSH. Only callable by any registered module.
    /// @dev Executes BEFORE_BURN hooks (reverts if any fail), burns, then AFTER_BURN hooks (best-effort).
    function burn(address from, uint256 amount) external whenNotPaused onlyRegisteredModule {
        _executeHooks(HookType.BEFORE_BURN, from, address(0), amount, true);
        _burn(from, amount);
        _executeHooks(HookType.AFTER_BURN, from, address(0), amount, false);

        emit Burn(from, amount);
    }

    // -------------------------------------------------------------------------
    // Hook execution
    // -------------------------------------------------------------------------

    /// @dev Override OZ v5 _update to fire AFTER_TRANSFER hooks on transfers (not mints/burns)
    function _update(address from, address to, uint256 value) internal override {
        if (transfersPaused && from != address(0) && to != address(0)) {
            revert TransfersPaused();
        }
        super._update(from, to, value);
        // Fire AFTER_TRANSFER only on actual transfers (not mint/burn)
        if (from != address(0) && to != address(0)) {
            _executeHooks(HookType.AFTER_TRANSFER, from, to, value, false);
        }
    }

    /// @dev Execute hooks for the given hook type. Reverts on failure when revertOnFail=true.
    function _executeHooks(
        HookType hookType,
        address addr1,
        address addr2,
        uint256 amount,
        bool revertOnFail
    ) internal {
        if (address(registry) == address(0)) return;

        address[] memory modules = registry.getHookModules(hookType);
        for (uint256 i = 0; i < modules.length; i++) {
            address module = modules[i];
            bytes memory data = _encodeHookCall(hookType, addr1, addr2, amount);

            (bool success,) = module.call{gas: hookGasLimit}(data);
            emit HookExecuted(hookType, module, success);

            if (!success && revertOnFail) revert HookReverted(module);
        }
    }

    function _encodeHookCall(
        HookType hookType,
        address addr1,
        address addr2,
        uint256 amount
    ) internal pure returns (bytes memory) {
        if (hookType == HookType.BEFORE_MINT) {
            return abi.encodeCall(IModule.beforeMint, (addr2, amount));
        } else if (hookType == HookType.AFTER_MINT) {
            return abi.encodeCall(IModule.afterMint, (addr2, amount));
        } else if (hookType == HookType.BEFORE_BURN) {
            return abi.encodeCall(IModule.beforeBurn, (addr1, amount));
        } else if (hookType == HookType.AFTER_BURN) {
            return abi.encodeCall(IModule.afterBurn, (addr1, amount));
        } else {
            return abi.encodeCall(IModule.afterTransfer, (addr1, addr2, amount));
        }
    }

    // -------------------------------------------------------------------------
    // Configuration — onlyOwner
    // -------------------------------------------------------------------------

    function setRegistry(address newRegistry) external onlyOwner {
        emit RegistryUpdated(address(registry), newRegistry);
        registry = IModuleRegistry(newRegistry);
    }

    function setHookGasLimit(uint256 limit) external onlyOwner {
        require(limit >= 50_000 && limit <= 2_000_000, "GToken: gas limit out of range");
        emit HookGasLimitUpdated(hookGasLimit, limit);
        hookGasLimit = limit;
    }

    function setMaxSupply(uint256 newMax) external onlyOwner {
        require(newMax >= totalSupply() || newMax == 0, "GToken: below current supply");
        emit MaxSupplyUpdated(maxSupply, newMax);
        maxSupply = newMax;
    }

    function pauseTransfers() external onlyOwner {
        transfersPaused = true;
    }

    function unpauseTransfers() external onlyOwner {
        transfersPaused = false;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
