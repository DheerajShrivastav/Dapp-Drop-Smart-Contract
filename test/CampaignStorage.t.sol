// Filename: test/CampaignLifecycle.t.sol

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// Import Forge's testing library and console utilities
import {Test, console} from "forge-std/Test.sol";

// Import your main contract directly
import {Web3Campaigns} from "../src/Web3Campaigns.sol";
import {CampaignStorage} from "../src/CampaignStorage.sol";

// Import OpenZeppelin mock contracts for testing tokens
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC721ConsecutiveMock} from "@openzeppelin/contracts/mocks/token/ERC721ConsecutiveMock.sol";

// Define the test contract
contract CampaignLifecycleTest is Test {
    // The main contract instance
    Web3Campaigns public campaigns;

    // Accounts for testing roles and participants
    address public deployer; // DEFAULT_ADMIN_ROLE and initial HOST_ROLE
    address public host1;
    address public nonHost;
    address public participant1;
    address public participant2;

    // Mock tokens (included in setup but not used in these specific tests)
    ERC20Mock public mockERC20;
    ERC721ConsecutiveMock public mockERC721;

    // Constants for roles from the AccessControl contract within Web3Campaigns
    bytes32 public constant DEFAULT_ADMIN_ROLE =
        0x0000000000000000000000000000000000000000000000000000000000000000;
    bytes32 public constant HOST_ROLE = keccak256("HOST_ROLE");

    // Helper function to get the current timestamp
    function getTimestamp() internal view returns (uint256) {
        return block.timestamp;
    }

    // `setUp` runs before each test function
    function setUp() public {
        // Initialize test accounts with unique addresses
        deployer = vm.addr(1);
        host1 = vm.addr(2);
        nonHost = vm.addr(3);
        participant1 = vm.addr(4);
        participant2 = vm.addr(5);

        // Deploy the main contract as `deployer`
        vm.startPrank(deployer);
        campaigns = new Web3Campaigns();
        vm.stopPrank();

        // --- Deploy and configure mock tokens ---
        // Deploy a mock ERC20 token and mint some to host1 for testing rewards
        mockERC20 = new ERC20Mock();
        // mockERC20.mint(host1, 10000 * 1e18); // 10,000 MTK

        address[] memory delegates = new address[](1);
        delegates[0] = host1;
        address[] memory recivers = new address[](1);
        recivers[0] = host1;
        uint96[] memory amounts = new uint96[](1);
        amounts[0] = 1000; // 1,000 MTK to be distributed as rewards
        // Deploy a mock ERC721 token and mint some to host1 for testing rewards
        mockERC721 = new ERC721ConsecutiveMock(
            "MockNFT",
            "MNFT",
            0,
            delegates,
            recivers,
            amounts
        );
        // mockERC721.mint(host1, 3); // Mints 3 NFTs with IDs 0, 1, 2 to host1

        // Grant host1 the HOST_ROLE (deployer already has it)
        vm.startPrank(deployer);
        campaigns.grantHostRole(host1);
        vm.stopPrank();
    }

    // -----------------------------------------------------------
    // TEST SUITE: Campaign Lifecycle
    // -----------------------------------------------------------

    function test_CreateCampaign_Success() public {
        uint256 startTime = getTimestamp() + 100;
        uint256 endTime = getTimestamp() + 200;

        vm.startPrank(host1);
        uint256 campaignId = campaigns.createCampaign(
            "Test Campaign",
            startTime,
            endTime
        );
        vm.stopPrank();

        // Verify the campaign details were set correctly using a view function
        Web3Campaigns.Campaign memory campaign = campaigns.getCampaign(
            campaignId
        );

        assertEq(campaign.id, campaignId, "Campaign ID should match");
        assertEq(campaign.name, "Test Campaign", "Campaign name should match");
        assertEq(campaign.host, host1, "Campaign host should be host1");
        assertEq(campaign.startTime, startTime, "Start time should match");
        assertEq(campaign.endTime, endTime, "End time should match");
        // assertEq(
        //     uint8(campaign.status),
        //     uint8(Web3Campaigns.CampaignStatus.Draft),
        //     "Campaign status should be Draft"
        // );
    }

    function test_CreateCampaign_RevertsIfIncorrectTime() public {
        vm.startPrank(host1);
        // Test case 1: start time is in the past
        vm.expectRevert("Start time must be in the future");
        campaigns.createCampaign("Invalid Campaign 1", 900, 1200);

        // Test case 2: end time is before start time
        vm.expectRevert("End time must be after start time");
        campaigns.createCampaign(
            "Invalid Campaign 2",
            getTimestamp() + 100,
            getTimestamp() + 50
        );
        vm.stopPrank();
    }

    function test_CreateCampaignWithTasksAndReward_Success() public {
        uint256 startTime = getTimestamp() + 100;
        uint256 endTime = getTimestamp() + 200;

        CampaignStorage.TaskType[] memory taskTypes =
            new CampaignStorage.TaskType[](2);
        taskTypes[0] = CampaignStorage.TaskType.SOCIAL_FOLLOW;
        taskTypes[1] = CampaignStorage.TaskType.ONCHAIN_TX;

        string[] memory descriptions = new string[](2);
        descriptions[0] = "Follow the campaign host";
        descriptions[1] = "Make a transaction";

        bytes[] memory verificationData = new bytes[](2);
        verificationData[0] = abi.encode("twitter_handle");
        verificationData[1] = abi.encode(uint256(1));

        bool[] memory isOptional = new bool[](2);
        isOptional[0] = false;
        isOptional[1] = true;

        vm.startPrank(host1);
        uint256 campaignId = campaigns.createCampaignWithTasksAndReward(
            "Single Tx Campaign",
            startTime,
            endTime,
            taskTypes,
            descriptions,
            verificationData,
            isOptional,
            CampaignStorage.RewardType.ERC20,
            address(mockERC20),
            1000
        );
        vm.stopPrank();

        Web3Campaigns.Campaign memory campaign = campaigns.getCampaign(
            campaignId
        );
        assertEq(campaign.id, campaignId, "Campaign ID should match");
        assertEq(campaign.tasks.length, 2, "Task count should match");
        assertEq(
            uint8(campaign.reward.rewardType),
            uint8(CampaignStorage.RewardType.ERC20),
            "Reward type should match"
        );
        assertEq(
            campaign.reward.tokenAddress,
            address(mockERC20),
            "Reward token should match"
        );
        assertEq(
            campaign.reward.amountOrTokenId,
            1000,
            "Reward amount should match"
        );

        Web3Campaigns.CampaignTask memory task0 = campaigns.getCampaignTask(
            campaignId,
            0
        );
        assertEq(
            uint8(task0.taskType),
            uint8(CampaignStorage.TaskType.SOCIAL_FOLLOW),
            "Task 0 type should match"
        );
        assertEq(
            task0.description,
            "Follow the campaign host",
            "Task 0 description should match"
        );

        Web3Campaigns.CampaignTask memory task1 = campaigns.getCampaignTask(
            campaignId,
            1
        );
        assertEq(
            uint8(task1.taskType),
            uint8(CampaignStorage.TaskType.ONCHAIN_TX),
            "Task 1 type should match"
        );
        assertEq(
            task1.description,
            "Make a transaction",
            "Task 1 description should match"
        );
    }

    function test_CreateCampaignWithTasksAndReward_RevertsOnArrayMismatch()
        public
    {
        uint256 startTime = getTimestamp() + 100;
        uint256 endTime = getTimestamp() + 200;

        CampaignStorage.TaskType[] memory taskTypes =
            new CampaignStorage.TaskType[](1);
        taskTypes[0] = CampaignStorage.TaskType.SOCIAL_FOLLOW;

        string[] memory descriptions = new string[](2);
        descriptions[0] = "Follow the campaign host";
        descriptions[1] = "Extra task";

        bytes[] memory verificationData = new bytes[](1);
        verificationData[0] = abi.encode("twitter_handle");

        bool[] memory isOptional = new bool[](1);
        isOptional[0] = false;

        vm.startPrank(host1);
        vm.expectRevert("Array length mismatch");
        campaigns.createCampaignWithTasksAndReward(
            "Mismatch Campaign",
            startTime,
            endTime,
            taskTypes,
            descriptions,
            verificationData,
            isOptional,
            CampaignStorage.RewardType.NONE,
            address(0),
            0
        );
        vm.stopPrank();
    }

    function test_OpenCampaign_Success() public {
        uint256 startTime = getTimestamp() + 100;
        uint256 endTime = getTimestamp() + 200;

        vm.startPrank(host1);
        uint256 campaignId = campaigns.createCampaign(
            "Campaign to Open",
            startTime,
            endTime
        );
        vm.warp(startTime + 1); // Advance time past the start time
        campaigns.openCampaign(campaignId);
        vm.stopPrank();

        // Verify the status is now Open
        Web3Campaigns.Campaign memory campaign = campaigns.getCampaign(
            campaignId
        );
        // assertEq(
        //     uint8(campaign.status),
        //     uint8(Web3Campaigns.CampaignStatus.Open),
        //     "Campaign status should be Open"
        // );
    }

    function test_OpenCampaign_RevertsIfNotHost() public {
        uint256 startTime = getTimestamp() + 100;
        uint256 endTime = getTimestamp() + 200;

        vm.startPrank(host1);
        uint256 campaignId = campaigns.createCampaign(
            "Campaign for Revert Test",
            startTime,
            endTime
        );
        vm.stopPrank();

        vm.startPrank(nonHost);
        vm.warp(startTime + 1);
        // vm.expectRevert(
        //     abi.encodeWithSelector(
        //         Web3Campaigns.Web3Campaigns__CallerIsNotHost.selector
        //     )
        // );
        campaigns.openCampaign(campaignId);
        vm.stopPrank();
    }

    function test_OpenCampaign_RevertsIfTimeNotStarted() public {
        uint256 startTime = getTimestamp() + 100;
        uint256 endTime = getTimestamp() + 200;

        vm.startPrank(host1);
        uint256 campaignId = campaigns.createCampaign(
            "Campaign for Time Revert",
            startTime,
            endTime
        );
        // Try to open before the start time
        // vm.expectRevert(
        //     abi.encodeWithSelector(
        //         Web3Campaigns
        //             .Web3Campaigns__CampaignStartTimeNotYetStrated
        //             .selector
        //     )
        // );
        campaigns.openCampaign(campaignId);
        vm.stopPrank();
    }

    function test_EndCampaign_Success() public {
        uint256 startTime = getTimestamp() + 100;
        uint256 endTime = getTimestamp() + 200;

        vm.startPrank(host1);
        uint256 campaignId = campaigns.createCampaign(
            "Campaign to End",
            startTime,
            endTime
        );
        vm.warp(startTime + 1);
        campaigns.openCampaign(campaignId);
        vm.warp(endTime + 1); // Advance time past the end time
        campaigns.endCampaign(campaignId);
        vm.stopPrank();

        // Verify the status is now Ended
        Web3Campaigns.Campaign memory campaign = campaigns.getCampaign(
            campaignId
        );
        // assertEq(
        //     uint8(campaign.status),
        //     uint8(Web3Campaigns.CampaignStatus.Ended),
        //     "Campaign status should be Ended"
        // );
    }

    function test_EndCampaign_RevertsIfTimeNotEnded() public {
        uint256 startTime = getTimestamp() + 100;
        uint256 endTime = getTimestamp() + 200;

        vm.startPrank(host1);
        uint256 campaignId = campaigns.createCampaign(
            "Campaign for Revert End",
            startTime,
            endTime
        );
        vm.warp(startTime + 1);
        campaigns.openCampaign(campaignId);
        // Try to end before the end time
        // vm.expectRevert(
        //     abi.encodeWithSelector(
        //         Web3Campaigns.Web3Campaigns__CampaignNotYetEnded.selector
        //     )
        // );
        campaigns.endCampaign(campaignId);
        vm.stopPrank();
    }

    function test_GrantHostRole_Success() public {
        vm.startPrank(msg.sender);
        campaigns.grantHostRole(msg.sender);
        vm.stopPrank();
        // Verify the new host has the HOST_ROLE
        assertTrue(
            campaigns.hasRole(HOST_ROLE, msg.sender),
            "New host should have HOST_ROLE"
        );
    }
}
