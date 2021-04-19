/*
             .#############. 
          .###################. 
       .####%####################.,::;;;;;;;;;;, 
      .####%###############%######:::;;;;;;;;;;;;;, 
      ####%%################%######:::;;;;;;;;@;;;;;;, 
      ####%%################%%#####:::;;;;;;;;;@;;;;;;, 
      ####%%################%%#####:::;;;;;;;;;@@;;;;;; 
      `####%################%#####:::;;;;;;;;;;@@;;;;;; 
        `###%##############%####:::;;;;;;;;;;;;@@;;;;;; 
           `#################'::%%%%%%%%%%%%;;;@;;;;;;' 
             `#############'.%%%%%%%%%%%%%%%%%%;;;;;' 
               `#########'%%%%#%%%%%%%%%%%%%%%%%%%, 
                 `#####'.%%%%#%%%%%%%%%%%%%%#%%%%%%, 
                   `##' %%%%##%%%%%%%%%%%%%%%##%%%%% 
                   ###  %%%%##%%%%%%%%%%%%%%%##%%%%% 
                    '   %%%%##%%%%%%%%%%%%%%%##%%%%% 
                   '    `%%%%#%%%%%%%%%%%%%%%#%%%%%' 
                  '       `%%%#%%%%%%%%%%%%%#%%%%' 
                  `         `%%%%%%%%%%%%%%%%%%' 
                   `          `%%%%%%%%%%%%%%' 
                    `           `%%%%%%%%%%'  ' 
                     '            `%%%%%%'   ' 
                    '              `%%%'    ' 
                   '               .%%      ` 
                  `                %%%       ' 
                   `                '       ' 
                    `              '      ' 
                    '            '      ' 
                   '           '       ` 
                  '           '        ' 
                              `       ' 
                               ' 
                              ' 
                             ' 
https://deflate.finance/
https://twitter.com/DeflateFinance
https://t.me/deflateann
https://t.me/deflatechat

Fork of AutoFarm with lots removed and an additional depositReward() function
Not auto compounding, native pool
Only want (BLN-BNB) and reward (WBNB) tokens are stored here.
*/

// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/token/ERC20/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/utils/EnumerableSet.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/utils/Pausable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/utils/ReentrancyGuard.sol";

contract StratA is Ownable, ReentrancyGuard, Pausable {

    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    
    struct UserInfo {
        uint256 shares; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.

        /**
         * We do some fancy math here. Basically, any point in time, the amount of BLN
         * entitled to a user but is pending to be distributed is:
         *
         *   amount = user.shares / sharesTotal * wantLockedTotal
         *   pending reward = (amount * pool.accBalloonPerShare) - user.rewardDebt
         *
         * Whenever a user deposits or withdraws want tokens to a pool. Here's what happens:
         *   1. The pool's `accBalloonPerShare` (and `lastRewardBlock`) gets updated.
         *   2. User receives the pending reward sent to his/her address.
         *   3. User's `amount` gets updated.
         *   4. User's `rewardDebt` gets updated.
         */
    }

    address public constant wbnbAddress = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public wantAddress;

    address public autoFarmAddress;
    address public govAddress; // timelock contract

    mapping(address => UserInfo) public userInfo;
    uint256 public sharesTotal = 0;
    uint256 public wantLockedTotal = 0; // Will always be the same as sharesTotal
    uint256 public accBnbPerShare = 0;

    constructor(
        address _autoFarmAddress,
        address _wantAddress
    ) public {
        govAddress = msg.sender;
        autoFarmAddress = _autoFarmAddress;
        
        wantAddress = _wantAddress;

        transferOwnership(autoFarmAddress);
    }
    
    modifier govOnly() {
        require(msg.sender == govAddress, "!gov");
        _;
    }

    /**
     * @dev Receives new deposits from user, can only be called by MasterChef
     * _userAddress is used
     */
    function deposit(address _userAddress, uint256 _wantAmt) external onlyOwner nonReentrant whenNotPaused returns (uint256) {
        UserInfo storage user = userInfo[_userAddress];
        
        if (user.shares > 0) {
            uint256 pending = user.shares.mul(accBnbPerShare).div(1e18).sub(user.rewardDebt);
            if (pending > 0) {
                IERC20(wbnbAddress).safeTransfer(_userAddress, pending);
            }
        }

        IERC20(wantAddress).safeTransferFrom(
            msg.sender,
            address(this),
            _wantAmt
        );

        sharesTotal = sharesTotal.add(_wantAmt);
        wantLockedTotal = sharesTotal;
        user.shares = user.shares.add(_wantAmt);
        
        user.rewardDebt = user.shares.mul(accBnbPerShare).div(1e18);

        return _wantAmt;
    }

    /**
     * @dev Returns deposits from user, can only be called by MasterChef
     * _userAddress is used
     */
    function withdraw(address _userAddress, uint256 _wantAmt) external onlyOwner nonReentrant returns (uint256) {
        require(_wantAmt > 0, "_wantAmt <= 0");
        UserInfo storage user = userInfo[_userAddress];
        
        // Withdraw pending BLN
        uint256 pending = user.shares.mul(accBnbPerShare).div(1e18).sub(user.rewardDebt);
        
        if (pending > 0) {
            IERC20(wbnbAddress).safeTransfer(_userAddress, pending);
        }

        uint256 wantAmt = IERC20(wantAddress).balanceOf(address(this));
        if (_wantAmt > wantAmt) {
            _wantAmt = wantAmt;
        }
        
        sharesTotal = sharesTotal.sub(_wantAmt);
        wantLockedTotal = sharesTotal;

        IERC20(wantAddress).safeTransfer(autoFarmAddress, _wantAmt);
        if (_wantAmt > user.shares) {
            user.shares = 0;
        } else {
            user.shares = user.shares.sub(_wantAmt);
        }
        
        user.rewardDebt = user.shares.mul(accBnbPerShare).div(1e18);

        return _wantAmt;
    }
    
    /**
     * @dev Called by MasterChef to properly reward stakers with WBNB
     * Anyone is free to call this function if they feel generous
     */
    function depositReward(uint256 _depositAmt) external returns (bool) {
        IERC20(wbnbAddress).safeTransferFrom(msg.sender, address(this), _depositAmt);
        accBnbPerShare = accBnbPerShare.add(_depositAmt.mul(1e18).div(sharesTotal));
        
        return true;
    }

    // Stops time
    function pause() external govOnly {
        _pause();
    }

    // The strat lives once more
    function unpause() external govOnly {
        _unpause();
    }

    function setGov(address _govAddress) external govOnly {
        govAddress = _govAddress;
    }
}