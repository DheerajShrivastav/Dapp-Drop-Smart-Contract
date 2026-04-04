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
- [Slither](https://github.com/crytic/slither) — static analysis
- [Aderyn](https://github.com/Cyfrin/aderyn) — security analysis

### Setup

```bash
# Clone the repository
git clone <your-repository-url>
cd DappDrop/smart-contract

# Install dependencies
forge install

# Install security tools
make install-security-tools
```

**Using the devcontainer (recommended):**  
Open this project in VS Code and select **"Reopen in Container"** — this gives you a sandboxed environment with all tools pre-installed. See [.devcontainer/devcontainer.json](.devcontainer/devcontainer.json).

### Build

```bash
forge build
```

### Test

```bash
forge test
```

### Security Analysis

> Reference: [How to Not Accidentally Shoot Yourself in the Foot with AI Development](https://www.cyfrin.io/blog/how-to-not-accidentally-shoot-yourself-in-the-foot-with-ai-development)

Run static analysis and security scanning before every commit:

```bash
# Run Slither static analysis (filters out library findings)
make slither

# Run Aderyn security analysis
make aderyn

# Run all security tools at once
make audit
```

### AI-Assisted Development Safety

This project includes guardrails for safe AI-assisted development:

| Layer | What | File |
|-------|------|------|
| AI Rules | Security-focused prompts & constraints for AI code generation | [CLAUDE.md](CLAUDE.md) |
| Static Analysis | Slither config scoped to `src/`, excludes libraries | [slither.config.json](slither.config.json) |
| Sandboxed Env | Devcontainer with all tools pre-installed | [.devcontainer/devcontainer.json](.devcontainer/devcontainer.json) |
| Automation | Makefile targets for build, test, and audit | [Makefile](Makefile) |

**Key practices (from the Cyfrin article):**

1. **Never expose secrets** — use `forge script --account <keystore>` for deploys, never raw private keys
2. **Review every AI-generated diff** — you are the developer and the security researcher
3. **Run `make audit` before committing** — catch issues before they reach the repo
4. **Verify dependencies** — don't blindly install AI-suggested packages
5. **Use the devcontainer** — sandboxes AI tool access, limits blast radius

### Deploy

```bash
# Deploy to Sepolia (uses keystore account — never paste private keys)
make deploy-sepolia
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
