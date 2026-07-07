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
        vm.expectRevert(CampaignStorage.Web3Campaigns__NotOnChainRewardModule.selector);
        campaigns.payOnChainReward(1, participant1, 1 ether, 1);
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
