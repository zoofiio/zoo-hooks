// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IProtocol} from "src/interfaces/IProtocol.sol";
import {Context} from "openzeppelin/utils/Context.sol";

contract ProtocolOwner is Context {

    address public immutable protocol;

    constructor(address _protocol_) {
        require(_protocol_ != address(0), "Zero address detected");
        protocol = _protocol_;
    }

    modifier onlyOwner() {
        require(_msgSender() == owner(), "Caller is not the owner");
        _;
    }

    function owner() public view returns(address) {
        return IProtocol(protocol).owner();
    }

}