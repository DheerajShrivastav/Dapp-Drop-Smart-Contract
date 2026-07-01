// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {Web3Campaigns} from "../src/Web3Campaigns.sol";
import {CampaignStorage} from "../src/CampaignStorage.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @notice Covers the Stage A correctness fixes:
///  - ONCHAIN_HOLD_* verificationData length (64-byte abi.encode)
///  - ONCHAIN_TX de-brick (host-verifiable, not self-assertable)
///  - flagAccount wiring of the suspicious-activity gate
///  - createCampaign pause coverage
contract StageAFixesTest is Test {
    Web3Campaigns public campaigns;
    ERC20Mock public mockERC20;

    address public deployer;
    address public host1;
    address public nonHost;
    address public participant1;

    bytes32 public constant MODERATOR_ROLE = keccak256("MODERATOR_ROLE");

    uint256 constant START_OFFSET = 1 days;
    uint256 constant CAMPAIGN_DURATION = 7 days;

    function setUp() public {
        vm.warp(1_000_000);

        deployer = vm.addr(1);
        host1 = vm.addr(2);
        nonHost = vm.addr(3);
        participant1 = vm.addr(4);

        vm.prank(deployer);
        campaigns = new Web3Campaigns();

        mockERC20 = new ERC20Mock();

        vm.prank(deployer);
        campaigns.grantHostRole(host1);
    }

    // --- helpers ---

    /// @dev Creates an Open campaign with a single task of the given type/data, warped into its active window.
    function _openCampaignWithTask(CampaignStorage.TaskType taskType, bytes memory verificationData, bool isOptional)
        internal
        returns (uint256 campaignId)
    {
        uint256 startTime = block.timestamp + START_OFFSET;
        uint256 endTime = startTime + CAMPAIGN_DURATION;

        vm.prank(host1);
        campaignId = campaigns.createCampaign("C", startTime, endTime);

        vm.prank(host1);
        campaigns.addTaskToCampaign(campaignId, taskType, "task", verificationData, isOptional);

        vm.warp(startTime + 1);
        vm.prank(host1);
        campaigns.openCampaign(campaignId);
    }

    /*//////////////////////////////////////////////////////////////
                        ONCHAIN_HOLD_ERC20 (64-byte)
    //////////////////////////////////////////////////////////////*/

    function test_OnchainHoldERC20_Succeeds_With64ByteData() public {
        bytes memory vData = abi.encode(address(mockERC20), uint256(100));
        assertEq(vData.length, 64, "abi.encode(address,uint256) must be 64 bytes");

        uint256 campaignId = _openCampaignWithTask(CampaignStorage.TaskType.ONCHAIN_HOLD_ERC20, vData, false);

        mockERC20.mint(participant1, 150);

        vm.prank(participant1);
        campaigns.completeTask(campaignId, 0);

        assertTrue(campaigns.hasCompletedTask(campaignId, participant1, 0));
    }

    function test_OnchainHoldERC20_RevertsOnInsufficientBalance() public {
        bytes memory vData = abi.encode(address(mockERC20), uint256(100));
        uint256 campaignId = _openCampaignWithTask(CampaignStorage.TaskType.ONCHAIN_HOLD_ERC20, vData, false);

        mockERC20.mint(participant1, 50); // below required 100

        vm.prank(participant1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__InsufficientERC20Balance.selector);
        campaigns.completeTask(campaignId, 0);
    }

    function test_OnchainHoldERC20_RevertsOnBadLength() public {
        // packed encoding is 52 bytes, which used to (incorrectly) pass; now rejected.
        bytes memory packed = abi.encodePacked(address(mockERC20), uint256(100));
        assertEq(packed.length, 52);

        uint256 campaignId = _openCampaignWithTask(CampaignStorage.TaskType.ONCHAIN_HOLD_ERC20, packed, false);

        mockERC20.mint(participant1, 150);

        vm.prank(participant1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__InvalidVerificationData.selector);
        campaigns.completeTask(campaignId, 0);
    }

    /*//////////////////////////////////////////////////////////////
                            ONCHAIN_TX DE-BRICK
    //////////////////////////////////////////////////////////////*/

    function test_OnchainTx_SelfCompleteReverts() public {
        uint256 campaignId = _openCampaignWithTask(CampaignStorage.TaskType.ONCHAIN_TX, "", false);

        vm.prank(participant1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__NotSelfVerifiable.selector);
        campaigns.completeTask(campaignId, 0);
    }

    function test_OnchainTx_HostCanVerify() public {
        // Previously bricked: host verification of ONCHAIN_TX reverted, so a mandatory
        // ONCHAIN_TX task could never be completed. Now the host can verify it.
        uint256 campaignId = _openCampaignWithTask(CampaignStorage.TaskType.ONCHAIN_TX, "", false);

        vm.prank(host1);
        campaigns.verifyTaskCompletion(campaignId, participant1, 0);

        assertTrue(campaigns.hasCompletedTask(campaignId, participant1, 0));
    }

    function test_OnchainHold_HostCannotVerify() public {
        // ONCHAIN_HOLD_* stays self-verified on-chain and must not be host-overridable.
        uint256 campaignId = _openCampaignWithTask(
            CampaignStorage.TaskType.ONCHAIN_HOLD_ERC721, abi.encode(address(mockERC20), uint256(1)), false
        );

        vm.prank(host1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__TaskNotVerifiableByHost.selector);
        campaigns.verifyTaskCompletion(campaignId, participant1, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        SUSPICIOUS-ACTIVITY GATE
    //////////////////////////////////////////////////////////////*/

    function test_FlagAccount_BlocksCompleteTask() public {
        uint256 campaignId = _openCampaignWithTask(CampaignStorage.TaskType.SOCIAL_FOLLOW, "", false);

        vm.prank(deployer); // deployer holds MODERATOR_ROLE
        campaigns.flagAccount(participant1, 100); // == MAX_SUSPICIOUS_SCORE

        vm.prank(participant1);
        vm.expectRevert(bytes("Account flagged for suspicious activity"));
        campaigns.completeTask(campaignId, 0);
    }

    function test_FlagAccount_OnlyModerator() public {
        vm.prank(nonHost);
        vm.expectRevert();
        campaigns.flagAccount(participant1, 100);
    }

    function test_FlagAccount_CanClear() public {
        uint256 campaignId = _openCampaignWithTask(CampaignStorage.TaskType.SOCIAL_FOLLOW, "", false);

        vm.prank(deployer);
        campaigns.flagAccount(participant1, 100);

        vm.prank(deployer);
        campaigns.flagAccount(participant1, 0); // clear

        vm.prank(participant1);
        campaigns.completeTask(campaignId, 0);
        assertTrue(campaigns.hasCompletedTask(campaignId, participant1, 0));
    }

    /*//////////////////////////////////////////////////////////////
                          PAUSE COVERAGE
    //////////////////////////////////////////////////////////////*/

    function test_CreateCampaign_RevertsWhenPaused() public {
        vm.prank(deployer); // deployer holds EMERGENCY_ADMIN
        campaigns.emergencyPause();

        uint256 startTime = block.timestamp + START_OFFSET;
        vm.prank(host1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        campaigns.createCampaign("Paused", startTime, startTime + CAMPAIGN_DURATION);
    }
}
