// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Web3Campaigns} from "../../src/Web3Campaigns.sol";
import {OnChainRewardModule} from "../../src/OnChainRewardModule.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {OnChainRewardHandler} from "./OnChainRewardHandler.sol";

/// @notice Invariant suite for the on-chain RANK_TIERED settlement path and per-campaign reward-
/// module pinning. Runs a fuzzed sequence of campaign creation, task completion, ending, claiming,
/// and GLOBAL MODULE ROTATION across many campaigns, and asserts the properties flagged as missing
/// coverage in docs/TEST_AND_BUILD.md after the pinning feature shipped (PR #6):
///   - sum(on-chain claims) <= escrowed
///   - each participant can claim at most once per campaign
///   - completion rank assignment is strictly monotone (no duplicate ranks within a campaign)
///   - the pinned-module invariant: once pinned, a campaign's module never changes, even across an
///     admin rotation of the global default
contract OnChainRewardInvariant is StdInvariant, Test {
    Web3Campaigns public campaigns;
    ERC20Mock public token;
    OnChainRewardModule public initialModule;
    OnChainRewardHandler public handler;

    function setUp() public {
        vm.warp(1_000_000);

        address deployer = vm.addr(1);
        vm.startPrank(deployer);
        campaigns = new Web3Campaigns();
        initialModule = new OnChainRewardModule(address(campaigns));
        campaigns.setOnChainRewardModule(address(initialModule));
        vm.stopPrank();

        token = new ERC20Mock();
        handler = new OnChainRewardHandler(campaigns, token, initialModule, deployer);

        vm.prank(deployer);
        campaigns.grantHostRole(address(handler));

        // Only fuzz the five lifecycle actions.
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = OnChainRewardHandler.createAndOpenRankTiered.selector;
        selectors[1] = OnChainRewardHandler.complete.selector;
        selectors[2] = OnChainRewardHandler.endCampaign.selector;
        selectors[3] = OnChainRewardHandler.claim.selector;
        selectors[4] = OnChainRewardHandler.rotateGlobalModule.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice Global token conservation for the on-chain-tiered path: every token the contract
    /// holds is exactly what was funded minus everything paid out via payOnChainReward. Catches any
    /// path that creates, loses, or double-moves tokens across the module<->Web3Campaigns boundary.
    function invariant_globalTokenAccounting() public view {
        assertEq(
            token.balanceOf(address(campaigns)),
            handler.ghost_totalFunded() - handler.ghost_totalClaimed(),
            "on-chain-reward global token accounting diverged"
        );
    }

    /// @notice No participant is ever paid twice for the same campaign. The handler's claim() does
    /// NOT skip a participant who already succeeded -- it retries freely -- so this directly
    /// exercises OnChainRewardModule's _onChainRewardClaimed guard under adversarial repetition,
    /// rather than just trusting the handler never asks twice.
    function invariant_claimAtMostOncePerParticipant() public view {
        uint256 n = handler.endedCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.endedAt(i);
            for (uint256 idx; idx < 4; ++idx) {
                assertLe(
                    handler.claimAttemptsSucceeded(id, idx), 1, "participant claimed on-chain reward more than once"
                );
            }
        }
    }

    /// @notice Within a single campaign, no two participants ever hold the same nonzero completion
    /// rank. Ranks are assigned by OnChainRewardModule via a per-campaign monotone counter
    /// (_campaignCompletionCount), so a duplicate here would mean that counter was double-used or
    /// reset -- checked across BOTH still-open and already-ended campaigns, since ranks are assigned
    /// live as participants complete, not just at Ended.
    function invariant_rankAssignmentsAreDistinct() public view {
        _checkDistinctRanks(true);
        _checkDistinctRanks(false);
    }

    function _checkDistinctRanks(bool checkOpen) internal view {
        uint256 n = checkOpen ? handler.openCount() : handler.endedCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = checkOpen ? handler.openAt(i) : handler.endedAt(i);
            // Query the LIVE pin (not the handler's own recorded copy) so this check stays valid
            // independently of invariant_pinnedModuleNeverChanges -- otherwise a pin-rotation bug
            // could make this silently observe the wrong module's (empty) rank state instead of
            // catching anything.
            OnChainRewardModule pinned = OnChainRewardModule(campaigns.getCampaignRewardModule(id));

            uint256[4] memory ranks;
            for (uint256 idx; idx < 4; ++idx) {
                (, uint256 rank,,,) = pinned.getOnChainRewardStatus(id, handler.participants(idx));
                ranks[idx] = rank;
            }
            for (uint256 a; a < 4; ++a) {
                if (ranks[a] == 0) continue;
                for (uint256 b = a + 1; b < 4; ++b) {
                    if (ranks[b] == 0) continue;
                    assertTrue(ranks[a] != ranks[b], "duplicate rank assigned within a campaign");
                }
            }
        }
    }

    /// @notice The core pinning guarantee: once a campaign adopts a module (setRankTiers), that pin
    /// never changes, even after rotateGlobalModule swaps the admin-rotatable default. Compares
    /// Web3Campaigns' own getCampaignRewardModule against the value the handler recorded the instant
    /// the campaign was pinned -- if a rotation ever leaked into an already-pinned campaign, or the
    /// pin were somehow re-derived from the (now different) global default, this fails.
    function invariant_pinnedModuleNeverChanges() public view {
        uint256 openN = handler.openCount();
        for (uint256 i; i < openN; ++i) {
            uint256 id = handler.openAt(i);
            assertEq(
                campaigns.getCampaignRewardModule(id),
                handler.pinnedModuleOf(id),
                "pinned module changed after adoption (open campaign)"
            );
        }
        uint256 endedN = handler.endedCount();
        for (uint256 i; i < endedN; ++i) {
            uint256 id = handler.endedAt(i);
            assertEq(
                campaigns.getCampaignRewardModule(id),
                handler.pinnedModuleOf(id),
                "pinned module changed after adoption (ended campaign)"
            );
        }
    }
}
