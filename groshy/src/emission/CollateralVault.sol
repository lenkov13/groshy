// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../interfaces/IEmissionModule.sol";
import "../interfaces/IGToken.sol";
import "../interfaces/IModuleRegistry.sol";
import "../interfaces/ICollateralVault.sol";
import "../lib/AggregatorV3Interface.sol";

/// @title CollateralVault — COLLATERAL emission module
/// @notice Users deposit approved assets (USDC, stETH, …) and receive GROSH.
///         A haircut is applied to each asset to under-collateralise minting conservatively.
///         GROSH itself is never accepted as collateral (circular-collateral guard).
contract CollateralVault is IEmissionModule, ICollateralVault, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    struct AssetConfig {
        bool accepted;
        uint16 haircut;         // basis points applied to collateral value (500 = 5%)
        uint16 maxAllocation;   // max % of total collateral in basis points (10000 = 100%)
        address chainlinkFeed;  // Chainlink price feed
        uint8 feedDecimals;     // cached feed decimals
    }

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    IGToken public immutable gtoken;
    IModuleRegistry public immutable registry;

    mapping(address => AssetConfig) public assetConfigs;
    address[] public acceptedAssets;

    // per-user, per-asset collateral balance
    mapping(address => mapping(address => uint256)) public userCollateral;
    // per-user GROSH minted via this vault
    mapping(address => uint256) public userGroshMinted;

    // locked collateral for CreditModule loans (separate from user deposit collateral)
    mapping(address => mapping(address => uint256)) public lockedCollateral;

    uint256 public minDepositUSD;       // 18 decimals
    uint256 public totalCollateralUSD;  // approximate cached total (18 dec)
    uint256 public oracleStalenessSecs; // max age of price data (default 3600)

    address public creditModule;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event Deposited(address indexed user, address indexed asset, uint256 assetAmount, uint256 groshMinted);
    event Withdrawn(address indexed user, address indexed asset, uint256 assetReturned, uint256 groshBurned);
    event AssetAdded(address indexed asset, uint16 haircut, uint16 maxAllocation, address feed);
    event AssetRemoved(address indexed asset);
    event CollateralLocked(address indexed user, address indexed asset, uint256 amount);
    event CollateralReleased(address indexed borrower, address indexed asset, uint256 amount, address to);
    event CreditModuleSet(address indexed creditModule);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error AssetNotAccepted();
    error BelowMinDeposit();
    error SlippageExceeded();
    error AllocationExceeded();
    error InsufficientMintedBalance();
    error InvalidOraclePrice();
    error OracleStale();
    error CircularCollateral();
    error HaircutTooHigh();
    error OnlyGToken();
    error OnlyCreditModule();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(
        address gtoken_,
        address registry_,
        uint256 minDepositUSD_,
        address owner_
    ) Ownable(owner_) {
        gtoken = IGToken(gtoken_);
        registry = IModuleRegistry(registry_);
        minDepositUSD = minDepositUSD_;
        oracleStalenessSecs = 3600;
    }

    // -------------------------------------------------------------------------
    // IModule
    // -------------------------------------------------------------------------

    function moduleType() external pure override returns (bytes32) {
        return keccak256("COLLATERAL_VAULT");
    }

    function beforeMint(address, uint256) external override onlyGToken {
        // Collateral recording happens inside deposit() before calling gtoken.mint()
        // Nothing extra needed here
    }

    function afterMint(address, uint256) external override onlyGToken {
        // Accounting updated in deposit()
    }

    function beforeBurn(address from, uint256 amount) external override onlyGToken {
        // Ensure user has enough minted balance to cover this burn
        if (userGroshMinted[from] != 0 && userGroshMinted[from] < amount) {
            revert InsufficientMintedBalance();
        }
    }

    function afterBurn(address, uint256) external override onlyGToken {}

    function afterTransfer(address, address, uint256) external override onlyGToken {}

    // -------------------------------------------------------------------------
    // IEmissionModule
    // -------------------------------------------------------------------------

    function emissionType() external pure override returns (EmissionType) {
        return EmissionType.COLLATERAL;
    }

    function totalBacking() external view override returns (uint256) {
        return totalCollateralUSD;
    }

    function collateralRatio() external view override returns (uint256) {
        uint256 supply = gtoken.totalSupply();
        if (supply == 0) return type(uint256).max;
        return totalCollateralUSD * 1e18 / supply;
    }

    // -------------------------------------------------------------------------
    // ICollateralVault
    // -------------------------------------------------------------------------

    function lockCollateral(address user, address asset, uint256 amount) external override onlyCreditModule {
        lockedCollateral[user][asset] += amount;
        emit CollateralLocked(user, asset, amount);
    }

    function releaseCollateral(
        address borrower,
        address asset,
        uint256 amount,
        address to
    ) external override onlyCreditModule {
        require(lockedCollateral[borrower][asset] >= amount, "CollateralVault: insufficient locked");
        lockedCollateral[borrower][asset] -= amount;
        IERC20(asset).safeTransfer(to, amount);
        emit CollateralReleased(borrower, asset, amount, to);
    }

    function getAssetValueUSD(address asset, uint256 amount) external view override returns (uint256) {
        return _getAssetValueUSD(asset, amount);
    }

    // -------------------------------------------------------------------------
    // Deposit
    // -------------------------------------------------------------------------

    /// @notice Deposit collateral asset, receive GROSH
    /// @param asset         Collateral asset address
    /// @param amount        Amount of asset to deposit
    /// @param minGroshOut   Slippage protection
    function deposit(
        address asset,
        uint256 amount,
        uint256 minGroshOut
    ) external nonReentrant whenNotPaused returns (uint256 groshOut) {
        AssetConfig memory cfg = assetConfigs[asset];
        if (!cfg.accepted) revert AssetNotAccepted();

        uint256 assetValueUSD = _getAssetValueUSD(asset, amount);
        if (assetValueUSD < minDepositUSD) revert BelowMinDeposit();

        // Apply haircut: mint less than full value
        groshOut = assetValueUSD * (10_000 - cfg.haircut) / 10_000;
        if (groshOut < minGroshOut) revert SlippageExceeded();

        // Max allocation check: new asset share of total collateral
        uint256 newTotalUSD = totalCollateralUSD + assetValueUSD;
        uint256 userAssetUSD = _getAssetValueUSD(asset, userCollateral[msg.sender][asset]) + assetValueUSD;
        if (cfg.maxAllocation < 10_000) {
            // Only check if not 100%
            require(
                userAssetUSD * 10_000 <= newTotalUSD * cfg.maxAllocation,
                "CollateralVault: asset allocation exceeded"
            );
        }

        // Transfer collateral in
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        // Update accounting
        userCollateral[msg.sender][asset] += amount;
        userGroshMinted[msg.sender] += groshOut;
        totalCollateralUSD = newTotalUSD;

        // Mint GROSH (triggers beforeMint hooks including R_min check)
        gtoken.mint(msg.sender, groshOut);

        emit Deposited(msg.sender, asset, amount, groshOut);
    }

    // -------------------------------------------------------------------------
    // Withdrawal
    // -------------------------------------------------------------------------

    /// @notice Burn GROSH, recover proportional collateral
    /// @param asset       Asset to receive back
    /// @param groshAmount Amount of GROSH to burn
    function withdraw(
        address asset,
        uint256 groshAmount
    ) external nonReentrant whenNotPaused {
        if (userGroshMinted[msg.sender] < groshAmount) revert InsufficientMintedBalance();

        AssetConfig memory cfg = assetConfigs[asset];
        // Calculate proportional asset return
        uint256 userAssetBalance = userCollateral[msg.sender][asset];
        uint256 userMinted = userGroshMinted[msg.sender];
        // assetOut = userAssetBalance * groshAmount / userMinted
        uint256 assetOut = userAssetBalance * groshAmount / userMinted;

        userGroshMinted[msg.sender] -= groshAmount;
        userCollateral[msg.sender][asset] -= assetOut;

        uint256 returnedUSD = _getAssetValueUSD(asset, assetOut);
        totalCollateralUSD = totalCollateralUSD > returnedUSD ? totalCollateralUSD - returnedUSD : 0;

        // Burn GROSH (triggers beforeBurn hooks)
        gtoken.burn(msg.sender, groshAmount);

        // Return collateral
        IERC20(asset).safeTransfer(msg.sender, assetOut);

        emit Withdrawn(msg.sender, asset, assetOut, groshAmount);

        // Suppress unused variable warning
        cfg;
    }

    // -------------------------------------------------------------------------
    // Asset management — onlyOwner
    // -------------------------------------------------------------------------

    function addAsset(
        address asset,
        uint16 haircut,
        uint16 maxAllocation,
        address chainlinkFeed
    ) external onlyOwner {
        if (asset == address(gtoken)) revert CircularCollateral();
        if (haircut > 5000) revert HaircutTooHigh();

        uint8 feedDec = AggregatorV3Interface(chainlinkFeed).decimals();
        assetConfigs[asset] = AssetConfig({
            accepted: true,
            haircut: haircut,
            maxAllocation: maxAllocation,
            chainlinkFeed: chainlinkFeed,
            feedDecimals: feedDec
        });
        acceptedAssets.push(asset);

        emit AssetAdded(asset, haircut, maxAllocation, chainlinkFeed);
    }

    function removeAsset(address asset) external onlyOwner {
        assetConfigs[asset].accepted = false;
        // Remove from array
        for (uint256 i = 0; i < acceptedAssets.length; i++) {
            if (acceptedAssets[i] == asset) {
                acceptedAssets[i] = acceptedAssets[acceptedAssets.length - 1];
                acceptedAssets.pop();
                break;
            }
        }
        emit AssetRemoved(asset);
    }

    function setMinDeposit(uint256 newMin) external onlyOwner {
        minDepositUSD = newMin;
    }

    function setOracleStalenessSecs(uint256 secs) external onlyOwner {
        require(secs >= 300 && secs <= 86_400, "CollateralVault: staleness out of range");
        oracleStalenessSecs = secs;
    }

    function setCreditModule(address creditModule_) external onlyOwner {
        creditModule = creditModule_;
        emit CreditModuleSet(creditModule_);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function getAcceptedAssets() external view returns (address[] memory) {
        return acceptedAssets;
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    function _getAssetValueUSD(address asset, uint256 amount) internal view returns (uint256) {
        AssetConfig memory cfg = assetConfigs[asset];
        AggregatorV3Interface feed = AggregatorV3Interface(cfg.chainlinkFeed);

        (, int256 price,, uint256 updatedAt,) = feed.latestRoundData();
        if (price <= 0) revert InvalidOraclePrice();
        if (block.timestamp - updatedAt > oracleStalenessSecs) revert OracleStale();

        uint8 assetDecimals = IERC20Metadata(asset).decimals();

        // Normalize to 18 decimals:
        // value = price * amount / (10^feedDecimals) / (10^assetDecimals) * 10^18
        return (uint256(price) * amount * 1e18) / (10 ** cfg.feedDecimals * 10 ** assetDecimals);
    }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyGToken() {
        if (msg.sender != address(gtoken)) revert OnlyGToken();
        _;
    }

    modifier onlyCreditModule() {
        if (msg.sender != creditModule) revert OnlyCreditModule();
        _;
    }
}
