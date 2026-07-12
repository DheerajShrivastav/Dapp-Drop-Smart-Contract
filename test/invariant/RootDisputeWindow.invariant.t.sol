// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Web3Campaigns} from "../../src/Web3Campaigns.sol";
import {NFTSettlementModule} from "../../src/NFTSettlementModule.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockERC721} from "../NFTSettlement.t.sol";
import {RootDisputeWindowHandler} from "./RootDisputeWindowHandler.sol";

/// @notice Invariant suite for the Merkle root dispute window (ROOT_DISPUTE_WINDOW), covering both
/// the ERC20 and NFT claim paths. Candidate property from docs/TEST_AND_BUILD.md: no claimERC20/
/// claimNFT ever succeeds when block.timestamp < claimableAt, fuzzed across many campaigns with
/// randomized publish/republish timing (including same-value no-op republishes, which must NOT
/// rearm the window -- see the self-griefing fix in docs/SECURITY_FINDINGS.md #14).
contract RootDisputeWindowInvariant is StdInvariant, Test {
    Web3Campaigns public campaigns;
    NFTSettlementModule public nftModule;
    ERC20Mock public token;
    MockERC721 public nft721;
    RootDisputeWindowHandler public handler;

    function setUp() public {
        vm.warp(1_000_000);

        address deployer = vm.addr(1);
        vm.prank(deployer);
        campaigns = new Web3Campaigns();

        nftModule = new NFTSettlementModule(address(campaigns));
        vm.prank(deployer);
        campaigns.setNFTSettlementModule(address(nftModule));

        token = new ERC20Mock();
        nft721 = new MockERC721();
        handler = new RootDisputeWindowHandler(campaigns, nftModule, token, nft721);

        vm.prank(deployer);
        campaigns.grantHostRole(address(handler));

        // Only fuzz the seven lifecycle actions.
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = RootDisputeWindowHandler.createERC20Campaign.selector;
        selectors[1] = RootDisputeWindowHandler.publishERC20Root.selector;
        selectors[2] = RootDisputeWindowHandler.attemptERC20Claim.selector;
        selectors[3] = RootDisputeWindowHandler.createNFTCampaign.selector;
        selectors[4] = RootDisputeWindowHandler.publishNFTRoot.selector;
        selectors[5] = RootDisputeWindowHandler.attemptNFTClaim.selector;
        selectors[6] = RootDisputeWindowHandler.warpForward.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice The live contract's getERC20ClaimableAt must always match the handler's independently
    /// reconstructed ghost mirror of the rearm rule (rearm only on a genuine root-value change).
    /// Any divergence means either the contract or the ghost model disagrees on when a root was
    /// last genuinely republished -- exactly the class of bug the same-root-republish fix addressed.
    function invariant_ERC20ClaimableAtMatchesGhostRearmRule() public view {
        uint256 n = handler.erc20Count();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.erc20At(i);
            assertEq(
                campaigns.getERC20ClaimableAt(id),
                handler.erc20ExpectedClaimableAt(id),
                "getERC20ClaimableAt diverged from the expected rearm rule"
            );
        }
    }

    /// @notice Same cross-check for the NFT path.
    function invariant_NFTClaimableAtMatchesGhostRearmRule() public view {
        uint256 n = handler.nftCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.nftAt(i);
            assertEq(
                nftModule.getNFTClaimableAt(id),
                handler.nftExpectedClaimableAt(id),
                "getNFTClaimableAt diverged from the expected rearm rule"
            );
        }
    }

    // NOTE: a "did both outcomes get exercised" liveness check was deliberately NOT added as an
    // invariant_* function here. Foundry evaluates every invariant_* once immediately after setUp,
    // before any fuzzed call has run (runs=0, calls=0) -- a ghost counter is unconditionally zero at
    // that point, so an assertGt(counter, 0) check fails on every single run regardless of what
    // happens afterward. This project already hit and removed an equivalent afterInvariant()
    // coverage-sanity hook for AttestationVersion.invariant.t.sol for the same class of flakiness
    // (see docs/TEST_AND_BUILD.md Known Issues). Non-vacuousness is instead confirmed by inspecting
    // the handler's call-summary table: attemptERC20Claim/attemptNFTClaim must show a healthy mix of
    // completed and reverted calls (not 100% either way), and ghost_erc20SuccessCount /
    // ghost_erc20RevertCount / ghost_nftSuccessCount / ghost_nftRevertCount (all public) can be
    // spot-checked with `forge test -vv` after a run.
}
