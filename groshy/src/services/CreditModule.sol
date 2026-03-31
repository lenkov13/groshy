// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IModule.sol";
import "../interfaces/IGToken.sol";
import "../interfaces/IReserveVault.sol";
import "../interfaces/IEPController.sol";
import "../interfaces/ICollateralVault.sol";

/// @title CreditModule — loan origination, interest accrual, and liquidation
/// @notice Issues GROSH loans to users. Collateralized loans use the CollateralVault.
///         Interest accrues per-second (linear approximation for v0.1).
///         CAR (capital adequacy ratio) limits total credit expansion.
contract CreditModule is IModule, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 public constant RAY = 1e27;
    uint256 public constant SECONDS_PER_YEAR = 31_536_000;

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    struct Loan {
        uint256 principal;          // original loan amount (GROSH, 18 dec)
        uint256 interestAccrued;    // accrued interest not yet settled
        uint256 ratePerSecond;      // interest rate per second (RAY units)
        uint256 lastUpdated;        // block.timestamp of last accrual
        address collateralAsset;    // address(0) = uncollateralized
        uint256 collateralAmount;   // amount of collateral locked
        bool active;
    }

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    IGToken public immutable gtoken;
    IReserveVault public reserveVault;
    ICollateralVault public collateralVault;
    IEPController public epController;

    mapping(address => Loan) public loans;

    uint16 public carMinBPS;              // min capital adequacy ratio
    uint16 public ltvMaxBPS;             // max loan-to-value ratio
    uint16 public liquidationPenaltyBPS; // liquidator bonus
    uint256 public maxMaturitySeconds;
    uint16 public originationFeeBPS;     // fee minted to reserveVault on loan open
    uint16 public liquidationThresholdBPS; // LTV at which liquidation becomes possible

    // Set true while repay() or liquidate() is executing to allow internal burns
    bool private _inRepay;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event LoanIssued(address indexed borrower, uint256 principal, uint256 rateBPS, bool collateralized);
    event LoanRepaid(address indexed borrower, uint256 principalPaid, uint256 interestPaid);
    event Liquidated(address indexed borrower, address indexed liquidator, uint256 collateralOut);
    event InterestAccrued(address indexed borrower, uint256 interest);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error ExistingLoan();
    error NoActiveLoan();
    error ZeroAmount();
    error CARTooLow();
    error LTVExceeded();
    error LoanIsHealthy();
    error UncollateralizedLiquidation();
    error Overpayment();
    error OnlyGToken();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(
        address gtoken_,
        address reserveVault_,
        address collateralVault_,  // address(0) for mutual credit config
        uint16 carMinBPS_,
        uint16 ltvMaxBPS_,
        uint16 liquidationPenaltyBPS_,
        uint256 maxMaturitySeconds_,
        uint16 originationFeeBPS_,
        address owner_
    ) Ownable(owner_) {
        gtoken = IGToken(gtoken_);
        reserveVault = IReserveVault(reserveVault_);
        if (collateralVault_ != address(0)) collateralVault = ICollateralVault(collateralVault_);
        carMinBPS = carMinBPS_;
        ltvMaxBPS = ltvMaxBPS_;
        liquidationPenaltyBPS = liquidationPenaltyBPS_;
        maxMaturitySeconds = maxMaturitySeconds_;
        originationFeeBPS = originationFeeBPS_;
        // Liquidation threshold = LTV_max * 1.25
        liquidationThresholdBPS = uint16(uint256(ltvMaxBPS_) * 125 / 100);
    }

    // -------------------------------------------------------------------------
    // IModule
    // -------------------------------------------------------------------------

    function moduleType() external pure override returns (bytes32) {
        return keccak256("CREDIT_MODULE");
    }

    function beforeMint(address, uint256) external override onlyGToken {}
    function afterMint(address, uint256) external override onlyGToken {}

    /// @notice BEFORE_BURN hook — block burns if borrower has an active loan
    /// @dev The _inRepay flag exempts burns that originate from repay() or liquidate()
    function beforeBurn(address from, uint256) external override onlyGToken {
        if (!_inRepay && loans[from].active) {
            revert("CreditModule: repay loan before transferring/burning");
        }
    }

    function afterBurn(address, uint256) external override onlyGToken {}
    function afterTransfer(address, address, uint256) external override onlyGToken {}

    // -------------------------------------------------------------------------
    // Borrow
    // -------------------------------------------------------------------------

    /// @notice Issue a GROSH loan
    /// @param amount           GROSH to borrow
    /// @param collateralAsset  Collateral asset (address(0) = uncollateralized)
    /// @param collateralAmount Amount of collateral to lock
    function borrow(
        uint256 amount,
        address collateralAsset,
        uint256 collateralAmount
    ) external nonReentrant whenNotPaused {
        if (loans[msg.sender].active) revert ExistingLoan();
        if (amount == 0) revert ZeroAmount();

        // 1. CAR check
        if (address(reserveVault) != address(0) && carMinBPS > 0) {
            uint256 capitalBPS = reserveVault.getCapitalBPS();
            if (capitalBPS < carMinBPS) revert CARTooLow();
        }

        // 2. Collateral handling
        if (collateralAsset != address(0)) {
            require(address(collateralVault) != address(0), "CreditModule: no collateral vault");
            uint256 collateralUSD = collateralVault.getAssetValueUSD(collateralAsset, collateralAmount);
            // LTV check: amount <= collateralUSD * ltvMax / 10_000
            if (amount * 10_000 > collateralUSD * ltvMaxBPS) revert LTVExceeded();

            IERC20(collateralAsset).safeTransferFrom(msg.sender, address(collateralVault), collateralAmount);
            collateralVault.lockCollateral(msg.sender, collateralAsset, collateralAmount);
        }

        // 3. Origination fee — minted separately to reserveVault
        uint256 fee = amount * originationFeeBPS / 10_000;
        uint256 disbursed = amount - fee;

        // 4. Get rate from EPController (or use default)
        uint256 rateBPS = address(epController) != address(0)
            ? epController.getCurrentRate()
            : 800; // 8% default

        // 5. Record loan
        loans[msg.sender] = Loan({
            principal: disbursed,
            interestAccrued: 0,
            ratePerSecond: _annualRateToPerSecond(rateBPS),
            lastUpdated: block.timestamp,
            collateralAsset: collateralAsset,
            collateralAmount: collateralAmount,
            active: true
        });

        // 6. Mint GROSH (fee to reserveVault, principal to borrower)
        if (fee > 0 && address(reserveVault) != address(0)) {
            gtoken.mint(address(reserveVault), fee);
        }
        gtoken.mint(msg.sender, disbursed);

        emit LoanIssued(msg.sender, disbursed, rateBPS, collateralAsset != address(0));
    }

    // -------------------------------------------------------------------------
    // Repay
    // -------------------------------------------------------------------------

    /// @notice Repay some or all of an active loan
    function repay(uint256 amount) external nonReentrant {
        Loan storage loan = loans[msg.sender];
        if (!loan.active) revert NoActiveLoan();
        if (amount == 0) revert ZeroAmount();

        _accrueInterest(msg.sender);

        uint256 totalDebt = loan.principal + loan.interestAccrued;
        if (amount > totalDebt) revert Overpayment();

        // Pay interest first, then principal
        uint256 interestPayment = amount <= loan.interestAccrued ? amount : loan.interestAccrued;
        uint256 principalPayment = amount - interestPayment;

        // Allow burns/mints during repayment without triggering the active-loan guard
        _inRepay = true;

        // Interest: mint new GROSH to reserveVault (income to reserves)
        if (interestPayment > 0) {
            gtoken.mint(address(reserveVault), interestPayment);
            loan.interestAccrued -= interestPayment;
        }

        // Principal: burn from borrower
        if (principalPayment > 0) {
            gtoken.burn(msg.sender, principalPayment);
            loan.principal -= principalPayment;
        }

        _inRepay = false;

        // Close loan if fully repaid
        if (loan.principal == 0 && loan.interestAccrued == 0) {
            _closeLoan(msg.sender);
        }

        emit LoanRepaid(msg.sender, principalPayment, interestPayment);
    }

    // -------------------------------------------------------------------------
    // Liquidation
    // -------------------------------------------------------------------------

    /// @notice Liquidate an undercollateralized loan
    function liquidate(address borrower) external nonReentrant {
        Loan storage loan = loans[borrower];
        if (!loan.active) revert NoActiveLoan();
        if (loan.collateralAsset == address(0)) revert UncollateralizedLiquidation();

        _accrueInterest(borrower);

        uint256 healthFactor = _getHealthFactor(borrower);
        if (healthFactor >= 1e18) revert LoanIsHealthy();

        uint256 totalDebt = loan.principal + loan.interestAccrued;

        // Liquidator burns GROSH equal to total debt (flag allows burn past active-loan guard)
        _inRepay = true;
        gtoken.burn(msg.sender, totalDebt);
        _inRepay = false;

        // Liquidator receives collateral
        uint256 collateralOut = loan.collateralAmount;
        collateralVault.releaseCollateral(borrower, loan.collateralAsset, collateralOut, msg.sender);

        _closeLoan(borrower);
        emit Liquidated(borrower, msg.sender, collateralOut);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function getActiveLoan(address borrower) external view returns (Loan memory) {
        return loans[borrower];
    }

    function getTotalDebt(address borrower) external view returns (uint256) {
        Loan storage loan = loans[borrower];
        if (!loan.active) return 0;

        uint256 elapsed = block.timestamp - loan.lastUpdated;
        uint256 interest = loan.principal * loan.ratePerSecond * elapsed / RAY;
        return loan.principal + loan.interestAccrued + interest;
    }

    function getHealthFactor(address borrower) external view returns (uint256) {
        return _getHealthFactor(borrower);
    }

    // -------------------------------------------------------------------------
    // Admin — onlyOwner
    // -------------------------------------------------------------------------

    function setReserveVault(address rv) external onlyOwner {
        reserveVault = IReserveVault(rv);
    }

    function setCollateralVault(address cv) external onlyOwner {
        collateralVault = ICollateralVault(cv);
    }

    function setEPController(address ep) external onlyOwner {
        epController = IEPController(ep);
    }

    function setCarMin(uint16 bps) external onlyOwner { carMinBPS = bps; }
    function setLtvMax(uint16 bps) external onlyOwner {
        ltvMaxBPS = bps;
        liquidationThresholdBPS = uint16(uint256(bps) * 125 / 100);
    }
    function setLiquidationPenalty(uint16 bps) external onlyOwner { liquidationPenaltyBPS = bps; }
    function setOriginationFee(uint16 bps) external onlyOwner { originationFeeBPS = bps; }
    function setMaxMaturity(uint256 secs) external onlyOwner { maxMaturitySeconds = secs; }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    function _accrueInterest(address borrower) internal {
        Loan storage loan = loans[borrower];
        if (!loan.active) return;

        uint256 elapsed = block.timestamp - loan.lastUpdated;
        if (elapsed == 0) return;

        // Linear interest approximation: interest = principal * rate * time
        uint256 interest = loan.principal * loan.ratePerSecond * elapsed / RAY;
        if (interest > 0) {
            loan.interestAccrued += interest;
            emit InterestAccrued(borrower, interest);
        }
        loan.lastUpdated = block.timestamp;
    }

    /// @notice Convert annual basis-point rate to per-second rate in RAY units
    function _annualRateToPerSecond(uint256 annualRateBPS) internal pure returns (uint256) {
        // Linear approximation: ratePerSecond = annualRate / secondsPerYear (in RAY)
        // annualRateBPS: 800 → 8% → 0.08
        // perSecond = 0.08 / 31_536_000 * RAY
        return annualRateBPS * RAY / 10_000 / SECONDS_PER_YEAR;
    }

    function _getHealthFactor(address borrower) internal view returns (uint256) {
        Loan storage loan = loans[borrower];
        if (!loan.active || loan.collateralAsset == address(0)) return type(uint256).max;

        uint256 totalDebt = loan.principal + loan.interestAccrued;
        if (totalDebt == 0) return type(uint256).max;

        uint256 collateralUSD = collateralVault.getAssetValueUSD(loan.collateralAsset, loan.collateralAmount);
        // HF = collateralUSD * 1e18 / (totalDebt * liquidationThreshold / 10_000)
        // If HF < 1e18, the loan is liquidatable
        return collateralUSD * 1e18 / (totalDebt * liquidationThresholdBPS / 10_000);
    }

    function _closeLoan(address borrower) internal {
        delete loans[borrower];
        // Release any remaining collateral (in case of partial liquidation not implemented in v0.1)
    }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyGToken() {
        if (msg.sender != address(gtoken)) revert OnlyGToken();
        _;
    }
}
