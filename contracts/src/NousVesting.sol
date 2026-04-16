// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/finance/VestingWallet.sol";

/// @title NousVesting — Founder token vesting (12 months linear, 6 month cliff).
/// @notice Wraps OpenZeppelin VestingWallet. Tokens vest linearly over 12 months
///         starting after a 6 month cliff. Before the cliff, nothing is releasable.
contract NousVesting is VestingWallet {
    /// @param beneficiary Founder address receiving vested tokens.
    constructor(address beneficiary)
        VestingWallet(beneficiary, uint64(block.timestamp + 180 days), 365 days)
    {}
}
