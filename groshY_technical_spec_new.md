# GroshY Protocol — Technical Specification
## Polygon Implementation · v0.1

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Contract Interfaces](#3-contract-interfaces)
4. [Module: GToken](#4-module-gtoken)
5. [Module: ModuleRegistry](#5-module-moduleregistry)
6. [Module: CollateralVault](#6-module-collateralvault)
7. [Module: CreditLedger](#7-module-creditledger)
8. [Module: ReserveVault](#8-module-reservevault)
9. [Module: CreditModule](#9-module-creditmodule)
10. [Module: ExitModule](#10-module-exitmodule)
11. [Module: EPController](#11-module-epcontroller)
12. [Hook System](#12-hook-system)
13. [Deployment Guide](#13-deployment-guide)
14. [Configuration Presets](#14-configuration-presets)
15. [Incompatibility Rules Engine](#15-incompatibility-rules-engine)
16. [Security Considerations](#16-security-considerations)
17. [Testing Strategy](#17-testing-strategy)

---

## 1. Overview

GroshY is a modular protocol for deploying on-chain monetary systems. It implements a two-tier banking architecture:

- **L1 — Emission Protocol (EP):** issues GROSH tokens, enforces system-wide norms, acts as lender of last resort
- **L2 — Credit Protocol (CP):** operates with end users, issues loans, accepts deposits, manages reserves

The protocol is a **constructor**: any community can assemble their monetary system from a set of modules. Two initial configurations are supported:

| Configuration | Emission module | Description |
|---|---|---|
| `COLLATERAL` | CollateralVault | Users deposit USDC/stETH → receive GROSH |
| `MUTUAL_CREDIT` | CreditLedger | GROSH issued via mutual credit lines, no collateral |

Both configurations share the same Core modules (GToken, ModuleRegistry) and Services modules (ReserveVault, CreditModule, ExitModule).

### Technology Stack

- **Blockchain:** Polygon PoS (chainId: 137) / Polygon Mumbai testnet (chainId: 80001)
- **Solidity:** ^0.8.24
- **Framework:** Foundry (forge, cast, anvil)
- **Standards:** ERC-20 (GToken), ERC-4626 (ReserveVault), OpenZeppelin 5.x
- **Oracle:** Chainlink Price Feeds (MATIC/USD, ETH/USD, USDC/USD)
- **Upgradability:** UUPS Proxy pattern (OpenZeppelin)

---

## 2. Architecture

### 2.1 Contract Hierarchy

```
GToken (ERC-20)
  └── ModuleRegistry (ACL + Hook Router)
        ├── [EMISSION — choose one]
        │     ├── CollateralVault    (collateral → GROSH)
        │     └── CreditLedger       (mutual credit lines)
        ├── [SERVICES — all optional]
        │     ├── ReserveVault       (R_min enforcement)
        │     ├── CreditModule       (loans + CAR + liquidation)
        │     └── ExitModule         (burn GROSH → USDC)
        └── [POLICY — V2+]
              ├── EPController       (rate + OMO + LOLR)
              └── M0Token            (inter-CP clearing, V3+)
```

### 2.2 Data Flow: Collateral Configuration

```
User → CollateralVault.deposit(USDC)
         → ReserveVault.checkRmin()           [beforeMint hook]
         → EPController.checkSystemState()    [beforeMint hook]
         → GToken.mint(user, amount)
         → afterMint hooks (accounting)
```

### 2.3 Data Flow: Mutual Credit Configuration

```
User → CreditLedger.openLine(member, limit)
         → ModuleRegistry.checkRole(ADMIN)
         → CreditLedger.borrow(amount)
         → GToken.mint(user, amount)          [sum of all balances = 0]
```

### 2.4 Deployment Sequence

```
1. Deploy GToken
2. Deploy ModuleRegistry(gtoken)
3. GToken.setRegistry(moduleRegistry)
4. Deploy emission module [CollateralVault | CreditLedger]
5. Deploy ReserveVault(gtoken, usdc)
6. Deploy CreditModule(gtoken, reserveVault, collateralVault)
7. Deploy ExitModule(gtoken, reserveVault)
8. Deploy EPController(gtoken, reserveVault)         [optional, V2+]
9. ModuleRegistry.registerModule(each deployed module)
10. ModuleRegistry.setHookOrder([...])
11. Transfer ownership to Gnosis Safe / DAO
```

---

## 3. Contract Interfaces

### 3.1 IModule — Base Interface

Every module must implement:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IModule {
    /// @notice Called by ModuleRegistry to verify module is alive
    function moduleType() external pure returns (bytes32);

    /// @notice Called before GToken.mint() — revert to block the mint
    /// @param to Recipient address
    /// @param amount Amount being minted
    function beforeMint(address to, uint256 amount) external;

    /// @notice Called after GToken.mint() completes
    function afterMint(address to, uint256 amount) external;

    /// @notice Called before GToken.burn()
    function beforeBurn(address from, uint256 amount) external;

    /// @notice Called after GToken.burn()
    function afterBurn(address from, uint256 amount) external;

    /// @notice Called after every GToken.transfer()
    function afterTransfer(address from, address to, uint256 amount) external;

    /// @notice Returns whether module is paused
    function paused() external view returns (bool);
}
```

### 3.2 IEmissionModule

Implemented by CollateralVault and CreditLedger:

```solidity
interface IEmissionModule is IModule {
    /// @notice Returns total collateral value backing circulating supply
    function totalBacking() external view returns (uint256);

    /// @notice Returns collateral ratio: backing / totalSupply * 1e18
    function collateralRatio() external view returns (uint256);

    /// @notice Emission type identifier
    function emissionType() external pure returns (EmissionType);
}

enum EmissionType { COLLATERAL, MUTUAL_CREDIT, ADMIN }
```

### 3.3 Events (System-wide)

```solidity
// ModuleRegistry
event ModuleRegistered(address indexed module, bytes32 moduleType);
event ModuleDeregistered(address indexed module);
event HookOrderSet(bytes32[] hookOrder);

// GToken
event Mint(address indexed to, uint256 amount);
event Burn(address indexed from, uint256 amount);
event HookExecuted(bytes32 hookType, address module, bool success);

// EPController
event RateChanged(uint256 oldRate, uint256 newRate);
event OMOExecuted(bool isBuy, uint256 amount);
event LOLRIssued(address indexed cp, uint256 amount, uint256 maturity);

// CreditModule
event LoanIssued(address indexed borrower, uint256 principal, uint256 rate);
event LoanRepaid(address indexed borrower, uint256 principal, uint256 interest);
event Liquidated(address indexed borrower, address indexed liquidator, uint256 collateral);

// ExitModule
event Exit(address indexed user, uint256 groshBurned, uint256 usdcOut);
event CircuitBreakerTriggered(uint256 dailyOutflow, uint256 threshold);
```

---

## 4. Module: GToken

**File:** `src/core/GToken.sol`

### 4.1 Storage

```solidity
contract GToken is ERC20, ERC20Permit, Ownable, Pausable {
    IModuleRegistry public registry;
    uint256 public maxSupply;           // 0 = unlimited
    uint256 public hookGasLimit;        // gas cap per hook call (default: 200_000)
    bool public transfersPaused;
```

### 4.2 Constructor Parameters

| Parameter | Type | Description |
|---|---|---|
| `name` | string | Token name (e.g. "GroshY") |
| `symbol` | string | Token symbol (e.g. "GRSH") |
| `maxSupply` | uint256 | Max mintable supply (0 = unlimited) |
| `hookGasLimit` | uint256 | Gas limit per hook call |
| `owner` | address | Initial owner (Gnosis Safe recommended) |

### 4.3 Key Functions

```solidity
/// @notice Mint GROSH. Only callable by registered emission module.
/// @dev Calls beforeMint on all registered modules, then mints, then afterMint.
function mint(address to, uint256 amount) external onlyRegisteredEmission {
    _executeHooks(HookType.BEFORE_MINT, to, amount);  // reverts if any hook reverts
    _mint(to, amount);
    _executeHooks(HookType.AFTER_MINT, to, amount);   // best-effort, no revert
    emit Mint(to, amount);
}

/// @notice Burn GROSH. Only callable by registered modules.
function burn(address from, uint256 amount) external onlyRegisteredModule {
    _executeHooks(HookType.BEFORE_BURN, from, amount);
    _burn(from, amount);
    _executeHooks(HookType.AFTER_BURN, from, amount);
    emit Burn(from, amount);
}

/// @notice Override ERC20 transfer to execute afterTransfer hooks
function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
    _executeHooks(HookType.AFTER_TRANSFER, from, to, amount);
}

/// @notice Execute hooks with gas limit protection
function _executeHooks(HookType hookType, ...) internal {
    address[] memory modules = registry.getHookModules(hookType);
    for (uint i = 0; i < modules.length; i++) {
        // Low-level call with gas limit — prevents single module from bricking system
        (bool success,) = modules[i].call{gas: hookGasLimit}(
            abi.encodeWithSelector(IModule.beforeMint.selector, to, amount)
        );
        if (hookType == HookType.BEFORE_MINT && !success) revert HookReverted(modules[i]);
        // afterMint/afterTransfer: log failure but don't revert
    }
}
```

### 4.4 Access Control

```solidity
modifier onlyRegisteredEmission() {
    require(registry.isRegistered(msg.sender, ModuleRole.EMISSION), "Not emission module");
    _;
}

modifier onlyRegisteredModule() {
    require(registry.isRegistered(msg.sender, ModuleRole.ANY), "Not registered module");
    _;
}
```

### 4.5 Configuration

```solidity
function setHookGasLimit(uint256 limit) external onlyOwner {
    require(limit >= 50_000 && limit <= 2_000_000, "Invalid gas limit");
    hookGasLimit = limit;
}

function setMaxSupply(uint256 newMax) external onlyOwner {
    require(newMax >= totalSupply() || newMax == 0, "Below current supply");
    maxSupply = newMax;
}
```

---

## 5. Module: ModuleRegistry

**File:** `src/core/ModuleRegistry.sol`

### 5.1 Storage

```solidity
contract ModuleRegistry is Ownable, TimelockController {
    IGToken public gtoken;

    mapping(address => ModuleInfo) public modules;
    mapping(ModuleRole => address[]) public modulesByRole;
    mapping(HookType => address[]) public hookModules;

    uint256 public timelockDelay;       // seconds, default: 172800 (48h)
    uint256 public maxModulesPerCP;     // default: 10
    address public adminMultisig;       // Gnosis Safe address

    struct ModuleInfo {
        bytes32 moduleType;
        ModuleRole role;
        bool active;
        uint256 registeredAt;
    }
}

enum ModuleRole { EMISSION, RESERVE, CREDIT, EXIT, POLICY, CLEARING }
enum HookType { BEFORE_MINT, AFTER_MINT, BEFORE_BURN, AFTER_BURN, AFTER_TRANSFER }
```

### 5.2 Key Functions

```solidity
/// @notice Register a new module. Subject to timelock.
function registerModule(
    address module,
    ModuleRole role,
    HookType[] calldata hooks
) external onlyOwner {
    require(IModule(module).moduleType() != bytes32(0), "Invalid module");
    require(!modules[module].active, "Already registered");

    // Schedule via timelock (48h delay)
    bytes memory data = abi.encodeCall(this._executeRegister, (module, role, hooks));
    schedule(address(this), 0, data, bytes32(0), bytes32(0), timelockDelay);
}

function _executeRegister(address module, ModuleRole role, HookType[] calldata hooks)
    external onlySelf
{
    modules[module] = ModuleInfo({
        moduleType: IModule(module).moduleType(),
        role: role,
        active: true,
        registeredAt: block.timestamp
    });
    modulesByRole[role].push(module);
    for (uint i = 0; i < hooks.length; i++) {
        hookModules[hooks[i]].push(module);
    }
    emit ModuleRegistered(module, IModule(module).moduleType());
}

/// @notice Deregister module. Also subject to timelock.
function deregisterModule(address module) external onlyOwner {
    // Schedule deregistration with timelock
}

/// @notice Set execution order for hooks (determines priority)
function setHookOrder(HookType hookType, address[] calldata ordered) external onlyOwner {
    hookModules[hookType] = ordered;
    emit HookOrderSet(hookType, ordered);
}

/// @notice Emergency pause — no timelock, immediate
function emergencyPause(address module) external onlyOwner {
    IModule(module).pause();  // module-level pause
}
```

### 5.3 Role Matrix

| Role | Can call mint? | Can call burn? | Receives hooks? |
|---|---|---|---|
| EMISSION | YES | NO | YES |
| RESERVE | NO | NO | YES (beforeMint) |
| CREDIT | NO | YES (on liquidation) | YES |
| EXIT | NO | YES | YES |
| POLICY | NO | NO | YES |
| CLEARING | NO | NO | YES (afterTransfer) |

---

## 6. Module: CollateralVault

**File:** `src/emission/CollateralVault.sol`

### 6.1 Storage

```solidity
contract CollateralVault is IEmissionModule, Ownable, Pausable, ReentrancyGuard {
    IGToken public gtoken;
    IModuleRegistry public registry;
    IOracle public oracle;             // Chainlink aggregator

    struct AssetConfig {
        bool accepted;
        uint16 haircut;               // basis points, e.g. 500 = 5%
        uint16 maxAllocation;         // max % of total collateral (basis points)
        address chainlinkFeed;        // price feed address
    }

    mapping(address asset => AssetConfig) public assetConfigs;
    mapping(address user => mapping(address asset => uint256)) public userCollateral;
    mapping(address user => uint256) public userGroshMinted;

    address[] public acceptedAssets;
    uint256 public minDeposit;         // minimum deposit in USD (18 decimals)
    uint256 public totalCollateralUSD; // cached, updated on deposit/withdraw
```

### 6.2 Constructor Parameters

| Parameter | Type | Description |
|---|---|---|
| `gtoken` | address | GToken contract |
| `registry` | address | ModuleRegistry |
| `oracle` | address | Chainlink oracle wrapper |
| `minDeposit` | uint256 | Minimum deposit (USD, 18 dec) |

### 6.3 Asset Configuration

```solidity
function addAsset(
    address asset,
    uint16 haircut,          // 500 = 5% haircut, mint 95% of value
    uint16 maxAllocation,    // 10000 = 100%, 3000 = 30%
    address chainlinkFeed
) external onlyOwner {
    require(haircut <= 5000, "Haircut too high");  // max 50%
    require(asset != address(gtoken), "GROSH cannot be collateral"); // CRITICAL
    assetConfigs[asset] = AssetConfig(true, haircut, maxAllocation, chainlinkFeed);
    acceptedAssets.push(asset);
}
```

**Important:** GToken itself must never be accepted as collateral. This is enforced at the contract level to prevent circular collateral (Terra UST failure mode).

### 6.4 Deposit Flow

```solidity
/// @notice Deposit asset, receive GROSH
/// @param asset Address of collateral asset (USDC, stETH, etc.)
/// @param amount Amount of asset to deposit
/// @param minGroshOut Slippage protection
function deposit(
    address asset,
    uint256 amount,
    uint256 minGroshOut
) external nonReentrant whenNotPaused returns (uint256 groshOut) {
    AssetConfig memory cfg = assetConfigs[asset];
    require(cfg.accepted, "Asset not accepted");
    require(amount >= minDeposit, "Below minimum deposit");

    // 1. Calculate GROSH to mint
    uint256 assetValueUSD = _getAssetValueUSD(asset, amount);
    groshOut = assetValueUSD * (10_000 - cfg.haircut) / 10_000;
    require(groshOut >= minGroshOut, "Slippage exceeded");

    // 2. Check max allocation
    uint256 newAllocation = (userCollateral[msg.sender][asset] + amount) * 10_000
        / (totalCollateralUSD + assetValueUSD);
    require(newAllocation <= cfg.maxAllocation, "Asset allocation exceeded");

    // 3. Transfer collateral in
    IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

    // 4. Update accounting
    userCollateral[msg.sender][asset] += amount;
    userGroshMinted[msg.sender] += groshOut;
    totalCollateralUSD += assetValueUSD;

    // 5. Mint GROSH (triggers beforeMint hooks — will revert if R_min violated)
    gtoken.mint(msg.sender, groshOut);
}
```

### 6.5 Withdrawal Flow

```solidity
/// @notice Burn GROSH, recover collateral
function withdraw(
    address asset,
    uint256 groshAmount
) external nonReentrant whenNotPaused {
    require(userGroshMinted[msg.sender] >= groshAmount, "Insufficient minted balance");

    uint256 assetOut = _groshToAsset(msg.sender, asset, groshAmount);

    userGroshMinted[msg.sender] -= groshAmount;
    userCollateral[msg.sender][asset] -= assetOut;

    // Burn GROSH (triggers beforeBurn hooks)
    gtoken.burn(msg.sender, groshAmount);

    // Return collateral
    IERC20(asset).safeTransfer(msg.sender, assetOut);
}
```

### 6.6 Oracle Integration

```solidity
function _getAssetValueUSD(address asset, uint256 amount) internal view returns (uint256) {
    (, int256 price,, uint256 updatedAt,) =
        AggregatorV3Interface(assetConfigs[asset].chainlinkFeed).latestRoundData();

    require(price > 0, "Invalid oracle price");
    require(block.timestamp - updatedAt <= 3600, "Oracle price stale"); // 1h staleness

    // Normalize to 18 decimals
    uint8 feedDecimals = AggregatorV3Interface(assetConfigs[asset].chainlinkFeed).decimals();
    uint8 assetDecimals = IERC20Metadata(asset).decimals();

    return (uint256(price) * amount * 1e18)
        / (10 ** feedDecimals * 10 ** assetDecimals);
}
```

### 6.7 IModule Hook Implementations

```solidity
function beforeMint(address, uint256) external override onlyGToken {
    // CollateralVault validates collateral was recorded before mint
    // (actual validation happens in deposit() before calling gtoken.mint())
}

function afterMint(address, uint256) external override onlyGToken {
    // No action needed — accounting updated in deposit()
}

function beforeBurn(address from, uint256 amount) external override onlyGToken {
    // Validate user has enough minted balance to cover burn
    require(userGroshMinted[from] >= amount, "Burn exceeds minted balance");
}
```

### 6.8 Configuration Parameters

| Parameter | Default | Range | Description |
|---|---|---|---|
| `minDeposit` | 10 USD | > 0 | Minimum deposit to prevent dust |
| `haircut` per asset | 500 bp | 0–5000 bp | Discount applied to collateral value |
| `maxAllocation` | 10000 bp | 100–10000 bp | Max % of total collateral per asset |
| Oracle staleness | 3600 s | 300–86400 s | Max age of price feed data |

---

## 7. Module: CreditLedger

**File:** `src/emission/CreditLedger.sol`

### 7.1 Design Principles

CreditLedger implements **mutual credit**: GROSH is created when a member draws on their credit line and destroyed when they repay. The sum of all balances is always zero (some positive, some negative at the ledger level, net = 0 in GROSH terms).

Key invariants:
- `Σ all positive balances = Σ all negative ledger positions`
- No external collateral required
- Requires closed, identified community (demurrage enforces circulation)

### 7.2 Storage

```solidity
contract CreditLedger is IEmissionModule, Ownable, Pausable {
    IGToken public gtoken;
    IModuleRegistry public registry;

    struct MemberLine {
        uint256 creditLimit;          // max GROSH member can hold (18 dec)
        uint256 debitLimit;           // max GROSH member can owe (18 dec)
        uint256 borrowed;             // current outstanding borrow
        uint256 lineExpiry;           // timestamp when line expires (0 = no expiry)
        bool active;
    }

    mapping(address => MemberLine) public memberLines;
    address[] public members;

    uint16 public demurrageRateBPS;   // basis points per month, e.g. 50 = 0.5%/mo
    uint256 public lastDemurrageAt;   // last demurrage timestamp
    uint256 public totalBorrowed;     // total GROSH outstanding from credit lines

    // Demurrage pool — collected demurrage redistributed to active CPs
    uint256 public demurragePool;
```

### 7.3 Member Management

```solidity
/// @notice Open credit line for a member. Only callable by admin (multisig/DAO).
function openLine(
    address member,
    uint256 creditLimit,     // max GROSH they can have
    uint256 debitLimit,      // max GROSH they can owe
    uint256 expiryDays       // 0 = no expiry
) external onlyOwner {
    require(!memberLines[member].active, "Line already exists");
    require(member != address(0), "Invalid member");
    require(debitLimit > 0 || creditLimit > 0, "Both limits zero");

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

/// @notice Adjust limits. Immediate for reduction, timelocked for increase.
function adjustLimit(address member, uint256 newDebitLimit, uint256 newCreditLimit)
    external onlyOwner
{
    MemberLine storage line = memberLines[member];
    require(line.active, "No active line");

    // Reducing limit: immediate (protects system)
    // Increasing limit: should go through governance
    if (newDebitLimit < line.debitLimit || newCreditLimit < line.creditLimit) {
        line.debitLimit = newDebitLimit;
        line.creditLimit = newCreditLimit;
    } else {
        // Timelock increase via governance
        revert("Use governance to increase limits");
    }
}
```

### 7.4 Borrowing Flow

```solidity
/// @notice Draw on credit line — creates GROSH
function borrow(uint256 amount) external whenNotPaused nonReentrant {
    MemberLine storage line = memberLines[msg.sender];
    require(line.active, "No active line");
    require(line.lineExpiry == 0 || block.timestamp < line.lineExpiry, "Line expired");
    require(line.borrowed + amount <= line.debitLimit, "Exceeds debit limit");

    // Apply demurrage before new borrow
    _applyDemurrage(msg.sender);

    line.borrowed += amount;
    totalBorrowed += amount;

    // Mint GROSH (triggers beforeMint hooks — no R_min check for mutual credit)
    gtoken.mint(msg.sender, amount);
    emit Borrowed(msg.sender, amount);
}

/// @notice Repay credit line — destroys GROSH
function repay(uint256 amount) external whenNotPaused nonReentrant {
    MemberLine storage line = memberLines[msg.sender];
    require(line.active, "No active line");
    require(line.borrowed >= amount, "Overpayment");

    line.borrowed -= amount;
    totalBorrowed -= amount;

    // Burn GROSH
    gtoken.burn(msg.sender, amount);
    emit Repaid(msg.sender, amount);
}
```

### 7.5 Demurrage Mechanism

Demurrage charges a holding fee on positive GROSH balances, stimulating circulation over hoarding.

```solidity
/// @notice Apply monthly demurrage to all active members
/// @dev Called periodically (e.g. monthly via keeper or on any user interaction)
function applyGlobalDemurrage() external {
    require(block.timestamp >= lastDemurrageAt + 30 days, "Too early");
    uint256 totalCharged = 0;

    for (uint i = 0; i < members.length; i++) {
        uint256 balance = gtoken.balanceOf(members[i]);
        if (balance > 0) {
            uint256 charge = balance * demurrageRateBPS / 10_000;
            // Transfer demurrage from member to pool
            gtoken.burn(members[i], charge);
            totalCharged += charge;
        }
    }

    demurragePool += totalCharged;
    lastDemurrageAt = block.timestamp;
    emit DemurrageApplied(totalCharged, block.timestamp);
}

/// @dev Gas-optimized: apply demurrage only to single member on interaction
function _applyDemurrage(address member) internal {
    // Calculate accrued demurrage since last interaction
    uint256 monthsElapsed = (block.timestamp - lastDemurrageAt) / 30 days;
    if (monthsElapsed == 0) return;

    uint256 balance = gtoken.balanceOf(member);
    if (balance == 0) return;

    // Compound demurrage: balance * (1 - rate)^months
    uint256 charge = balance -
        (balance * (10_000 - demurrageRateBPS) ** monthsElapsed / 10_000 ** monthsElapsed);

    if (charge > 0) {
        gtoken.burn(member, charge);
        demurragePool += charge;
    }
}
```

### 7.6 Invariant Checks

```solidity
/// @notice Verify system invariant: totalBorrowed == totalSupply (for pure mutual credit)
function checkInvariant() external view returns (bool) {
    return gtoken.totalSupply() == totalBorrowed;
}

/// @notice Called by monitoring bots
function getNetPosition(address member) external view returns (int256) {
    int256 balance = int256(gtoken.balanceOf(member));
    int256 borrowed = int256(memberLines[member].borrowed);
    return balance - borrowed; // positive = net creditor, negative = net debtor
}
```

### 7.7 Configuration Parameters

| Parameter | Default | Range | Description |
|---|---|---|---|
| `demurrageRateBPS` | 50 | 0–500 | Monthly holding fee (basis points) |
| `lineExpiry` | 0 (no expiry) | 0–3650 days | Days until line must be renewed |
| `maxDebitLimit` | Governance-set | > 0 | Per-member max borrow |
| `maxCreditLimit` | Governance-set | > 0 | Per-member max holding |

---

## 8. Module: ReserveVault

**File:** `src/services/ReserveVault.sol`

### 8.1 Purpose

ReserveVault enforces the liquidity ratio (R_min): minimum reserve relative to outstanding obligations. It is the primary protection against bank runs.

```
R_min = reserveBalance / totalObligations >= R_min_target
```

Where `totalObligations = totalSupply (GROSH) + EP loans to this CP`.

### 8.2 Storage

```solidity
contract ReserveVault is ERC4626, IModule, Ownable, Pausable {
    IGToken public gtoken;
    IERC20 public reserveAsset;        // USDC (or configured stable)
    IEPController public epController;

    uint16 public rMinBPS;             // e.g. 2000 = 20%
    uint16 public rebalanceThresholdBPS; // trigger rebalance at e.g. 2200 = 22%
    uint16 public emergencyBufferBPS;  // additional buffer on top of R_min
    uint256 public epLoanBalance;      // outstanding EP emergency loans to this CP

    // Circuit breaker
    uint256 public dailyOutflow;
    uint256 public lastOutflowReset;
    uint16 public cbThresholdBPS;      // daily outflow % that triggers circuit breaker
    bool public circuitBreakerActive;
```

### 8.3 beforeMint Hook — R_min Enforcement

```solidity
/// @notice BEFORE_MINT hook — reverts if mint would violate R_min
function beforeMint(address, uint256 amount) external override onlyGToken {
    if (paused() || circuitBreakerActive) revert SystemPaused();

    uint256 newSupply = gtoken.totalSupply() + amount;
    uint256 reserve = reserveAsset.balanceOf(address(this));
    uint256 obligations = newSupply + epLoanBalance;

    // Check R_min: reserve / obligations >= rMin
    require(
        reserve * 10_000 >= obligations * rMinBPS,
        "R_min violation: insufficient reserves"
    );
}
```

### 8.4 Circuit Breaker

```solidity
/// @notice afterBurn hook — tracks daily outflow, triggers circuit breaker
function afterBurn(address, uint256 amount) external override onlyGToken {
    // Reset daily counter
    if (block.timestamp > lastOutflowReset + 1 days) {
        dailyOutflow = 0;
        lastOutflowReset = block.timestamp;
        circuitBreakerActive = false; // auto-reset after 24h
    }

    dailyOutflow += amount;
    uint256 totalSupply = gtoken.totalSupply();

    // Trigger if daily outflow exceeds threshold % of total supply
    if (totalSupply > 0 && dailyOutflow * 10_000 > totalSupply * cbThresholdBPS) {
        circuitBreakerActive = true;
        emit CircuitBreakerTriggered(dailyOutflow, totalSupply * cbThresholdBPS / 10_000);
    }
}

/// @notice Manual circuit breaker reset (governance only, after investigation)
function resetCircuitBreaker() external onlyOwner {
    circuitBreakerActive = false;
    dailyOutflow = 0;
    emit CircuitBreakerReset(block.timestamp);
}
```

### 8.5 EP Loan Tracking

```solidity
/// @notice Record EP emergency loan (LOLR). Only callable by EPController.
function recordEPLoan(uint256 amount) external onlyEPController {
    epLoanBalance += amount;
    // This increases obligations, making R_min harder to maintain
    // — creates incentive to repay EP loans quickly
}

function repayEPLoan(uint256 amount) external onlyEPController {
    require(epLoanBalance >= amount, "Overpayment");
    epLoanBalance -= amount;
}
```

### 8.6 Configuration Parameters

| Parameter | Default | Range | Description |
|---|---|---|---|
| `rMinBPS` | 2000 | 0–10000 | Minimum reserve ratio (basis points) |
| `rebalanceThresholdBPS` | 2200 | rMin–10000 | Trigger for rebalance alert |
| `emergencyBufferBPS` | 500 | 0–2000 | Buffer above R_min before blocking |
| `cbThresholdBPS` | 1000 | 100–5000 | Daily outflow % triggering circuit breaker |

---

## 9. Module: CreditModule

**File:** `src/services/CreditModule.sol`

### 9.1 Storage

```solidity
contract CreditModule is IModule, Ownable, Pausable, ReentrancyGuard {
    IGToken public gtoken;
    IReserveVault public reserveVault;
    ICollateralVault public collateralVault; // null for mutual credit config

    struct Loan {
        uint256 principal;           // original loan amount (GROSH)
        uint256 interestAccrued;     // accrued but not yet minted
        uint256 ratePerSecond;       // interest rate per second (ray, 27 decimals)
        uint256 lastUpdated;         // block.timestamp of last accrual
        address collateralAsset;     // address(0) for uncollateralized
        uint256 collateralAmount;    // amount of collateral locked
        bool active;
    }

    mapping(address => Loan) public loans;

    uint16 public carMinBPS;             // min capital adequacy ratio (basis points)
    uint16 public ltvMaxBPS;             // max loan-to-value (basis points)
    uint16 public liquidationPenaltyBPS; // bonus to liquidator (basis points)
    uint256 public maxMaturitySeconds;   // max loan duration
    uint16 public originationFeeBPS;     // fee on loan origination
```

### 9.2 Interest Rate Model

Interest accrues continuously (compound per second, not per block — more predictable):

```solidity
/// @notice Accrue interest on a loan (call before any loan interaction)
function _accrueInterest(address borrower) internal {
    Loan storage loan = loans[borrower];
    if (!loan.active) return;

    uint256 elapsed = block.timestamp - loan.lastUpdated;
    if (elapsed == 0) return;

    // Compound interest: principal * ((1 + r)^t - 1)
    // Using ray math (27 decimals) for precision
    uint256 multiplier = _rpow(loan.ratePerSecond + RAY, elapsed, RAY);
    uint256 newDebt = loan.principal * multiplier / RAY;
    loan.interestAccrued += newDebt - loan.principal;
    loan.lastUpdated = block.timestamp;
}

/// @notice Convert annual rate to per-second rate (ray math)
function _annualRateToPerSecond(uint256 annualRateBPS) internal pure returns (uint256) {
    // annualRateBPS in basis points: 800 = 8%/year
    // perSecond = (1 + 0.08)^(1/31536000) - 1 expressed in ray
    uint256 annualRate = annualRateBPS * RAY / 10_000; // convert to ray
    return _nthRoot(RAY + annualRate, 31_536_000) - RAY;
}
```

### 9.3 Loan Origination

```solidity
/// @notice Issue a loan to borrower
/// @param amount GROSH amount to borrow
/// @param collateralAsset Asset to lock as collateral (address(0) for uncollateralized)
/// @param collateralAmount Amount of collateral
function borrow(
    uint256 amount,
    address collateralAsset,
    uint256 collateralAmount
) external nonReentrant whenNotPaused {
    require(!loans[msg.sender].active, "Existing loan must be repaid first");
    require(amount > 0, "Zero amount");

    // 1. Check CAR (Capital Adequacy Ratio)
    uint256 totalCredit = gtoken.totalSupply();
    uint256 capitalBPS = reserveVault.getCapitalBPS();
    require(capitalBPS >= carMinBPS, "CAR too low — system at capacity");

    // 2. Check LTV if collateralized
    if (collateralAsset != address(0)) {
        uint256 collateralUSD = collateralVault.getAssetValueUSD(collateralAsset, collateralAmount);
        require(
            amount * 10_000 <= collateralUSD * ltvMaxBPS,
            "Exceeds max LTV"
        );
        // Lock collateral in CollateralVault
        IERC20(collateralAsset).safeTransferFrom(msg.sender, address(collateralVault), collateralAmount);
        collateralVault.lockCollateral(msg.sender, collateralAsset, collateralAmount);
    }

    // 3. Calculate interest rate from EPController
    uint256 rate = epController.getCurrentRate(); // R_target in BPS

    // 4. Origination fee
    uint256 fee = amount * originationFeeBPS / 10_000;
    reserveVault.deposit(fee); // fee goes to reserve

    // 5. Record loan
    loans[msg.sender] = Loan({
        principal: amount,
        interestAccrued: 0,
        ratePerSecond: _annualRateToPerSecond(rate),
        lastUpdated: block.timestamp,
        collateralAsset: collateralAsset,
        collateralAmount: collateralAmount,
        active: true
    });

    // 6. Mint GROSH (triggers beforeMint hooks — checks R_min)
    gtoken.mint(msg.sender, amount - fee);
    emit LoanIssued(msg.sender, amount, rate);
}
```

### 9.4 Repayment

```solidity
/// @notice Repay loan
/// @param amount Amount of GROSH to repay
function repay(uint256 amount) external nonReentrant {
    Loan storage loan = loans[msg.sender];
    require(loan.active, "No active loan");

    _accrueInterest(msg.sender);

    uint256 totalDebt = loan.principal + loan.interestAccrued;
    require(amount <= totalDebt, "Overpayment");

    // Split payment: interest first, then principal
    uint256 interestPayment = amount > loan.interestAccrued
        ? loan.interestAccrued
        : amount;
    uint256 principalPayment = amount - interestPayment;

    // Interest: mint new GROSH and send to ReserveVault as income
    // NOTE: interest GROSH minted only at repayment — no inflationary pressure during loan life
    if (interestPayment > 0) {
        gtoken.mint(address(reserveVault), interestPayment);
        loan.interestAccrued -= interestPayment;
    }

    // Principal: burn from borrower
    if (principalPayment > 0) {
        gtoken.burn(msg.sender, principalPayment);
        loan.principal -= principalPayment;
    }

    // If fully repaid, close loan and release collateral
    if (loan.principal == 0 && loan.interestAccrued == 0) {
        _closeLoan(msg.sender);
    }

    emit LoanRepaid(msg.sender, principalPayment, interestPayment);
}
```

### 9.5 Liquidation

```solidity
/// @notice Liquidate undercollateralized loan
function liquidate(address borrower) external nonReentrant {
    Loan storage loan = loans[borrower];
    require(loan.active, "No active loan");
    require(loan.collateralAsset != address(0), "Uncollateralized loan cannot be liquidated");

    _accrueInterest(borrower);

    uint256 totalDebt = loan.principal + loan.interestAccrued;
    uint256 healthFactor = _getHealthFactor(borrower);
    require(healthFactor < 1e18, "Loan is healthy"); // HF < 1.0

    // Liquidator repays full debt
    gtoken.burn(msg.sender, totalDebt);

    // Liquidator receives collateral + penalty bonus
    uint256 collateralOut = loan.collateralAmount;
    uint256 penaltyBonus = collateralOut * liquidationPenaltyBPS / 10_000;

    // Transfer collateral + bonus to liquidator
    collateralVault.releaseCollateral(
        borrower,
        loan.collateralAsset,
        collateralOut,
        msg.sender
    );

    // Penalty goes to ReserveVault as insurance
    // (penalty is sourced from liquidator's payment exceeding debt value)

    _closeLoan(borrower);
    emit Liquidated(borrower, msg.sender, collateralOut);
}

/// @notice Health Factor = collateral_value_USD / (total_debt * liquidation_threshold)
function _getHealthFactor(address borrower) internal view returns (uint256) {
    Loan storage loan = loans[borrower];
    uint256 totalDebt = loan.principal + loan.interestAccrued;
    if (totalDebt == 0) return type(uint256).max;

    uint256 collateralUSD = collateralVault.getAssetValueUSD(
        loan.collateralAsset,
        loan.collateralAmount
    );

    // liquidation threshold = LTV_max * 1.25 (25% buffer above max LTV)
    uint256 liquidationThreshold = ltvMaxBPS * 125 / 100;
    return collateralUSD * 1e18 / (totalDebt * liquidationThreshold / 10_000);
}
```

### 9.6 Configuration Parameters

| Parameter | Default | Range | Description |
|---|---|---|---|
| `carMinBPS` | 1000 | 0–10000 | Min capital adequacy ratio |
| `ltvMaxBPS` | 7500 | 1000–9000 | Max loan-to-value ratio |
| `liquidationPenaltyBPS` | 1000 | 100–3000 | Bonus to liquidator |
| `maxMaturitySeconds` | 365 days | 1 day–∞ | Max loan duration |
| `originationFeeBPS` | 50 | 0–500 | Fee on loan origination |

---

## 10. Module: ExitModule

**File:** `src/services/ExitModule.sol`

### 10.1 Design

ExitModule implements the mechanism for leaving the system. It supports three modes:

| Mode | Description | When to use |
|---|---|---|
| `HARD_PEG` | 1:1 burn GROSH → USDC from reserve | Currency board config |
| `PSM` | 1:1 up to PSM_cap, then spread applies | Soft peg config |
| `AMM` | Market rate via AMM pool | Floating rate config |

The mode is set at deployment and should match the trilemma choice.

### 10.2 Storage

```solidity
contract ExitModule is IModule, Ownable, Pausable, ReentrancyGuard {
    IGToken public gtoken;
    IReserveVault public reserveVault;

    ExitMode public mode;
    uint16 public exitSpreadBPS;       // e.g. 30 = 0.3%
    uint16 public maxExitPerDayBPS;    // max % of supply exitable per day
    uint256 public cooldownBlocks;     // blocks between exits per address
    uint16 public cbThresholdBPS;      // daily exit % triggering circuit breaker

    // PSM mode
    uint256 public psmCapUSD;          // max USDC in PSM module
    uint256 public psmUsed;            // current PSM utilization

    // Per-user cooldown
    mapping(address => uint256) public lastExitBlock;

    // Daily tracking
    uint256 public dailyExitAmount;
    uint256 public lastExitResetDay;

enum ExitMode { HARD_PEG, PSM, AMM }
```

### 10.3 Exit Flow (Hard Peg)

```solidity
/// @notice Exit system: burn GROSH, receive reserve asset
function exit(
    uint256 groshAmount,
    uint256 minOut    // slippage protection
) external nonReentrant whenNotPaused returns (uint256 usdcOut) {
    require(groshAmount > 0, "Zero amount");
    require(
        block.number >= lastExitBlock[msg.sender] + cooldownBlocks,
        "Cooldown not elapsed"
    );

    // Circuit breaker check (also enforced in afterBurn hook)
    _checkDailyLimit(groshAmount);

    // R_min check: will reserve cover this exit?
    uint256 reserve = reserveVault.totalAssets();
    uint256 supply = gtoken.totalSupply();
    require(
        (reserve - groshAmount) * 10_000 >= (supply - groshAmount) * reserveVault.rMinBPS(),
        "Exit would violate R_min"
    );

    // Calculate output with spread
    usdcOut = groshAmount * (10_000 - exitSpreadBPS) / 10_000;
    require(usdcOut >= minOut, "Slippage exceeded");

    // Update state
    lastExitBlock[msg.sender] = block.number;
    dailyExitAmount += groshAmount;

    // Burn GROSH (triggers beforeBurn → afterBurn hooks)
    gtoken.burn(msg.sender, groshAmount);

    // Transfer USDC from reserve
    reserveVault.withdrawReserve(msg.sender, usdcOut);

    emit Exit(msg.sender, groshAmount, usdcOut);
}
```

### 10.4 PSM Mode

```solidity
/// @notice PSM: swap GROSH ↔ USDC at 1:1 (up to cap)
function psmSwapGroshToUsdc(uint256 amount) external nonReentrant {
    require(mode == ExitMode.PSM, "Not PSM mode");
    require(psmUsed + amount <= psmCapUSD, "PSM cap reached");

    uint256 fee = amount * exitSpreadBPS / 10_000;
    uint256 usdcOut = amount - fee;

    psmUsed += amount;
    gtoken.burn(msg.sender, amount);
    reserveVault.withdrawReserve(msg.sender, usdcOut);
}

function psmSwapUsdcToGrosh(uint256 usdcAmount) external nonReentrant {
    require(mode == ExitMode.PSM, "Not PSM mode");

    IERC20(reserveVault.asset()).safeTransferFrom(msg.sender, address(reserveVault), usdcAmount);
    psmUsed = psmUsed > usdcAmount ? psmUsed - usdcAmount : 0;

    uint256 fee = usdcAmount * exitSpreadBPS / 10_000;
    gtoken.mint(msg.sender, usdcAmount - fee);
}
```

### 10.5 Daily Limit Enforcement

```solidity
function _checkDailyLimit(uint256 amount) internal {
    if (block.timestamp / 1 days > lastExitResetDay) {
        dailyExitAmount = 0;
        lastExitResetDay = block.timestamp / 1 days;
    }

    uint256 totalSupply = gtoken.totalSupply();
    require(
        (dailyExitAmount + amount) * 10_000 <= totalSupply * maxExitPerDayBPS,
        "Daily exit limit reached"
    );
}
```

### 10.6 Configuration Parameters

| Parameter | Default | Range | Description |
|---|---|---|---|
| `exitSpreadBPS` | 30 | 0–500 | Exit fee (also discourages panic) |
| `maxExitPerDayBPS` | 500 | 100–10000 | Max daily exit as % of supply |
| `cooldownBlocks` | 100 | 0–43200 | ~3 min on Polygon at 2s block time |
| `cbThresholdBPS` | 1000 | 100–5000 | Circuit breaker trigger |
| `psmCapUSD` | 1M USD | > 0 | PSM module capacity |

---

## 11. Module: EPController

**File:** `src/policy/EPController.sol`

### 11.1 Purpose

EPController is the on-chain central bank. It:
- Sets the key rate (R_target) used by CreditModule
- Conducts Open Market Operations (OMO)
- Provides emergency liquidity (LOLR) to distressed CPs
- Issues forward guidance (signal future rate changes)

EPController is **required** for any configuration with R_min < 100%.

### 11.2 Storage

```solidity
contract EPController is IModule, Ownable, Pausable {
    IGToken public gtoken;
    mapping(address => IReserveVault) public registeredCPs;

    uint256 public rTargetBPS;           // current key rate (basis points/year)
    uint256 public rFloorBPS;            // minimum rate (prevents ZIRP traps)
    uint256 public rCeilingBPS;          // maximum rate
    uint256 public interventionThresholdBPS; // depeg % triggering automatic OMO

    // LOLR
    struct LOLRLoan {
        uint256 amount;
        uint256 ratePerSecond;
        uint256 maturity;
        uint256 disbursedAt;
        bool repaid;
    }
    mapping(address => LOLRLoan) public lolrLoans;
    uint256 public lolrRateBPS;          // LOLR rate (penalty rate, > R_target)
    uint256 public lolrMaxTermSeconds;   // max LOLR duration (e.g. 7 days)
    uint256 public maxLolrPerCP;         // max LOLR size per CP (e.g. 20% of supply)

    // Forward guidance
    uint256 public signalledNextRate;
    uint256 public signalledChangeAt;
```

### 11.3 Rate Management

```solidity
/// @notice Set key rate. Governance action — should have timelock in production.
function setRate(uint256 newRateBPS) external onlyOwner {
    require(newRateBPS >= rFloorBPS && newRateBPS <= rCeilingBPS, "Out of corridor");
    uint256 oldRate = rTargetBPS;
    rTargetBPS = newRateBPS;
    emit RateChanged(oldRate, newRateBPS);
}

/// @notice Signal future rate change (forward guidance)
function signalRateChange(uint256 futureRate, uint256 effectiveAt) external onlyOwner {
    require(effectiveAt > block.timestamp, "Must be future");
    signalledNextRate = futureRate;
    signalledChangeAt = effectiveAt;
    emit ForwardGuidance(futureRate, effectiveAt);
}

/// @notice Apply signalled rate change if effective time has passed
function applySignalledChange() external {
    require(block.timestamp >= signalledChangeAt, "Not yet effective");
    require(signalledNextRate > 0, "No pending change");
    setRate(signalledNextRate);
    signalledNextRate = 0;
    signalledChangeAt = 0;
}

/// @notice Get current effective rate (accounts for signalled change)
function getCurrentRate() external view returns (uint256) {
    if (signalledNextRate > 0 && block.timestamp >= signalledChangeAt) {
        return signalledNextRate;
    }
    return rTargetBPS;
}
```

### 11.4 Open Market Operations

```solidity
/// @notice OMO Buy: EP purchases GROSH from market using reserves, reducing supply
function omoBuy(uint256 usdcAmount, uint256 minGroshOut) external onlyOwner {
    // EP spends USDC from its own reserves to buy GROSH
    // Bought GROSH is burned, reducing supply → price support
    uint256 groshOut = _swapUsdcForGrosh(usdcAmount, minGroshOut); // via AMM
    gtoken.burn(address(this), groshOut);
    emit OMOExecuted(true, groshOut);
}

/// @notice OMO Sell: EP mints GROSH and sells for USDC, increasing supply
function omoSell(uint256 groshAmount, uint256 minUsdcOut) external onlyOwner {
    // EP mints GROSH and sells to market
    // Increases supply → reduces price pressure if GROSH is above peg
    gtoken.mint(address(this), groshAmount);
    uint256 usdcOut = _swapGroshForUsdc(groshAmount, minUsdcOut); // via AMM
    // USDC goes to EP reserves
    emit OMOExecuted(false, groshAmount);
}
```

### 11.5 LOLR Mechanism

```solidity
/// @notice Issue emergency loan to CP (Lender of Last Resort)
/// @param cp Address of distressed Credit Protocol
/// @param amount GROSH amount to loan
function issueLOLR(address cp, uint256 amount) external onlyOwner {
    require(registeredCPs[cp] != IReserveVault(address(0)), "CP not registered");
    require(!lolrLoans[cp].amount > 0, "Existing LOLR loan");

    uint256 maxLolr = gtoken.totalSupply() * maxLolrPerCP / 10_000;
    require(amount <= maxLolr, "Exceeds max LOLR");

    lolrLoans[cp] = LOLRLoan({
        amount: amount,
        ratePerSecond: _annualRateToPerSecond(lolrRateBPS),
        maturity: block.timestamp + lolrMaxTermSeconds,
        disbursedAt: block.timestamp,
        repaid: false
    });

    // Record loan in CP's ReserveVault (increases obligations → incentive to repay)
    registeredCPs[cp].recordEPLoan(amount);

    // Mint GROSH directly to CP's reserve
    gtoken.mint(address(registeredCPs[cp]), amount);
    emit LOLRIssued(cp, amount, block.timestamp + lolrMaxTermSeconds);
}

/// @notice CP repays LOLR loan
function repayLOLR() external {
    LOLRLoan storage loan = lolrLoans[msg.sender];
    require(loan.amount > 0, "No LOLR loan");

    uint256 interest = _calculateLOLRInterest(msg.sender);
    uint256 total = loan.amount + interest;

    // Burn principal + interest from CP's reserve
    gtoken.burn(address(registeredCPs[msg.sender]), total);
    registeredCPs[msg.sender].repayEPLoan(loan.amount);

    loan.repaid = true;
    loan.amount = 0;
    emit LOLRRepaid(msg.sender, total);
}
```

### 11.6 Configuration Parameters

| Parameter | Default | Range | Description |
|---|---|---|---|
| `rTargetBPS` | 800 | rFloor–rCeiling | Key rate (8%/year default) |
| `rFloorBPS` | 100 | 0–1000 | Minimum rate |
| `rCeilingBPS` | 3000 | rTarget–10000 | Maximum rate |
| `lolrRateBPS` | 1500 | > rTarget | LOLR penalty rate |
| `lolrMaxTermSeconds` | 7 days | 1 day–30 days | Max LOLR duration |
| `maxLolrPerCP` | 2000 bp | 100–5000 bp | Max LOLR as % of total supply |

---

## 12. Hook System

### 12.1 Hook Execution Order

Hook order matters. Default recommended order:

**BEFORE_MINT:**
```
1. EPController.beforeMint()     — system state check (frozen? intervention needed?)
2. ReserveVault.beforeMint()     — R_min check (REVERT if violated)
3. CollateralVault.beforeMint()  — collateral recorded check
```

**AFTER_MINT:**
```
1. ReserveVault.afterMint()      — update utilization metrics
2. EPController.afterMint()      — update supply tracking for OMO triggers
```

**BEFORE_BURN:**
```
1. ExitModule.beforeBurn()       — cooldown + daily limit check
2. CreditModule.beforeBurn()     — validate no outstanding loans
```

**AFTER_BURN:**
```
1. ReserveVault.afterBurn()      — circuit breaker tracking
2. EPController.afterBurn()      — update supply tracking
```

**AFTER_TRANSFER:**
```
1. CreditLedger.afterTransfer()  — update net positions (mutual credit only)
2. EPController.afterTransfer()  — velocity tracking for monetary policy
```

### 12.2 Gas Budget

| Hook | Max gas | Notes |
|---|---|---|
| `beforeMint` | 200,000 | Can revert — keep lean |
| `afterMint` | 200,000 | Best-effort |
| `beforeBurn` | 150,000 | Can revert |
| `afterBurn` | 200,000 | Circuit breaker logic |
| `afterTransfer` | 100,000 | Called on every transfer — must be cheap |

Total `hookGasLimit` recommendation: **200,000** (covers the heaviest single hook).

---

## 13. Deployment Guide

### 13.1 Prerequisites

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Install dependencies
forge install OpenZeppelin/openzeppelin-contracts
forge install smartcontractkit/chainlink

# Environment
cp .env.example .env
# Fill: PRIVATE_KEY, POLYGON_RPC_URL, POLYGONSCAN_API_KEY
```

### 13.2 Project Structure

```
groshY/
├── src/
│   ├── core/
│   │   ├── GToken.sol
│   │   └── ModuleRegistry.sol
│   ├── emission/
│   │   ├── CollateralVault.sol
│   │   └── CreditLedger.sol
│   ├── services/
│   │   ├── ReserveVault.sol
│   │   ├── CreditModule.sol
│   │   └── ExitModule.sol
│   ├── policy/
│   │   └── EPController.sol
│   └── interfaces/
│       ├── IModule.sol
│       ├── IEmissionModule.sol
│       ├── IGToken.sol
│       ├── IModuleRegistry.sol
│       ├── IReserveVault.sol
│       └── IEPController.sol
├── script/
│   ├── Deploy.s.sol              — full deployment script
│   ├── DeployCollateral.s.sol    — collateral config only
│   └── DeployMutualCredit.s.sol  — mutual credit config only
├── test/
│   ├── unit/
│   ├── integration/
│   └── invariant/
└── foundry.toml
```

### 13.3 Deployment Script — Collateral Configuration

```solidity
// script/DeployCollateral.s.sol
contract DeployCollateral is Script {
    address constant USDC_POLYGON = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    address constant USDC_USD_FEED = 0xfE4A8cc5b5B2366C1B58Bea3858e81843581b2F7;
    address constant WETH_USD_FEED = 0xF9680D99D6C9589e2a93a78A04A279e509205945;
    address constant GNOSIS_SAFE = 0x...; // Set before deploy

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        // 1. Core
        GToken gtoken = new GToken(
            "GroshY",
            "GRSH",
            0,           // no max supply
            200_000,     // hookGasLimit
            GNOSIS_SAFE  // owner
        );

        ModuleRegistry registry = new ModuleRegistry(
            address(gtoken),
            172800,      // 48h timelock
            GNOSIS_SAFE
        );
        gtoken.setRegistry(address(registry));

        // 2. Emission
        CollateralVault vault = new CollateralVault(
            address(gtoken),
            address(registry),
            10e18        // $10 min deposit
        );
        vault.addAsset(USDC_POLYGON, 500, 10000, USDC_USD_FEED); // 5% haircut

        // 3. Services
        ReserveVault reserve = new ReserveVault(
            address(gtoken),
            USDC_POLYGON,
            2000,        // R_min = 20%
            2500,        // rebalance at 25%
            1000         // circuit breaker at 10% daily outflow
        );

        CreditModule credit = new CreditModule(
            address(gtoken),
            address(reserve),
            address(vault),
            1000,        // CAR_min 10%
            7500,        // LTV_max 75%
            1000,        // liquidation penalty 10%
            365 days,    // max maturity
            50           // origination fee 0.5%
        );

        ExitModule exitMod = new ExitModule(
            address(gtoken),
            address(reserve),
            ExitModule.ExitMode.PSM,  // soft peg
            30,          // 0.3% exit spread
            500,         // max 5% daily exit
            100,         // 100 blocks cooldown
            1000         // circuit breaker at 10% daily
        );
        exitMod.setPsmCap(1_000_000e6); // $1M PSM cap

        // 4. Policy (V2)
        EPController ep = new EPController(
            address(gtoken),
            800,         // R_target = 8%/year
            100,         // R_floor = 1%
            3000,        // R_ceiling = 30%
            1500,        // LOLR rate = 15%
            7 days,      // LOLR max term
            2000         // max LOLR = 20% of supply
        );

        // 5. Register modules
        // Note: all registrations go through timelock in production
        // For initial deploy, owner can bypass timelock with initialSetup flag
        registry.initialSetup(
            address(vault),
            address(reserve),
            address(credit),
            address(exitMod),
            address(ep)
        );

        // 6. Set hook order
        registry.setHookOrder(HookType.BEFORE_MINT, _beforeMintOrder(reserve, ep, vault));
        registry.setHookOrder(HookType.AFTER_BURN, _afterBurnOrder(reserve, ep));
        registry.setHookOrder(HookType.AFTER_TRANSFER, new address[](0)); // none for collateral

        // 7. Transfer all ownerships to Gnosis Safe
        vault.transferOwnership(GNOSIS_SAFE);
        reserve.transferOwnership(GNOSIS_SAFE);
        credit.transferOwnership(GNOSIS_SAFE);
        exitMod.transferOwnership(GNOSIS_SAFE);
        ep.transferOwnership(GNOSIS_SAFE);
        // registry and gtoken already owned by GNOSIS_SAFE

        vm.stopBroadcast();

        // Log deployed addresses
        console.log("GToken:", address(gtoken));
        console.log("ModuleRegistry:", address(registry));
        console.log("CollateralVault:", address(vault));
        console.log("ReserveVault:", address(reserve));
        console.log("CreditModule:", address(credit));
        console.log("ExitModule:", address(exitMod));
        console.log("EPController:", address(ep));
    }
}
```

### 13.4 Foundry Config

```toml
# foundry.toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc = "0.8.24"
optimizer = true
optimizer_runs = 200
via_ir = false

[profile.default.fuzz]
runs = 1000
seed = 0x1234

[profile.default.invariant]
runs = 500
depth = 50

[rpc_endpoints]
polygon = "${POLYGON_RPC_URL}"
mumbai = "${MUMBAI_RPC_URL}"
anvil = "http://localhost:8545"

[etherscan]
polygon = { key = "${POLYGONSCAN_API_KEY}", url = "https://api.polygonscan.com/api" }
```

---

## 14. Configuration Presets

### 14.1 Preset: Sardex / WIR (Mutual Credit, Closed)

```javascript
const SARDEX_CONFIG = {
  emission: "MUTUAL_CREDIT",
  peg: "NONE",              // no peg — internal unit of account
  reserve: false,
  credit: true,
  exit: false,              // closed economy
  epController: false,

  creditLedger: {
    demurrageRateBPS: 50,   // 0.5%/month
    lineExpiry: 365,        // annual renewal
  },

  creditModule: {
    carMinBPS: 0,           // no CAR — mutual credit doesn't need it
    ltvMaxBPS: 0,           // no LTV — no collateral
    ratePerSecond: 0,       // zero interest (WIR model)
  }
};
```

### 14.2 Preset: GroshY V1 (Collateral, Soft Peg)

```javascript
const GROSHYV1_CONFIG = {
  emission: "COLLATERAL",
  peg: "SOFT_USD",
  reserve: true,
  credit: true,
  exit: true,
  epController: true,

  collateralVault: {
    acceptedAssets: ["USDC"],
    haircutBPS: 500,
    minDeposit: "10e18",
  },

  reserveVault: {
    rMinBPS: 2000,
    cbThresholdBPS: 1000,
  },

  creditModule: {
    ltvMaxBPS: 7500,
    liquidationPenaltyBPS: 1000,
  },

  exitModule: {
    mode: "PSM",
    exitSpreadBPS: 30,
    psmCapUSD: "1000000e6",
  },

  epController: {
    rTargetBPS: 800,
    rFloorBPS: 100,
    rCeilingBPS: 3000,
  }
};
```

### 14.3 Preset: Currency Board (Hard Peg, No Credit)

```javascript
const CURRENCY_BOARD_CONFIG = {
  emission: "COLLATERAL",
  peg: "HARD_USD",
  reserve: true,
  credit: false,
  exit: true,
  epController: false,

  collateralVault: {
    haircutBPS: 0,          // no haircut — 1:1
  },

  reserveVault: {
    rMinBPS: 10000,         // 100% reserve
  },

  exitModule: {
    mode: "HARD_PEG",
    exitSpreadBPS: 0,       // free exit
    maxExitPerDayBPS: 10000, // no limit
  }
};
```

---

## 15. Incompatibility Rules Engine

The incompatibility engine validates configurations before deployment and at runtime. Rules are encoded as a JSON file read by both the frontend constructor and the deployment script.

### 15.1 Rule Structure

```typescript
interface Rule {
  id: string;
  severity: "CRITICAL" | "WARNING" | "INFO";
  conditions: Conditions;
  message: {
    short: string;
    explanation: string;
    historicalExample?: string;
    suggestedFix: string;
  };
}

interface Conditions {
  emission?: EmissionType;
  hasReserve?: boolean;
  hasCredit?: boolean;
  hasExit?: boolean;
  hasEPController?: boolean;
  exitMode?: ExitMode;
  rMinBPS?: { lt?: number; gt?: number; eq?: number };
  peg?: PegType;
}
```

### 15.2 Critical Rules (Block Deployment)

```json
[
  {
    "id": "MUTUAL_CREDIT_FREE_EXIT_NO_RESERVE",
    "severity": "CRITICAL",
    "conditions": {
      "emission": "MUTUAL_CREDIT",
      "hasReserve": false,
      "hasExit": true,
      "exitMode": "HARD_PEG"
    },
    "message": {
      "short": "Mutual credit + hard peg exit + no reserve",
      "explanation": "ExitModule requires USDC reserves to pay out. Mutual credit has no reserves by definition. First panic exit will drain nothing and freeze the system.",
      "historicalExample": "IRON Finance, June 2021",
      "suggestedFix": "Either disable Exit (closed economy, like Sardex) or add ReserveVault with minimum 50% R_min"
    }
  },
  {
    "id": "NO_LOLR_WITH_FRACTIONAL_RESERVE",
    "severity": "CRITICAL",
    "conditions": {
      "hasEPController": false,
      "hasReserve": true,
      "rMinBPS": { "lt": 10000 }
    },
    "message": {
      "short": "Fractional reserve without lender of last resort",
      "explanation": "Any R_min below 100% means system cannot cover simultaneous exits. Without EPController as LOLR, the first bank run will be fatal with no recourse.",
      "suggestedFix": "Add EPController or set R_min to 100% (currency board)"
    }
  },
  {
    "id": "GROSH_AS_COLLATERAL",
    "severity": "CRITICAL",
    "conditions": {
      "collateralIncludesGToken": true
    },
    "message": {
      "short": "GROSH accepted as collateral",
      "explanation": "Circular collateral: GROSH price falls → collateral value falls → more GROSH sold → price falls further. Exact failure mode of Terra UST (May 2022, $40B lost).",
      "historicalExample": "Terra UST, May 2022",
      "suggestedFix": "Only accept external assets (USDC, stETH, etc.) as collateral"
    }
  },
  {
    "id": "M0_WITHOUT_EP",
    "severity": "CRITICAL",
    "conditions": {
      "hasM0Token": true,
      "hasEPController": false
    },
    "message": {
      "short": "M0Token deployed without EPController",
      "explanation": "M0 is the inter-CP settlement asset emitted by EP. Without EP, M0 has no issuer and cannot function.",
      "suggestedFix": "Deploy EPController before M0Token"
    }
  },
  {
    "id": "HARD_PEG_NO_RESERVE_NO_EP",
    "severity": "CRITICAL",
    "conditions": {
      "peg": "HARD_USD",
      "hasReserve": false,
      "hasEPController": false
    },
    "message": {
      "short": "Hard peg with no reserves and no intervention tools",
      "explanation": "A hard peg requires either 100% reserves (currency board) or active intervention (EPController). Without either, the peg will break on first significant sell pressure.",
      "historicalExample": "Terra UST, May 2022",
      "suggestedFix": "Add ReserveVault with R_min=100% OR add EPController for interventions"
    }
  },
  {
    "id": "PERMISSIONLESS_REPUTATION_CREDIT",
    "severity": "CRITICAL",
    "conditions": {
      "onboarding": "PERMISSIONLESS",
      "creditType": "REPUTATION"
    },
    "message": {
      "short": "Reputation-based credit with permissionless onboarding",
      "explanation": "Reputation requires identity. Permissionless = anonymous addresses. Anonymous addresses cannot have reputation — anyone can create a new address and get a fresh credit line.",
      "suggestedFix": "Use invite-based or KYC onboarding for reputation credit"
    }
  },
  {
    "id": "HARD_CAPITAL_CONTROL_PERMISSIONLESS",
    "severity": "CRITICAL",
    "conditions": {
      "capitalControl": "HARD",
      "onboarding": "PERMISSIONLESS"
    },
    "message": {
      "short": "Hard capital controls with permissionless access",
      "explanation": "Hard controls (governance-only exit) require identity to enforce. Permissionless users can bypass via secondary markets — control becomes theater.",
      "suggestedFix": "Use KYC/allowlist onboarding, or relax to soft capital controls"
    }
  }
]
```

### 15.3 Warning Rules (Deploy with Warning)

```json
[
  {
    "id": "RMIN_100_WITH_CREDIT",
    "severity": "WARNING",
    "conditions": {
      "rMinBPS": { "eq": 10000 },
      "hasCredit": true
    },
    "message": {
      "short": "R_min 100% with credit module",
      "explanation": "With 100% reserve requirement, loans cannot create new GROSH beyond the reserve. Credit module adds complexity with no multiplier benefit.",
      "suggestedFix": "Either reduce R_min (e.g. 20%) to enable multiplier, or remove CreditModule (currency board needs no lending)"
    }
  },
  {
    "id": "DEMURRAGE_HARD_PEG",
    "severity": "WARNING",
    "conditions": {
      "demurrageRateBPS": { "gt": 0 },
      "peg": "HARD_USD"
    },
    "message": {
      "short": "Demurrage with hard peg",
      "explanation": "Demurrage creates constant selling pressure on GROSH (holders pay to hold). With hard peg, EPController or reserves must absorb this pressure continuously.",
      "suggestedFix": "Ensure EPController is active with sufficient OMO capacity, or use soft peg"
    }
  },
  {
    "id": "COMMODITY_PEG_FREE_EXIT",
    "severity": "WARNING",
    "conditions": {
      "peg": "COMMODITY",
      "exitMode": "HARD_PEG"
    },
    "message": {
      "short": "Commodity peg with hard exit",
      "explanation": "Commodity prices are seasonal and volatile. Hard exit requires reserves to track commodity price exactly. Reserve shortfalls likely during price spikes.",
      "historicalExample": "Liberty Dollar, closed by FBI 2009",
      "suggestedFix": "Use PSM with spread or AMM exit for commodity-pegged systems"
    }
  }
]
```

### 15.4 Deployment-time Validation

```solidity
// script/Validator.s.sol
contract ConfigValidator {
    function validate(DeploymentConfig memory cfg) external pure {
        // Run all critical rules — revert if any fail
        _checkNoCircularCollateral(cfg);
        _checkLOLRRequirement(cfg);
        _checkM0Consistency(cfg);
        _checkPegConsistency(cfg);
        _checkCapitalControlConsistency(cfg);
        _checkReputationCreditConsistency(cfg);
    }

    function _checkLOLRRequirement(DeploymentConfig memory cfg) internal pure {
        if (cfg.reserveVault.rMinBPS < 10_000 && !cfg.hasEPController) {
            revert("CRITICAL: Fractional reserve requires EPController as LOLR");
        }
    }
}
```

---

## 16. Security Considerations

### 16.1 Oracle Manipulation

- Use Chainlink price feeds with staleness check (max 1 hour)
- For assets with low liquidity, add TWAP oracle as secondary source
- Reject deposits/loans if primary and secondary oracles diverge > 5%

```solidity
function _getSecurePrice(address asset) internal view returns (uint256) {
    uint256 chainlinkPrice = _getChainlinkPrice(asset);
    uint256 twapPrice = _getTWAPPrice(asset);

    uint256 deviation = chainlinkPrice > twapPrice
        ? (chainlinkPrice - twapPrice) * 10_000 / twapPrice
        : (twapPrice - chainlinkPrice) * 10_000 / chainlinkPrice;

    require(deviation <= 500, "Oracle deviation too high"); // 5% max
    return chainlinkPrice; // use Chainlink as primary
}
```

### 16.2 Reentrancy

- All state-changing functions: `nonReentrant` modifier
- Checks-Effects-Interactions pattern enforced
- No external calls before state updates

### 16.3 Hook Gas Griefing

A malicious module could consume all gas in a hook, preventing mints/burns.

Mitigation:
- `hookGasLimit` caps gas per hook call
- Failed `afterMint`/`afterBurn` hooks emit event but don't revert
- Only `beforeMint`/`beforeBurn` can revert (and these are governance-controlled modules)

### 16.4 Flash Loan Attacks on Circuit Breaker

An attacker could manipulate `dailyOutflow` by borrowing and repaying flash loans.

Mitigation:
- Circuit breaker tracks GROSH burns per day by address (not aggregate)
- Flash loans within a single transaction don't affect block.timestamp day counter
- `cooldownBlocks` between exits per address prevents rapid cycling

### 16.5 Timelock Bypass

In initial deployment, `initialSetup()` bypasses timelock for the first module registration batch. This window must be used and closed immediately.

```solidity
function initialSetup(/* modules */) external onlyOwner {
    require(!initialSetupDone, "Already initialized");
    initialSetupDone = true;
    // Register all initial modules without timelock
    // After this, all changes require 48h timelock
}
```

---

## 17. Testing Strategy

### 17.1 Unit Tests

Each module tested in isolation with mocked dependencies.

```bash
forge test --match-path "test/unit/*" -v
```

Key test files:
- `test/unit/GTokenTest.t.sol` — mint/burn/hook execution
- `test/unit/CollateralVaultTest.t.sol` — deposit, haircut, oracle
- `test/unit/CreditLedgerTest.t.sol` — mutual credit invariant
- `test/unit/ReserveVaultTest.t.sol` — R_min enforcement
- `test/unit/CreditModuleTest.t.sol` — loan lifecycle, liquidation
- `test/unit/ExitModuleTest.t.sol` — exit modes, circuit breaker
- `test/unit/EPControllerTest.t.sol` — rate changes, LOLR

### 17.2 Integration Tests

Full system scenarios with real contract interactions:

```bash
forge test --match-path "test/integration/*" -v
```

Key scenarios:
- `test/integration/CollateralFlow.t.sol` — full deposit → loan → repay → exit
- `test/integration/BankRun.t.sol` — circuit breaker activation
- `test/integration/Liquidation.t.sol` — price drop → liquidation
- `test/integration/LOLRScenario.t.sol` — CP distress → EP intervention
- `test/integration/MutualCreditFlow.t.sol` — full mutual credit lifecycle

### 17.3 Invariant Tests

Property-based testing ensuring system invariants hold:

```solidity
// test/invariant/SystemInvariant.t.sol
contract SystemInvariant is StdInvariant {
    function invariant_totalSupplyEqualsCollateral() public view {
        // For collateral config: totalSupply <= totalCollateralUSD * (1 - avg_haircut)
        assertLe(gtoken.totalSupply(), vault.totalBacking());
    }

    function invariant_rMinNeverViolated() public view {
        // Reserve ratio always >= R_min
        uint256 reserve = reserveVault.totalAssets();
        uint256 supply = gtoken.totalSupply();
        if (supply > 0) {
            assertGe(reserve * 10_000 / supply, reserveVault.rMinBPS());
        }
    }

    function invariant_mutualCreditSumZero() public view {
        // For mutual credit: totalBorrowed == totalSupply
        if (emissionType == EmissionType.MUTUAL_CREDIT) {
            assertEq(gtoken.totalSupply(), creditLedger.totalBorrowed());
        }
    }

    function invariant_noSelfCollateral() public view {
        // GROSH is never accepted as collateral
        assertFalse(vault.assetConfigs(address(gtoken)).accepted);
    }
}
```

### 17.4 Stress Tests

```bash
# Simulate bank run: 80% of supply attempts exit simultaneously
forge test --match-test "testBankRun" --fuzz-runs 10000

# Simulate oracle failure
forge test --match-test "testOracleStale"

# Simulate price crash
forge test --match-test "testCollateralPriceCrash"
```

### 17.5 Polygon Fork Tests

Test against real Polygon mainnet state:

```bash
forge test --fork-url $POLYGON_RPC_URL --fork-block-number latest \
  --match-path "test/fork/*"
```

```solidity
// test/fork/PolygonFork.t.sol
contract PolygonForkTest is Test {
    address constant USDC = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    address constant CHAINLINK_USDC_USD = 0xfE4A8cc5b5B2366C1B58Bea3858e81843581b2F7;

    function setUp() public {
        // Deploy on real Polygon fork
        // Test with real USDC balances and real Chainlink prices
    }

    function test_depositRealUSDC() public {
        deal(USDC, address(this), 10_000e6); // give test contract 10k USDC
        vault.deposit(USDC, 10_000e6, 0);
        assertGt(gtoken.balanceOf(address(this)), 0);
    }
}
```

---

## Appendix A: Polygon-specific Addresses

| Contract | Polygon Mainnet |
|---|---|
| USDC | `0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174` |
| USDT | `0xc2132D05D31c914a87C6611C10748AEb04B58e8F` |
| WETH | `0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619` |
| WMATIC | `0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270` |
| stETH (Lido) | — (use wstETH) |
| wstETH | `0x03b54A6e9a984069379fae1a4fC4dBAE93B3bCCD` |
| Chainlink USDC/USD | `0xfE4A8cc5b5B2366C1B58Bea3858e81843581b2F7` |
| Chainlink ETH/USD | `0xF9680D99D6C9589e2a93a78A04A279e509205945` |
| Chainlink MATIC/USD | `0xAB594600376Ec9fD91F8e885dADF0CE036862dE0` |

## Appendix B: Gas Estimates (Polygon)

| Operation | Estimated Gas | Cost @ 100 gwei |
|---|---|---|
| `GToken.mint()` + 3 hooks | ~350,000 | ~0.035 MATIC |
| `CollateralVault.deposit()` | ~280,000 | ~0.028 MATIC |
| `CreditModule.borrow()` | ~320,000 | ~0.032 MATIC |
| `CreditModule.repay()` | ~250,000 | ~0.025 MATIC |
| `ExitModule.exit()` | ~200,000 | ~0.020 MATIC |
| `CreditModule.liquidate()` | ~380,000 | ~0.038 MATIC |
| `EPController.setRate()` | ~80,000 | ~0.008 MATIC |
| `EPController.issueLOLR()` | ~250,000 | ~0.025 MATIC |

*At Polygon average ~100 gwei and MATIC ~$0.80, costs are ~$0.02–0.03 per operation.*

---

*GroshY Protocol Technical Specification v0.1 — For use with Claude Code*
