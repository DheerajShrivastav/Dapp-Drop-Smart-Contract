// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {Web3Campaigns} from "../../src/Web3Campaigns.sol";
import {OnChainRewardModule} from "../../src/OnChainRewardModule.sol";
import {CampaignStorage} from "../../src/CampaignStorage.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/// @notice Stateful-fuzz handler for the on-chain RANK_TIERED settlement path + per-campaign module
///         pinning, across MANY campaigns and a rotating global reward module.
///
/// Design: each campaign has one required task and a single flat rank tier covering ranks 1..4 (the
/// handler's fixed 4-participant set), paid `tierAmount` per rank -- so escrow is funded at exactly
/// `tierAmount * 4`, the maximum any campaign could ever pay out (every participant completes and
/// gets ranked). This keeps the escrow-accounting invariant meaningfully tight rather than vacuously
/// true.
///
/// The global reward module is rotatable mid-run (rotateGlobalModule): campaigns created before a
/// rotation stay pinned to the pre-rotation module and must remain claimable through it; campaigns
/// created after pin to the new one. This directly exercises the per-campaign pinning guarantee the
/// feature exists to provide -- see docs/SECURITY_FINDINGS.md.
///
/// claim() deliberately does NOT gate on "already claimed" before attempting -- unlike
/// EscrowSolvencyHandler's claim, which skips a known-claimed leaf, this handler lets the fuzzer
/// retry the same (campaign, participant) claim repeatedly. Success is counted every time via
/// claimAttemptsSucceeded, so invariant_claimAtMostOncePerParticipant actually exercises the
/// contract's own double-claim guard rather than just trusting the handler never asks twice.
contract OnChainRewardHandler is Test {
    uint256 internal constant NUM_PARTICIPANTS = 4;

    Web3Campaigns public campaigns;
    ERC20Mock public token;
    OnChainRewardModule public currentModule; // whichever module is currently the global default
    address public deployer;

    address[4] public participants;

    uint256[] public openCampaigns; // Open, not yet ended
    uint256[] public endedCampaigns; // Ended, claimable

    mapping(uint256 => address) public pinnedModuleOf; // campaignId => module it was pinned to
    mapping(uint256 => uint256) public tierAmountOf; // campaignId => flat per-rank payout
    mapping(uint256 => mapping(uint256 => bool)) public completedInCampaign; // id => pIdx => completed
    mapping(uint256 => mapping(uint256 => uint256)) public claimAttemptsSucceeded; // id => pIdx => success count

    // --- ghost accounting ---
    uint256 public ghost_totalFunded;
    uint256 public ghost_totalClaimed;

    constructor(Web3Campaigns _campaigns, ERC20Mock _token, OnChainRewardModule _initialModule, address _deployer) {
        campaigns = _campaigns;
        token = _token;
        currentModule = _initialModule;
        deployer = _deployer;

        participants[0] = address(0xA11CE);
        participants[1] = address(0xB0B01);
        participants[2] = address(0xC0FFEE);
        participants[3] = address(0xD00D);
    }

    // --- actions ---

    /// @dev Create a RANK_TIERED campaign, fund it exactly (tierAmount * 4), and open it. Pins the
    /// campaign to whichever module is currently the global default.
    function createAndOpenRankTiered(uint256 tierAmountSeed, uint256 durSeed) external {
        // Sidestep createCampaign's per-host rate limit (5 min cooldown).
        vm.warp(block.timestamp + campaigns.RATE_LIMIT_COOLDOWN() + 1);

        uint256 dur = bound(durSeed, campaigns.MIN_CAMPAIGN_DURATION(), campaigns.MAX_CAMPAIGN_DURATION());
        uint256 startTime = block.timestamp + 1;
        uint256 endTime = startTime + dur;

        uint256 id = campaigns.createCampaign("C", startTime, endTime);
        campaigns.addTaskToCampaign(id, CampaignStorage.TaskType.SOCIAL_FOLLOW, "Follow us", "", false);
        campaigns.configureERC20Reward(id, address(token));

        uint256 tierAmount = bound(tierAmountSeed, 1, 1e24);
        uint256[] memory startRanks = new uint256[](1);
        uint256[] memory endRanks = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        startRanks[0] = 1;
        endRanks[0] = NUM_PARTICIPANTS;
        amounts[0] = tierAmount;
        // Commits RANK_TIERED and pins `currentModule` to this campaign.
        currentModule.setRankTiers(id, startRanks, endRanks, amounts);

        uint256 fundAmount = tierAmount * NUM_PARTICIPANTS;
        token.mint(address(this), fundAmount);
        token.approve(address(campaigns), fundAmount);
        campaigns.fundCampaignERC20(id, fundAmount);
        ghost_totalFunded += fundAmount;

        campaigns.openCampaign(id);

        pinnedModuleOf[id] = address(currentModule);
        tierAmountOf[id] = tierAmount;
        openCampaigns.push(id);

        // Land inside the campaign's active window for the earliest completeTask calls.
        vm.warp(startTime + 1);
    }

    /// @dev A participant self-completes the campaign's single required task.
    function complete(uint256 campaignSeed, uint256 participantSeed) external {
        if (openCampaigns.length == 0) return;
        uint256 id = openCampaigns[bound(campaignSeed, 0, openCampaigns.length - 1)];
        uint256 idx = bound(participantSeed, 0, NUM_PARTICIPANTS - 1);
        if (completedInCampaign[id][idx]) return;

        vm.warp(block.timestamp + 31); // clear the participant's 30s anti-spam cooldown
        vm.prank(participants[idx]);
        campaigns.completeTask(id, 0); // reverts (e.g. window elapsed) are discarded, ghosts untouched

        completedInCampaign[id][idx] = true;
    }

    /// @dev End a still-open campaign once its window has elapsed (warping forward if needed).
    function endCampaign(uint256 campaignSeed) external {
        if (openCampaigns.length == 0) return;
        uint256 i = bound(campaignSeed, 0, openCampaigns.length - 1);
        uint256 id = openCampaigns[i];

        uint256 endTime = campaigns.getCampaign(id).endTime;
        if (block.timestamp < endTime) {
            vm.warp(endTime + 1);
        }
        campaigns.endCampaign(id);

        openCampaigns[i] = openCampaigns[openCampaigns.length - 1];
        openCampaigns.pop();
        endedCampaigns.push(id);
    }

    /// @dev A participant claims via the campaign's PINNED module (not necessarily the current
    /// global default). No pre-check on prior claim success -- see contract-level doc comment.
    function claim(uint256 campaignSeed, uint256 participantSeed) external {
        if (endedCampaigns.length == 0) return;
        uint256 id = endedCampaigns[bound(campaignSeed, 0, endedCampaigns.length - 1)];
        uint256 idx = bound(participantSeed, 0, NUM_PARTICIPANTS - 1);

        OnChainRewardModule pinned = OnChainRewardModule(pinnedModuleOf[id]);
        vm.prank(participants[idx]);
        pinned.claimReward(id); // reverts (not completed, already claimed, wrong tier) are discarded

        claimAttemptsSucceeded[id][idx] += 1;
        ghost_totalClaimed += tierAmountOf[id];
    }

    /// @dev Admin rotates the GLOBAL default module. Campaigns already pinned must stay pinned to
    /// their original module; only campaigns created AFTER this call adopt the new one.
    function rotateGlobalModule() external {
        OnChainRewardModule fresh = new OnChainRewardModule(address(campaigns));
        vm.prank(deployer);
        campaigns.setOnChainRewardModule(address(fresh));
        currentModule = fresh;
    }

    // --- views for the invariant contract ---
    function openCount() external view returns (uint256) {
        return openCampaigns.length;
    }

    function openAt(uint256 i) external view returns (uint256) {
        return openCampaigns[i];
    }

    function endedCount() external view returns (uint256) {
        return endedCampaigns.length;
    }

    function endedAt(uint256 i) external view returns (uint256) {
        return endedCampaigns[i];
    }
}
