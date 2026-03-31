// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IEmissionModule.sol";
import "../interfaces/IGToken.sol";

/// @title CreditLedger — MUTUAL_CREDIT emission module
/// @notice GROSH is created when a member draws on their credit line (borrow)
///         and destroyed when they repay. Key invariant: totalBorrowed == totalSupply.
///         Demurrage discourages hoarding and encourages circulation.
contract CreditLedger is IEmissionModule, Ownable, Pausable, ReentrancyGuard {

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    struct MemberLine {
        uint256 creditLimit;    // max GROSH the member can hold
        uint256 debitLimit;     // max GROSH the member can owe
        uint256 borrowed;       // current outstanding borrow
        uint256 lineExpiry;     // 0 = no expiry
        bool active;
    }

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    IGToken public immutable gtoken;

    mapping(address => MemberLine) public memberLines;
    address[] public members;

    uint16 public demurrageRateBPS;  // basis points per month (50 = 0.5%/month)
    uint256 public lastDemurrageAt;  // timestamp of last global demurrage

    uint256 public totalBorrowed;    // total GROSH outstanding from credit lines
    uint256 public demurragePool;    // accumulated demurrage (burned from supply, tracked separately)

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event LineOpened(address indexed member, uint256 creditLimit, uint256 debitLimit);
    event LineClosed(address indexed member);
    event LimitAdjusted(address indexed member, uint256 newDebitLimit, uint256 newCreditLimit);
    event Borrowed(address indexed member, uint256 amount);
    event Repaid(address indexed member, uint256 amount);
    event DemurrageApplied(uint256 totalCharged, uint256 timestamp);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error NoActiveLine();
    error LineAlreadyExists();
    error LineExpired();
    error ExceedsDebitLimit();
    error Overpayment();
    error DemurrageTooEarly();
    error BothLimitsZero();
    error OnlyGToken();
    error CannotIncreaseViaThis();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(
        address gtoken_,
        uint16 demurrageRateBPS_,
        address owner_
    ) Ownable(owner_) {
        gtoken = IGToken(gtoken_);
        demurrageRateBPS = demurrageRateBPS_;
        lastDemurrageAt = block.timestamp;
    }

    // -------------------------------------------------------------------------
    // IModule
    // -------------------------------------------------------------------------

    function moduleType() external pure override returns (bytes32) {
        return keccak256("CREDIT_LEDGER");
    }

    function beforeMint(address, uint256) external override onlyGToken {}
    function afterMint(address, uint256) external override onlyGToken {}

    function beforeBurn(address from, uint256 amount) external override onlyGToken {
        // For mutual credit, burning is repayment — validate via repay()
        // If called outside of repay(), check the line exists and has sufficient borrow
        MemberLine storage line = memberLines[from];
        if (line.active && line.borrowed < amount) {
            revert Overpayment();
        }
    }

    function afterBurn(address, uint256) external override onlyGToken {}
    function afterTransfer(address, address, uint256) external override onlyGToken {}

    // -------------------------------------------------------------------------
    // IEmissionModule
    // -------------------------------------------------------------------------

    function emissionType() external pure override returns (EmissionType) {
        return EmissionType.MUTUAL_CREDIT;
    }

    /// @notice In mutual credit, backing = total outstanding borrow (GROSH owed by members)
    function totalBacking() external view override returns (uint256) {
        return totalBorrowed;
    }

    /// @notice Mutual credit is always 1:1 by design
    function collateralRatio() external pure override returns (uint256) {
        return 1e18;
    }

    // -------------------------------------------------------------------------
    // Member management — onlyOwner
    // -------------------------------------------------------------------------

    function openLine(
        address member,
        uint256 creditLimit,
        uint256 debitLimit,
        uint256 expiryDays
    ) external onlyOwner {
        if (memberLines[member].active) revert LineAlreadyExists();
        if (debitLimit == 0 && creditLimit == 0) revert BothLimitsZero();

        memberLines[member] = MemberLine({
            creditLimit: creditLimit,
            debitLimit: debitLimit,
            borrowed: 0,
            lineExpiry: expiryDays > 0 ? block.timestamp + expiryDays * 1 days : 0,
            active: true
        });
        members.push(member);

        emit LineOpened(member, creditLimit, debitLimit);
    }

    function closeLine(address member) external onlyOwner {
        MemberLine storage line = memberLines[member];
        if (!line.active) revert NoActiveLine();
        require(line.borrowed == 0, "CreditLedger: outstanding balance, repay first");
        line.active = false;
        emit LineClosed(member);
    }

    /// @notice Adjust limits. Reduction is immediate; increases require governance (use this then upgrade limit via a new tx after governance vote).
    function adjustLimit(
        address member,
        uint256 newDebitLimit,
        uint256 newCreditLimit
    ) external onlyOwner {
        MemberLine storage line = memberLines[member];
        if (!line.active) revert NoActiveLine();

        bool reducingDebit = newDebitLimit <= line.debitLimit;
        bool reducingCredit = newCreditLimit <= line.creditLimit;

        if (!reducingDebit || !reducingCredit) revert CannotIncreaseViaThis();

        line.debitLimit = newDebitLimit;
        line.creditLimit = newCreditLimit;
        emit LimitAdjusted(member, newDebitLimit, newCreditLimit);
    }

    /// @notice Force-increase a limit (requires separate explicit governance call)
    function increaseLimitGovernance(
        address member,
        uint256 newDebitLimit,
        uint256 newCreditLimit
    ) external onlyOwner {
        MemberLine storage line = memberLines[member];
        if (!line.active) revert NoActiveLine();
        line.debitLimit = newDebitLimit;
        line.creditLimit = newCreditLimit;
        emit LimitAdjusted(member, newDebitLimit, newCreditLimit);
    }

    function setDemurrageRate(uint16 newRateBPS) external onlyOwner {
        require(newRateBPS <= 500, "CreditLedger: demurrage too high");
        demurrageRateBPS = newRateBPS;
    }

    // -------------------------------------------------------------------------
    // Borrowing
    // -------------------------------------------------------------------------

    /// @notice Draw on credit line — creates new GROSH
    function borrow(uint256 amount) external whenNotPaused nonReentrant {
        MemberLine storage line = memberLines[msg.sender];
        if (!line.active) revert NoActiveLine();
        if (line.lineExpiry != 0 && block.timestamp >= line.lineExpiry) revert LineExpired();
        if (line.borrowed + amount > line.debitLimit) revert ExceedsDebitLimit();

        _applyDemurrage(msg.sender);

        line.borrowed += amount;
        totalBorrowed += amount;

        gtoken.mint(msg.sender, amount);
        emit Borrowed(msg.sender, amount);
    }

    /// @notice Repay credit line — destroys GROSH
    function repay(uint256 amount) external whenNotPaused nonReentrant {
        MemberLine storage line = memberLines[msg.sender];
        if (!line.active) revert NoActiveLine();
        if (line.borrowed < amount) revert Overpayment();

        line.borrowed -= amount;
        totalBorrowed -= amount;

        gtoken.burn(msg.sender, amount);
        emit Repaid(msg.sender, amount);
    }

    // -------------------------------------------------------------------------
    // Demurrage
    // -------------------------------------------------------------------------

    /// @notice Apply demurrage to all members (callable by anyone once per 30 days)
    function applyGlobalDemurrage() external {
        if (block.timestamp < lastDemurrageAt + 30 days) revert DemurrageTooEarly();

        uint256 totalCharged = 0;
        for (uint256 i = 0; i < members.length; i++) {
            address member = members[i];
            uint256 balance = gtoken.balanceOf(member);
            if (balance > 0 && demurrageRateBPS > 0) {
                uint256 charge = balance * demurrageRateBPS / 10_000;
                if (charge > 0) {
                    gtoken.burn(member, charge);
                    totalCharged += charge;
                }
            }
        }

        demurragePool += totalCharged;
        lastDemurrageAt = block.timestamp;
        emit DemurrageApplied(totalCharged, block.timestamp);
    }

    // -------------------------------------------------------------------------
    // Invariants
    // -------------------------------------------------------------------------

    /// @notice Check system invariant: totalBorrowed == totalSupply (pure mutual credit)
    function checkInvariant() external view returns (bool) {
        return gtoken.totalSupply() == totalBorrowed;
    }

    /// @notice Net position: positive = net creditor, negative = net debtor
    function getNetPosition(address member) external view returns (int256) {
        int256 balance = int256(gtoken.balanceOf(member));
        int256 borrowed = int256(memberLines[member].borrowed);
        return balance - borrowed;
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function getMemberCount() external view returns (uint256) {
        return members.length;
    }

    function getMemberLine(address member) external view returns (MemberLine memory) {
        return memberLines[member];
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    function _applyDemurrage(address member) internal {
        if (demurrageRateBPS == 0) return;

        uint256 monthsElapsed = (block.timestamp - lastDemurrageAt) / 30 days;
        if (monthsElapsed == 0) return;

        uint256 balance = gtoken.balanceOf(member);
        if (balance == 0) return;

        // Simplified linear demurrage per elapsed month
        uint256 charge = balance * demurrageRateBPS * monthsElapsed / 10_000;
        if (charge > balance) charge = balance; // cap at full balance

        if (charge > 0) {
            gtoken.burn(member, charge);
            demurragePool += charge;
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
