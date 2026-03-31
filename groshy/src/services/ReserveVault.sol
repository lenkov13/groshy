// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../interfaces/IModule.sol";
import "../interfaces/IReserveVault.sol";
import "../interfaces/IGToken.sol";

/// @title ReserveVault — R_min enforcement, circuit breaker, EP loan tracking
/// @notice Holds USDC reserves. Enforces the minimum reserve ratio on every mint
///         via the BEFORE_MINT hook. Tracks daily outflow and can activate a
///         circuit breaker on excessive exits.
contract ReserveVault is IModule, IReserveVault, Ownable, Pausable {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    IGToken public immutable gtoken;
    IERC20 public immutable reserveAsset; // USDC

    address public epController;
    address public exitModule;

    uint16 public rMinBPS;                 // minimum reserve ratio (2000 = 20%)
    uint16 public rebalanceThresholdBPS;   // alert threshold (2200 = 22%)
    uint16 public cbThresholdBPS;          // daily outflow % triggering circuit breaker (1000 = 10%)

    uint256 public epLoanBalance;          // outstanding EP emergency loans (18 dec, GROSH units)
    uint8 public immutable reserveDecimals; // cached decimals of reserve asset (e.g. 6 for USDC)

    // Circuit breaker
    uint256 public dailyOutflow;
    uint256 public lastOutflowReset;
    bool public circuitBreakerActive;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event ReserveDeposited(address indexed from, uint256 amount);
    event ReserveWithdrawn(address indexed to, uint256 amount);
    event CircuitBreakerTriggered(uint256 dailyOutflow, uint256 threshold);
    event CircuitBreakerReset(uint256 timestamp);
    event EPLoanRecorded(uint256 amount, uint256 newBalance);
    event EPLoanRepaid(uint256 amount, uint256 newBalance);
    event RMinUpdated(uint16 oldRMin, uint16 newRMin);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error SystemPaused();
    error CircuitBreakerOn();
    error RMinViolation();
    error OnlyGToken();
    error OnlyEPController();
    error OnlyExitModule();
    error InsufficientReserve();
    error Overpayment();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(
        address gtoken_,
        address reserveAsset_,
        uint16 rMinBPS_,
        uint16 rebalanceThresholdBPS_,
        uint16 cbThresholdBPS_,
        address owner_
    ) Ownable(owner_) {
        gtoken = IGToken(gtoken_);
        reserveAsset = IERC20(reserveAsset_);
        reserveDecimals = IERC20Metadata(reserveAsset_).decimals();
        rMinBPS = rMinBPS_;
        rebalanceThresholdBPS = rebalanceThresholdBPS_;
        cbThresholdBPS = cbThresholdBPS_;
        lastOutflowReset = block.timestamp;
    }

    // -------------------------------------------------------------------------
    // IModule
    // -------------------------------------------------------------------------

    function moduleType() external pure override returns (bytes32) {
        return keccak256("RESERVE_VAULT");
    }

    /// @notice BEFORE_MINT hook — reverts if mint would violate R_min
    function beforeMint(address, uint256 amount) external override onlyGToken {
        if (paused()) revert SystemPaused();
        if (circuitBreakerActive) revert CircuitBreakerOn();

        uint256 newSupply = gtoken.totalSupply() + amount;
        // Normalize reserve to 18 decimals (same as GROSH) for comparison
        // e.g. USDC has 6 dec → multiply by 1e12
        uint256 reserve18 = reserveAsset.balanceOf(address(this)) * (10 ** (18 - reserveDecimals));
        uint256 obligations = newSupply + epLoanBalance;

        // R_min check: reserve18 / obligations >= rMinBPS / 10_000
        if (reserve18 * 10_000 < obligations * rMinBPS) revert RMinViolation();
    }

    function afterMint(address, uint256) external override onlyGToken {
        // Could update utilization metrics here
    }

    function beforeBurn(address, uint256) external override onlyGToken {}

    /// @notice AFTER_BURN hook — tracks daily outflow, may trigger circuit breaker
    function afterBurn(address, uint256 amount) external override onlyGToken {
        // Reset daily counter if a new day started
        if (block.timestamp > lastOutflowReset + 1 days) {
            dailyOutflow = 0;
            lastOutflowReset = block.timestamp;
            circuitBreakerActive = false; // auto-reset after 24h
        }

        dailyOutflow += amount;
        uint256 supply = gtoken.totalSupply();

        if (supply > 0 && dailyOutflow * 10_000 > supply * cbThresholdBPS) {
            circuitBreakerActive = true;
            emit CircuitBreakerTriggered(dailyOutflow, supply * cbThresholdBPS / 10_000);
        }
    }

    function afterTransfer(address, address, uint256) external override onlyGToken {}

    // -------------------------------------------------------------------------
    // IReserveVault
    // -------------------------------------------------------------------------

    function asset() external view override returns (address) {
        return address(reserveAsset);
    }

    /// @notice Total reserve assets in native decimals (e.g. USDC with 6 dec)
    function totalAssets() external view override returns (uint256) {
        return reserveAsset.balanceOf(address(this));
    }

    /// @notice Reserve ratio in basis points, normalised to 18 decimals for comparison with GROSH supply
    function getCapitalBPS() external view override returns (uint256) {
        uint256 supply = gtoken.totalSupply();
        if (supply == 0) return 10_000;
        uint256 reserve18 = reserveAsset.balanceOf(address(this)) * (10 ** (18 - reserveDecimals));
        return reserve18 * 10_000 / supply;
    }

    function recordEPLoan(uint256 amount) external override onlyEPController {
        epLoanBalance += amount;
        emit EPLoanRecorded(amount, epLoanBalance);
    }

    function repayEPLoan(uint256 amount) external override onlyEPController {
        if (epLoanBalance < amount) revert Overpayment();
        epLoanBalance -= amount;
        emit EPLoanRepaid(amount, epLoanBalance);
    }

    function withdrawReserve(address to, uint256 amount) external override onlyExitModule {
        if (reserveAsset.balanceOf(address(this)) < amount) revert InsufficientReserve();
        reserveAsset.safeTransfer(to, amount);
        emit ReserveWithdrawn(to, amount);
    }

    function depositReserve(uint256 amount) external override {
        reserveAsset.safeTransferFrom(msg.sender, address(this), amount);
        emit ReserveDeposited(msg.sender, amount);
    }

    // -------------------------------------------------------------------------
    // Admin — onlyOwner
    // -------------------------------------------------------------------------

    function setRMin(uint16 newRMinBPS) external onlyOwner {
        require(newRMinBPS <= 10_000, "ReserveVault: rMin > 100%");
        emit RMinUpdated(rMinBPS, newRMinBPS);
        rMinBPS = newRMinBPS;
    }

    function setRebalanceThreshold(uint16 newBPS) external onlyOwner {
        rebalanceThresholdBPS = newBPS;
    }

    function setCbThreshold(uint16 newBPS) external onlyOwner {
        cbThresholdBPS = newBPS;
    }

    function setEPController(address ep) external onlyOwner {
        epController = ep;
    }

    function setExitModule(address exit_) external onlyOwner {
        exitModule = exit_;
    }

    function resetCircuitBreaker() external onlyOwner {
        circuitBreakerActive = false;
        dailyOutflow = 0;
        emit CircuitBreakerReset(block.timestamp);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyGToken() {
        if (msg.sender != address(gtoken)) revert OnlyGToken();
        _;
    }

    modifier onlyEPController() {
        if (msg.sender != epController) revert OnlyEPController();
        _;
    }

    modifier onlyExitModule() {
        if (msg.sender != exitModule) revert OnlyExitModule();
        _;
    }
}
