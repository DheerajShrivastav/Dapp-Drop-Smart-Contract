# CLAUDE.md — AI Development Security Rules

> Based on: [How to Not Accidentally Shoot Yourself in the Foot with AI Development](https://www.cyfrin.io/blog/how-to-not-accidentally-shoot-yourself-in-the-foot-with-ai-development)

## Core Principle

**You are the developer. You are the security researcher.** Every line of AI-generated code must be reviewed as if you wrote it by hand. AI is a tool — you own the output.

## Security Rules for AI-Assisted Development

### Never expose secrets

- Never include private keys, mnemonics, or API keys in prompts or code
- Use `--account` keystore or environment variables for deployment
- Treat all cloud-based AI as public — anything you send may be logged

### Code generation rules

- Never hardcode private keys, even for tests (use `vm.addr()` / `makeAddr()`)
- Always use OpenZeppelin's audited contracts over hand-rolled implementations
- Never use `tx.origin` for authorization
- Always use `ReentrancyGuard` on functions that make external calls
- Use `SafeERC20` for all token transfers
- Validate all external inputs at contract boundaries
- Use `Checks-Effects-Interactions` pattern in all state-changing functions
- Emit events for all critical state changes

### Dependency safety

- Verify every AI-suggested package exists and is legitimate before installing
- Run `forge update` only for known, trusted dependencies
- Never blindly add git submodules without checking the source repository
- Pin dependency versions — no floating refs

### Before committing any AI-generated code

1. Read every line of the diff — no exceptions
2. Run `forge build` — must compile cleanly
3. Run `forge test` — all tests must pass
4. Run `make slither` — review all findings
5. Run `make aderyn` — review all findings
6. Check for common Solidity pitfalls: reentrancy, overflow, access control, front-running

## Build & Test Commands

```bash
forge build          # Compile contracts
forge test           # Run all tests
forge test -vvvv     # Run tests with full trace
make slither         # Run Slither static analysis
make aderyn          # Run Aderyn security analysis
make audit           # Run all security tools
```
