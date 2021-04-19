// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

/**
 * @dev Interface for AutoFarm.
 */
interface IAutoFarm {

    /**
     * @dev View function to see pending AUTO on frontend.
     */ 
    function pendingAUTO(uint256 _pid, address _user) external view returns (uint256);

    /**
     * @dev View function to see staked Want tokens on frontend.
     */
    function stakedWantTokens(uint256 _pid, address _user) external view returns (uint256);

    /**
     * @dev Want tokens moved from user -> AUTOFarm (AUTO allocation) -> Strat (compounding)
     */ 
    function deposit(uint256 _pid, uint256 _amount) external;

    /**
     * @dev Withdraw LP tokens from MasterChef.
     */
    function withdraw(uint256 _pid, uint256 _amount) external;
    
    function userInfo(uint256 _pid, address _user) external view returns (uint256, uint256);
}