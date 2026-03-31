// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/core/GToken.sol";
import "../src/core/ModuleRegistry.sol";
import "../src/emission/CreditLedger.sol";
import "../src/services/CreditModule.sol";
import "../src/interfaces/IModuleRegistry.sol";

/// @notice Deploy GroshY — Mutual Credit configuration (Sardex/WIR-style, closed economy)
/// @dev No reserve vault, no exit module, no EPController.
///      Members are onboarded manually by the owner (multisig/DAO).
/// @dev Usage:
///   forge script script/DeployMutualCredit.s.sol --rpc-url $AMOY_RPC_URL --broadcast
contract DeployMutualCredit is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address owner = vm.envOr("GNOSIS_SAFE", deployer);

        vm.startBroadcast(deployerKey);

        // ── 1. Core ──────────────────────────────────────────────────────────

        GToken gtoken = new GToken(
            "GroshY Mutual Credit",
            "GRSHMC",
            0,          // no max supply
            200_000,    // hookGasLimit
            owner
        );
        console.log("GToken:       ", address(gtoken));

        ModuleRegistry registry = new ModuleRegistry(
            address(gtoken),
            172_800,    // 48h timelock
            owner
        );
        console.log("ModuleRegistry:", address(registry));

        gtoken.setRegistry(address(registry));

        // ── 2. Emission ──────────────────────────────────────────────────────

        CreditLedger ledger = new CreditLedger(
            address(gtoken),
            50,         // demurrage = 0.5%/month
            owner
        );
        console.log("CreditLedger: ", address(ledger));

        // ── 3. Optional: CreditModule for inter-member loans ─────────────────
        // In a pure mutual credit system this is often omitted.
        // Included here for completeness; set collateralVault to address(0).

        CreditModule credit = new CreditModule(
            address(gtoken),
            address(0), // no reserve vault
            address(0), // no collateral vault
            0,          // no CAR minimum
            0,          // no LTV (uncollateralized)
            0,          // no liquidation penalty
            365 days,
            0,          // no origination fee
            owner
        );
        console.log("CreditModule: ", address(credit));

        // ── 4. Register modules ──────────────────────────────────────────────

        HookType[] memory emissionHooks = new HookType[](2);
        emissionHooks[0] = HookType.BEFORE_MINT;
        emissionHooks[1] = HookType.BEFORE_BURN;

        HookType[] memory creditHooks = new HookType[](1);
        creditHooks[0] = HookType.BEFORE_BURN;

        HookType[] memory noHooks = new HookType[](0);

        registry.initialSetup(
            address(ledger), ModuleRole.EMISSION, emissionHooks,
            address(0),                           noHooks,   // no reserve
            address(credit),                      creditHooks,
            address(0),                           noHooks,   // no exit
            address(0),                           noHooks    // no policy
        );

        // ── 5. Hook order ────────────────────────────────────────────────────

        address[] memory beforeBurnOrder = new address[](1);
        beforeBurnOrder[0] = address(credit);
        registry.setHookOrder(HookType.BEFORE_BURN, beforeBurnOrder);

        // AFTER_TRANSFER: CreditLedger tracks net positions
        address[] memory afterTransferOrder = new address[](1);
        afterTransferOrder[0] = address(ledger);
        registry.setHookOrder(HookType.AFTER_TRANSFER, afterTransferOrder);

        vm.stopBroadcast();

        console.log("------------------------------------------------------");
        console.log("Mutual Credit deployment complete.");
        console.log("Next: call CreditLedger.openLine() to onboard members.");
    }
}
