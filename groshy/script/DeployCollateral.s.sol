// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/core/GToken.sol";
import "../src/core/ModuleRegistry.sol";
import "../src/emission/CollateralVault.sol";
import "../src/services/ReserveVault.sol";
import "../src/services/CreditModule.sol";
import "../src/services/ExitModule.sol";
import "../src/policy/EPController.sol";
import "../src/interfaces/IModuleRegistry.sol";

/// @notice Deploy GroshY — Collateral configuration (USDC-backed, soft peg via PSM)
/// @dev Usage:
///   forge script script/DeployCollateral.s.sol --rpc-url $AMOY_RPC_URL --broadcast --verify
contract DeployCollateral is Script {
    // -------------------------------------------------------------------------
    // Polygon Amoy testnet addresses
    // -------------------------------------------------------------------------
    // NOTE: Update these before mainnet deployment
    address constant USDC_AMOY = 0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582; // mock USDC on Amoy
    address constant USDC_USD_FEED_AMOY = 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43; // Amoy Chainlink USDC/USD

    // -------------------------------------------------------------------------
    // Polygon mainnet addresses (for reference)
    // -------------------------------------------------------------------------
    // address constant USDC_POLYGON    = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    // address constant USDC_USD_FEED   = 0xfE4A8cc5b5B2366C1B58Bea3858e81843581b2F7;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // Optional: use a Gnosis Safe as owner. Falls back to deployer for testnet.
        address owner = vm.envOr("GNOSIS_SAFE", deployer);

        vm.startBroadcast(deployerKey);

        // ── 1. Core ──────────────────────────────────────────────────────────

        GToken gtoken = new GToken(
            "GroshY",
            "GRSH",
            0,          // no max supply cap
            200_000,    // hookGasLimit per call
            owner
        );
        console.log("GToken:          ", address(gtoken));

        ModuleRegistry registry = new ModuleRegistry(
            address(gtoken),
            172_800,    // 48h timelock for module changes
            owner
        );
        console.log("ModuleRegistry:  ", address(registry));

        // Wire GToken → ModuleRegistry (still owned by owner, not deployer, but
        // deployer == owner on testnet so this call works)
        gtoken.setRegistry(address(registry));

        // ── 2. Emission ──────────────────────────────────────────────────────

        CollateralVault vault = new CollateralVault(
            address(gtoken),
            address(registry),
            10e18,      // $10 minimum deposit (18 dec USD)
            owner
        );
        console.log("CollateralVault: ", address(vault));

        // Accept USDC with 5% haircut, 100% max allocation, Chainlink feed
        vault.addAsset(USDC_AMOY, 500, 10_000, USDC_USD_FEED_AMOY);

        // ── 3. Services ──────────────────────────────────────────────────────

        ReserveVault reserve = new ReserveVault(
            address(gtoken),
            USDC_AMOY,
            2000,       // R_min = 20%
            2500,       // rebalance alert at 25%
            1000,       // circuit breaker at 10% daily outflow
            owner
        );
        console.log("ReserveVault:    ", address(reserve));

        CreditModule credit = new CreditModule(
            address(gtoken),
            address(reserve),
            address(vault),
            1000,       // CAR_min = 10%
            7500,       // LTV_max = 75%
            1000,       // liquidation penalty = 10%
            365 days,   // max loan maturity
            50,         // origination fee = 0.5%
            owner
        );
        console.log("CreditModule:    ", address(credit));

        ExitModule exitMod = new ExitModule(
            address(gtoken),
            address(reserve),
            ExitModule.ExitMode.PSM, // soft peg via PSM
            30,         // 0.3% exit spread
            500,        // max 5% of supply can exit per day
            100,        // 100 blocks cooldown (~3 min on Polygon)
            1000,       // circuit breaker at 10% daily
            owner
        );
        exitMod.setPsmCap(1_000_000e6); // $1M PSM capacity
        console.log("ExitModule:      ", address(exitMod));

        // ── 4. Policy (EPController) ─────────────────────────────────────────

        EPController ep = new EPController(
            address(gtoken),
            800,        // R_target = 8%/year
            100,        // R_floor  = 1%
            3000,       // R_ceiling = 30%
            1500,       // LOLR rate = 15%
            7 days,     // LOLR max term
            2000,       // max LOLR = 20% of supply
            owner
        );
        console.log("EPController:    ", address(ep));

        // Register this CP in EPController
        ep.registerCP(deployer, address(reserve));

        // ── 5. Wire cross-contract references ───────────────────────────────

        reserve.setEPController(address(ep));
        reserve.setExitModule(address(exitMod));
        vault.setCreditModule(address(credit));

        // ── 6. Register modules (no timelock for initial setup) ──────────────

        // Hook arrays
        HookType[] memory emissionHooks = new HookType[](2);
        emissionHooks[0] = HookType.BEFORE_MINT;
        emissionHooks[1] = HookType.BEFORE_BURN;

        HookType[] memory reserveHooks = new HookType[](2);
        reserveHooks[0] = HookType.AFTER_BURN;
        reserveHooks[1] = HookType.AFTER_MINT;

        HookType[] memory creditHooks = new HookType[](1);
        creditHooks[0] = HookType.BEFORE_BURN;

        HookType[] memory exitHooks  = new HookType[](0);
        HookType[] memory policyHooks = new HookType[](0);

        registry.initialSetup(
            address(vault),   ModuleRole.EMISSION, emissionHooks,
            address(reserve),                      reserveHooks,
            address(credit),                       creditHooks,
            address(exitMod),                      exitHooks,
            address(ep),                           policyHooks
        );

        // ── 7. Set hook execution order ──────────────────────────────────────

        // BEFORE_MINT: EP → ReserveVault → CollateralVault
        address[] memory beforeMintOrder = new address[](2);
        beforeMintOrder[0] = address(ep);
        beforeMintOrder[1] = address(reserve);
        registry.setHookOrder(HookType.BEFORE_MINT, beforeMintOrder);

        // AFTER_MINT: ReserveVault
        address[] memory afterMintOrder = new address[](1);
        afterMintOrder[0] = address(reserve);
        registry.setHookOrder(HookType.AFTER_MINT, afterMintOrder);

        // BEFORE_BURN: CreditModule (block burn if active loan)
        address[] memory beforeBurnOrder = new address[](1);
        beforeBurnOrder[0] = address(credit);
        registry.setHookOrder(HookType.BEFORE_BURN, beforeBurnOrder);

        // AFTER_BURN: ReserveVault (circuit breaker)
        address[] memory afterBurnOrder = new address[](1);
        afterBurnOrder[0] = address(reserve);
        registry.setHookOrder(HookType.AFTER_BURN, afterBurnOrder);

        // AFTER_TRANSFER: empty for collateral config
        address[] memory afterTransferOrder = new address[](0);
        registry.setHookOrder(HookType.AFTER_TRANSFER, afterTransferOrder);

        // ── 8. Transfer all ownerships to Safe / final owner ─────────────────
        // (skipped if deployer == owner, which is the case on testnet)

        vm.stopBroadcast();

        console.log("------------------------------------------------------");
        console.log("Deployment complete. Copy addresses to .env or frontend.");
    }
}
