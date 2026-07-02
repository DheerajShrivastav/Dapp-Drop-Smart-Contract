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

    function test_OnchainTx_SignerCanVerify() public {
        // Previously bricked: host verification of ONCHAIN_TX reverted, so a mandatory
        // ONCHAIN_TX task could never be completed. Now a SIGNER_ROLE-signed attestation
        // completes it (deployer holds SIGNER_ROLE by default, pk=1).
        uint256 campaignId = _openCampaignWithTask(CampaignStorage.TaskType.ONCHAIN_TX, "", false);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signAttestation(1, address(campaigns), campaignId, participant1, 0, true, 1, deadline);

        campaigns.verifyTaskCompletionWithSignature(campaignId, participant1, 0, true, deadline, sig);

        assertTrue(campaigns.hasCompletedTask(campaignId, participant1, 0));
    }

    function test_OnchainHold_SignatureCannotVerify() public {
        // ONCHAIN_HOLD_* stays self-verified on-chain and must not be signature-overridable.
        uint256 campaignId = _openCampaignWithTask(
            CampaignStorage.TaskType.ONCHAIN_HOLD_ERC721, abi.encode(address(mockERC20), uint256(1)), false
        );

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signAttestation(1, address(campaigns), campaignId, participant1, 0, true, 1, deadline);

        vm.expectRevert(CampaignStorage.Web3Campaigns__TaskNotVerifiableByHost.selector);
        campaigns.verifyTaskCompletionWithSignature(campaignId, participant1, 0, true, deadline, sig);
    }

    function test_VerifyTaskCompletionWithSignature_RevertsOnExpiredDeadline() public {
        uint256 campaignId = _openCampaignWithTask(CampaignStorage.TaskType.ONCHAIN_TX, "", false);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signAttestation(1, address(campaigns), campaignId, participant1, 0, true, 1, deadline);

        vm.warp(deadline + 1);
        vm.expectRevert(CampaignStorage.Web3Campaigns__SignatureExpired.selector);
        campaigns.verifyTaskCompletionWithSignature(campaignId, participant1, 0, true, deadline, sig);
    }

    function test_VerifyTaskCompletionWithSignature_RevertsOnNonSigner() public {
        uint256 campaignId = _openCampaignWithTask(CampaignStorage.TaskType.ONCHAIN_TX, "", false);

        uint256 deadline = block.timestamp + 1 hours;
        // nonHost = vm.addr(3) does not hold SIGNER_ROLE.
        bytes memory sig = _signAttestation(3, address(campaigns), campaignId, participant1, 0, true, 1, deadline);

        vm.expectRevert(CampaignStorage.Web3Campaigns__InvalidSigner.selector);
        campaigns.verifyTaskCompletionWithSignature(campaignId, participant1, 0, true, deadline, sig);
    }

    function test_VerifyTaskCompletionWithSignature_RevertsOnReplay() public {
        uint256 campaignId = _openCampaignWithTask(CampaignStorage.TaskType.ONCHAIN_TX, "", false);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signAttestation(1, address(campaigns), campaignId, participant1, 0, true, 1, deadline);

        campaigns.verifyTaskCompletionWithSignature(campaignId, participant1, 0, true, deadline, sig);

        // Same signature (still targeting version 1) can't be replayed now that version is 2.
        vm.expectRevert(CampaignStorage.Web3Campaigns__InvalidSigner.selector);
        campaigns.verifyTaskCompletionWithSignature(campaignId, participant1, 0, true, deadline, sig);
    }

    function test_VerifyTaskCompletionWithSignature_SupportsReverification() public {
        // A signer can issue a fresh attestation targeting the next version to flip a
        // completion back to false (e.g. correcting a mistake), then re-affirm it later.
        uint256 campaignId = _openCampaignWithTask(CampaignStorage.TaskType.ONCHAIN_TX, "", false);
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig1 = _signAttestation(1, address(campaigns), campaignId, participant1, 0, true, 1, deadline);
        campaigns.verifyTaskCompletionWithSignature(campaignId, participant1, 0, true, deadline, sig1);
        assertTrue(campaigns.hasCompletedTask(campaignId, participant1, 0));
        assertEq(campaigns.getTaskAttestationVersion(campaignId, participant1, 0), 1);

        bytes memory sig2 = _signAttestation(1, address(campaigns), campaignId, participant1, 0, false, 2, deadline);
        campaigns.verifyTaskCompletionWithSignature(campaignId, participant1, 0, false, deadline, sig2);
        assertFalse(campaigns.hasCompletedTask(campaignId, participant1, 0));
        assertEq(campaigns.getTaskAttestationVersion(campaignId, participant1, 0), 2);
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
