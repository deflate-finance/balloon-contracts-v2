// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./interfaces/IWBNB.sol";
import "./StratY.sol";

contract StratY_AUTO is StratY {

    constructor(
        address _autoFarmAddress,
        address _rewardAddress,
        address _rewardToken,
        address _balloonAddress,
        bool _isTokenStaking,
        address _farmContractAddress,
        uint256 _farmPid,
        address _wantAddress,
        address _earnedAddress
    ) public {
        govAddress = msg.sender;
        autoFarmAddress = _autoFarmAddress;
        rewardAddress = _rewardAddress;
        rewardToken = _rewardToken;
        balloonAddress = _balloonAddress;
        
        isTokenStaking = _isTokenStaking;
        wantAddress = _wantAddress;

        farmContractAddress = _farmContractAddress;	
        pid = _farmPid;
        earnedAddress = _earnedAddress;

        earnedToWbnbPath = [earnedAddress, wbnbAddress];
        earnedToRewardPath = [earnedAddress, wbnbAddress, rewardToken];
        if (wbnbAddress == rewardToken) {
            earnedToRewardPath = [earnedAddress, wbnbAddress];
        }

        earnedToBLNPath = [earnedAddress, wbnbAddress, balloonAddress];
        if (wbnbAddress == earnedAddress) {
            earnedToBLNPath = [wbnbAddress, balloonAddress];
        }
    
        wantToWbnbPath = [wantAddress, wbnbAddress];
        if (isTokenStaking) {
            earnedToWantPath = [earnedAddress, wbnbAddress, wantAddress];
            if (wbnbAddress == wantAddress) {
                earnedToWantPath = [earnedAddress, wantAddress];
            }
        } else {
            token0Address = IPancakePair(wantAddress).token0();
            token1Address = IPancakePair(wantAddress).token1();
            
            earnedToToken0Path = [earnedAddress, wbnbAddress, token0Address];
            if (wbnbAddress == token0Address) {
                earnedToToken0Path = [earnedAddress, wbnbAddress];
            }
    
            earnedToToken1Path = [earnedAddress, wbnbAddress, token1Address];
            if (wbnbAddress == token1Address) {
                earnedToToken1Path = [earnedAddress, wbnbAddress];
            }
    
            token0ToEarnedPath = [token0Address, wbnbAddress, earnedAddress];
            if (wbnbAddress == token0Address) {
                token0ToEarnedPath = [wbnbAddress, earnedAddress];
            }
    
            token1ToEarnedPath = [token1Address, wbnbAddress, earnedAddress];
            if (wbnbAddress == token1Address) {
                token1ToEarnedPath = [wbnbAddress, earnedAddress];
            }
        }

        transferOwnership(autoFarmAddress);
        
        _resetAllowances();
    }
}