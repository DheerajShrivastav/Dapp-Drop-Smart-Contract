// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Import all the modular components
import "./CampaignManagement.sol";
import "./ParticipantManagement.sol";
import "./CampaignViewFunctions.sol";

// This is the main contract that users will interact with.
// It inherits all the functionalities from the modular contracts.
contract Web3Campaigns is
    CampaignManagement,
    ParticipantManagement,
    CampaignViewFunctions
{
    // The constructor will automatically call the constructors of its base contracts.
    // In this case, CampaignManagement's constructor will handle AccessControl initialization.
    constructor() {}

    // Receive and fallback functions remain here as they deal with Ether sent directly to this contract.
    receive() external payable {}

    fallback() external payable {}
}
