// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {Web3Campaigns} from "../src/Web3Campaigns.sol";
import {CampaignStorage} from "../src/CampaignStorage.sol";

/// @notice Covers Phase 2: signature-based off-chain task verification.
/// Replaces the old host-tx verifyTaskCompletion/batchVerifyTaskCompletion with EIP-712
/// signed attestations from SIGNER_ROLE keys. See docs/NEXT_STEPS.md "Phase 2".
contract SignatureVerificationTest is Test {
    Web3Campaigns public campaigns;

    address public deployer; // pk=1, holds SIGNER_ROLE + DEFAULT_ADMIN_ROLE by default
    address public host1; // pk=2
    address public participant1; // pk=4
    address public participant2; // pk=5

    bytes32 public constant SIGNER_ROLE = keccak256("SIGNER_ROLE");

    uint256 constant START_OFFSET = 1 days;
    uint256 constant CAMPAIGN_DURATION = 7 days;

    // --- EIP-712 signing helpers (mirrors CampaignStorage's TASK_ATTESTATION_TYPEHASH) ---
    bytes32 constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant TASK_ATTESTATION_TYPEHASH = keccak256(
        "TaskAttestation(uint256 campaignId,address participant,uint256 taskIndex,bool completed,uint256 version,uint256 deadline)"
    );

    function _domainSeparator(address verifyingContract) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("Web3Campaigns")),
                keccak256(bytes("1")),
                block.chainid,
                verifyingContract
            )
        );
    }

    function _signAttestation(
        uint256 signerPk,
        address verifyingContract,
        uint256 campaignId,
        address participant,
        uint256 taskIndex,
        bool completed,
        uint256 version,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(TASK_ATTESTATION_TYPEHASH, campaignId, participant, taskIndex, completed, version, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(verifyingContract), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function setUp() public {
        vm.warp(1_000_000);

        deployer = vm.addr(1);
        host1 = vm.addr(2);
        participant1 = vm.addr(4);
        participant2 = vm.addr(5);

        vm.prank(deployer);
        campaigns = new Web3Campaigns();

        vm.prank(deployer);
        campaigns.grantHostRole(host1);
    }

    function _openCampaignWithSocialTask() internal returns (uint256 campaignId) {
        uint256 startTime = block.timestamp + START_OFFSET;
        uint256 endTime = startTime + CAMPAIGN_DURATION;

        vm.prank(host1);
        campaignId = campaigns.createCampaign("C", startTime, endTime);

        vm.prank(host1);
        campaigns.addTaskToCampaign(campaignId, CampaignStorage.TaskType.SOCIAL_FOLLOW, "Follow us", "", false);

        vm.warp(startTime + 1);
        vm.prank(host1);
        campaigns.openCampaign(campaignId);
    }

    /*//////////////////////////////////////////////////////////////
                                HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_VerifySignature_Success_IncrementsParticipantsOnce() public {
        uint256 campaignId = _openCampaignWithSocialTask();
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig = _signAttestation(1, address(campaigns), campaignId, participant1, 0, true, 1, deadline);
        campaigns.verifyTaskCompletionWithSignature(campaignId, participant1, 0, true, deadline, sig);

        assertTrue(campaigns.hasCompletedTask(campaignId, participant1, 0));
        assertTrue(campaigns.hasParticipated(campaignId, participant1));
        Web3Campaigns.Campaign memory campaign = campaigns.getCampaign(campaignId);
        assertEq(campaign.totalParticipants, 1);
    }

    function test_VerifySignature_AnyoneCanSubmit() public {
        // The submitting caller is irrelevant — only the recovered signer matters. A relayer
        // (participant2, who holds no special role) can submit participant1's attestation.
        uint256 campaignId = _openCampaignWithSocialTask();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signAttestation(1, address(campaigns), campaignId, participant1, 0, true, 1, deadline);

        vm.prank(participant2);
        campaigns.verifyTaskCompletionWithSignature(campaignId, participant1, 0, true, deadline, sig);

        assertTrue(campaigns.hasCompletedTask(campaignId, participant1, 0));
    }

    function test_VerifySignature_FalseAttestation_DoesNotCountParticipant() public {
        uint256 campaignId = _openCampaignWithSocialTask();
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig = _signAttestation(1, address(campaigns), campaignId, participant1, 0, false, 1, deadline);
        campaigns.verifyTaskCompletionWithSignature(campaignId, participant1, 0, false, deadline, sig);

        assertFalse(campaigns.hasCompletedTask(campaignId, participant1, 0));
        assertFalse(campaigns.hasParticipated(campaignId, participant1));
        assertEq(campaigns.getTaskAttestationVersion(campaignId, participant1, 0), 1);
    }

    /*//////////////////////////////////////////////////////////////
                        STATUS / TASK VALIDITY GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_VerifySignature_RevertsIfCampaignDraft() public {
        vm.prank(host1);
        uint256 campaignId = campaigns.createCampaign(
            "C", block.timestamp + START_OFFSET, block.timestamp + START_OFFSET + CAMPAIGN_DURATION
        );
        vm.prank(host1);
        campaigns.addTaskToCampaign(campaignId, CampaignStorage.TaskType.SOCIAL_FOLLOW, "Follow us", "", false);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signAttestation(1, address(campaigns), campaignId, participant1, 0, true, 1, deadline);

        vm.expectRevert(CampaignStorage.Web3Campaigns__CampaignNotOpen.selector);
        campaigns.verifyTaskCompletionWithSignature(campaignId, participant1, 0, true, deadline, sig);
    }

    function test_VerifySignature_AllowedWhenEnded() public {
        uint256 campaignId = _openCampaignWithSocialTask();
        Web3Campaigns.Campaign memory c = campaigns.getCampaign(campaignId);
        vm.warp(c.endTime + 1);
        vm.prank(host1);
        campaigns.endCampaign(campaignId);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signAttestation(1, address(campaigns), campaignId, participant1, 0, true, 1, deadline);
        campaigns.verifyTaskCompletionWithSignature(campaignId, participant1, 0, true, deadline, sig);

        assertTrue(campaigns.hasCompletedTask(campaignId, participant1, 0));
    }

    function test_VerifySignature_RevertsOnTaskNotFound() public {
        uint256 campaignId = _openCampaignWithSocialTask();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signAttestation(1, address(campaigns), campaignId, participant1, 5, true, 1, deadline);

        vm.expectRevert(CampaignStorage.Web3Campaigns__TaskNotFound.selector);
        campaigns.verifyTaskCompletionWithSignature(campaignId, participant1, 5, true, deadline, sig);
    }

    /*//////////////////////////////////////////////////////////////
                        SIGNER ROLE ROTATION / REVOCATION
    //////////////////////////////////////////////////////////////*/

    function test_SignerRotation_RevokedSignerCannotVerify() public {
        uint256 campaignId = _openCampaignWithSocialTask();
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(deployer);
        campaigns.revokeRole(SIGNER_ROLE, deployer);

        bytes memory sig = _signAttestation(1, address(campaigns), campaignId, participant1, 0, true, 1, deadline);
        vm.expectRevert(CampaignStorage.Web3Campaigns__InvalidSigner.selector);
        campaigns.verifyTaskCompletionWithSignature(campaignId, participant1, 0, true, deadline, sig);
    }

    function test_SignerRotation_NewSignerCanVerify() public {
        uint256 campaignId = _openCampaignWithSocialTask();
        uint256 deadline = block.timestamp + 1 hours;

        uint256 newSignerPk = 42;
        address newSigner = vm.addr(newSignerPk);
        vm.prank(deployer);
        campaigns.grantRole(SIGNER_ROLE, newSigner);

        bytes memory sig =
            _signAttestation(newSignerPk, address(campaigns), campaignId, participant1, 0, true, 1, deadline);
        campaigns.verifyTaskCompletionWithSignature(campaignId, participant1, 0, true, deadline, sig);

        assertTrue(campaigns.hasCompletedTask(campaignId, participant1, 0));
    }

    function test_SignerRotation_GrantRestrictedToAdmin() public {
        uint256 newSignerPk = 42;
        address newSigner = vm.addr(newSignerPk);

        vm.prank(participant1); // not DEFAULT_ADMIN_ROLE
        vm.expectRevert();
        campaigns.grantRole(SIGNER_ROLE, newSigner);
    }

    /*//////////////////////////////////////////////////////////////
                        DOMAIN SEPARATION
    //////////////////////////////////////////////////////////////*/

    function test_VerifySignature_RevertsForSignatureBoundToDifferentContract() public {
        uint256 campaignId = _openCampaignWithSocialTask();
        uint256 deadline = block.timestamp + 1 hours;

        // Sign a digest bound to a different (unrelated) verifyingContract address; even
        // though pk=1 holds SIGNER_ROLE on `campaigns`, the domain separator differs, so the
        // signature recovers to an unrelated address here and is rejected.
        address otherContract = makeAddr("otherContract");
        bytes memory sig = _signAttestation(1, otherContract, campaignId, participant1, 0, true, 1, deadline);

        vm.expectRevert(CampaignStorage.Web3Campaigns__InvalidSigner.selector);
        campaigns.verifyTaskCompletionWithSignature(campaignId, participant1, 0, true, deadline, sig);
    }

    /*//////////////////////////////////////////////////////////////
                                  BATCH
    //////////////////////////////////////////////////////////////*/

    function test_Batch_RevertsAtomicallyOnOneBadSignature() public {
        uint256 campaignId = _openCampaignWithSocialTask();
        uint256 deadline = block.timestamp + 1 hours;

        address[] memory participants = new address[](2);
        participants[0] = participant1;
        participants[1] = participant2;
        uint256[] memory taskIndices = new uint256[](2);
        taskIndices[0] = 0;
        taskIndices[1] = 0;
        bool[] memory completedFlags = new bool[](2);
        completedFlags[0] = true;
        completedFlags[1] = true;
        uint256[] memory deadlines = new uint256[](2);
        deadlines[0] = deadline;
        deadlines[1] = deadline;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = _signAttestation(1, address(campaigns), campaignId, participant1, 0, true, 1, deadline);
        // Bad: signed by a non-signer (pk=99).
        signatures[1] = _signAttestation(99, address(campaigns), campaignId, participant2, 0, true, 1, deadline);

        vm.expectRevert(CampaignStorage.Web3Campaigns__InvalidSigner.selector);
        campaigns.batchVerifyTaskCompletionWithSignatures(
            campaignId, participants, taskIndices, completedFlags, deadlines, signatures
        );

        // Atomic: participant1's entry (which was individually valid) must NOT have applied.
        assertFalse(campaigns.hasCompletedTask(campaignId, participant1, 0));
        assertEq(campaigns.getTaskAttestationVersion(campaignId, participant1, 0), 0);
    }

    function test_Batch_RevertsOnArrayLengthMismatch() public {
        uint256 campaignId = _openCampaignWithSocialTask();

        address[] memory participants = new address[](2);
        participants[0] = participant1;
        participants[1] = participant2;
        uint256[] memory taskIndices = new uint256[](1); // mismatched length
        taskIndices[0] = 0;
        bool[] memory completedFlags = new bool[](2);
        uint256[] memory deadlines = new uint256[](2);
        bytes[] memory signatures = new bytes[](2);

        vm.expectRevert(CampaignStorage.Web3Campaigns__ArrayLengthMismatch.selector);
        campaigns.batchVerifyTaskCompletionWithSignatures(
            campaignId, participants, taskIndices, completedFlags, deadlines, signatures
        );
    }

    function test_Batch_RevertsOnEmptyBatch() public {
        uint256 campaignId = _openCampaignWithSocialTask();

        address[] memory participants = new address[](0);
        uint256[] memory taskIndices = new uint256[](0);
        bool[] memory completedFlags = new bool[](0);
        uint256[] memory deadlines = new uint256[](0);
        bytes[] memory signatures = new bytes[](0);

        vm.expectRevert(CampaignStorage.Web3Campaigns__BatchTooLarge.selector);
        campaigns.batchVerifyTaskCompletionWithSignatures(
            campaignId, participants, taskIndices, completedFlags, deadlines, signatures
        );
    }
}
