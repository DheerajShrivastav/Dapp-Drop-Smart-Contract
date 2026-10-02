// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import {Web3Campaigns} from "../src/Web3Campaigns.sol";
import {CampaignStorage} from "../src/CampaignStorage.sol";
import {AttestationHelper} from "./utils/AttestationHelper.sol";
import {MockERC721} from "./NFTSettlement.t.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/// @notice completeTask self-verifies ONCHAIN_HOLD_ERC20 / ONCHAIN_HOLD_ERC721 only. Every other task
/// type is attestation-only (SIGNER_ROLE), and hold tasks are never signer-overridable.
contract CompleteTaskSelfVerificationTest is AttestationHelper {
    Web3Campaigns public campaigns;
    ERC20Mock public token;
    MockERC721 public nft;

    uint256 constant SIGNER_PK = 1; // deployer = vm.addr(SIGNER_PK) holds SIGNER_ROLE by default
    address public host1;
    address public participant1;

    uint256 constant START_OFFSET = 1 days;
    uint256 constant CAMPAIGN_DURATION = 7 days;

    function setUp() public {
        vm.warp(1_000_000);
        address deployer = vm.addr(SIGNER_PK);
        host1 = makeAddr("host1");
        participant1 = makeAddr("participant1");

        vm.startPrank(deployer);
        campaigns = new Web3Campaigns();
        campaigns.grantHostRole(host1);
        vm.stopPrank();

        token = new ERC20Mock();
        nft = new MockERC721();
    }

    function _openCampaignWith(CampaignStorage.TaskType taskType, bytes memory vData) internal returns (uint256 id) {
        vm.warp(block.timestamp + campaigns.RATE_LIMIT_COOLDOWN() + 1);
        uint256 startTime = block.timestamp + START_OFFSET;
        vm.startPrank(host1);
        id = campaigns.createCampaign("C", startTime, startTime + CAMPAIGN_DURATION);
        campaigns.addTaskToCampaign(id, taskType, "task", vData, false);
        vm.stopPrank();
        vm.warp(startTime + 1);
        vm.prank(host1);
        campaigns.openCampaign(id);
    }

    function test_CompleteTask_RevertsNotSelfVerifiable_ForEveryNonHoldType() public {
        uint8 holdErc20 = uint8(CampaignStorage.TaskType.ONCHAIN_HOLD_ERC20);
        uint8 holdErc721 = uint8(CampaignStorage.TaskType.ONCHAIN_HOLD_ERC721);
        uint256 checked;
        for (uint8 t; t <= holdErc721; ++t) {
            if (t == holdErc20 || t == holdErc721) continue;
            uint256 id = _openCampaignWith(CampaignStorage.TaskType(t), "");

            vm.prank(participant1);
            vm.expectRevert(CampaignStorage.Web3Campaigns__NotSelfVerifiable.selector);
            campaigns.completeTask(id, 0);

            assertFalse(campaigns.hasCompletedTask(id, participant1, 0));
            assertEq(campaigns.getCampaign(id).totalParticipants, 0);
            ++checked;
        }
        assertEq(checked, 8, "every non-hold TaskType covered");
    }

    function testFuzz_CompleteTask_RevertsNotSelfVerifiable_ForNonHoldType(uint8 seed) public {
        CampaignStorage.TaskType t =
            CampaignStorage.TaskType(bound(seed, 0, uint8(CampaignStorage.TaskType.ONCHAIN_TX)));
        uint256 id = _openCampaignWith(t, "");

        vm.prank(participant1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__NotSelfVerifiable.selector);
        campaigns.completeTask(id, 0);
    }

    function test_HoldERC20_SelfVerifies() public {
        uint256 id = _openCampaignWith(CampaignStorage.TaskType.ONCHAIN_HOLD_ERC20, abi.encode(address(token), 100));
        token.mint(participant1, 100);

        vm.prank(participant1);
        campaigns.completeTask(id, 0);

        assertTrue(campaigns.hasCompletedTask(id, participant1, 0));
        assertEq(campaigns.getCampaign(id).totalParticipants, 1);
    }

    function test_HoldERC20_RevertsBelowRequiredBalance() public {
        uint256 id = _openCampaignWith(CampaignStorage.TaskType.ONCHAIN_HOLD_ERC20, abi.encode(address(token), 100));
        token.mint(participant1, 99);

        vm.prank(participant1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__InsufficientERC20Balance.selector);
        campaigns.completeTask(id, 0);
    }

    function test_HoldERC721_SelfVerifies() public {
        uint256 id = _openCampaignWith(CampaignStorage.TaskType.ONCHAIN_HOLD_ERC721, abi.encode(address(nft), 7));
        nft.mint(participant1, 7);

        vm.prank(participant1);
        campaigns.completeTask(id, 0);

        assertTrue(campaigns.hasCompletedTask(id, participant1, 0));
    }

    function test_HoldERC721_RevertsWhenNotOwner() public {
        uint256 id = _openCampaignWith(CampaignStorage.TaskType.ONCHAIN_HOLD_ERC721, abi.encode(address(nft), 7));
        nft.mint(makeAddr("someoneElse"), 7);

        vm.prank(participant1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__NotHoldingSpecificERC721.selector);
        campaigns.completeTask(id, 0);
    }

    /// @notice Hold tasks stay signer-unoverridable: an attestation can neither complete nor revoke
    /// one, so the attestation version never moves and TaskManagedBySignature never locks
    /// completeTask out -- self-verification remains the only path for holds.
    function test_HoldTask_NotSignerOverridable_AndNeverManagedBySignature() public {
        uint256 id = _openCampaignWith(CampaignStorage.TaskType.ONCHAIN_HOLD_ERC20, abi.encode(address(token), 1));

        vm.expectRevert(CampaignStorage.Web3Campaigns__TaskNotVerifiableByHost.selector);
        this.attestExternal(id, participant1, 0, true);
        assertEq(campaigns.getTaskAttestationVersion(id, participant1, 0), 0);

        // A non-holder can't self-verify either -- the signer path did not grant anything.
        vm.prank(participant1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__InsufficientERC20Balance.selector);
        campaigns.completeTask(id, 0);

        token.mint(participant1, 1);
        vm.prank(participant1);
        campaigns.completeTask(id, 0);
        assertTrue(campaigns.hasCompletedTask(id, participant1, 0));

        vm.expectRevert(CampaignStorage.Web3Campaigns__TaskNotVerifiableByHost.selector);
        this.attestExternal(id, participant1, 0, false);
        assertTrue(campaigns.hasCompletedTask(id, participant1, 0));
    }

    /// @dev External shim so vm.expectRevert targets the attestation call itself, not the view
    /// calls _attestTask makes to build the signature.
    function attestExternal(uint256 id, address who, uint256 idx, bool completed) external {
        _attestTask(campaigns, SIGNER_PK, id, who, idx, completed);
    }
}
