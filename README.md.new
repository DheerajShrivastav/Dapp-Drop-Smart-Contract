# Web3Campaigns Smart Contracts

This directory contains the smart contract components of the DappDrop platform, a decentralized system for creating, managing, and participating in Web3 marketing campaigns.

## Architecture

The smart contract system uses a modular design with several key components:

1. **Web3Campaigns**: Main contract that inherits functionality from all other components
2. **CampaignManagement**: Handles campaign creation, task addition, and campaign lifecycle management
3. **ParticipantManagement**: Manages participant interactions, task completion, and reward claiming
4. **CampaignStorage**: Defines shared data structures and state variables used across contracts
5. **CampaignViewFunctions**: Provides read-only functions for retrieving campaign data

## Development

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) for building and testing
- Solidity ^0.8.20

### Setup

```bash
# Clone the repository
git clone <your-repository-url>
cd DappDrop/smart-contract

# Install dependencies
forge install
```

### Build

```bash
forge build
```

### Test

```bash
forge test
```

### Deploy

```bash
# Deploy to a testnet
forge create ./src/Web3Campaigns.sol:Web3Campaigns --rpc-url <your-rpc-url> --account <your-account> --verify --etherscan-api-key <your-key> --broadcast
```

## Contract Functionality

### Campaign Creation and Management

- Create campaigns with start/end times
- Add tasks of different types (social media, on-chain actions)
- Configure rewards (ERC20, ERC721)
- Open, end, and close campaigns

### Participant Interactions

- Complete tasks with automated verification for on-chain actions
- Claim rewards after completing required tasks
- View campaign details and progress

### Security Features

- Role-based access control
- Pause/unpause functionality for emergency situations
- Rate limiting to prevent abuse
- Non-reentrancy guards

## License

This project is licensed under the MIT License.
