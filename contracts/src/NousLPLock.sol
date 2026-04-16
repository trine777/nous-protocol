// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title NousLPLock — Timelock for Uniswap LP tokens.
/// @notice Locks LP tokens for a minimum duration. Cannot be withdrawn early.
///         Prevents rug-pull perception by making liquidity removal impossible.
contract NousLPLock {
    address public immutable beneficiary;
    IERC20 public immutable lpToken;
    uint256 public immutable unlockTime;

    error TooEarly();
    error NotBeneficiary();

    constructor(address _lpToken, address _beneficiary, uint256 lockDuration) {
        lpToken = IERC20(_lpToken);
        beneficiary = _beneficiary;
        unlockTime = block.timestamp + lockDuration;
    }

    /// @notice Release LP tokens after lock period expires.
    function release() external {
        if (msg.sender != beneficiary) revert NotBeneficiary();
        if (block.timestamp < unlockTime) revert TooEarly();
        lpToken.transfer(beneficiary, lpToken.balanceOf(address(this)));
    }
}
