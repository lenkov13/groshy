// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../interfaces/IModule.sol";
import "../interfaces/IGToken.sol";
import "../interfaces/IReserveVault.sol";

/// @title ExitModule — mechanism for leaving the GROSH system
/// @notice Supports three modes: HARD_PEG (1:1), PSM (1:1 up to cap), AMM (stub for v0.1).
///         Enforces per-user cooldowns, daily exit limits, and a circuit breaker.
contract ExitModule is IModule, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    enum ExitMode { HARD_PEG, PSM, AMM }

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    IGToken public immutable gtoken;
    IReserveVault public reserveVault;

    ExitMode public mode;
    uint16 public exitSpreadBPS;        // exit fee in basis points (30 = 0.3%)
    uint16 public maxExitPerDayBPS;     // max daily exit as % of supply
    uint256 public cooldownBlocks;      // blocks between exits per address
    uint16 public cbThresholdBPS;       // daily exit % triggering circuit breaker

    // PSM mode
    uint256 public psmCapUSD;           // max stablecoin in PSM module (reserve asset native decimals)
    uint256 public psmUsed;             // current PSM utilization (reserve asset native decimals)
    uint8 public immutable stableDecimals; // decimals of the reserve asset (e.g. 6 for USDC)

    // Per-user cooldown
    mapping(address => uint256) public lastExitBlock;

    // Daily tracking
    uint256 public dailyExitAmount;
    uint256 public lastExitResetDay;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event Exit(address indexed user, uint256 groshBurned, uint256 stableOut);
    event PSMSwapGroshToStable(address indexed user, uint256 groshIn, uint256 stableOut);
    event PSMSwapStableToGrosh(address indexed user, uint256 stableIn, uint256 groshOut);
    event CircuitBreakerTriggered(uint256 dailyOutflow, uint256 threshold);
    event ModeChanged(ExitMode newMode);
    event PsmCapUpdated(uint256 newCap);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error CooldownNotElapsed();
    error DailyLimitReached();
    error SlippageExceeded();
    error RMinWouldBeViolated();
    error NotPSMMode();
    error PSMCapReached();
    error AMMNotImplemented();
    error OnlyGToken();
    error CircuitBreakerActive();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(
        address gtoken_,
        address reserveVault_,
        ExitMode mode_,
        uint16 exitSpreadBPS_,
        uint16 maxExitPerDayBPS_,
        uint256 cooldownBlocks_,
        uint16 cbThresholdBPS_,
        address owner_
    ) Ownable(owner_) {
        gtoken = IGToken(gtoken_);
        reserveVault = IReserveVault(reserveVault_);
        // Cache decimals of reserve asset so we can normalize GROSH (18 dec) → stable
        if (reserveVault_ != address(0)) {
            stableDecimals = IERC20Metadata(IReserveVault(reserveVault_).asset()).decimals();
        } else {
            stableDecimals = 18;
        }
        mode = mode_;
        exitSpreadBPS = exitSpreadBPS_;
        maxExitPerDayBPS = maxExitPerDayBPS_;
        cooldownBlocks = cooldownBlocks_;
        cbThresholdBPS = cbThresholdBPS_;
        lastExitResetDay = block.timestamp / 1 days;
    }

    // -------------------------------------------------------------------------
    // IModule
    // -------------------------------------------------------------------------

    function moduleType() external pure override returns (bytes32) {
        return keccak256("EXIT_MODULE");
    }

    function beforeMint(address, uint256) external override onlyGToken {}
    function afterMint(address, uint256) external override onlyGToken {}
    function beforeBurn(address, uint256) external override onlyGToken {}
    function afterBurn(address, uint256) external override onlyGToken {}
    function afterTransfer(address, address, uint256) external override onlyGToken {}

    // -------------------------------------------------------------------------
    // Exit — HARD_PEG mode
    // -------------------------------------------------------------------------

    /// @notice Exit the system: burn GROSH, receive stable reserve asset
    function exit(
        uint256 groshAmount,
        uint256 minOut
    ) external nonReentrant whenNotPaused returns (uint256 stableOut) {
        if (mode == ExitMode.AMM) revert AMMNotImplemented();

        _checkCooldown();
        _checkDailyLimit(groshAmount);

        // Convert GROSH amount (18 dec) to stable amount (stableDecimals)
        // Assumes 1 GROSH = 1 USD. stableOut is in stableDecimals units.
        uint256 decimalAdj = 10 ** (18 - stableDecimals);
        stableOut = (groshAmount / decimalAdj) * (10_000 - exitSpreadBPS) / 10_000;
        if (stableOut < minOut) revert SlippageExceeded();

        // Check R_min will still hold after exit (reserve and supply both normalised to 18 dec)
        if (address(reserveVault) != address(0)) {
            uint256 reserve = reserveVault.totalAssets(); // native decimals
            uint256 reserve18 = reserve * decimalAdj;
            uint256 stableOut18 = stableOut * decimalAdj;
            uint256 supply = gtoken.totalSupply();
            uint256 newReserve18 = reserve18 > stableOut18 ? reserve18 - stableOut18 : 0;
            uint256 newSupply = supply > groshAmount ? supply - groshAmount : 0;
            if (newSupply > 0) {
                require(
                    newReserve18 * 10_000 >= newSupply * reserveVault.rMinBPS(),
                    "ExitModule: exit would violate R_min"
                );
            }
        }

        // Update state
        lastExitBlock[msg.sender] = block.number;
        dailyExitAmount += groshAmount;

        // Burn GROSH then withdraw stable
        gtoken.burn(msg.sender, groshAmount);
        if (address(reserveVault) != address(0)) {
            reserveVault.withdrawReserve(msg.sender, stableOut);
        }

        emit Exit(msg.sender, groshAmount, stableOut);
    }

    // -------------------------------------------------------------------------
    // PSM mode
    // -------------------------------------------------------------------------

    /// @notice PSM: swap GROSH → stable at near 1:1 (up to cap)
    function psmSwapGroshToStable(uint256 amount) external nonReentrant whenNotPaused {
        if (mode != ExitMode.PSM) revert NotPSMMode();

        uint256 fee = amount * exitSpreadBPS / 10_000;
        uint256 stableOut = amount - fee;

        require(psmUsed + stableOut <= psmCapUSD, "ExitModule: PSM cap reached");

        psmUsed += stableOut;
        gtoken.burn(msg.sender, amount);
        reserveVault.withdrawReserve(msg.sender, stableOut);

        emit PSMSwapGroshToStable(msg.sender, amount, stableOut);
    }

    /// @notice PSM: swap stable → GROSH at near 1:1 (refills PSM)
    function psmSwapStableToGrosh(uint256 stableAmount) external nonReentrant whenNotPaused {
        if (mode != ExitMode.PSM) revert NotPSMMode();

        reserveVault.depositReserve(stableAmount);
        psmUsed = psmUsed > stableAmount ? psmUsed - stableAmount : 0;

        uint256 fee = stableAmount * exitSpreadBPS / 10_000;
        uint256 groshOut = stableAmount - fee;
        gtoken.mint(msg.sender, groshOut);

        emit PSMSwapStableToGrosh(msg.sender, stableAmount, groshOut);
    }

    // -------------------------------------------------------------------------
    // Admin — onlyOwner
    // -------------------------------------------------------------------------

    function setMode(ExitMode newMode) external onlyOwner {
        mode = newMode;
        emit ModeChanged(newMode);
    }

    function setPsmCap(uint256 cap) external onlyOwner {
        psmCapUSD = cap;
        emit PsmCapUpdated(cap);
    }

    function setExitSpread(uint16 bps) external onlyOwner {
        require(bps <= 500, "ExitModule: spread too high");
        exitSpreadBPS = bps;
    }

    function setMaxExitPerDay(uint16 bps) external onlyOwner { maxExitPerDayBPS = bps; }
    function setCooldownBlocks(uint256 blocks_) external onlyOwner { cooldownBlocks = blocks_; }
    function setCbThreshold(uint16 bps) external onlyOwner { cbThresholdBPS = bps; }

    function setReserveVault(address rv) external onlyOwner {
        reserveVault = IReserveVault(rv);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    function _checkCooldown() internal view {
        if (block.number < lastExitBlock[msg.sender] + cooldownBlocks) {
            revert CooldownNotElapsed();
        }
    }

    function _checkDailyLimit(uint256 amount) internal {
        uint256 today = block.timestamp / 1 days;
        if (today > lastExitResetDay) {
            dailyExitAmount = 0;
            lastExitResetDay = today;
        }

        uint256 supply = gtoken.totalSupply();
        if (supply > 0) {
            require(
                (dailyExitAmount + amount) * 10_000 <= supply * maxExitPerDayBPS,
                "ExitModule: daily limit reached"
            );
        }

        // Circuit breaker check
        if (cbThresholdBPS > 0 && supply > 0) {
            if ((dailyExitAmount + amount) * 10_000 > supply * cbThresholdBPS) {
                emit CircuitBreakerTriggered(dailyExitAmount + amount, supply * cbThresholdBPS / 10_000);
                revert CircuitBreakerActive();
            }
        }
    }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyGToken() {
        if (msg.sender != address(gtoken)) revert OnlyGToken();
        _;
    }
}
