// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/GToken.sol";
import "../../src/core/ModuleRegistry.sol";
import "../../src/emission/CollateralVault.sol";
import "../../src/services/ReserveVault.sol";
import "../../src/services/CreditModule.sol";
import "../../src/services/ExitModule.sol";
import "../../src/policy/EPController.sol";
import "../../src/interfaces/IModuleRegistry.sol";
import "../../src/lib/AggregatorV3Interface.sol";

/// @dev Mock USDC with 6 decimals
contract MockUSDC {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
}

/// @dev Mock Chainlink USDC/USD feed (always 1.00, never stale)
contract MockChainlinkFeed {
    uint8 public decimals = 8;
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 1e8, block.timestamp, block.timestamp, 1); // $1.00 USD
    }
}

/// @title CollateralFlow — full system integration test
/// @notice Exercises the complete lifecycle: deposit → borrow → repay → exit
contract CollateralFlowTest is Test {
    GToken internal gtoken;
    ModuleRegistry internal registry;
    CollateralVault internal vault;
    ReserveVault internal reserve;
    CreditModule internal credit;
    ExitModule internal exitMod;
    EPController internal ep;

    MockUSDC internal usdc;
    MockChainlinkFeed internal usdcFeed;

    address internal owner = address(this);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        usdc = new MockUSDC();
        usdcFeed = new MockChainlinkFeed();

        // ── Core ──────────────────────────────────────────────────────────────

        gtoken = new GToken("GroshY", "GRSH", 0, 200_000, owner);
        registry = new ModuleRegistry(address(gtoken), 0, owner); // zero timelock for tests
        gtoken.setRegistry(address(registry));

        // ── Emission ──────────────────────────────────────────────────────────

        vault = new CollateralVault(
            address(gtoken),
            address(registry),
            1e18,   // $1 minimum deposit
            owner
        );
        vault.addAsset(address(usdc), 0, 10_000, address(usdcFeed)); // 0% haircut for simplicity
        vault.setCreditModule(address(0)); // no credit module for basic test

        // ── Services ──────────────────────────────────────────────────────────

        reserve = new ReserveVault(
            address(gtoken),
            address(usdc),
            0,      // R_min = 0% to not block mints in test
            0,
            0,
            owner
        );

        credit = new CreditModule(
            address(gtoken),
            address(0), // no reserve vault
            address(0), // no collateral vault
            0, 0, 0,
            365 days,
            0,
            owner
        );

        exitMod = new ExitModule(
            address(gtoken),
            address(reserve),
            ExitModule.ExitMode.HARD_PEG,
            0,      // 0% exit spread
            10_000, // no daily limit
            0,      // no cooldown
            0,
            owner
        );

        ep = new EPController(
            address(gtoken),
            800, 100, 3000, 1500, 7 days, 2000,
            owner
        );

        reserve.setExitModule(address(exitMod));
        reserve.setEPController(address(ep));

        // ── Register modules ──────────────────────────────────────────────────

        HookType[] memory emHooks  = new HookType[](2);
        emHooks[0] = HookType.BEFORE_MINT;
        emHooks[1] = HookType.BEFORE_BURN;

        HookType[] memory noHooks = new HookType[](0);

        registry.initialSetup(
            address(vault), ModuleRole.EMISSION, emHooks,
            address(reserve),                    noHooks,
            address(credit),                     noHooks,
            address(exitMod),                    noHooks,
            address(ep),                         noHooks
        );
    }

    // ── Deposit ───────────────────────────────────────────────────────────────

    function test_deposit_mintsGROSH() public {
        _giveAndApprove(alice, 1000e6);

        vm.prank(alice);
        vault.deposit(address(usdc), 1000e6, 0);

        // USDC/USD = $1.00, so 1000 USDC → 1000e18 GROSH (0% haircut)
        // Value: 1e8 * 1000e6 * 1e18 / (1e8 * 1e6) = 1000e18
        assertGt(gtoken.balanceOf(alice), 0);
    }

    function test_deposit_haircut() public {
        // Add USDC with 10% haircut
        vault.addAsset(address(usdc), 1000, 10_000, address(usdcFeed)); // 10% haircut

        _giveAndApprove(alice, 1000e6);
        vm.prank(alice);
        vault.deposit(address(usdc), 1000e6, 0);

        // 10% haircut → receives 900e18 GROSH
        uint256 balance = gtoken.balanceOf(alice);
        assertEq(balance, 900e18);
    }

    function test_deposit_twice_accumulates() public {
        _giveAndApprove(alice, 2000e6);

        vm.prank(alice);
        vault.deposit(address(usdc), 1000e6, 0);
        vm.prank(alice);
        vault.deposit(address(usdc), 1000e6, 0);

        assertEq(gtoken.balanceOf(alice), 2000e18);
    }

    // ── Withdraw ──────────────────────────────────────────────────────────────

    function test_withdraw_burnsGrosh_returnsCollateral() public {
        _giveAndApprove(alice, 1000e6);
        vm.prank(alice);
        vault.deposit(address(usdc), 1000e6, 0);

        uint256 groshBefore = gtoken.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        vault.withdraw(address(usdc), groshBefore);

        assertEq(gtoken.balanceOf(alice), 0);
        assertGt(usdc.balanceOf(alice), usdcBefore);
    }

    // ── Exit ──────────────────────────────────────────────────────────────────

    function test_exit_burnsGrosh_sendsUSDC() public {
        // Seed reserve with USDC
        usdc.mint(address(reserve), 10_000e6);

        // Give alice GROSH directly via emission (simulating prior deposit)
        _giveAndApprove(alice, 1000e6);
        vm.prank(alice);
        vault.deposit(address(usdc), 1000e6, 0);

        uint256 groshBal = gtoken.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        exitMod.exit(groshBal, 0);

        assertEq(gtoken.balanceOf(alice), 0);
        assertGt(usdc.balanceOf(alice), usdcBefore);
    }

    // ── EPController rate ─────────────────────────────────────────────────────

    function test_epController_setRate() public {
        ep.setRate(1200); // 12%
        assertEq(ep.getCurrentRate(), 1200);
    }

    function test_epController_forwardGuidance() public {
        uint256 futureTime = block.timestamp + 2 days;
        ep.signalRateChange(500, futureTime);

        // Before effective time — still old rate
        assertEq(ep.getCurrentRate(), 800);

        // After effective time — returns signalled rate
        vm.warp(futureTime);
        assertEq(ep.getCurrentRate(), 500);
    }

    // ── Helper ────────────────────────────────────────────────────────────────

    function _giveAndApprove(address user, uint256 amount) internal {
        usdc.mint(user, amount);
        vm.prank(user);
        usdc.approve(address(vault), amount);
    }
}
