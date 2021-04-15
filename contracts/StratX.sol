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

Fork from AutoFarm with isAutoComp removed
Autocompounding for PancakeSwap and clones
Earned, want, and the individual lp tokens are stored here.
*/

// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/token/ERC20/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/utils/EnumerableSet.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/utils/Pausable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/utils/ReentrancyGuard.sol";

import "./IPancakeswapFarm.sol";
import "./IPancakeRouter02.sol";
import "./IStratA.sol";

contract StratX is Ownable, ReentrancyGuard, Pausable {
    // Maximises yields in pancakeswap

    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    bool public isCAKEStaking; // only for staking CAKE using pancakeswap's native CAKE staking contract.

    address public farmContractAddress; // address of farm, eg, PCS, Thugs etc.
    uint256 public pid; // pid of pool in farmContractAddress
    address public wantAddress;
    address public token0Address;
    address public token1Address;
    address public earnedAddress;
    
    address public constant pcsRouterAddress = 0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F; // uniswap, pancakeswap etc
    address public constant wbnbAddress = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public rewardAddress; // StratA
    address public constant devAddress = 0x47231b2EcB18b7724560A78cd7191b121f53FABc;
    address public autoFarmAddress;
    address public balloonAddress;
    address public govAddress; // timelock contract
    bool public onlyGov = true; // used for earn()

    uint256 public lastEarnBlock = block.number;
    uint256 public wantLockedTotal = 0;
    uint256 public sharesTotal = 0;

    uint256 public constant controllerFee = 100;
    uint256 public constant controllerFeeMax = 10000; // 100 = 1%

    uint256 public constant rewardRate = 100;
    uint256 public constant rewardRateMax = 10000; // 100 = 1%

    uint256 public constant buyBackRate = 100;
    uint256 public constant buyBackRateMax = 10000; // 100 = 1%
    address public constant buyBackAddress = 0x000000000000000000000000000000000000dEaD;

    uint256 public entranceFeeFactor = 9990; // < 0.1% entrance fee - goes to pool + prevents front-running
    uint256 public constant entranceFeeFactorMax = 10000;
    uint256 public constant entranceFeeFactorLL = 9950; // 0.5% is the max entrance fee settable. LL = lowerlimit

    uint256 public slippageFactor = 950; // 5% default slippage tolerance
    uint256 public constant slippageFactorUL = 995;

    address[] public earnedToWbnbPath;
    address[] public earnedToBLNPath;
    address[] public earnedToToken0Path;
    address[] public earnedToToken1Path;
    address[] public token0ToEarnedPath;
    address[] public token1ToEarnedPath;

    constructor(
        address _autoFarmAddress,
        address _rewardAddress,
        address _balloonAddress,
        bool _isCAKEStaking,
        address _farmContractAddress,
        uint256 _farmPid,
        address _wantAddress,
        address _token0Address,
        address _token1Address,
        address _earnedAddress
    ) public {
        govAddress = msg.sender;
        autoFarmAddress = _autoFarmAddress;
        rewardAddress = _rewardAddress;
        balloonAddress = _balloonAddress;

        isCAKEStaking = _isCAKEStaking;
        wantAddress = _wantAddress;

        if (!isCAKEStaking) {
            token0Address = _token0Address;
            token1Address = _token1Address;
        }

        farmContractAddress = _farmContractAddress;
        pid = _farmPid;
        earnedAddress = _earnedAddress;

        earnedToWbnbPath = [earnedAddress, wbnbAddress];

        earnedToBLNPath = [earnedAddress, wbnbAddress, balloonAddress];
        if (wbnbAddress == earnedAddress) {
            earnedToBLNPath = [wbnbAddress, balloonAddress];
        }

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

        transferOwnership(autoFarmAddress);
        
        _resetAllowances();
    }
    
    event SetSettings(
        uint256 _entranceFeeFactor,
        uint256 _slippageFactor
    );
    
    modifier govOnly() {
        require(msg.sender == govAddress, "!gov");
        _;
    }

    /**
     * @dev Receives new deposits from user, can only be called by MasterChef
     * _userAddress not used, possibly used by other strats
     */
    function deposit(address _userAddress, uint256 _wantAmt) external onlyOwner nonReentrant whenNotPaused returns (uint256) {
        IERC20(wantAddress).safeTransferFrom(
            address(msg.sender),
            address(this),
            _wantAmt
        );

        uint256 sharesAdded = _wantAmt;
        if (wantLockedTotal > 0) {
            sharesAdded = _wantAmt
                .mul(sharesTotal)
                .mul(entranceFeeFactor)
                .div(wantLockedTotal)
                .div(entranceFeeFactorMax);
        }
        sharesTotal = sharesTotal.add(sharesAdded);

        _farm();

        return sharesAdded;
    }

    // If want tokens ever get stuck
    function farm() public nonReentrant {
        _farm();
    }

    // Deposit into the yield farm we're autocompounding
    function _farm() internal {
        require(sharesTotal > 0, "No stakers");
        uint256 wantAmt = IERC20(wantAddress).balanceOf(address(this));
        wantLockedTotal = wantLockedTotal.add(wantAmt);

        if (isCAKEStaking) {
            IPancakeswapFarm(farmContractAddress).enterStaking(wantAmt); // Just for CAKE staking, we dont use deposit()
        } else {
            IPancakeswapFarm(farmContractAddress).deposit(pid, wantAmt);
        }
    }

    /**
     * @dev Returns deposits from user, can only be called by MasterChef
     * _userAddress not used, possibly used by other strats
     */
    function withdraw(address _userAddress, uint256 _wantAmt) external onlyOwner nonReentrant returns (uint256) {
        require(_wantAmt > 0, "_wantAmt is 0");

        if (isCAKEStaking) {
            IPancakeswapFarm(farmContractAddress).leaveStaking(_wantAmt); // Just for CAKE staking, we dont use withdraw()
        } else {
            IPancakeswapFarm(farmContractAddress).withdraw(pid, _wantAmt);
        }

        uint256 wantAmt = IERC20(wantAddress).balanceOf(address(this));
        if (_wantAmt > wantAmt) {
            _wantAmt = wantAmt;
        }

        if (wantLockedTotal < _wantAmt) {
            _wantAmt = wantLockedTotal;
        }

        uint256 sharesRemoved = _wantAmt.mul(sharesTotal).div(wantLockedTotal);
        if (sharesRemoved > sharesTotal) {
            sharesRemoved = sharesTotal;
        }
        sharesTotal = sharesTotal.sub(sharesRemoved);
        wantLockedTotal = wantLockedTotal.sub(_wantAmt);

        IERC20(wantAddress).safeTransfer(autoFarmAddress, _wantAmt);

        return sharesRemoved;
    }

    /**
     * 1. Harvest farm tokens
     * 2. Converts farm tokens into want tokens
     * 3. Deposits want tokens
     */
    function earn() external nonReentrant whenNotPaused {
        if (onlyGov) {
            require(msg.sender == govAddress, "Not authorised");
        }

        // Harvest farm tokens
        if (isCAKEStaking) {
            IPancakeswapFarm(farmContractAddress).leaveStaking(0); // Just for CAKE staking, we dont use withdraw()
        } else {
            IPancakeswapFarm(farmContractAddress).withdraw(pid, 0);
        }

        // Converts farm tokens into want tokens
        uint256 earnedAmt = IERC20(earnedAddress).balanceOf(address(this));

        earnedAmt = distributeFees(earnedAmt);
        earnedAmt = distributeRewards(earnedAmt);
        earnedAmt = buyBack(earnedAmt);

        if (isCAKEStaking) {
            lastEarnBlock = block.number;
            _farm();
            return;
        }

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

        lastEarnBlock = block.number;

        _farm();
    }

    /**
     * 1. Takes a percentage (1%) of earned tokens
     * 2. Converts the percentage to BLN
     * 3. Burns the BLN
     */
    function buyBack(uint256 _earnedAmt) internal returns (uint256) {
        if (buyBackRate == 0) {
            return _earnedAmt;
        }

        uint256 buyBackAmt = _earnedAmt.mul(buyBackRate).div(buyBackRateMax);

        _safeSwap(
            buyBackAmt,
            earnedToBLNPath,
            buyBackAddress
        );

        return _earnedAmt.sub(buyBackAmt);
    }

    /**
     * 1. Takes a percentage (1%) of earned tokens
     * 2. Converts the percentage to WBNB
     * 3. Rewards BLN-BNB stakers with the WBNB
     */
    function distributeRewards(uint256 _earnedAmt) internal returns (uint256) {
        if (_earnedAmt > 0 && rewardRate > 0) {
            // Performance fee
            uint256 fee = _earnedAmt.mul(rewardRate).div(rewardRateMax);
    
            uint256 currWbnb = IERC20(wbnbAddress).balanceOf(address(this));
            
            // One must hope for a WBNB pairing
            _safeSwap(
                fee,
                earnedToWbnbPath,
                address(this)
            );
            
            uint256 diffWbnb = IERC20(wbnbAddress).balanceOf(address(this)).sub(currWbnb);
            
            IStratA(rewardAddress).depositReward(diffWbnb);
            
            _earnedAmt = _earnedAmt.sub(fee);
        }

        return _earnedAmt;
    }

    /**
     * 1. Takes a percentage (1%) of earned tokens
     * 2. Converts the percentage to WBNB
     * 3. Rewards dev for existing
     */
    function distributeFees(uint256 _earnedAmt) internal returns (uint256) {
        if (_earnedAmt > 0 && controllerFee > 0) {
            // Performance fee
            uint256 fee = _earnedAmt.mul(controllerFee).div(controllerFeeMax);
    
            // One must hope for a WBNB pairing
            _safeSwap(
                fee,
                earnedToWbnbPath,
                devAddress
            );
            
            _earnedAmt = _earnedAmt.sub(fee);
        }

        return _earnedAmt;
    }

    /**
     * @dev Every time earn() is called dust will accumulate
     * We call this function to convert the dust as well
     */
    function convertDustToEarned() external nonReentrant whenNotPaused {
        require(!isCAKEStaking, "isCAKEStaking");

        // Converts dust tokens into earned tokens, which will be reinvested on the next earn().

        // Converts token0 dust (if any) to earned tokens
        uint256 token0Amt = IERC20(token0Address).balanceOf(address(this));
        if (token0Amt > 0 && token0Address != earnedAddress) {
            // Swap all dust tokens to earned tokens
            IPancakeRouter02(pcsRouterAddress).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                token0Amt,
                0,
                token0ToEarnedPath,
                address(this),
                now.add(600)
            );
        }

        // Converts token1 dust (if any) to earned tokens
        uint256 token1Amt = IERC20(token1Address).balanceOf(address(this));
        if (token1Amt > 0 && token1Address != earnedAddress) {
            // Swap all dust tokens to earned tokens
            IPancakeRouter02(pcsRouterAddress).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                token1Amt,
                0,
                token1ToEarnedPath,
                address(this),
                now.add(600)
            );
        }
    }

    // Stops time
    function pause() external govOnly {
        _pause();
    }

    // The strat lives once more
    function unpause() external govOnly {
        _unpause();
        _resetAllowances();
    }

    function _resetAllowances() internal {
        IERC20(wantAddress).safeApprove(pcsRouterAddress, uint256(0));
        IERC20(wantAddress).safeIncreaseAllowance(
            farmContractAddress,
            uint256(-1)
        );

        IERC20(earnedAddress).safeApprove(pcsRouterAddress, uint256(0));
        IERC20(earnedAddress).safeIncreaseAllowance(
            pcsRouterAddress,
            uint256(-1)
        );

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
        
        IERC20(wbnbAddress).safeApprove(rewardAddress, uint256(0));
        IERC20(wbnbAddress).safeIncreaseAllowance(
            rewardAddress,
            uint256(-1)
        );
    }

    function resetAllowances() external govOnly {
        _resetAllowances();
    }
    
    function setSettings(
        uint256 _entranceFeeFactor,
        uint256 _slippageFactor
    ) external govOnly {
        require(_entranceFeeFactor >= entranceFeeFactorLL, "_entranceFeeFactor too low");
        require(_entranceFeeFactor <= entranceFeeFactorMax, "_entranceFeeFactor too high");
        entranceFeeFactor = _entranceFeeFactor;

        require(_slippageFactor <= slippageFactorUL, "_slippageFactor too high");
        slippageFactor = _slippageFactor;

        emit SetSettings(
            _entranceFeeFactor,
            _slippageFactor
        );
    }

    function setGov(address _govAddress) external govOnly {
        govAddress = _govAddress;
    }

    function setOnlyGov(bool _onlyGov) external govOnly {
        onlyGov = _onlyGov;
    }
    
    /** 
     *  @dev Accidentally send your tokens to this address? We can help!
     *  Explicitly cannot call the tokens stored in this contract
     */
    function inCaseTokensGetStuck(address _token, uint256 _amount, address _to) external govOnly {
        require(
            _token != earnedAddress &&
            _token != wantAddress &&
            _token != token0Address &&
            _token != token1Address
            , "!safe");
        IERC20(_token).safeTransfer(_to, _amount);
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
}