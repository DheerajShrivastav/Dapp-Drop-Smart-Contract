// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Web3Campaigns} from "../../src/Web3Campaigns.sol";
import {CampaignStorage} from "../../src/CampaignStorage.sol";
import {AttestationVersionHandler} from "./AttestationVersionHandler.sol";

/// @notice Invariant suite for the signed-attestation replay guard (Phase 2 task verification).
/// Fuzzes an adversarial mix of legitimate next-version attestations, stale-version replays,
/// version skip-aheads, non-signer signatures, and expired deadlines against a single
/// (participant, campaign, task) triple, and checks the on-chain version/completion state always
/// tracks the ghost model exactly -- i.e. only ever advances by 1, only on a genuinely valid
/// SIGNER_ROLE signature for precisely the next version with a live deadline.
contract AttestationVersionInvariant is StdInvariant, Test {
    Web3Campaigns public campaigns;
    AttestationVersionHandler public handler;
    uint256 public campaignId;

    function setUp() public {
        vm.warp(1_000_000);

        address deployer = vm.addr(1); // SIGNER_ROLE holder by construction
        vm.prank(deployer);
        campaigns = new Web3Campaigns();

        vm.prank(deployer);
        campaigns.grantHostRole(deployer);

        uint256 startTime = block.timestamp + 1;
        uint256 endTime = startTime + campaigns.MAX_CAMPAIGN_DURATION();
        vm.startPrank(deployer);
        campaignId = campaigns.createCampaign("C", startTime, endTime);
        campaigns.addTaskToCampaign(campaignId, CampaignStorage.TaskType.SOCIAL_FOLLOW, "Follow us", "", false);
        vm.warp(startTime + 1);
        campaigns.openCampaign(campaignId);
        vm.stopPrank();

        handler = new AttestationVersionHandler(campaigns, campaignId);

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = AttestationVersionHandler.attestCorrectVersion.selector;
        selectors[1] = AttestationVersionHandler.attestReplayStaleVersion.selector;
        selectors[2] = AttestationVersionHandler.attestSkipAheadVersion.selector;
        selectors[3] = AttestationVersionHandler.attestNonSigner.selector;
        selectors[4] = AttestationVersionHandler.attestExpiredDeadline.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice The on-chain attestation version exactly matches the ghost model, no matter how many
    /// stale/skip-ahead/non-signer/expired attempts were interleaved with legitimate attestations.
    function invariant_versionMatchesGhostModel() public view {
        assertEq(
            campaigns.getTaskAttestationVersion(campaignId, handler.participant(), 0),
            handler.ghost_expectedVersion(),
            "on-chain attestation version diverged from ghost model"
        );
    }

    /// @notice The on-chain completion flag matches the last successfully-accepted attestation --
    /// no rejected attempt (stale/skip-ahead/non-signer/expired) ever mutated completion state.
    function invariant_completionMatchesLastAcceptedAttestation() public view {
        assertEq(
            campaigns.hasCompletedTask(campaignId, handler.participant(), 0),
            handler.ghost_lastCompleted(),
            "completion state diverged from last accepted attestation"
        );
    }
}
