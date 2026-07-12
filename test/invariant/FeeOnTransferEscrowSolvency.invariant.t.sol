// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Web3Campaigns} from "../../src/Web3Campaigns.sol";
import {FeeOnTransferMock} from "../FeeOnTransferERC20.t.sol";
import {FeeOnTransferEscrowSolvencyHandler} from "./FeeOnTransferEscrowSolvencyHandler.sol";

/// @notice Same three properties as EscrowSolvency.invariant.t.sol, fuzzed against a
/// fee-on-transfer ERC20 instead of a standard token. Confirms the fundCampaignERC20 balance-diff
/// fix (see docs/SECURITY_FINDINGS.md) keeps the contract solvent across long random
/// fund/claim/sweep sequences -- not just the fixed points the unit suite
/// (test/FeeOnTransferERC20.t.sol) checks.
contract FeeOnTransferEscrowSolvencyInvariant is StdInvariant, Test {
    Web3Campaigns public campaigns;
    FeeOnTransferMock public token;
    FeeOnTransferEscrowSolvencyHandler public handler;

    function setUp() public {
        vm.warp(1_000_000);

        address deployer = vm.addr(1);
        vm.prank(deployer);
        campaigns = new Web3Campaigns();

        token = new FeeOnTransferMock(500); // 5% skimmed in transit, same rate as the unit tests
        handler = new FeeOnTransferEscrowSolvencyHandler(campaigns, token);

        vm.prank(deployer);
        campaigns.grantHostRole(address(handler));

        // Only fuzz the three lifecycle actions.
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = FeeOnTransferEscrowSolvencyHandler.createFundAndSettle.selector;
        selectors[1] = FeeOnTransferEscrowSolvencyHandler.claim.selector;
        selectors[2] = FeeOnTransferEscrowSolvencyHandler.sweep.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice Global token conservation: every token the contract holds is exactly what was
    /// ACTUALLY received (ghost_totalFunded, post token-skim) minus everything claimed out minus
    /// everything swept back to hosts. Would catch a regression where escrow accounting drifted
    /// back to trusting the nominal funding amount instead of the measured one.
    function invariant_globalTokenAccounting() public view {
        assertEq(
            token.balanceOf(address(campaigns)),
            handler.ghost_totalFunded() - handler.ghost_totalClaimed() - handler.ghost_totalSwept(),
            "fee-on-transfer global token accounting diverged"
        );
    }

    /// @notice Per-campaign backing: the contract must always hold at least the sum of what every
    /// still-open campaign is owed (escrowed - distributed), same commingled-pool check as the
    /// standard-token suite, now against a token that skims on every transfer leg.
    function invariant_perCampaignBacked() public view {
        uint256 owed;
        uint256 n = handler.settledCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.settledAt(i);
            if (handler.isSwept(id)) continue;
            (, uint256 escrowed, uint256 distributed,,,) = campaigns.getERC20Settlement(id);
            owed += (escrowed - distributed);
        }
        assertGe(token.balanceOf(address(campaigns)), owed, "fee-on-transfer per-campaign backing underwater");
    }

    /// @notice Per campaign, distributed never exceeds escrowed (the contract's own accounting
    /// guard) -- unaffected by the token's own in-transit skim, since escrowed/distributed are
    /// ledger amounts debited by the full requested amount either way (see
    /// docs/SECURITY_FINDINGS.md's note on the fee-payout-leg nuance).
    function invariant_distributedLeqEscrowed() public view {
        uint256 n = handler.settledCount();
        for (uint256 i; i < n; ++i) {
            (, uint256 escrowed, uint256 distributed,,,) = campaigns.getERC20Settlement(handler.settledAt(i));
            assertLe(distributed, escrowed, "distributed exceeded escrowed");
        }
    }
}
