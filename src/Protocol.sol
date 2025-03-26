// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IProtocol} from "src/interfaces/IProtocol.sol";
import {Ownable} from "openzeppelin/access/Ownable.sol";

contract Protocol is IProtocol, Ownable {

    constructor() Ownable(_msgSender()) {}

    function owner() public view override(Ownable, IProtocol) returns (address) {
        return Ownable.owner();
    }

}