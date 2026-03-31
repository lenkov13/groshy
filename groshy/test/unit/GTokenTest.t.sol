// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/GToken.sol";
import "../../src/core/ModuleRegistry.sol";
import "../../src/interfaces/IModuleRegistry.sol";
import "../../src/interfaces/IModule.sol";

/// @dev Minimal module stub used in tests
contract MockModule is IModule {
    bool public shouldRevert;
    bool private _paused;

    constructor(bytes32) {} // type_ ignored; moduleType is hardcoded

    function moduleType() external pure override returns (bytes32) { return keccak256("MOCK_MODULE"); }

    function setShouldRevert(bool v) external { shouldRevert = v; }
    function pause() external override { _paused = true; }
    function unpause() external { _paused = false; }

    function beforeMint(address, uint256) external view override {
        if (shouldRevert) revert("MockModule: beforeMint revert");
    }
    function afterMint(address, uint256) external view override {}
    function beforeBurn(address, uint256) external view override {
        if (shouldRevert) revert("MockModule: beforeBurn revert");
    }
    function afterBurn(address, uint256) external view override {}
    function afterTransfer(address, address, uint256) external view override {}
}

contract GTokenTest is Test {
    GToken internal gtoken;
    ModuleRegistry internal registry;
    MockModule internal emissionMod;
    MockModule internal otherMod;

    address internal owner = address(this);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        gtoken = new GToken("GroshY", "GRSH", 0, 200_000, owner);
        registry = new ModuleRegistry(address(gtoken), 0, owner); // 0 timelock for tests
        gtoken.setRegistry(address(registry));

        emissionMod = new MockModule(keccak256("EMISSION_MOD"));
        otherMod    = new MockModule(keccak256("OTHER_MOD"));

        // Register emission module
        HookType[] memory hooks = new HookType[](2);
        hooks[0] = HookType.BEFORE_MINT;
        hooks[1] = HookType.BEFORE_BURN;

        HookType[] memory noHooks = new HookType[](0);

        registry.initialSetup(
            address(emissionMod), ModuleRole.EMISSION, hooks,
            address(0),                                noHooks,
            address(0),                                noHooks,
            address(0),                                noHooks,
            address(0),                                noHooks
        );
    }

    // ── mint ──────────────────────────────────────────────────────────────────

    function test_mint_byEmissionModule() public {
        vm.prank(address(emissionMod));
        gtoken.mint(alice, 100e18);
        assertEq(gtoken.balanceOf(alice), 100e18);
        assertEq(gtoken.totalSupply(), 100e18);
    }

    function test_mint_rejects_nonEmission() public {
        vm.prank(alice);
        vm.expectRevert();
        gtoken.mint(alice, 100e18);
    }

    function test_mint_respectsMaxSupply() public {
        gtoken.setMaxSupply(50e18);

        vm.prank(address(emissionMod));
        vm.expectRevert(GToken.MaxSupplyExceeded.selector);
        gtoken.mint(alice, 100e18);
    }

    function test_mint_maxSupply_zero_means_unlimited() public {
        gtoken.setMaxSupply(0);
        vm.prank(address(emissionMod));
        gtoken.mint(alice, 1_000_000_000e18);
        assertEq(gtoken.totalSupply(), 1_000_000_000e18);
    }

    // ── burn ──────────────────────────────────────────────────────────────────

    function test_burn_byRegisteredModule() public {
        vm.prank(address(emissionMod));
        gtoken.mint(alice, 100e18);

        vm.prank(address(emissionMod));
        gtoken.burn(alice, 50e18);
        assertEq(gtoken.balanceOf(alice), 50e18);
    }

    function test_burn_rejects_nonModule() public {
        vm.prank(address(emissionMod));
        gtoken.mint(alice, 100e18);

        vm.prank(alice);
        vm.expectRevert();
        gtoken.burn(alice, 50e18);
    }

    // ── hooks ─────────────────────────────────────────────────────────────────

    function test_beforeMint_revert_blocks_mint() public {
        emissionMod.setShouldRevert(true);

        vm.prank(address(emissionMod));
        vm.expectRevert();
        gtoken.mint(alice, 100e18);

        // Supply must still be zero
        assertEq(gtoken.totalSupply(), 0);
    }

    function test_beforeBurn_revert_blocks_burn() public {
        vm.prank(address(emissionMod));
        gtoken.mint(alice, 100e18);

        emissionMod.setShouldRevert(true);

        vm.prank(address(emissionMod));
        vm.expectRevert();
        gtoken.burn(alice, 50e18);

        // Balance unchanged
        assertEq(gtoken.balanceOf(alice), 100e18);
    }

    // ── hookGasLimit ──────────────────────────────────────────────────────────

    function test_setHookGasLimit_validRange() public {
        gtoken.setHookGasLimit(500_000);
        assertEq(gtoken.hookGasLimit(), 500_000);
    }

    function test_setHookGasLimit_tooLow_reverts() public {
        vm.expectRevert();
        gtoken.setHookGasLimit(10_000);
    }

    // ── maxSupply ─────────────────────────────────────────────────────────────

    function test_setMaxSupply_cannotGoBelowCurrentSupply() public {
        vm.prank(address(emissionMod));
        gtoken.mint(alice, 100e18);

        vm.expectRevert();
        gtoken.setMaxSupply(50e18);
    }

    // ── transfers ─────────────────────────────────────────────────────────────

    function test_transfer_works() public {
        vm.prank(address(emissionMod));
        gtoken.mint(alice, 100e18);

        vm.prank(alice);
        gtoken.transfer(bob, 30e18);

        assertEq(gtoken.balanceOf(alice), 70e18);
        assertEq(gtoken.balanceOf(bob), 30e18);
    }

    function test_pauseTransfers_blocks_transfer() public {
        vm.prank(address(emissionMod));
        gtoken.mint(alice, 100e18);

        gtoken.pauseTransfers();

        vm.prank(alice);
        vm.expectRevert(GToken.TransfersPaused.selector);
        gtoken.transfer(bob, 30e18);
    }

    function test_pauseTransfers_allows_mint_and_burn() public {
        gtoken.pauseTransfers();

        // Mint (no transfer, so not blocked)
        vm.prank(address(emissionMod));
        gtoken.mint(alice, 100e18);
        assertEq(gtoken.balanceOf(alice), 100e18);

        // Burn (no transfer, so not blocked)
        vm.prank(address(emissionMod));
        gtoken.burn(alice, 50e18);
        assertEq(gtoken.balanceOf(alice), 50e18);
    }
}
