// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {Web3Campaigns} from "../../src/Web3Campaigns.sol";
import {CampaignStorage} from "../../src/CampaignStorage.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/// @notice Stateful-fuzz handler adversarially hammering the SETTLER_ROLE fallback settlement path
/// (setERC20MerkleRoot's settler branch, closeCampaign's settler branch) across many campaigns with
/// randomized timing, interleaved with a plain host-publish path and an unauthorized-caller path.
///
/// Each campaign uses a single-leaf tree (one fixed participant), so root == leaf and proofs are
/// always empty -- the interesting surface here is AUTHORIZATION + TIMING (does a settler action
/// ever succeed before it should, or against an already-published root), not Merkle mechanics
/// (already covered by EscrowSolvency/RootDisputeWindow) or the dispute-window rearm rule itself
/// (already covered by RootDisputeWindowHandler). Scoped to the ERC20 path only, mirroring this
/// project's established one-dedicated-suite-per-concern pattern (RootDisputeWindow/NFTInventory/
/// OnChainReward are all separate files too) -- the NFT settler path shares the identical
/// authorization logic (see NFTSettlementModule.setNFTMerkleRoot) and is exhaustively covered by
/// SettlerFallbackTest.t.sol's unit tests instead.
///
/// Ghost counters record the outcome and are asserted via assertEq inside
/// SettlerFallback.invariant.t.sol's invariant_* functions -- NOT a loud revert("...") on the
/// unexpected branch. This project's own prior handlers (AttestationVersionHandler,
/// RootDisputeWindowHandler) were found, via negative control, to have that exact bug: under
/// fail_on_revert=false, ANY revert from a handler call -- including a deliberate loud revert meant
/// to flag a caught violation -- is silently discarded, rolling back the exploited call's own state
/// mutation along with the ghost write meant to catch it. See docs/SECURITY_FINDINGS.md and
/// docs/README.md for the full writeup. The ghost-counter-only pattern (record + return normally)
/// is this project's fix, applied here from the start rather than retrofitted.
contract SettlerFallbackHandler is Test {
    Web3Campaigns public campaigns;
    ERC20Mock public token;

    address public settler = address(0x5E77E4);
    address public attacker = address(0xBAD1);
    address public participant = address(0xF00D);

    // Mirrors CampaignStorage's internal SETTLEMENT_FALLBACK_DELAY (not publicly readable
    // on-chain -- internal, kept off the entrypoint's ABI purely for bytecode headroom).
    uint256 public constant SETTLEMENT_FALLBACK_DELAY = 14 days;

    uint256[] public campaignIds;
    mapping(uint256 => uint256) public fundedAmount; // escrow ceiling, fixed at creation
    mapping(uint256 => uint256) public endTimeOf;
    mapping(uint256 => uint256) public currentAmount; // amount encoded in the currently-live root
    mapping(uint256 => bool) public rootPublished;
    mapping(uint256 => uint256) public rootSetAt;
    mapping(uint256 => bool) public closedFlag;
    mapping(uint256 => bool) public claimedFlag;

    // --- ghost accounting (escrow solvency, property (c)) ---
    uint256 public ghost_totalFunded;
    uint256 public ghost_totalClaimed;

    // --- ghost violation counters -- MUST all stay 0 ---
    // Property (a): a settler action can never occur before endTime + SETTLEMENT_FALLBACK_DELAY.
    uint256 public ghost_settlerPublishedBeforeDelay;
    uint256 public ghost_settlerClosedBeforeDelay;
    // Property (b): a settler can never change an already-published root (or force a close with no
    // settlement ever committed -- the close-path analog of "never act without a legitimate basis").
    uint256 public ghost_settlerOverwroteRoot;
    uint256 public ghost_settlerClosedWithNoRoot;
    // Defense-in-depth: a caller with neither the host relationship nor SETTLER_ROLE must never
    // succeed at either fallback action, regardless of timing.
    uint256 public ghost_unauthorizedPublishSuccess;
    uint256 public ghost_unauthorizedCloseSuccess;

    // --- non-vacuousness counters (not asserted, spot-checked with `forge test -vv`) ---
    // A nonzero count here proves the settler branch was legitimately exercised under the correct
    // gate, not just correctly rejected every time -- without this, invariant_NoSettlerFallbackViolations
    // could pass vacuously if the fuzzer never happened to push a settler action past the delay.
    uint256 public ghost_settlerPublishLegitimateSuccess;
    uint256 public ghost_settlerCloseLegitimateSuccess;

    constructor(Web3Campaigns _campaigns, ERC20Mock _token) {
        campaigns = _campaigns;
        token = _token;
    }

    function _leaf(uint256 amt) internal view returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(participant, amt))));
    }

    // --- lifecycle ---

    function createAndEndCampaign(uint256 fundAmountSeed, uint256 durSeed) external {
        vm.warp(block.timestamp + campaigns.RATE_LIMIT_COOLDOWN() + 1);
        uint256 dur = bound(durSeed, campaigns.MIN_CAMPAIGN_DURATION(), campaigns.MAX_CAMPAIGN_DURATION());
        uint256 startTime = block.timestamp + 1;
        uint256 endTime = startTime + dur;

        uint256 id = campaigns.createCampaign("C", startTime, endTime);
        campaigns.configureERC20Reward(id, address(token));

        uint256 fundAmount = bound(fundAmountSeed, 1, 1e24);
        token.mint(address(this), fundAmount);
        token.approve(address(campaigns), fundAmount);
        campaigns.fundCampaignERC20(id, fundAmount);
        ghost_totalFunded += fundAmount;

        vm.warp(startTime + 1);
        campaigns.openCampaign(id);
        vm.warp(endTime + 1);
        campaigns.endCampaign(id);

        fundedAmount[id] = fundAmount;
        endTimeOf[id] = endTime;
        campaignIds.push(id);
    }

    /// @dev The "responsive host" path -- some campaigns get a normal, on-time root so the fuzzer
    /// doesn't ONLY exercise abandoned campaigns.
    function hostPublishRoot(uint256 campaignSeed, uint256 amountSeed) external {
        if (campaignIds.length == 0) return;
        uint256 id = campaignIds[bound(campaignSeed, 0, campaignIds.length - 1)];
        if (rootPublished[id] || closedFlag[id]) return;

        uint256 amt = bound(amountSeed, 1, fundedAmount[id]);
        campaigns.setERC20MerkleRoot(id, _leaf(amt));

        rootPublished[id] = true;
        currentAmount[id] = amt;
        rootSetAt[id] = block.timestamp;
    }

    /// @dev The path under test: SETTLER_ROLE attempting a fallback publish, on ANY campaign
    /// (already-published or not, delay-elapsed or not) -- the fuzzer explores every combination.
    function settlerAttemptPublish(uint256 campaignSeed, uint256 amountSeed) external {
        if (campaignIds.length == 0) return;
        uint256 id = campaignIds[bound(campaignSeed, 0, campaignIds.length - 1)];
        if (closedFlag[id]) return; // status != Ended is already covered by the unit tests directly

        bool wasPublished = rootPublished[id];
        bool delayElapsed = block.timestamp >= endTimeOf[id] + SETTLEMENT_FALLBACK_DELAY;
        uint256 amt = bound(amountSeed, 1, fundedAmount[id]);

        vm.prank(settler);
        try campaigns.setERC20MerkleRoot(id, _leaf(amt)) {
            if (wasPublished) {
                ghost_settlerOverwroteRoot++;
            } else if (!delayElapsed) {
                ghost_settlerPublishedBeforeDelay++;
            } else {
                rootPublished[id] = true;
                currentAmount[id] = amt;
                rootSetAt[id] = block.timestamp;
                ghost_settlerPublishLegitimateSuccess++;
            }
        } catch {
            // Correctly rejected -- nothing to record.
        }
    }

    function settlerAttemptClose(uint256 campaignSeed) external {
        if (campaignIds.length == 0) return;
        uint256 id = campaignIds[bound(campaignSeed, 0, campaignIds.length - 1)];
        if (closedFlag[id]) return;

        bool hasRoot = rootPublished[id];
        bool delayElapsed = block.timestamp >= endTimeOf[id] + SETTLEMENT_FALLBACK_DELAY;

        vm.prank(settler);
        try campaigns.closeCampaign(id) {
            if (!hasRoot) {
                ghost_settlerClosedWithNoRoot++;
            } else if (!delayElapsed) {
                ghost_settlerClosedBeforeDelay++;
            } else {
                closedFlag[id] = true;
                ghost_settlerCloseLegitimateSuccess++;
            }
        } catch {
            // Correctly rejected -- nothing to record.
        }
    }

    /// @dev `attacker` holds neither HOST_ROLE-derived campaign ownership nor SETTLER_ROLE for any
    /// campaign here -- any success at all, regardless of timing or root state, is a critical bug.
    function attackerAttemptPublish(uint256 campaignSeed, uint256 amountSeed) external {
        if (campaignIds.length == 0) return;
        uint256 id = campaignIds[bound(campaignSeed, 0, campaignIds.length - 1)];
        uint256 amt = bound(amountSeed, 1, fundedAmount[id]);

        vm.prank(attacker);
        try campaigns.setERC20MerkleRoot(id, _leaf(amt)) {
            ghost_unauthorizedPublishSuccess++;
            rootPublished[id] = true;
            currentAmount[id] = amt;
            rootSetAt[id] = block.timestamp;
        } catch {
            // Correctly rejected -- nothing to record.
        }
    }

    function attackerAttemptClose(uint256 campaignSeed) external {
        if (campaignIds.length == 0) return;
        uint256 id = campaignIds[bound(campaignSeed, 0, campaignIds.length - 1)];

        vm.prank(attacker);
        try campaigns.closeCampaign(id) {
            ghost_unauthorizedCloseSuccess++;
            closedFlag[id] = true;
        } catch {
            // Correctly rejected -- nothing to record.
        }
    }

    /// @dev Escrow-solvency exercise (property (c)): a participant claims once a root exists (host-
    /// or settler-published, this handler makes no distinction) and the dispute window has elapsed.
    function claim(uint256 campaignSeed) external {
        if (campaignIds.length == 0) return;
        uint256 id = campaignIds[bound(campaignSeed, 0, campaignIds.length - 1)];
        if (!rootPublished[id] || claimedFlag[id]) return;
        if (block.timestamp < rootSetAt[id] + campaigns.ROOT_DISPUTE_WINDOW()) return;

        bytes32[] memory proof = new bytes32[](0);
        vm.prank(participant);
        campaigns.claimERC20(id, currentAmount[id], proof); // a revert here discards the call, ghosts untouched

        claimedFlag[id] = true;
        ghost_totalClaimed += currentAmount[id];
    }

    /// @dev Explicit time-advance lever so the fuzzer can deliberately push past
    /// SETTLEMENT_FALLBACK_DELAY (14 days) as well as ROOT_DISPUTE_WINDOW (24h) -- without this,
    /// most calls would land well inside both windows.
    function warpForward(uint256 seed) external {
        uint256 delta = bound(seed, 1, 3 * SETTLEMENT_FALLBACK_DELAY);
        vm.warp(block.timestamp + delta);
    }

    // --- views for the invariant contract ---
    function campaignCount() external view returns (uint256) {
        return campaignIds.length;
    }

    function campaignAt(uint256 i) external view returns (uint256) {
        return campaignIds[i];
    }
}
