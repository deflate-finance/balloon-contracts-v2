// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

/**
 * @dev Interface for AutoFarm.
 */
interface IPancakePair {

    function token0() external view returns (address);
    function token1() external view returns (address);
}