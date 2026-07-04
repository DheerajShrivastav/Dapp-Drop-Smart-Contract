// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Web3Campaigns} from "../../src/Web3Campaigns.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {EscrowSolvencyHandler} from "./EscrowSolvencyHandler.sol";

/// @notice Invariant suite for ERC20 escrow + Merkle settlement solvency.
/// Runs a fuzzed sequence of create/fund/settle, claim, and sweep across many campaigns sharing one
/// reward token, and asserts the contract can always cover what it owes.
contract EscrowSolvencyInvariant is StdInvariant, Test {
    Web3Campaigns public campaigns;
    ERC20Mock public token;
    EscrowSolvencyHandler public handler;

    function setUp() public {
        vm.warp(1_000_000);

        address deployer = vm.addr(1);
        vm.prank(deployer);
        campaigns = new Web3Campaigns();

        token = new ERC20Mock();
        handler = new EscrowSolvencyHandler(campaigns, token);

        vm.prank(deployer);
        campaigns.grantHostRole(address(handler));

        // Only fuzz the three lifecycle actions.
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = EscrowSolvencyHandler.createFundAndSettle.selector;
        selectors[1] = EscrowSolvencyHandler.claim.selector;
        selectors[2] = EscrowSolvencyHandler.sweep.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice Global token conservation: every token the contract holds is exactly what was funded
    /// minus everything claimed out minus everything swept back to hosts. Catches any path that
    /// creates, loses, or double-moves tokens.
    function invariant_globalTokenAccounting() public view {
        assertEq(
            token.balanceOf(address(campaigns)),
            handler.ghost_totalFunded() - handler.ghost_totalClaimed() - handler.ghost_totalSwept(),
            "global token accounting diverged"
        );
    }

    /// @notice Per-campaign backing: the contract must always hold at least the sum of what every
    /// still-open campaign is owed (escrowed - distributed). A campaign that has been swept is owed
    /// nothing further. If any campaign's claim were paid from another campaign's commingled escrow,
    /// this sum would exceed the real balance.
    function invariant_perCampaignBacked() public view {
        uint256 owed;
        uint256 n = handler.settledCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.settledAt(i);
            if (handler.isSwept(id)) continue;
            (, uint256 escrowed, uint256 distributed,,,) = campaigns.getERC20Settlement(id);
            owed += (escrowed - distributed);
        }
        assertGe(token.balanceOf(address(campaigns)), owed, "per-campaign backing underwater");
    }

    /// @notice Per campaign, distributed never exceeds escrowed (the contract's own accounting guard).
    function invariant_distributedLeqEscrowed() public view {
        uint256 n = handler.settledCount();
        for (uint256 i; i < n; ++i) {
            (, uint256 escrowed, uint256 distributed,,,) = campaigns.getERC20Settlement(handler.settledAt(i));
            assertLe(distributed, escrowed, "distributed exceeded escrowed");
        }
    }
}
