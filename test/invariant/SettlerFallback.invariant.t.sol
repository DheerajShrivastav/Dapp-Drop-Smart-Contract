// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Web3Campaigns} from "../../src/Web3Campaigns.sol";
import {CampaignStorage} from "../../src/CampaignStorage.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {SettlerFallbackHandler} from "./SettlerFallbackHandler.sol";

/// @notice Invariant suite for the SETTLER_ROLE fallback settlement path (ERC20 side). Fuzzes a
/// host-publish path, the settler-fallback publish/close path under test, and an unauthorized
/// caller, interleaved across many campaigns with randomized timing around
/// SETTLEMENT_FALLBACK_DELAY (14 days) and ROOT_DISPUTE_WINDOW (24h).
contract SettlerFallbackInvariant is StdInvariant, Test {
    Web3Campaigns public campaigns;
    ERC20Mock public token;
    SettlerFallbackHandler public handler;

    function setUp() public {
        vm.warp(1_000_000);

        address deployer = vm.addr(1);
        vm.prank(deployer);
        campaigns = new Web3Campaigns();

        token = new ERC20Mock();
        handler = new SettlerFallbackHandler(campaigns, token);

        vm.startPrank(deployer);
        campaigns.grantHostRole(address(handler));
        campaigns.grantRole(campaigns.SETTLER_ROLE(), handler.settler());
        vm.stopPrank();

        // Only fuzz the eight lifecycle actions.
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = SettlerFallbackHandler.createAndEndCampaign.selector;
        selectors[1] = SettlerFallbackHandler.hostPublishRoot.selector;
        selectors[2] = SettlerFallbackHandler.settlerAttemptPublish.selector;
        selectors[3] = SettlerFallbackHandler.settlerAttemptClose.selector;
        selectors[4] = SettlerFallbackHandler.attackerAttemptPublish.selector;
        selectors[5] = SettlerFallbackHandler.attackerAttemptClose.selector;
        selectors[6] = SettlerFallbackHandler.claim.selector;
        selectors[7] = SettlerFallbackHandler.warpForward.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice Property (a): a settler action (publish or close) can never occur before
    /// endTime + SETTLEMENT_FALLBACK_DELAY. Property (b): a settler can never change an
    /// already-published root, nor force a close with no settlement ever committed. Property
    /// (defense-in-depth): an unauthorized caller (neither host nor SETTLER_ROLE) can never succeed
    /// at either action, regardless of timing or root state.
    function invariant_NoSettlerFallbackViolations() public view {
        assertEq(handler.ghost_settlerPublishedBeforeDelay(), 0, "settler published before the fallback delay elapsed");
        assertEq(handler.ghost_settlerClosedBeforeDelay(), 0, "settler closed before the fallback delay elapsed");
        assertEq(handler.ghost_settlerOverwroteRoot(), 0, "settler overwrote an already-published root");
        assertEq(handler.ghost_settlerClosedWithNoRoot(), 0, "settler closed a campaign with no root ever published");
        assertEq(handler.ghost_unauthorizedPublishSuccess(), 0, "an unauthorized caller published a root");
        assertEq(handler.ghost_unauthorizedCloseSuccess(), 0, "an unauthorized caller closed a campaign");
    }

    /// @notice Property (c): escrow solvency invariants still hold with the settler actor in the
    /// mix. Global conservation: every token the contract holds equals what was funded minus what
    /// was claimed (no sweep action in this handler, so nothing else should move token balance).
    function invariant_globalTokenAccounting() public view {
        assertEq(
            token.balanceOf(address(campaigns)),
            handler.ghost_totalFunded() - handler.ghost_totalClaimed(),
            "global token accounting diverged with a settler actor in the mix"
        );
    }

    /// @notice Per-campaign backing: the contract must always hold at least the sum of what every
    /// campaign with a published root is still owed (escrowed - distributed), whether that root was
    /// published by the host, a settler, or (if the authorization bug this suite hunts for exists)
    /// an attacker.
    function invariant_perCampaignBacked() public view {
        uint256 owed;
        uint256 n = handler.campaignCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.campaignAt(i);
            (, uint256 escrowed, uint256 distributed,,,) = campaigns.getERC20Settlement(id);
            owed += (escrowed - distributed);
        }
        assertGe(
            token.balanceOf(address(campaigns)), owed, "per-campaign backing underwater with a settler actor in the mix"
        );
    }

    /// @notice Per campaign, distributed never exceeds escrowed, regardless of who published the
    /// root that authorized the claim.
    function invariant_distributedLeqEscrowed() public view {
        uint256 n = handler.campaignCount();
        for (uint256 i; i < n; ++i) {
            (, uint256 escrowed, uint256 distributed,,,) = campaigns.getERC20Settlement(handler.campaignAt(i));
            assertLe(distributed, escrowed, "distributed exceeded escrowed");
        }
    }

    /// @notice Non-vacuousness sanity check, run deterministically (not through the fuzzer): a
    /// settler CAN legitimately succeed at both actions once past the gate, proving
    /// invariant_NoSettlerFallbackViolations isn't vacuously passing because the fuzzer never
    /// happened to push a settler action past SETTLEMENT_FALLBACK_DELAY. A separate `handler2`
    /// instance is used so this deterministic script doesn't interact with the fuzzed `handler`'s
    /// state or selectors.
    function test_NonVacuous_SettlerCanLegitimatelySucceed() public {
        SettlerFallbackHandler handler2 = new SettlerFallbackHandler(campaigns, token);
        address deployer = vm.addr(1);
        vm.startPrank(deployer);
        campaigns.grantHostRole(address(handler2));
        campaigns.grantRole(campaigns.SETTLER_ROLE(), handler2.settler());
        vm.stopPrank();

        handler2.createAndEndCampaign(100 ether, 7 days);
        handler2.warpForward(handler2.SETTLEMENT_FALLBACK_DELAY() + 1);
        handler2.settlerAttemptPublish(0, 50 ether);
        assertEq(
            handler2.ghost_settlerPublishLegitimateSuccess(), 1, "settler publish should have legitimately succeeded"
        );

        handler2.settlerAttemptClose(0);
        assertEq(handler2.ghost_settlerCloseLegitimateSuccess(), 1, "settler close should have legitimately succeeded");

        assertEq(handler2.ghost_settlerPublishedBeforeDelay(), 0);
        assertEq(handler2.ghost_settlerOverwroteRoot(), 0);
        assertEq(handler2.ghost_settlerClosedBeforeDelay(), 0);
        assertEq(handler2.ghost_settlerClosedWithNoRoot(), 0);
    }
}
