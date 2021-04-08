// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

// For interacting with our own strategy A
interface IStratA {
    // Total want tokens managed by strategy
    function depositReward(uint256 _depositAmt) external returns (bool);
}