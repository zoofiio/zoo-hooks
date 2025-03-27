// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProtocolOwner} from "src/ProtocolOwner.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "openzeppelin/token/ERC20/extensions/ERC20Burnable.sol";
import {ReentrancyGuard} from "openzeppelin/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "openzeppelin/utils/structs/EnumerableSet.sol";

contract StandardYieldToken is ProtocolOwner, ERC20, ERC20Burnable, ReentrancyGuard {
    constructor(address _protocol) ProtocolOwner(_protocol) ERC20("Zoo Standard Yield Token", "SY") {}

    function mint(address to, uint256 value) public virtual nonReentrant onlyOwner{
        _mint(to, value);
    }
}