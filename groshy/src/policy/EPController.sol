// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../interfaces/IModule.sol";
import "../interfaces/IEPController.sol";
import "../interfaces/IGToken.sol";
import "../interfaces/IReserveVault.sol";

/// @title EPController — on-chain central bank (Emission Protocol)
/// @notice Manages the key interest rate, conducts OMO, provides LOLR emergency
///         liquidity to distressed Credit Protocols, and issues forward guidance.
///         Required for any configuration with R_min < 100%.
contract EPController is IModule, IEPController, Ownable, Pausable {

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 public constant RAY = 1e27;
    uint256 public constant SECONDS_PER_YEAR = 31_536_000;

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    struct LOLRLoan {
        uint256 amount;
        uint256 ratePerSecond;  // RAY
        uint256 maturity;       // timestamp
        uint256 disbursedAt;
        bool repaid;
    }

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    IGToken public immutable gtoken;

    // Registered Credit Protocols: cp address → its reserve vault
    mapping(address => IReserveVault) public registeredCPs;

    // Key rate corridor
    uint256 public rTargetBPS;          // current key rate (basis points/year)
    uint256 public rFloorBPS;           // minimum rate
    uint256 public rCeilingBPS;         // maximum rate

    // Forward guidance
    uint256 public signalledNextRate;
    uint256 public signalledChangeAt;

    // LOLR
    mapping(address => LOLRLoan) public lolrLoans;
    uint256 public lolrRateBPS;         // penalty rate > rTarget
    uint256 public lolrMaxTermSeconds;  // max LOLR duration
    uint256 public maxLolrPerCPBPS;     // max LOLR as % of total supply

    // OMO tracking
    uint256 public omoBuyVolume;
    uint256 public omoSellVolume;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event RateChanged(uint256 oldRate, uint256 newRate);
    event ForwardGuidance(uint256 futureRate, uint256 effectiveAt);
    event SignalledRateApplied(uint256 rate);
    event OMOExecuted(bool isBuy, uint256 amount);
    event LOLRIssued(address indexed cp, uint256 amount, uint256 maturity);
    event LOLRRepaid(address indexed cp, uint256 totalRepaid);
    event CPRegistered(address indexed cp, address reserveVault);
    event CPDeregistered(address indexed cp);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error OutOfRateCorridor();
    error SignalNotEffectiveYet();
    error NoPendingSignal();
    error CPNotRegistered();
    error ExistingLOLRLoan();
    error ExceedsMaxLOLR();
    error NoLOLRLoan();
    error LOLRExpired();
    error FutureTimestampRequired();
    error OnlyGToken();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(
        address gtoken_,
        uint256 rTargetBPS_,
        uint256 rFloorBPS_,
        uint256 rCeilingBPS_,
        uint256 lolrRateBPS_,
        uint256 lolrMaxTermSeconds_,
        uint256 maxLolrPerCPBPS_,
        address owner_
    ) Ownable(owner_) {
        gtoken = IGToken(gtoken_);
        rTargetBPS = rTargetBPS_;
        rFloorBPS = rFloorBPS_;
        rCeilingBPS = rCeilingBPS_;
        lolrRateBPS = lolrRateBPS_;
        lolrMaxTermSeconds = lolrMaxTermSeconds_;
        maxLolrPerCPBPS = maxLolrPerCPBPS_;
    }

    // -------------------------------------------------------------------------
    // IModule
    // -------------------------------------------------------------------------

    function moduleType() external pure override returns (bytes32) {
        return keccak256("EP_CONTROLLER");
    }

    function beforeMint(address, uint256) external override onlyGToken {}

    function afterMint(address, uint256 amount) external override onlyGToken {
        // Track supply expansion for OMO trigger analysis
        omoSellVolume; // no-op, just exists to silence compiler
        amount;
    }

    function beforeBurn(address, uint256) external override onlyGToken {}

    function afterBurn(address, uint256) external override onlyGToken {}

    function afterTransfer(address, address, uint256) external override onlyGToken {}

    // -------------------------------------------------------------------------
    // IEPController
    // -------------------------------------------------------------------------

    /// @notice Returns current effective rate (may be the signalled rate if effective)
    function getCurrentRate() external view override returns (uint256) {
        if (signalledNextRate > 0 && block.timestamp >= signalledChangeAt) {
            return signalledNextRate;
        }
        return rTargetBPS;
    }

    // -------------------------------------------------------------------------
    // Rate management — onlyOwner
    // -------------------------------------------------------------------------

    /// @notice Set the key rate immediately (governance action)
    function setRate(uint256 newRateBPS) external onlyOwner {
        if (newRateBPS < rFloorBPS || newRateBPS > rCeilingBPS) revert OutOfRateCorridor();
        uint256 old = rTargetBPS;
        rTargetBPS = newRateBPS;
        emit RateChanged(old, newRateBPS);
    }

    /// @notice Signal a future rate change (forward guidance)
    function signalRateChange(uint256 futureRate, uint256 effectiveAt) external onlyOwner {
        if (effectiveAt <= block.timestamp) revert FutureTimestampRequired();
        if (futureRate < rFloorBPS || futureRate > rCeilingBPS) revert OutOfRateCorridor();

        signalledNextRate = futureRate;
        signalledChangeAt = effectiveAt;
        emit ForwardGuidance(futureRate, effectiveAt);
    }

    /// @notice Apply the signalled rate change once the effective time has passed
    function applySignalledChange() external {
        if (signalledNextRate == 0) revert NoPendingSignal();
        if (block.timestamp < signalledChangeAt) revert SignalNotEffectiveYet();

        uint256 old = rTargetBPS;
        rTargetBPS = signalledNextRate;
        signalledNextRate = 0;
        signalledChangeAt = 0;

        emit RateChanged(old, rTargetBPS);
        emit SignalledRateApplied(rTargetBPS);
    }

    /// @notice Set rate corridor parameters
    function setRateCorridor(uint256 floor, uint256 ceiling) external onlyOwner {
        require(floor <= ceiling, "EPController: floor > ceiling");
        rFloorBPS = floor;
        rCeilingBPS = ceiling;
    }

    // -------------------------------------------------------------------------
    // Open Market Operations — onlyOwner
    // -------------------------------------------------------------------------

    /// @notice OMO Buy: reduce supply by burning GROSH held by this contract
    /// @dev In a full implementation this would swap USDC on an AMM for GROSH.
    ///      For v0.1: burns any GROSH this contract holds (acquired externally or via sell OMO).
    function omoBuy(uint256 groshAmount) external onlyOwner {
        // Burns GROSH from EP's own balance (EP accumulates GROSH via interest or sell OMO)
        gtoken.burn(address(this), groshAmount);
        omoBuyVolume += groshAmount;
        emit OMOExecuted(true, groshAmount);
    }

    /// @notice OMO Sell: increase supply by minting GROSH to this contract
    /// @dev In a full implementation this would sell GROSH on an AMM for USDC.
    function omoSell(uint256 groshAmount) external onlyOwner {
        gtoken.mint(address(this), groshAmount);
        omoSellVolume += groshAmount;
        emit OMOExecuted(false, groshAmount);
    }

    // -------------------------------------------------------------------------
    // LOLR — onlyOwner
    // -------------------------------------------------------------------------

    /// @notice Issue emergency loan to a distressed Credit Protocol
    function issueLOLR(address cp, uint256 amount) external onlyOwner {
        IReserveVault cpVault = registeredCPs[cp];
        if (address(cpVault) == address(0)) revert CPNotRegistered();
        if (lolrLoans[cp].amount > 0 && !lolrLoans[cp].repaid) revert ExistingLOLRLoan();

        uint256 maxLolr = gtoken.totalSupply() * maxLolrPerCPBPS / 10_000;
        if (amount > maxLolr) revert ExceedsMaxLOLR();

        lolrLoans[cp] = LOLRLoan({
            amount: amount,
            ratePerSecond: _annualRateToPerSecond(lolrRateBPS),
            maturity: block.timestamp + lolrMaxTermSeconds,
            disbursedAt: block.timestamp,
            repaid: false
        });

        // Record loan in CP's ReserveVault (increases obligations → incentive to repay)
        cpVault.recordEPLoan(amount);

        // Mint GROSH directly to CP's reserve vault
        gtoken.mint(address(cpVault), amount);

        emit LOLRIssued(cp, amount, block.timestamp + lolrMaxTermSeconds);
    }

    /// @notice CP repays its LOLR loan
    function repayLOLR() external {
        LOLRLoan storage loan = lolrLoans[msg.sender];
        if (loan.amount == 0 || loan.repaid) revert NoLOLRLoan();

        IReserveVault cpVault = registeredCPs[msg.sender];
        if (address(cpVault) == address(0)) revert CPNotRegistered();

        uint256 interest = _calculateLOLRInterest(msg.sender);
        uint256 total = loan.amount + interest;

        // Burn principal + interest from CP's reserve vault
        gtoken.burn(address(cpVault), total);
        cpVault.repayEPLoan(loan.amount);

        loan.repaid = true;
        loan.amount = 0;

        emit LOLRRepaid(msg.sender, total);
    }

    // -------------------------------------------------------------------------
    // CP registration — onlyOwner
    // -------------------------------------------------------------------------

    function registerCP(address cp, address reserveVault_) external onlyOwner {
        registeredCPs[cp] = IReserveVault(reserveVault_);
        emit CPRegistered(cp, reserveVault_);
    }

    function deregisterCP(address cp) external onlyOwner {
        delete registeredCPs[cp];
        emit CPDeregistered(cp);
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    function setLolrRate(uint256 bps) external onlyOwner { lolrRateBPS = bps; }
    function setLolrMaxTerm(uint256 secs) external onlyOwner { lolrMaxTermSeconds = secs; }
    function setMaxLolrPerCP(uint256 bps) external onlyOwner { maxLolrPerCPBPS = bps; }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function getLOLRLoan(address cp) external view returns (LOLRLoan memory) {
        return lolrLoans[cp];
    }

    function getLOLRDebt(address cp) external view returns (uint256) {
        LOLRLoan storage loan = lolrLoans[cp];
        if (loan.amount == 0 || loan.repaid) return 0;
        return loan.amount + _calculateLOLRInterest(cp);
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    function _annualRateToPerSecond(uint256 annualRateBPS) internal pure returns (uint256) {
        return annualRateBPS * RAY / 10_000 / SECONDS_PER_YEAR;
    }

    function _calculateLOLRInterest(address cp) internal view returns (uint256) {
        LOLRLoan storage loan = lolrLoans[cp];
        if (loan.amount == 0 || loan.repaid) return 0;
        uint256 elapsed = block.timestamp - loan.disbursedAt;
        return loan.amount * loan.ratePerSecond * elapsed / RAY;
    }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyGToken() {
        if (msg.sender != address(gtoken)) revert OnlyGToken();
        _;
    }
}
