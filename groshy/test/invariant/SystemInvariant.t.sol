// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/GToken.sol";
import "../../src/core/ModuleRegistry.sol";
import "../../src/emission/CollateralVault.sol";
import "../../src/emission/CreditLedger.sol";
import "../../src/services/ReserveVault.sol";
import "../../src/interfaces/IModuleRegistry.sol";
import "../../src/interfaces/IModule.sol";
import "../../src/lib/AggregatorV3Interface.sol";

// ─── Minimal mocks ────────────────────────────────────────────────────────────

contract MockUSDCInv {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }
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

contract MockFeedInv {
    uint8 public decimals = 8;
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 1e8, block.timestamp, block.timestamp, 1);
    }
}

// ─── Invariant actor (uses forge Vm cheatcode address directly) ───────────────

contract VaultActor is Test {
    CollateralVault public vault;
    MockUSDCInv public usdc;
    GToken public gtoken;
    address[] public users;

    constructor(address vault_, address usdc_, address gtoken_) {
        vault = CollateralVault(vault_);
        usdc = MockUSDCInv(usdc_);
        gtoken = GToken(gtoken_);
    }

    function addUser(address user) external { users.push(user); }

    function deposit(uint256 actorIdx, uint256 amount) external {
        if (users.length == 0) return;
        address user = users[actorIdx % users.length];
        amount = bound(amount, 1e6, 10_000e6);

        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        try vault.deposit(address(usdc), amount, 0) {} catch {}
        vm.stopPrank();
    }

    function withdraw(uint256 actorIdx, uint256 groshAmount) external {
        if (users.length == 0) return;
        address user = users[actorIdx % users.length];
        uint256 minted = vault.userGroshMinted(user);
        if (minted == 0) return;
        groshAmount = bound(groshAmount, 1, minted);

        vm.prank(user);
        try vault.withdraw(address(usdc), groshAmount) {} catch {}
    }
}

// ─── Invariant test ───────────────────────────────────────────────────────────

contract SystemInvariantTest is Test {
    GToken internal gtoken;
    ModuleRegistry internal registry;
    CollateralVault internal vault;
    MockUSDCInv internal usdc;
    MockFeedInv internal feed;
    VaultActor internal actor;

    address internal owner = address(this);

    function setUp() public {
        usdc = new MockUSDCInv();
        feed = new MockFeedInv();

        gtoken = new GToken("GroshY", "GRSH", 0, 200_000, owner);
        registry = new ModuleRegistry(address(gtoken), 0, owner);
        gtoken.setRegistry(address(registry));

        vault = new CollateralVault(
            address(gtoken),
            address(registry),
            1e15, // tiny min deposit for fuzzing
            owner
        );
        vault.addAsset(address(usdc), 0, 10_000, address(feed));

        HookType[] memory emHooks = new HookType[](2);
        emHooks[0] = HookType.BEFORE_MINT;
        emHooks[1] = HookType.BEFORE_BURN;
        HookType[] memory noHooks = new HookType[](0);

        registry.initialSetup(
            address(vault), ModuleRole.EMISSION, emHooks,
            address(0),                          noHooks,
            address(0),                          noHooks,
            address(0),                          noHooks,
            address(0),                          noHooks
        );

        actor = new VaultActor(address(vault), address(usdc), address(gtoken));
        actor.addUser(makeAddr("user1"));
        actor.addUser(makeAddr("user2"));
        actor.addUser(makeAddr("user3"));

        targetContract(address(actor));
    }

    /// @notice GROSH must never be accepted as collateral (circular collateral guard)
    function invariant_noCircularCollateral() public view {
        (bool accepted,,,,) = vault.assetConfigs(address(gtoken));
        assertFalse(accepted);
    }

    /// @notice Total supply must never exceed totalBacking (with 0% haircut they're equal)
    function invariant_supplyNeverExceedsBacking() public view {
        uint256 supply = gtoken.totalSupply();
        uint256 backing = vault.totalBacking();
        // backing is in USD (18 dec), supply is GROSH (18 dec)
        // with 0% haircut and USDC price = $1.00, they should be equal
        assertLe(supply, backing + 1); // +1 for rounding
    }

    /// @notice Vault must hold USDC when there is outstanding GROSH supply
    function invariant_vaultSolventWhenSupplyPositive() public view {
        if (gtoken.totalSupply() > 0) {
            assertGt(usdc.balanceOf(address(vault)), 0);
        }
    }

    /// @notice Registry's initial setup can only be done once
    function invariant_initialSetupDone() public view {
        assertTrue(registry.initialSetupDone());
    }
}
