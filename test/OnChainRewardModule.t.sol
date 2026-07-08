// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {Web3Campaigns} from "../src/Web3Campaigns.sol";
import {OnChainRewardModule} from "../src/OnChainRewardModule.sol";
import {CampaignStorage} from "../src/CampaignStorage.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/// @notice Covers the two-contract on-chain reward tier architecture: Web3Campaigns (fund
/// custody + core campaign state) paired with the standalone OnChainRewardModule (rank/score
/// bookkeeping, tier config, claim computation), wired together via setOnChainRewardModule /
/// setSettlementMode / notifyTaskCompletion / payOnChainReward.
contract OnChainRewardModuleTest is Test {
    Web3Campaigns public campaigns;
    OnChainRewardModule public module;
    ERC20Mock public token;

    address public deployer;
    address public host1;
    address public participant1;
    address public participant2;
    address public participant3;

    uint256 constant START_OFFSET = 1 days;
    uint256 constant CAMPAIGN_DURATION = 7 days;

    function setUp() public {
        vm.warp(1_000_000);

        deployer = vm.addr(1);
        host1 = vm.addr(2);
        participant1 = vm.addr(3);
        participant2 = vm.addr(4);
        participant3 = vm.addr(5);

        vm.startPrank(deployer);
        campaigns = new Web3Campaigns();
        module = new OnChainRewardModule(address(campaigns));
        campaigns.setOnChainRewardModule(address(module));
        campaigns.grantHostRole(host1);
        vm.stopPrank();

        token = new ERC20Mock();
        token.mint(host1, 1_000_000 ether);
    }

    /*//////////////////////////////////////////////////////////////
                              SETUP HELPERS
    //////////////////////////////////////////////////////////////*/

    function _draftCampaign() internal returns (uint256 id, uint256 startTime, uint256 endTime) {
        startTime = block.timestamp + START_OFFSET;
        endTime = startTime + CAMPAIGN_DURATION;

        vm.prank(host1);
        id = campaigns.createCampaign("C", startTime, endTime);
    }

    function _addSocialTask(uint256 id) internal {
        vm.prank(host1);
        campaigns.addTaskToCampaign(id, CampaignStorage.TaskType.SOCIAL_FOLLOW, "Follow us", "", false);
    }

    function _fundEscrow(uint256 id, uint256 amount) internal {
        vm.startPrank(host1);
        token.approve(address(campaigns), amount);
        campaigns.fundCampaignERC20(id, amount);
        vm.stopPrank();
    }

    function _openCampaign(uint256 id, uint256 startTime) internal {
        vm.warp(startTime + 1);
        vm.prank(host1);
        campaigns.openCampaign(id);
    }

    function _endCampaign(uint256 id, uint256 endTime) internal {
        vm.warp(endTime + 1);
        vm.prank(host1);
        campaigns.endCampaign(id);
    }

    /*//////////////////////////////////////////////////////////////
                          RANK_TIERED END-TO-END
    //////////////////////////////////////////////////////////////*/

    function test_RankTiered_FirstCompleterGetsTopTier() public {
        (uint256 id, uint256 startTime, uint256 endTime) = _draftCampaign();
        _addSocialTask(id);

        vm.prank(host1);
        campaigns.configureERC20Reward(id, address(token));

        uint256[] memory startRanks = new uint256[](2);
        uint256[] memory endRanks = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        startRanks[0] = 1;
        endRanks[0] = 1;
        amounts[0] = 100 ether;
        startRanks[1] = 2;
        endRanks[1] = 3;
        amounts[1] = 10 ether;

        vm.prank(host1);
        module.setRankTiers(id, startRanks, endRanks, amounts);

        _fundEscrow(id, 120 ether);
        _openCampaign(id, startTime);

        vm.prank(participant1);
        campaigns.completeTask(id, 0);
        vm.prank(participant2);
        campaigns.completeTask(id, 0);

        _endCampaign(id, endTime);

        vm.prank(participant1);
        module.claimReward(id);
        assertEq(token.balanceOf(participant1), 100 ether);

        vm.prank(participant2);
        module.claimReward(id);
        assertEq(token.balanceOf(participant2), 10 ether);

        (, uint256 rank1,,, bool claimed1) = module.getOnChainRewardStatus(id, participant1);
        assertEq(rank1, 1);
        assertTrue(claimed1);
    }

    function test_RankTiered_DoubleClaimReverts() public {
        (uint256 id, uint256 startTime, uint256 endTime) = _draftCampaign();
        _addSocialTask(id);

        vm.prank(host1);
        campaigns.configureERC20Reward(id, address(token));

        uint256[] memory startRanks = new uint256[](1);
        uint256[] memory endRanks = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        startRanks[0] = 1;
        endRanks[0] = 5;
        amounts[0] = 50 ether;

        vm.prank(host1);
        module.setRankTiers(id, startRanks, endRanks, amounts);

        _fundEscrow(id, 50 ether);
        _openCampaign(id, startTime);

        vm.prank(participant1);
        campaigns.completeTask(id, 0);

        _endCampaign(id, endTime);

        vm.prank(participant1);
        module.claimReward(id);

        vm.expectRevert(CampaignStorage.Web3Campaigns__AlreadyClaimedSettlement.selector);
        vm.prank(participant1);
        module.claimReward(id);
    }

    function test_RankTiered_UnrankedParticipantReverts() public {
        (uint256 id, uint256 startTime, uint256 endTime) = _draftCampaign();
        _addSocialTask(id);

        vm.prank(host1);
        campaigns.configureERC20Reward(id, address(token));

        uint256[] memory startRanks = new uint256[](1);
        uint256[] memory endRanks = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        startRanks[0] = 1;
        endRanks[0] = 5;
        amounts[0] = 50 ether;

        vm.prank(host1);
        module.setRankTiers(id, startRanks, endRanks, amounts);

        _fundEscrow(id, 50 ether);
        _openCampaign(id, startTime);
        _endCampaign(id, endTime);

        vm.expectRevert(CampaignStorage.Web3Campaigns__NotFullyCompleted.selector);
        vm.prank(participant3);
        module.claimReward(id);
    }

    /*//////////////////////////////////////////////////////////////
                          SCORE_TIERED END-TO-END
    //////////////////////////////////////////////////////////////*/

    function test_ScoreTiered_TaskPointsDriveTierMatch() public {
        (uint256 id, uint256 startTime, uint256 endTime) = _draftCampaign();
        _addSocialTask(id);
        _addSocialTask(id);

        vm.prank(host1);
        campaigns.configureERC20Reward(id, address(token));

        uint256[] memory taskIndices = new uint256[](2);
        uint256[] memory points = new uint256[](2);
        taskIndices[0] = 0;
        points[0] = 10;
        taskIndices[1] = 1;
        points[1] = 20;

        vm.prank(host1);
        module.setTaskPoints(id, taskIndices, points);

        uint256[] memory minScores = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        minScores[0] = 30;
        amounts[0] = 100 ether;
        minScores[1] = 10;
        amounts[1] = 20 ether;

        vm.prank(host1);
        module.setScoreTiers(id, minScores, amounts);

        _fundEscrow(id, 120 ether);
        _openCampaign(id, startTime);

        // participant1 completes both tasks -> score 30 -> top tier. completeTask enforces a 30s
        // per-user anti-spam cooldown, so the two completions must straddle it.
        vm.prank(participant1);
        campaigns.completeTask(id, 0);
        vm.warp(block.timestamp + 31);
        vm.prank(participant1);
        campaigns.completeTask(id, 1);

        // participant2 completes only the first task -> score 10 -> second tier.
        vm.prank(participant2);
        campaigns.completeTask(id, 0);

        _endCampaign(id, endTime);

        vm.prank(participant1);
        module.claimReward(id);
        assertEq(token.balanceOf(participant1), 100 ether);

        vm.prank(participant2);
        module.claimReward(id);
        assertEq(token.balanceOf(participant2), 20 ether);
    }

    function test_ScoreTiered_BelowLowestTierReverts() public {
        (uint256 id, uint256 startTime, uint256 endTime) = _draftCampaign();
        _addSocialTask(id);

        vm.prank(host1);
        campaigns.configureERC20Reward(id, address(token));

        uint256[] memory taskIndices = new uint256[](1);
        uint256[] memory points = new uint256[](1);
        taskIndices[0] = 0;
        points[0] = 5;

        vm.prank(host1);
        module.setTaskPoints(id, taskIndices, points);

        uint256[] memory minScores = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        minScores[0] = 10;
        amounts[0] = 100 ether;

        vm.prank(host1);
        module.setScoreTiers(id, minScores, amounts);

        _fundEscrow(id, 100 ether);
        _openCampaign(id, startTime);

        vm.prank(participant1);
        campaigns.completeTask(id, 0);

        _endCampaign(id, endTime);

        vm.expectRevert(CampaignStorage.Web3Campaigns__NoTierMatched.selector);
        vm.prank(participant1);
        module.claimReward(id);
    }

    /*//////////////////////////////////////////////////////////////
                       MODE EXCLUSIVITY / ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    /// @notice Configuring the reward token does NOT commit the campaign to MERKLE (token config is
    /// common to all three settlement paths), so a host can configure the token and then still
    /// commit the campaign to RANK_TIERED. This is the case the old MERKLE-on-configure coupling
    /// wrongly blocked.
    function test_ConfiguringTokenDoesNotForeCloseRankTiered() public {
        (uint256 id,,) = _draftCampaign();

        vm.prank(host1);
        campaigns.configureERC20Reward(id, address(token));

        uint256[] memory startRanks = new uint256[](1);
        uint256[] memory endRanks = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        startRanks[0] = 1;
        endRanks[0] = 1;
        amounts[0] = 10 ether;

        // Succeeds: no mode was committed by configureERC20Reward.
        vm.prank(host1);
        module.setRankTiers(id, startRanks, endRanks, amounts);

        (CampaignStorage.ERC20SettlementMode mode,,,,) = module.getOnChainRewardStatus(id, participant1);
        assertEq(uint256(mode), uint256(CampaignStorage.ERC20SettlementMode.RANK_TIERED));
    }

    /// @notice The MERKLE and on-chain-tiered paths remain mutually exclusive on a single campaign:
    /// once a campaign commits to RANK_TIERED, publishing a Merkle root (the MERKLE-committing
    /// action) reverts, so the same escrow can never be settled two different ways.
    function test_ModeExclusivity_CannotSetMerkleRootAfterRankTiered() public {
        (uint256 id, uint256 startTime, uint256 endTime) = _draftCampaign();
        _addSocialTask(id);

        vm.prank(host1);
        campaigns.configureERC20Reward(id, address(token));

        uint256[] memory startRanks = new uint256[](1);
        uint256[] memory endRanks = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        startRanks[0] = 1;
        endRanks[0] = 1;
        amounts[0] = 10 ether;

        vm.prank(host1);
        module.setRankTiers(id, startRanks, endRanks, amounts); // commits RANK_TIERED

        _fundEscrow(id, 10 ether);
        _openCampaign(id, startTime);
        _endCampaign(id, endTime);

        vm.expectRevert(CampaignStorage.Web3Campaigns__SettlementModeAlreadySet.selector);
        vm.prank(host1);
        campaigns.setERC20MerkleRoot(id, bytes32(uint256(1)));
    }

    function test_ModeExclusivity_CannotSwitchFromRankTieredToScoreTiered() public {
        (uint256 id,,) = _draftCampaign();

        uint256[] memory startRanks = new uint256[](1);
        uint256[] memory endRanks = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        startRanks[0] = 1;
        endRanks[0] = 1;
        amounts[0] = 10 ether;

        vm.prank(host1);
        module.setRankTiers(id, startRanks, endRanks, amounts);

        uint256[] memory minScores = new uint256[](1);
        uint256[] memory scoreAmounts = new uint256[](1);
        minScores[0] = 5;
        scoreAmounts[0] = 10 ether;

        vm.expectRevert(CampaignStorage.Web3Campaigns__SettlementModeAlreadySet.selector);
        vm.prank(host1);
        module.setScoreTiers(id, minScores, scoreAmounts);
    }

    function test_OnlyHostCanConfigureTiers() public {
        (uint256 id,,) = _draftCampaign();

        uint256[] memory startRanks = new uint256[](1);
        uint256[] memory endRanks = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        startRanks[0] = 1;
        endRanks[0] = 1;
        amounts[0] = 10 ether;

        vm.expectRevert(OnChainRewardModule.OnChainRewardModule__NotCampaignHost.selector);
        vm.prank(participant1);
        module.setRankTiers(id, startRanks, endRanks, amounts);
    }

    function test_OnlyRegisteredModuleCanCallSetSettlementMode() public {
        vm.expectRevert(CampaignStorage.Web3Campaigns__NotOnChainRewardModule.selector);
        campaigns.setSettlementMode(1, CampaignStorage.ERC20SettlementMode.RANK_TIERED);
    }

    function test_OnlyRegisteredModuleCanCallPayOnChainReward() public {
        // Campaign 1 has never adopted an on-chain mode, so it has no pinned module. The per-campaign
        // authorization check runs first and rejects any caller against the address(0) pin.
        vm.expectRevert(
            abi.encodeWithSelector(
                CampaignStorage.Web3Campaigns__RewardModuleMismatch.selector, uint256(1), address(0), address(this)
            )
        );
        campaigns.payOnChainReward(1, participant1, 1 ether, 1);
    }

    /// @dev Full RANK_TIERED setup through Ended, funded, with `module` pinned as authoritative.
    function _pinnedEndedRankCampaign() internal returns (uint256 id) {
        uint256 startTime;
        uint256 endTime;
        (id, startTime, endTime) = _draftCampaign();
        _addSocialTask(id);

        vm.prank(host1);
        campaigns.configureERC20Reward(id, address(token));

        uint256[] memory startRanks = new uint256[](1);
        uint256[] memory endRanks = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        startRanks[0] = 1;
        endRanks[0] = 5;
        amounts[0] = 50 ether;

        vm.prank(host1);
        module.setRankTiers(id, startRanks, endRanks, amounts); // pins `module` to this campaign

        _fundEscrow(id, 50 ether);
        _openCampaign(id, startTime);
        _endCampaign(id, endTime);
    }

    function test_PayOnChainReward_SucceedsFromPinnedModule() public {
        uint256 id = _pinnedEndedRankCampaign();
        assertEq(campaigns.getCampaignRewardModule(id), address(module));

        vm.prank(address(module));
        campaigns.payOnChainReward(id, participant1, 10 ether, 1);

        assertEq(token.balanceOf(participant1), 10 ether);
    }

    function test_PayOnChainReward_RevertsFromNonPinnedAddress() public {
        uint256 id = _pinnedEndedRankCampaign();

        address intruder = vm.addr(42);
        vm.expectRevert(
            abi.encodeWithSelector(
                CampaignStorage.Web3Campaigns__RewardModuleMismatch.selector, id, address(module), intruder
            )
        );
        vm.prank(intruder);
        campaigns.payOnChainReward(id, participant1, 10 ether, 1);
    }

    /// @notice The actual rotation scenario: after the admin rotates the GLOBAL module to a new
    /// address, that new global module is still NOT this campaign's pinned module, so it cannot pay
    /// out -- proving the per-campaign pin binds independently of the mutable global pointer, and
    /// that the per-campaign check fires ahead of the global one (the rotated-in module would have
    /// passed the old global check).
    function test_PayOnChainReward_RevertsFromRotatedGlobalModule() public {
        uint256 id = _pinnedEndedRankCampaign();

        address newGlobalModule = vm.addr(99);
        vm.prank(deployer);
        campaigns.setOnChainRewardModule(newGlobalModule);

        vm.expectRevert(
            abi.encodeWithSelector(
                CampaignStorage.Web3Campaigns__RewardModuleMismatch.selector, id, address(module), newGlobalModule
            )
        );
        vm.prank(newGlobalModule);
        campaigns.payOnChainReward(id, participant1, 10 ether, 1);
    }

    /// @notice The core guarantee of the pin: after the global default is rotated away to another
    /// address, the campaign's ORIGINAL pinned module can STILL settle it. Before check 2 (the
    /// global-module gate) was removed this reverted NotOnChainRewardModule and stranded the
    /// campaign; now the per-campaign pin alone authorizes the payout, so it must succeed.
    function test_PayOnChainReward_PinnedModuleStillPaysAfterRotation() public {
        uint256 id = _pinnedEndedRankCampaign();

        address newGlobalModule = vm.addr(99);
        vm.prank(deployer);
        campaigns.setOnChainRewardModule(newGlobalModule);

        // `module` is no longer the global default, but is still this campaign's pinned module.
        vm.prank(address(module));
        campaigns.payOnChainReward(id, participant1, 10 ether, 1);

        assertEq(token.balanceOf(participant1), 10 ether);
        assertEq(campaigns.getCampaignRewardModule(id), address(module));
    }

    /// @notice An unpinned campaign (never adopted an on-chain mode) has pin == address(0), so the
    /// sole per-campaign check rejects EVERY caller -- including the currently-registered global
    /// module -- with RewardModuleMismatch. Confirms removing check 2 opened no path to paying out
    /// an unpinned campaign.
    function test_PayOnChainReward_UnpinnedCampaignRejectsAllCallers() public {
        (uint256 id,,) = _draftCampaign(); // no tiers set -> _campaignRewardModule[id] == address(0)
        assertEq(campaigns.getCampaignRewardModule(id), address(0));

        // Even the registered global module is rejected, because this campaign pinned no module.
        vm.expectRevert(
            abi.encodeWithSelector(
                CampaignStorage.Web3Campaigns__RewardModuleMismatch.selector, id, address(0), address(module)
            )
        );
        vm.prank(address(module));
        campaigns.payOnChainReward(id, participant1, 1 ether, 0);

        // And so is an arbitrary address.
        address intruder = vm.addr(42);
        vm.expectRevert(
            abi.encodeWithSelector(
                CampaignStorage.Web3Campaigns__RewardModuleMismatch.selector, id, address(0), intruder
            )
        );
        vm.prank(intruder);
        campaigns.payOnChainReward(id, participant1, 1 ether, 0);
    }

    /// @notice claimReward's self-check: a module that is NOT the campaign's authoritative (pinned)
    /// module reverts NotAuthoritativeModule before evaluating any rank/score/tier state.
    /// @dev Defense-in-depth. Because a campaign's pin is fixed at adoption and can't currently be
    /// reassigned, there is no live attack path today: the only way to get pin != address(this) is
    /// to route the claim through a DIFFERENT deployed module (here M2, freshly rotated in as the
    /// global default) that never governed this campaign. Such a module would also fail the later
    /// mode gate; the self-check just makes it fail fast with a precise, module-specific error.
    function test_ClaimReward_NonAuthoritativeModuleReverts() public {
        uint256 id = _pinnedEndedRankCampaign(); // pinned to `module` (M1)

        // A second module instance is rotated in as the global default; the campaign stays pinned
        // to M1, so M2 is not authoritative for it.
        OnChainRewardModule m2 = new OnChainRewardModule(address(campaigns));
        vm.prank(deployer);
        campaigns.setOnChainRewardModule(address(m2));
        assertEq(campaigns.getCampaignRewardModule(id), address(module));

        vm.expectRevert(OnChainRewardModule.OnChainRewardModule__NotAuthoritativeModule.selector);
        vm.prank(participant1);
        m2.claimReward(id);
    }

    function test_OnlyWeb3CampaignsCanNotifyModule() public {
        vm.expectRevert(OnChainRewardModule.OnChainRewardModule__NotWeb3Campaigns.selector);
        module.notifyTaskCompletion(1, participant1, 0, true, true);
    }

    function test_OnlyAdminCanRotateModule() public {
        vm.expectRevert();
        vm.prank(host1);
        campaigns.setOnChainRewardModule(address(0x1234));
    }

    /*//////////////////////////////////////////////////////////////
                       SIGNER REVOCATION DISQUALIFIES
    //////////////////////////////////////////////////////////////*/

    function test_RankTiered_SignerRevocationBlocksClaimDespiteHistoricalRank() public {
        (uint256 id, uint256 startTime, uint256 endTime) = _draftCampaign();
        _addSocialTask(id);

        vm.prank(host1);
        campaigns.configureERC20Reward(id, address(token));

        uint256[] memory startRanks = new uint256[](1);
        uint256[] memory endRanks = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        startRanks[0] = 1;
        endRanks[0] = 5;
        amounts[0] = 50 ether;

        vm.prank(host1);
        module.setRankTiers(id, startRanks, endRanks, amounts);

        _fundEscrow(id, 50 ether);
        _openCampaign(id, startTime);

        vm.prank(participant1);
        campaigns.completeTask(id, 0);

        // Signer revokes the completion via a signed attestation (completed = false).
        uint256 deadline = block.timestamp + 1 hours;
        uint256 version = 1; // first attestation for this (participant, campaign, task)
        bytes32 digest = _attestationDigest(id, participant1, 0, false, version, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(1, digest); // deployer holds SIGNER_ROLE by default
        bytes memory sig = abi.encodePacked(r, s, v);

        campaigns.verifyTaskCompletionWithSignature(id, participant1, 0, false, deadline, sig);

        _endCampaign(id, endTime);

        vm.expectRevert(CampaignStorage.Web3Campaigns__NotFullyCompleted.selector);
        vm.prank(participant1);
        module.claimReward(id);

        (,,, bool qualified,) = module.getOnChainRewardStatus(id, participant1);
        assertFalse(qualified);
    }

    /// @notice The immutability invariant that makes notifyTaskCompletion's checked `-= points`
    /// unable to underflow: task points can be configured only while the campaign is Draft, and the
    /// lifecycle is strictly forward, so the value credited at completion (Open/Ended) is the exact
    /// value debited at revoke.
    function test_SetTaskPoints_RevertsOnceCampaignLeavesDraft() public {
        (uint256 id, uint256 startTime,) = _draftCampaign();
        _addSocialTask(id);

        vm.prank(host1);
        campaigns.configureERC20Reward(id, address(token));

        uint256[] memory taskIndices = new uint256[](1);
        uint256[] memory points = new uint256[](1);
        taskIndices[0] = 0;
        points[0] = 10;
        vm.prank(host1);
        module.setTaskPoints(id, taskIndices, points); // allowed while Draft

        _fundEscrow(id, 1 ether);
        _openCampaign(id, startTime);

        // Once the campaign has left Draft, points can never be reconfigured again.
        points[0] = 999;
        vm.expectRevert(OnChainRewardModule.OnChainRewardModule__CampaignAlreadyStarted.selector);
        vm.prank(host1);
        module.setTaskPoints(id, taskIndices, points);
    }

    /// @notice Exercises the checked `-= points` on the live revoke path: a completion credits the
    /// score, a signer revocation debits it, and the running score returns to EXACTLY its
    /// pre-completion value -- no underflow, no unexpected revert.
    function test_ScoreTiered_RevokeRestoresScoreExactly() public {
        (uint256 id, uint256 startTime,) = _draftCampaign();
        _addSocialTask(id);

        vm.prank(host1);
        campaigns.configureERC20Reward(id, address(token));

        uint256[] memory taskIndices = new uint256[](1);
        uint256[] memory points = new uint256[](1);
        taskIndices[0] = 0;
        points[0] = 10;
        vm.prank(host1);
        module.setTaskPoints(id, taskIndices, points);

        uint256[] memory minScores = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        minScores[0] = 10;
        amounts[0] = 100 ether;
        vm.prank(host1);
        module.setScoreTiers(id, minScores, amounts); // commits SCORE_TIERED

        _fundEscrow(id, 100 ether);
        _openCampaign(id, startTime);

        // Complete -> score credited (+10).
        vm.prank(participant1);
        campaigns.completeTask(id, 0);
        (,, uint256 scoreAfterComplete,,) = module.getOnChainRewardStatus(id, participant1);
        assertEq(scoreAfterComplete, 10);

        // Signer revokes the same task -> checked `-= points` runs.
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _attestationDigest(id, participant1, 0, false, 1, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(1, digest); // deployer holds SIGNER_ROLE by default
        bytes memory sig = abi.encodePacked(r, s, v);
        campaigns.verifyTaskCompletionWithSignature(id, participant1, 0, false, deadline, sig);

        (,, uint256 scoreAfterRevoke,,) = module.getOnChainRewardStatus(id, participant1);
        assertEq(scoreAfterRevoke, 0);
    }

    /// @notice Regression for the notify-routing desync: a completion after the global default is
    /// rotated mid-campaign is bookkept by the campaign's PINNED module, not the rotated-in global
    /// one -- so rank/score/qualification state stays with the module that will settle the claim.
    /// Before the fix (notify read the global _onChainRewardModule) this state landed on the wrong
    /// module and the pinned module's claim would see the participant as unranked/unqualified.
    function test_Notify_RoutesToPinnedModuleAfterGlobalRotation() public {
        (uint256 id, uint256 startTime,) = _draftCampaign();
        _addSocialTask(id);

        vm.prank(host1);
        campaigns.configureERC20Reward(id, address(token));

        uint256[] memory startRanks = new uint256[](1);
        uint256[] memory endRanks = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        startRanks[0] = 1;
        endRanks[0] = 5;
        amounts[0] = 50 ether;
        vm.prank(host1);
        module.setRankTiers(id, startRanks, endRanks, amounts); // pins `module` (A)

        _fundEscrow(id, 50 ether);
        _openCampaign(id, startTime);

        // Admin rotates the GLOBAL default to a different module B; the campaign stays pinned to A.
        OnChainRewardModule b = new OnChainRewardModule(address(campaigns));
        vm.prank(deployer);
        campaigns.setOnChainRewardModule(address(b));

        // The completion must be recorded by the pinned module A...
        vm.prank(participant1);
        campaigns.completeTask(id, 0);

        (, uint256 rankA,, bool qualifiedA,) = module.getOnChainRewardStatus(id, participant1);
        assertEq(rankA, 1);
        assertTrue(qualifiedA);

        // ...and NOT by the rotated-in global module B.
        (, uint256 rankB,, bool qualifiedB,) = b.getOnChainRewardStatus(id, participant1);
        assertEq(rankB, 0);
        assertFalse(qualifiedB);
    }

    /// @notice Revoking an OPTIONAL task must NOT disqualify a RANK_TIERED participant who still
    /// holds every required task. Before the fix, hasAllRequired was gated by _nowCompleted so
    /// it was always false on revoke, and the module unconditionally set _currentlyQualified=false.
    function test_RankTiered_OptionalTaskRevokeKeepsQualified() public {
        (uint256 id, uint256 startTime, uint256 endTime) = _draftCampaign();
        // task0: required; task1: optional
        _addSocialTask(id);
        vm.prank(host1);
        campaigns.addTaskToCampaign(id, CampaignStorage.TaskType.SOCIAL_FOLLOW, "Optional task", "", true);

        vm.prank(host1);
        campaigns.configureERC20Reward(id, address(token));

        uint256[] memory startRanks = new uint256[](1);
        uint256[] memory endRanks = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        startRanks[0] = 1;
        endRanks[0] = 5;
        amounts[0] = 50 ether;
        vm.prank(host1);
        module.setRankTiers(id, startRanks, endRanks, amounts);

        _fundEscrow(id, 50 ether);
        _openCampaign(id, startTime);

        // participant1 completes both tasks; they become qualified (rank 1)
        vm.prank(participant1);
        campaigns.completeTask(id, 0);
        vm.warp(block.timestamp + 5 minutes + 1);
        vm.prank(participant1);
        campaigns.completeTask(id, 1);

        (,,, bool qualifiedBefore,) = module.getOnChainRewardStatus(id, participant1);
        assertTrue(qualifiedBefore);

        // Signer revokes the OPTIONAL task; participant1 still has the required task
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _attestationDigest(id, participant1, 1, false, 1, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(1, digest);
        bytes memory sig = abi.encodePacked(r, s, v);
        campaigns.verifyTaskCompletionWithSignature(id, participant1, 1, false, deadline, sig);

        // Qualification must survive — only the optional task was revoked
        (,,, bool qualifiedAfter,) = module.getOnChainRewardStatus(id, participant1);
        assertTrue(qualifiedAfter);

        // Claim succeeds because the participant is still qualified
        _endCampaign(id, endTime);
        vm.prank(participant1);
        module.claimReward(id);
        assertEq(token.balanceOf(participant1), 50 ether);
    }

    /// @notice The Web3Campaigns-level double-claim guard in payOnChainReward must fire even when
    /// called directly by the pinned module (bypassing the module's own _onChainRewardClaimed
    /// check). This defends against a compromised module that omits its own guard.
    function test_PayOnChainReward_DirectDoubleClaimReverts() public {
        (uint256 id, uint256 startTime, uint256 endTime) = _draftCampaign();
        _addSocialTask(id);

        vm.prank(host1);
        campaigns.configureERC20Reward(id, address(token));

        uint256[] memory startRanks = new uint256[](1);
        uint256[] memory endRanks = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        startRanks[0] = 1;
        endRanks[0] = 5;
        amounts[0] = 50 ether;
        vm.prank(host1);
        module.setRankTiers(id, startRanks, endRanks, amounts);

        _fundEscrow(id, 50 ether);
        _openCampaign(id, startTime);

        vm.prank(participant1);
        campaigns.completeTask(id, 0);

        _endCampaign(id, endTime);

        // First direct call (as pinned module) succeeds
        vm.prank(address(module));
        campaigns.payOnChainReward(id, participant1, 1 ether, 1);

        // Second direct call for the same participant hits the Web3Campaigns-level guard
        vm.expectRevert(CampaignStorage.Web3Campaigns__AlreadyClaimedSettlement.selector);
        vm.prank(address(module));
        campaigns.payOnChainReward(id, participant1, 1 ether, 1);
    }

    function _attestationDigest(
        uint256 campaignId,
        address participant,
        uint256 taskIndex,
        bool completed,
        uint256 version,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                campaigns.TASK_ATTESTATION_TYPEHASH(), campaignId, participant, taskIndex, completed, version, deadline
            )
        );
        bytes32 domainSeparator = _domainSeparator();
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Web3Campaigns")),
                keccak256(bytes("1")),
                block.chainid,
                address(campaigns)
            )
        );
    }
}
