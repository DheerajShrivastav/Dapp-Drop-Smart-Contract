# Smart Contract Security Tooling
# Reference: https://www.cyfrin.io/blog/how-to-not-accidentally-shoot-yourself-in-the-foot-with-ai-development

.PHONY: build test slither aderyn audit snapshot fmt

# ── Build & Test ─────────────────────────────────────────────
build:
	forge build

test:
	forge test

test-v:
	forge test -vvvv

snapshot:
	forge snapshot

fmt:
	forge fmt

# ── Security Analysis ────────────────────────────────────────
slither:
	slither src/ --config-file slither.config.json

aderyn:
	aderyn .

# Run all security tools in sequence
audit: slither aderyn
	@echo "Security audit complete. Review findings above."

# ── Setup ────────────────────────────────────────────────────
install-security-tools:
	@echo "Installing Slither..."
	pip3 install slither-analyzer
	@echo "Installing Aderyn..."
	cargo install aderyn
	@echo "Done. Run 'make audit' to analyze your contracts."

install:
	forge install

# ── Deployment Safety ────────────────────────────────────────
# Always use --account (keystore) instead of raw private keys
deploy-sepolia:
	@echo "Using keystore account for deployment (never paste private keys)"
	forge script script/DeployWeb3Campaigns.s.sol:DeployWeb3Campaigns \
		--rpc-url $${SEPOLIA_RPC_URL} \
		--account $${DEPLOYER_ACCOUNT} \
		--broadcast \
		--verify \
		--etherscan-api-key $${ETHERSCAN_API_KEY}
