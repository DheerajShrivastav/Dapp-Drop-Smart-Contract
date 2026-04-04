// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {Web3Campaigns} from "../src/Web3Campaigns.sol";
import {CampaignStorage} from "../src/CampaignStorage.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC721ConsecutiveMock} from "@openzeppelin/contracts/mocks/token/ERC721ConsecutiveMock.sol";

contract CampaignLifecycleTest is Test {
    Web3Campaigns public campaigns;

    address public deployer;
    address public host1;
    address public nonHost;
    address public participant1;
    address public participant2;

    ERC20Mock public mockERC20;
    ERC721ConsecutiveMock public mockERC721;

    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant HOST_ROLE = keccak256("HOST_ROLE");

    // Realistic time offsets
    uint256 constant START_OFFSET = 1 days;
    uint256 constant CAMPAIGN_DURATION = 7 days;

    function setUp() public {
        // Warp to a realistic timestamp so rate limiting doesn't block tests
        vm.warp(1_000_000);

        deployer = vm.addr(1);
        host1 = vm.addr(2);
        nonHost = vm.addr(3);
        participant1 = vm.addr(4);
        participant2 = vm.addr(5);

        vm.startPrank(deployer);
        campaigns = new Web3Campaigns();
        vm.stopPrank();

        mockERC20 = new ERC20Mock();

        address[] memory delegates = new address[](1);
        delegates[0] = host1;
        address[] memory receivers = new address[](1);
        receivers[0] = host1;
        uint96[] memory amounts = new uint96[](1);
        amounts[0] = 1000;
        mockERC721 = new ERC721ConsecutiveMock(
            "MockNFT",
            "MNFT",
            0,
            delegates,
            receivers,
            amounts
        );

        vm.startPrank(deployer);
        campaigns.grantHostRole(host1);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                           CAMPAIGN LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    function test_CreateCampaign_Success() public {
        uint256 startTime = block.timestamp + START_OFFSET;
        uint256 endTime = startTime + CAMPAIGN_DURATION;

        vm.prank(host1);
        uint256 campaignId = campaigns.createCampaign(
            "Test Campaign",
            startTime,
            endTime
        );

        Web3Campaigns.Campaign memory campaign = campaigns.getCampaign(campaignId);

        assertEq(campaign.id, campaignId);
        assertEq(campaign.name, "Test Campaign");
        assertEq(campaign.host, host1);
        assertEq(campaign.startTime, startTime);
        assertEq(campaign.endTime, endTime);
    }

    function test_CreateCampaign_RevertsIfIncorrectTime() public {
        vm.startPrank(host1);

        // Start time in the past
        vm.expectRevert(CampaignStorage.Web3Campaigns__CampaignStartTimeNotYetStarted.selector);
        campaigns.createCampaign("Invalid Campaign 1", 900, 1200);

        // End time before start time
        vm.expectRevert(CampaignStorage.Web3Campaigns__InvalidCampaignDuration.selector);
        campaigns.createCampaign(
            "Invalid Campaign 2",
            block.timestamp + START_OFFSET,
            block.timestamp + 50
        );
        vm.stopPrank();
    }

    function test_OpenCampaign_Success() public {
        uint256 startTime = block.timestamp + START_OFFSET;
        uint256 endTime = startTime + CAMPAIGN_DURATION;

        vm.prank(host1);
        uint256 campaignId = campaigns.createCampaign("Campaign to Open", startTime, endTime);

        vm.warp(startTime + 1);
        vm.prank(host1);
        campaigns.openCampaign(campaignId);

        Web3Campaigns.Campaign memory campaign = campaigns.getCampaign(campaignId);
        assertEq(uint8(campaign.status), uint8(CampaignStorage.CampaignStatus.Open));
    }

    function test_OpenCampaign_RevertsIfNotHost() public {
        uint256 startTime = block.timestamp + START_OFFSET;
        uint256 endTime = startTime + CAMPAIGN_DURATION;

        vm.prank(host1);
        uint256 campaignId = campaigns.createCampaign("Campaign for Revert Test", startTime, endTime);

        vm.warp(startTime + 1);
        vm.prank(nonHost);
        vm.expectRevert(CampaignStorage.Web3Campaigns__CallerIsNotHost.selector);
        campaigns.openCampaign(campaignId);
    }

    function test_OpenCampaign_RevertsIfAlreadyOpen() public {
        uint256 startTime = block.timestamp + START_OFFSET;
        uint256 endTime = startTime + CAMPAIGN_DURATION;

        vm.prank(host1);
        uint256 campaignId = campaigns.createCampaign("Campaign for Time Revert", startTime, endTime);

        vm.warp(startTime + 1);
        vm.prank(host1);
        campaigns.openCampaign(campaignId);

        // Try to open again
        vm.prank(host1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__CampaignAlreadyStarted.selector);
        campaigns.openCampaign(campaignId);
    }

    function test_EndCampaign_Success() public {
        uint256 startTime = block.timestamp + START_OFFSET;
        uint256 endTime = startTime + CAMPAIGN_DURATION;

        vm.prank(host1);
        uint256 campaignId = campaigns.createCampaign("Campaign to End", startTime, endTime);

        vm.warp(startTime + 1);
        vm.prank(host1);
        campaigns.openCampaign(campaignId);

        vm.warp(endTime + 1);
        vm.prank(host1);
        campaigns.endCampaign(campaignId);

        Web3Campaigns.Campaign memory campaign = campaigns.getCampaign(campaignId);
        assertEq(uint8(campaign.status), uint8(CampaignStorage.CampaignStatus.Ended));
    }

    function test_EndCampaign_RevertsIfTimeNotEnded() public {
        uint256 startTime = block.timestamp + START_OFFSET;
        uint256 endTime = startTime + CAMPAIGN_DURATION;

        vm.prank(host1);
        uint256 campaignId = campaigns.createCampaign("Campaign for Revert End", startTime, endTime);

        vm.warp(startTime + 1);
        vm.prank(host1);
        campaigns.openCampaign(campaignId);

        // Try to end before end time
        vm.prank(host1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__CampaignNotYetEnded.selector);
        campaigns.endCampaign(campaignId);
    }

    function test_GrantHostRole_Success() public {
        address newHost = makeAddr("newHost");
        vm.prank(deployer);
        campaigns.grantHostRole(newHost);
        assertTrue(campaigns.hasRole(HOST_ROLE, newHost));
    }

    /*//////////////////////////////////////////////////////////////
                            BATCH OPERATIONS
    //////////////////////////////////////////////////////////////*/

    function test_BatchAddTasks_Success() public {
        uint256 startTime = block.timestamp + START_OFFSET;
        uint256 endTime = startTime + CAMPAIGN_DURATION;

        vm.prank(host1);
        uint256 campaignId = campaigns.createCampaign("Batch Task Campaign", startTime, endTime);

        CampaignStorage.TaskType[] memory taskTypes = new CampaignStorage.TaskType[](3);
        taskTypes[0] = CampaignStorage.TaskType.SOCIAL_FOLLOW;
        taskTypes[1] = CampaignStorage.TaskType.SOCIAL_LIKE;
        taskTypes[2] = CampaignStorage.TaskType.DISCORD_JOIN;

        string[] memory descriptions = new string[](3);
        descriptions[0] = "Follow us on Twitter";
        descriptions[1] = "Like our post";
        descriptions[2] = "Join our Discord";

        bytes[] memory verificationData = new bytes[](3);
        verificationData[0] = "";
        verificationData[1] = "";
        verificationData[2] = "";

        bool[] memory isOptional = new bool[](3);
        isOptional[0] = false;
        isOptional[1] = false;
        isOptional[2] = true;

        vm.prank(host1);
        campaigns.batchAddTasks(campaignId, taskTypes, descriptions, verificationData, isOptional);

        Web3Campaigns.Campaign memory campaign = campaigns.getCampaign(campaignId);
        assertEq(campaign.tasks.length, 3);
    }

    function test_BatchVerifyTaskCompletion_Success() public {
        uint256 startTime = block.timestamp + START_OFFSET;
        uint256 endTime = startTime + CAMPAIGN_DURATION;

        vm.prank(host1);
        uint256 campaignId = campaigns.createCampaign("Batch Verify Campaign", startTime, endTime);

        // Add a social task
        vm.prank(host1);
        campaigns.addTaskToCampaign(
            campaignId,
            CampaignStorage.TaskType.SOCIAL_FOLLOW,
            "Follow us",
            "",
            false
        );

        vm.warp(startTime + 1);
        vm.prank(host1);
        campaigns.openCampaign(campaignId);

        // Batch verify for two participants
        address[] memory participants = new address[](2);
        participants[0] = participant1;
        participants[1] = participant2;

        uint256[] memory taskIndices = new uint256[](2);
        taskIndices[0] = 0;
        taskIndices[1] = 0;

        vm.prank(host1);
        campaigns.batchVerifyTaskCompletion(campaignId, participants, taskIndices);

        assertTrue(campaigns.hasCompletedTask(campaignId, participant1, 0));
        assertTrue(campaigns.hasCompletedTask(campaignId, participant2, 0));
    }

    /*//////////////////////////////////////////////////////////////
                            ETH WITHDRAWAL
    //////////////////////////////////////////////////////////////*/

    function test_WithdrawETH_Success() public {
        // Send ETH to the contract
        vm.deal(address(this), 1 ether);
        (bool sent, ) = address(campaigns).call{value: 1 ether}("");
        assertTrue(sent);

        uint256 balBefore = deployer.balance;

        vm.prank(deployer);
        campaigns.withdrawETH(payable(deployer));

        assertEq(deployer.balance - balBefore, 1 ether);
    }
}
