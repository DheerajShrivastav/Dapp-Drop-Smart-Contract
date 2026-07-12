// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {Web3Campaigns} from "../src/Web3Campaigns.sol";
import {CampaignStorage} from "../src/CampaignStorage.sol";
import {FeeModule} from "../src/FeeModule.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice A minimal fee-on-transfer ERC20: skims `feeBps` of every transfer/transferFrom to a
/// burn sink, so the recipient always receives less than the nominal `amount` passed to
/// transfer/transferFrom. Used to test that fundCampaignERC20 credits escrow with what was
/// ACTUALLY received, not the nominal amount requested -- see docs/SECURITY_FINDINGS.md.
contract FeeOnTransferMock is ERC20 {
    uint256 public immutable feeBps; // e.g. 500 = 5%

    constructor(uint256 _feeBps) ERC20("FeeOnTransfer", "FOT") {
        feeBps = _feeBps;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, amount); // mint/burn: no fee
            return;
        }
        uint256 fee = (amount * feeBps) / 10_000;
        super._update(from, address(0xdEaD), fee);
        super._update(from, to, amount - fee);
    }
}

/// @notice Covers fee-on-transfer ERC20 support in fundCampaignERC20: escrow accounting must be
/// based on the amount actually received (measured via balanceOf before/after the pull), not the
/// nominal _amount requested, which a fee-on-transfer token can silently reduce in transit.
contract FeeOnTransferERC20Test is Test {
    Web3Campaigns public campaigns;
    FeeOnTransferMock public token;

    address public deployer;
    address public host1;
    address public treasury;

    uint256 constant START_OFFSET = 1 days;
    uint256 constant CAMPAIGN_DURATION = 7 days;

    function setUp() public {
        vm.warp(1_000_000);

        deployer = vm.addr(1);
        host1 = vm.addr(2);
        treasury = vm.addr(3);

        vm.prank(deployer);
        campaigns = new Web3Campaigns();

        vm.prank(deployer);
        campaigns.grantHostRole(host1);
    }

    function _draftCampaign() internal returns (uint256 id) {
        uint256 startTime = block.timestamp + START_OFFSET;
        vm.prank(host1);
        id = campaigns.createCampaign("C", startTime, startTime + CAMPAIGN_DURATION);
        vm.prank(host1);
        campaigns.configureERC20Reward(id, address(token));
    }

    /*//////////////////////////////////////////////////////////////
                    NO FEE MODULE -- FEE-ON-TRANSFER TOKEN ONLY
    //////////////////////////////////////////////////////////////*/

    function test_FundCampaignERC20_CreditsActualReceivedAmount_NotNominal() public {
        token = new FeeOnTransferMock(500); // 5% skimmed in transit
        token.mint(host1, 1_000 ether);
        uint256 id = _draftCampaign();

        vm.startPrank(host1);
        token.approve(address(campaigns), 100 ether);
        campaigns.fundCampaignERC20(id, 100 ether);
        vm.stopPrank();

        // 5% of 100 ether = 5 ether skimmed by the token itself before it ever reached the
        // contract -- escrow must reflect the 95 ether that actually landed, not the nominal 100.
        (, uint256 escrowed,,,,) = campaigns.getERC20Settlement(id);
        assertEq(escrowed, 95 ether);
        assertEq(token.balanceOf(address(campaigns)), 95 ether);
    }

    function test_FundCampaignERC20_StandardToken_StillCreditsFullAmount() public {
        token = new FeeOnTransferMock(0); // 0% fee -- behaves like a standard token
        token.mint(host1, 1_000 ether);
        uint256 id = _draftCampaign();

        vm.startPrank(host1);
        token.approve(address(campaigns), 100 ether);
        campaigns.fundCampaignERC20(id, 100 ether);
        vm.stopPrank();

        (, uint256 escrowed,,,,) = campaigns.getERC20Settlement(id);
        assertEq(escrowed, 100 ether);
    }

    function test_FundCampaignERC20_MultipleFundingCallsAccumulateReceivedAmounts() public {
        token = new FeeOnTransferMock(1000); // 10%
        token.mint(host1, 1_000 ether);
        uint256 id = _draftCampaign();

        vm.startPrank(host1);
        token.approve(address(campaigns), 200 ether);
        campaigns.fundCampaignERC20(id, 100 ether); // +90 ether received
        campaigns.fundCampaignERC20(id, 100 ether); // +90 ether received
        vm.stopPrank();

        (, uint256 escrowed,,,,) = campaigns.getERC20Settlement(id);
        assertEq(escrowed, 180 ether);
    }

    /*//////////////////////////////////////////////////////////////
                FEE-ON-TRANSFER TOKEN + PROTOCOL FEE MODULE
    //////////////////////////////////////////////////////////////*/

    function test_FundCampaignERC20_ProtocolFeeComputedOnReceivedAmount_NotNominal() public {
        token = new FeeOnTransferMock(500); // 5% skimmed in transit
        token.mint(host1, 1_000 ether);
        uint256 id = _draftCampaign();

        FeeModule feeModule = new FeeModule(deployer, 1000, treasury); // 10% protocol fee
        vm.prank(deployer);
        campaigns.setFeeModule(address(feeModule));

        vm.startPrank(host1);
        token.approve(address(campaigns), 100 ether);
        campaigns.fundCampaignERC20(id, 100 ether);
        vm.stopPrank();

        // Token skims 5 ether in transit -> 95 ether actually received. Protocol fee is 10% of
        // the RECEIVED amount (9.5 ether), not 10% of the nominal 100 ether (10 ether) -- the
        // contract can never owe a fee on funds it never actually custodied. That 9.5 ether is
        // debited from the contract's own balance in full (escrow accounting is internal
        // bookkeeping, unaffected by what the token does on the way out), but the treasury itself
        // nets less than 9.5 ether: the fee-payout transfer is itself subject to the SAME token's
        // 5% in-transit skim, since safeTransfer has no balance-diff protection of its own (that
        // would require repeating the same fee-on-transfer defense on every outbound leg, which is
        // out of scope for the escrow-accounting fix this test targets).
        uint256 nominalFee = 9.5 ether;
        uint256 expectedEscrow = 95 ether - nominalFee;
        uint256 treasuryNetOfTokensOwnSkim = nominalFee - (nominalFee * 500 / 10_000);

        (, uint256 escrowed,,,,) = campaigns.getERC20Settlement(id);
        assertEq(escrowed, expectedEscrow);
        assertEq(token.balanceOf(treasury), treasuryNetOfTokensOwnSkim);
        assertEq(token.balanceOf(address(campaigns)), expectedEscrow);
    }

    /*//////////////////////////////////////////////////////////////
                            DEGENERATE CASE
    //////////////////////////////////////////////////////////////*/

    function test_FundCampaignERC20_RevertsIfTokenSkimsEverything() public {
        token = new FeeOnTransferMock(10_000); // 100% skimmed -- nothing ever arrives
        token.mint(host1, 1_000 ether);
        uint256 id = _draftCampaign();

        vm.startPrank(host1);
        token.approve(address(campaigns), 100 ether);
        vm.expectRevert(CampaignStorage.Web3Campaigns__NoFundsReceived.selector);
        campaigns.fundCampaignERC20(id, 100 ether);
        vm.stopPrank();
    }
}
