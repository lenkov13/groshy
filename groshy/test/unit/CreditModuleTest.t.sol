// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/GToken.sol";
import "../../src/core/ModuleRegistry.sol";
import "../../src/services/CreditModule.sol";
import "../../src/services/ReserveVault.sol";
import "../../src/interfaces/IModuleRegistry.sol";
import "../../src/interfaces/IModule.sol";
import "../../src/interfaces/ICollateralVault.sol";

/// @dev Simple ERC20 mock
contract ERC20Mock {
    string public name;
    string public symbol;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) { name = n; symbol = s; decimals = d; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a; return true;
    }
}

/// @dev Mock collateral vault for credit module testing
contract MockCollateralVault is ICollateralVault {
    mapping(address => mapping(address => uint256)) public locked;
    uint256 public mockValueUSD = 1000e18; // 1000 USD per unit for simplicity

    function setMockValueUSD(uint256 v) external { mockValueUSD = v; }

    function lockCollateral(address user, address asset, uint256 amount) external override {
        locked[user][asset] += amount;
    }

    function releaseCollateral(address borrower, address asset, uint256 amount, address to) external override {
        locked[borrower][asset] -= amount;
        // In tests, transfer is mocked by tracking
    }

    function getAssetValueUSD(address, uint256 amount) external view override returns (uint256) {
        return amount * mockValueUSD / 1e18;
    }
}

/// @dev Minimal module stub
contract NullModule is IModule {
    constructor(bytes32) {} // type_ ignored
    function moduleType() external pure override returns (bytes32) { return keccak256("NULL_MODULE"); }
    function beforeMint(address, uint256) external override {}
    function afterMint(address, uint256) external override {}
    function beforeBurn(address, uint256) external override {}
    function afterBurn(address, uint256) external override {}
    function afterTransfer(address, address, uint256) external override {}
    function pause() external override {}
}

contract CreditModuleTest is Test {
    GToken internal gtoken;
    ModuleRegistry internal registry;
    CreditModule internal credit;
    MockCollateralVault internal collVault;
    NullModule internal emission;

    address internal owner = address(this);
    address internal alice = makeAddr("alice");

    function setUp() public {
        gtoken = new GToken("GroshY", "GRSH", 0, 200_000, owner);
        registry = new ModuleRegistry(address(gtoken), 0, owner);
        gtoken.setRegistry(address(registry));

        collVault = new MockCollateralVault();

        credit = new CreditModule(
            address(gtoken),
            address(0),         // no reserve vault
            address(collVault),
            0,                  // no CAR min
            7500,               // LTV 75%
            1000,               // liquidation penalty 10%
            365 days,
            0,                  // no origination fee
            owner
        );

        emission = new NullModule(keccak256("EMISSION"));

        HookType[] memory emHooks = new HookType[](1);
        emHooks[0] = HookType.BEFORE_MINT;

        HookType[] memory crHooks = new HookType[](1);
        crHooks[0] = HookType.BEFORE_BURN;

        HookType[] memory noHooks = new HookType[](0);

        registry.initialSetup(
            address(emission), ModuleRole.EMISSION, emHooks,
            address(0),                             noHooks,
            address(credit),                        crHooks,
            address(0),                             noHooks,
            address(0),                             noHooks
        );

        // Set hook execution order
        address[] memory beforeBurnModules = new address[](1);
        beforeBurnModules[0] = address(credit);
        registry.setHookOrder(HookType.BEFORE_BURN, beforeBurnModules);
    }

    // ── borrow ────────────────────────────────────────────────────────────────

    function test_borrow_uncollateralized() public {
        // CreditModule has CREDIT role and can call gtoken.mint
        vm.prank(alice);
        credit.borrow(100e18, address(0), 0);

        assertEq(gtoken.balanceOf(alice), 100e18);
        assertTrue(credit.getActiveLoan(alice).active);
        assertEq(credit.getActiveLoan(alice).principal, 100e18);
    }

    function test_borrow_collateralized_ltv() public {
        // Mock: 1000 USD value for 1 unit of collateral
        // borrow 750 GROSH against 1 unit → 75% LTV (exactly at limit)
        ERC20Mock collToken = new ERC20Mock("Coll", "COLL", 18);
        collToken.mint(alice, 1e18);

        vm.prank(alice);
        collToken.approve(address(credit), 1e18);

        // collVault.getAssetValueUSD(asset, 1e18) = 1e18 * 1000e18 / 1e18 = 1000e18
        // maxBorrow = 1000e18 * 7500 / 10_000 = 750e18
        vm.prank(alice);
        credit.borrow(750e18, address(collToken), 1e18);

        assertEq(gtoken.balanceOf(alice), 750e18);
    }

    function test_borrow_ltv_exceeded_reverts() public {
        ERC20Mock collToken = new ERC20Mock("Coll", "COLL", 18);
        collToken.mint(alice, 1e18);
        vm.prank(alice);
        collToken.approve(address(credit), 1e18);

        // Try to borrow 800 > 750 max
        vm.prank(alice);
        vm.expectRevert(CreditModule.LTVExceeded.selector);
        credit.borrow(800e18, address(collToken), 1e18);
    }

    function test_borrow_existingLoan_reverts() public {
        vm.prank(alice);
        credit.borrow(100e18, address(0), 0);

        vm.prank(alice);
        vm.expectRevert(CreditModule.ExistingLoan.selector);
        credit.borrow(50e18, address(0), 0);
    }

    // ── repay ─────────────────────────────────────────────────────────────────

    function test_repay_closesLoan() public {
        vm.prank(alice);
        credit.borrow(100e18, address(0), 0);

        // Repay full principal (no interest at t=0)
        vm.prank(alice);
        credit.repay(100e18);

        assertFalse(credit.getActiveLoan(alice).active);
        assertEq(gtoken.balanceOf(alice), 0);
    }

    function test_repay_partial() public {
        vm.prank(alice);
        credit.borrow(100e18, address(0), 0);

        vm.prank(alice);
        credit.repay(40e18);

        CreditModule.Loan memory loan = credit.getActiveLoan(alice);
        assertTrue(loan.active);
        assertEq(loan.principal, 60e18);
    }

    // ── interest accrual ──────────────────────────────────────────────────────

    function test_interestAccrues_overTime() public {
        vm.prank(alice);
        credit.borrow(100e18, address(0), 0);

        // Advance 1 year
        vm.warp(block.timestamp + 365 days);

        uint256 totalDebt = credit.getTotalDebt(alice);
        // With 8% default rate, debt should be > 100e18
        assertGt(totalDebt, 100e18);
        // And not more than 110e18 (8% per year linearly)
        assertLt(totalDebt, 110e18);
    }

    // ── liquidation ───────────────────────────────────────────────────────────

    function test_liquidate_whenHealthFactorBelowOne() public {
        ERC20Mock collToken = new ERC20Mock("Coll", "COLL", 18);
        collToken.mint(alice, 1e18);
        vm.prank(alice);
        collToken.approve(address(credit), 1e18);

        vm.prank(alice);
        credit.borrow(750e18, address(collToken), 1e18);

        // Simulate collateral price crash: set mock value to make HF < 1
        // LiqThreshold = 75% * 1.25 = 93.75%
        // HF = collateralUSD / (debt * 93.75%)
        // Need collateralUSD < debt * 93.75% = 750 * 0.9375 = ~703 USD
        collVault.setMockValueUSD(900e18); // 0.9 per unit → 900 USD for 1e18 units... wait

        // getAssetValueUSD(asset, 1e18) = 1e18 * mockValueUSD / 1e18 = mockValueUSD
        // Set to 600 USD total collateral value → HF = 600 / (750 * 0.9375) = 600/703 < 1
        collVault.setMockValueUSD(600e18);

        // Give liquidator enough GROSH
        vm.prank(address(emission));
        gtoken.mint(address(this), 1000e18);

        // Liquidate
        credit.liquidate(alice);

        assertFalse(credit.getActiveLoan(alice).active);
    }

    function test_liquidate_healthyLoan_reverts() public {
        vm.prank(alice);
        credit.borrow(100e18, address(0), 0);

        vm.expectRevert(CreditModule.UncollateralizedLiquidation.selector);
        credit.liquidate(alice);
    }

    // ── beforeBurn hook ───────────────────────────────────────────────────────

    function test_beforeBurn_blocksTransfer_withActiveLoan() public {
        vm.prank(alice);
        credit.borrow(100e18, address(0), 0);

        // CreditModule.beforeBurn fires on burn — should block it
        vm.prank(address(credit));
        vm.expectRevert();
        gtoken.burn(alice, 50e18);
    }
}
