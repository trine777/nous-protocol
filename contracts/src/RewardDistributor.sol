// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title RewardDistributor — Rate-limited $NOUS reward distribution.
/// @notice Holds the community reward pool (40M $NOUS). Only the authorized
///         NousCore contract can request distributions, capped at DAILY_LIMIT per day.
contract RewardDistributor is Ownable {
    IERC20 public immutable nous;
    address public core; // NousCore contract, set once
    uint256 public constant DAILY_LIMIT = 10_000e18; // 10,000 $NOUS per day

    uint256 public dayStart;
    uint256 public dayDistributed;

    error Unauthorized();
    error DailyLimitExceeded();
    error CoreAlreadySet();

    modifier onlyCore() {
        if (msg.sender != core) revert Unauthorized();
        _;
    }

    constructor(address nousToken) Ownable(msg.sender) {
        nous = IERC20(nousToken);
        dayStart = block.timestamp;
    }

    /// @notice Set the NousCore contract address. Can only be called once.
    function setCore(address _core) external onlyOwner {
        if (core != address(0)) revert CoreAlreadySet();
        core = _core;
    }

    /// @notice Distribute reward tokens to a recipient. Called by NousCore.
    /// @param to Recipient address.
    /// @param amount Amount of $NOUS to distribute.
    function distribute(address to, uint256 amount) external onlyCore {
        _rollDay();
        if (dayDistributed + amount > DAILY_LIMIT) revert DailyLimitExceeded();
        dayDistributed += amount;
        nous.transfer(to, amount);
    }

    /// @notice Check remaining distribution capacity for today.
    function remainingToday() external view returns (uint256) {
        if (block.timestamp >= dayStart + 1 days) return DAILY_LIMIT;
        return DAILY_LIMIT - dayDistributed;
    }

    function _rollDay() internal {
        if (block.timestamp >= dayStart + 1 days) {
            dayStart = block.timestamp;
            dayDistributed = 0;
        }
    }
}
