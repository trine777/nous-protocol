# Nous Protocol

## Project
Nous (νοῦς) — cognitive frontier thought marketplace.
Stake ETH to post questions, pay to unlock answers, vote via bonding curve.

## Stack
- **Contracts**: Solidity, Foundry (Base L2)
- **Frame**: Farcaster Frame, Frog/Next.js
- **Storage**: PostgreSQL (v1), IPFS (v2)

## Architecture
```
contracts/       Solidity smart contracts (Foundry)
  src/           Contract source
  test/          Forge tests
  script/        Deploy scripts
frame/           Farcaster Frame app (Next.js + Frog)
  app/           Frame routes
docs/            Design docs, D23 decision record
```

## Key Design Decisions (D23)
- No content moderation — pure economic gates (stake + slash)
- Slash: 30 days no unlock → 50% slashed; extend to 90 days costs +50% stake
- Unlock fee: market-priced, 90% author / 10% platform
- Bonding curve: sqrt(votes) × base_price + commit-reveal
- Chain: Base L2
- Identity: Farcaster FID (v1)
- Decentralization: progressive (v0.1 contracts on-chain, frontend centralized)

## Conventions
- Solidity: follow Foundry defaults, pragma ^0.8.24
- Frame: TypeScript, Frog framework
- Test before deploy, always
- Chinese for discussion, English for code/specs

## Managed by
Matrix OS (matrix-os.fly.dev) — Area `nous_forge`
