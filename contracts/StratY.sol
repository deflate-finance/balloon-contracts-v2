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

Fork from AutoFarm with isAutoComp and isCakeStaking removed
Autocompounding for Autofarm and clones, for lp token
Is it wrong to autocompound our fork?
Earned, want, and the individual lp tokens are stored here.
*/

// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/token/ERC20/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/utils/EnumerableSet.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/utils/Pausable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/utils/ReentrancyGuard.sol";

import "./interfaces/IAutoFarm.sol";
import "./interfaces/IPancakePair.sol";
import "./interfaces/IPancakeRouter02.sol";
import "./interfaces/IStrategy.sol";
import "./interfaces/IStratA.sol";

abstract contract StratY is Ownable, ReentrancyGuard, Pausable {
    // Maximises yields in autofarm

    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    bool public isTokenStaking;

    address public farmContractAddress; // address of farm, eg, Auto, Swamp, etc.	
    uint256 public pid; // pid of pool in farmContractAddress
    address public wantAddress;
    address public token0Address;
    address public token1Address;
    address public earnedAddress;
    
    address public constant pcsRouterAddress = 0x10ED43C718714eb63d5aA57B78B54704E256024E; // uniswap, pancakeswap etc
    address public constant wbnbAddress = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public rewardToken;
    address public rewardAddress; // StratA
    address public constant devAddress = 0x7ead6eb3aB594817995F9995D091c06913c9A21C;
    address public autoFarmAddress;
    address public balloonAddress;
    address public constant depositFeeAddress = 0x4E62a0488f0E207B3087e321937Fd9F5240ab930;
    address public govAddress; // timelock contract

    uint256 public lastEarnBlock = block.number;
    uint256 public sharesTotal = 0;

    address public constant buyBackAddress = 0x000000000000000000000000000000000000dEaD;
    uint256 public controllerFee = 100;
    uint256 public rewardRate = 150;
    uint256 public buyBackRate = 200;
    uint256 public constant feeMaxTotal = 450; // 4.5%. Anything above this is a negative APY
    uint256 public constant feeMax = 10000; // 100 = 1%
    
    uint256 public entranceFeeFactor = 9990; // < 0.1% entrance fee - used for farm autocompounding
    uint256 public constant entranceFeeFactorMax = 10000;
    uint256 public constant entranceFeeFactorLL = 9950; // 0.5% is the max entrance fee settable. LL = lowerlimit

    uint256 public slippageFactor = 950; // 5% default slippage tolerance
    uint256 public constant slippageFactorUL = 995;

    address[] public earnedToWbnbPath;
    address[] public earnedToRewardPath;
    address[] public earnedToBLNPath;
    address[] public earnedToWantPath;
    address[] public earnedToToken0Path;
    address[] public earnedToToken1Path;
    address[] public token0ToEarnedPath;
    address[] public token1ToEarnedPath;
    address[] public wantToWbnbPath;
    
    event SetSettings(
        uint256 _controllerFee,
        uint256 _rewardRate,
        uint256 _buyBackRate,
        uint256 _entranceFeeFactor,
        uint256 _slippageFactor
    );
    
    modifier govOnly() {
        require(msg.sender == govAddress, "!gov");
        _;
    }

    /**
     * Receives new deposits from user, can only be called by MasterChef
     * _userAddress not used, possibly used by other strats
     */
    function deposit(address _userAddress, uint256 _wantAmt) external onlyOwner nonReentrant whenNotPaused returns (uint256) {
        IERC20(wantAddress).safeTransferFrom(
            address(msg.sender),
            address(this),
            _wantAmt
        );
        
        // Deposit fee
        uint256 depositFee = _wantAmt
            .mul(entranceFeeFactorMax.sub(entranceFeeFactor))
            .div(entranceFeeFactorMax);
        IERC20(wantAddress).safeTransfer(depositFeeAddress, depositFee);

        // Also make sure you account for farm fees
        uint256 sharesBefore = vaultSharesTotal();
        uint256 sharesAdded = _farm();
        if (sharesTotal != 0) {
            sharesAdded.mul(sharesTotal).div(sharesBefore);
        }

        sharesTotal = sharesTotal.add(sharesAdded);

        return sharesAdded;
    }

    // If want tokens ever get stuck
    function farm() external govOnly {
        _farm();
    }

    // Deposit into the yield farm we're autocompounding
    function _farm() internal returns (uint256) {
        uint256 wantAmt = IERC20(wantAddress).balanceOf(address(this));
        if(wantAmt == 0) return 0;

        uint256 sharesBefore = vaultSharesTotal();
        IAutoFarm(farmContractAddress).deposit(pid, wantAmt);
        uint256 sharesAfter = vaultSharesTotal();
        uint256 sharesAmount = sharesAfter.sub(sharesBefore); // Entrance fees
        return sharesAmount;
    }

    /**
     * Returns deposits from user, can only be called by MasterChef
     * _userAddress not used, possibly used by other strats
     */
    function withdraw(address _userAddress, uint256 _wantAmt) external onlyOwner nonReentrant returns (uint256) {
        require(_wantAmt > 0, "_wantAmt is 0");

        uint256 sharesRemoved = _wantAmt.mul(sharesTotal).div(wantLockedTotal());
        
        uint256 wantBal = IERC20(wantAddress).balanceOf(address(this));
        
        if (wantBal < _wantAmt) {
            IAutoFarm(farmContractAddress).withdraw(pid, _wantAmt.sub(wantBal));
            wantBal = IERC20(wantAddress).balanceOf(address(this));
        }
        if (wantBal > _wantAmt) {
            wantBal = _wantAmt;
        }
        if (sharesRemoved > wantBal) {
            sharesRemoved = wantBal;
        }

        sharesTotal = sharesTotal.sub(sharesRemoved);

        IERC20(wantAddress).safeTransfer(autoFarmAddress, _wantAmt);

        return sharesRemoved;
    }

    /**
     * 1. Harvest farm tokens
     * 2. Converts farm tokens into want tokens
     * 3. Deposits want tokens
     */
    function earn() external virtual nonReentrant whenNotPaused {
        IAutoFarm(farmContractAddress).withdraw(pid, 0);

        // Converts farm tokens into want tokens
        uint256 earnedAmt = IERC20(earnedAddress).balanceOf(address(this));

        earnedAmt = distributeFees(earnedAmt);
        earnedAmt = distributeRewards(earnedAmt);
        earnedAmt = buyBack(earnedAmt);

        if (isTokenStaking) {
            if (earnedAddress != wantAddress) {
                _safeSwap(
                    earnedAmt,
                    earnedToWantPath,
                    address(this)
                );
            }
        } else {
            if (earnedAddress != token0Address) {
                // Swap half earned to token0
                _safeSwap(
                    earnedAmt.div(2),
                    earnedToToken0Path,
                    address(this)
                );
            }
    
            if (earnedAddress != token1Address) {
                // Swap half earned to token1
                _safeSwap(
                    earnedAmt.div(2),
                    earnedToToken1Path,
                    address(this)
                );
            }
    
            // Get want tokens, ie. add liquidity
            uint256 token0Amt = IERC20(token0Address).balanceOf(address(this));
            uint256 token1Amt = IERC20(token1Address).balanceOf(address(this));
            if (token0Amt > 0 && token1Amt > 0) {
                IPancakeRouter02(pcsRouterAddress).addLiquidity(
                    token0Address,
                    token1Address,
                    token0Amt,
                    token1Amt,
                    0,
                    0,
                    address(this),
                    now.add(600)
                );
            }
        }

        lastEarnBlock = block.number;

        _farm();
    }

    /**
     * 1. Takes a percentage (1%) of earned tokens
     * 2. Converts the percentage to WBNB
     * 3. Rewards dev for existing
     */
    function distributeFees(uint256 _earnedAmt) internal returns (uint256) {
        if (_earnedAmt > 0 && controllerFee > 0) {
            // Performance fee
            uint256 fee = _earnedAmt.mul(controllerFee).div(feeMax);
    
            // One must hope for a BNB pairing
            _safeSwapBnb(
                fee,
                earnedToWbnbPath,
                devAddress
            );
            
            _earnedAmt = _earnedAmt.sub(fee);
        }

        return _earnedAmt;
    }

    /**
     * 1. Takes a percentage (1%) of earned tokens
     * 2. Converts the percentage to WBNB
     * 3. Rewards BLN-BNB stakers with the WBNB
     */
    function distributeRewards(uint256 _earnedAmt) internal returns (uint256) {
        if (_earnedAmt > 0 && rewardRate > 0) {
            // Performance fee
            uint256 fee = _earnedAmt.mul(rewardRate).div(feeMax);
    
            uint256 currReward = IERC20(rewardToken).balanceOf(address(this));
            
            // One must hope for a BNB pairing
            _safeSwap(
                fee,
                earnedToRewardPath,
                address(this)
            );
            
            uint256 diffReward = IERC20(rewardToken).balanceOf(address(this)).sub(currReward);
            
            IStratA(rewardAddress).depositReward(diffReward);
            
            _earnedAmt = _earnedAmt.sub(fee);
        }

        return _earnedAmt;
    }

    /**
     * 1. Takes a percentage (1%) of earned tokens
     * 2. Converts the percentage to BLN
     * 3. Burns the BLN
     */
    function buyBack(uint256 _earnedAmt) internal returns (uint256) {
        if (buyBackRate > 0) {
            uint256 buyBackAmt = _earnedAmt.mul(buyBackRate).div(feeMax);
    
            _safeSwap(
                buyBackAmt,
                earnedToBLNPath,
                buyBackAddress
            );
            
            _earnedAmt = _earnedAmt.sub(buyBackAmt);
        }

        return _earnedAmt;
    }

    /**
     * Every time earn() is called dust will accumulate
     * Converts dust tokens into earned tokens, which will be reinvested on the next earn().
     */
    function convertDustToEarned() external nonReentrant whenNotPaused {
        require(!isTokenStaking, "isTokenStaking");
        // Converts token0 dust (if any) to earned tokens
        uint256 token0Amt = IERC20(token0Address).balanceOf(address(this));
        if (token0Amt > 0 && token0Address != earnedAddress) {
            // Swap all dust tokens to earned tokens
            _safeSwap(
                token0Amt,
                token0ToEarnedPath,
                address(this)
            );
        }

        // Converts token1 dust (if any) to earned tokens
        uint256 token1Amt = IERC20(token1Address).balanceOf(address(this));
        if (token1Amt > 0 && token1Address != earnedAddress) {
            // Swap all dust tokens to earned tokens
            _safeSwap(
                token1Amt,
                token1ToEarnedPath,
                address(this)
            );
        }
    }
    
    function vaultSharesTotal() public view returns (uint256) {	
        (uint256 vaultShares,) = IAutoFarm(farmContractAddress).userInfo(pid, address(this));
        return vaultShares;
    }
    
    function wantLockedTotal() public view returns (uint256) {	
        return IERC20(wantAddress).balanceOf(address(this))
            .add(IAutoFarm(farmContractAddress).stakedWantTokens(pid, address(this)));
    }
    
    function updateRewardAddress(address _rewardAddress, address _rewardToken) external govOnly {	
        rewardAddress = _rewardAddress;
        rewardToken = _rewardToken;
        earnedToRewardPath = [earnedAddress, wbnbAddress, _rewardToken];
    }

    // Stops time
    function pause() external govOnly {
        _pause();
    }

    // The strat lives once more
    function unpause() external govOnly {
        _unpause();
    }

    function _resetAllowances() internal {
        IERC20(wantAddress).safeApprove(farmContractAddress, uint256(0));
        IERC20(wantAddress).safeIncreaseAllowance(
            farmContractAddress,
            uint256(-1)
        );

        IERC20(wantAddress).safeApprove(pcsRouterAddress, uint256(0));
        IERC20(wantAddress).safeIncreaseAllowance(
            pcsRouterAddress,
            uint256(-1)
        );

        IERC20(earnedAddress).safeApprove(pcsRouterAddress, uint256(0));
        IERC20(earnedAddress).safeIncreaseAllowance(
            pcsRouterAddress,
            uint256(-1)
        );

        if (!isTokenStaking) {
            IERC20(token0Address).safeApprove(pcsRouterAddress, uint256(0));
            IERC20(token0Address).safeIncreaseAllowance(
                pcsRouterAddress,
                uint256(-1)
            );
    
            IERC20(token1Address).safeApprove(pcsRouterAddress, uint256(0));
            IERC20(token1Address).safeIncreaseAllowance(
                pcsRouterAddress,
                uint256(-1)
            );
        }
        
        IERC20(wbnbAddress).safeApprove(rewardAddress, uint256(0));
        IERC20(wbnbAddress).safeIncreaseAllowance(
            rewardAddress,
            uint256(-1)
        );
    }
    
    function setSettings(
        uint256 _controllerFee,
        uint256 _rewardRate,
        uint256 _buyBackRate,
        uint256 _entranceFeeFactor,
        uint256 _slippageFactor
    ) external govOnly {
        require(_controllerFee.add(_rewardRate).add(_buyBackRate) <= feeMaxTotal, "Max fee of 4.5%");
        require(_entranceFeeFactor >= entranceFeeFactorLL, "_entranceFeeFactor too low");
        require(_entranceFeeFactor <= entranceFeeFactorMax, "_entranceFeeFactor too high");
        require(_slippageFactor <= slippageFactorUL, "_slippageFactor too high");
        controllerFee = _controllerFee;
        rewardRate = _rewardRate;
        buyBackRate = _buyBackRate;
        entranceFeeFactor = _entranceFeeFactor;
        slippageFactor = _slippageFactor;

        emit SetSettings(
            _controllerFee,
            _rewardRate,
            _buyBackRate,
            _entranceFeeFactor,
            _slippageFactor
        );
    }


    function setGov(address _govAddress) external govOnly {
        govAddress = _govAddress;
    }

    /**
     * @dev Pauses deposits. Withdraws all funds from the MasterChef, leaving rewards behind
     */
    function panic() external govOnly {
        _pause();
        IAutoFarm(farmContractAddress).withdraw(pid, uint(-1));
    }

    /**
     * @dev Pauses deposits. Withdraws all funds from the MasterChef, leaving rewards behind
     */
    function panicEmergency() external govOnly {
        _pause();
        IAutoFarm(farmContractAddress).emergencyWithdraw(pid);
    }

    function unpanic() external govOnly {
        _unpause();
        _farm();
    }

    
    function _safeSwap(
        uint256 _amountIn,
        address[] memory _path,
        address _to
    ) internal {
        uint256[] memory amounts = IPancakeRouter02(pcsRouterAddress).getAmountsOut(_amountIn, _path);
        uint256 amountOut = amounts[amounts.length.sub(1)];

        IPancakeRouter02(pcsRouterAddress).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            _amountIn,
            amountOut.mul(slippageFactor).div(1000),
            _path,
            _to,
            now.add(600)
        );
    }
    
    function _safeSwapBnb(
        uint256 _amountIn,
        address[] memory _path,
        address _to
    ) internal {
        uint256[] memory amounts = IPancakeRouter02(pcsRouterAddress).getAmountsOut(_amountIn, _path);
        uint256 amountOut = amounts[amounts.length.sub(1)];

        IPancakeRouter02(pcsRouterAddress).swapExactTokensForETHSupportingFeeOnTransferTokens(
            _amountIn,
            amountOut.mul(slippageFactor).div(1000),
            _path,
            _to,
            now.add(600)
        );
    }
}