// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title NousToken — Fixed supply ERC20 for the Nous protocol.
/// @notice 100M total supply, minted once at deployment. No inflation.
contract NousToken is ERC20, ERC20Burnable {
    uint256 public constant TOTAL_SUPPLY = 100_000_000e18;

    constructor() ERC20("Nous", "NOUS") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
