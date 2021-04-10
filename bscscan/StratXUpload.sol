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

import "./Ownable.sol";
import "./SafeERC20.sol";
import "./EnumerableSet.sol";
import "./Pausable.sol";
import "./ReentrancyGuard.sol";
import "./IPancakeswapFarm.sol";
import "./IPancakeRouter01.sol";
import "./IPancakeRouter02.sol";
import "./IStratA.sol";
import "./BalloonTokenUpload.sol";

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
    BalloonToken public balloon;
    address public govAddress; // timelock contract
    bool public onlyGov = true; // used for earn()

    uint256 public lastEarnBlock = block.number;
    uint256 public wantLockedTotal = 0;
    uint256 public sharesTotal = 0;

    uint256 public controllerFee = 100;
    uint256 public constant controllerFeeMax = 10000; // 100 = 1%

    uint256 public rewardRate = 100;
    uint256 public constant rewardRateMax = 10000; // 100 = 1%

    uint256 public buyBackRate = 100;
    uint256 public constant buyBackRateMax = 10000; // 100 = 1%
    address public constant buyBackAddress = 0x000000000000000000000000000000000000dEaD;

    uint256 public entranceFeeFactor = 9990; // < 0.1% entrance fee - goes to pool + prevents front-running
    uint256 public constant entranceFeeFactorMax = 10000;

    address[] public earnedToBnbPath;
    address[] public earnedToBLNPath;
    address[] public earnedToToken0Path;
    address[] public earnedToToken1Path;
    address[] public token0ToEarnedPath;
    address[] public token1ToEarnedPath;

    constructor(
        address _autoFarmAddress,
        address _rewardAddress,
        BalloonToken _balloon,
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
        balloon = _balloon;

        isCAKEStaking = _isCAKEStaking;
        wantAddress = _wantAddress;

        if (!isCAKEStaking) {
            token0Address = _token0Address;
            token1Address = _token1Address;
        }

        farmContractAddress = _farmContractAddress;
        pid = _farmPid;
        earnedAddress = _earnedAddress;

        earnedToBnbPath = [earnedAddress, wbnbAddress];

        earnedToBLNPath = [earnedAddress, wbnbAddress, address(balloon)];
        if (wbnbAddress == earnedAddress) {
            earnedToBLNPath = [wbnbAddress, address(balloon)];
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
    }
    
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
        IERC20(wantAddress).safeIncreaseAllowance(farmContractAddress, wantAmt);

        if (isCAKEStaking) {
            IPancakeswapFarm(farmContractAddress).enterStaking(wantAmt); // Just for CAKE staking, we dont use deposit()
        } else {
            IPancakeswapFarm(farmContractAddress).deposit(pid, wantAmt);
        }
    }

    /**
     * Returns deposits from user, can only be called by MasterChef
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

        IERC20(earnedAddress).safeIncreaseAllowance(
            pcsRouterAddress,
            earnedAmt
        );

        if (earnedAddress != token0Address) {
            // Swap half earned to token0
            IPancakeRouter02(pcsRouterAddress).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                earnedAmt.div(2),
                0,
                earnedToToken0Path,
                address(this),
                now + 600
            );
        }

        if (earnedAddress != token1Address) {
            // Swap half earned to token1
            IPancakeRouter02(pcsRouterAddress).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                earnedAmt.div(2),
                0,
                earnedToToken1Path,
                address(this),
                now + 600
            );
        }

        // Get want tokens, ie. add liquidity
        uint256 token0Amt = IERC20(token0Address).balanceOf(address(this));
        uint256 token1Amt = IERC20(token1Address).balanceOf(address(this));
        if (token0Amt > 0 && token1Amt > 0) {
            IERC20(token0Address).safeIncreaseAllowance(
                pcsRouterAddress,
                token0Amt
            );
            IERC20(token1Address).safeIncreaseAllowance(
                pcsRouterAddress,
                token1Amt
            );
            IPancakeRouter02(pcsRouterAddress).addLiquidity(
                token0Address,
                token1Address,
                token0Amt,
                token1Amt,
                0,
                0,
                address(this),
                now + 600
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

        IERC20(earnedAddress).safeIncreaseAllowance(
            pcsRouterAddress,
            buyBackAmt
        );

        IPancakeRouter02(pcsRouterAddress).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            buyBackAmt,
            0,
            earnedToBLNPath,
            buyBackAddress,
            now + 600
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
            IERC20(earnedAddress).safeIncreaseAllowance(
                pcsRouterAddress,
                fee
            );
    
            uint256 currWbnb = IERC20(wbnbAddress).balanceOf(address(this));
            
            // One must hope for a BNB pairing
            IPancakeRouter02(pcsRouterAddress).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                fee,
                0,
                earnedToBnbPath,
                address(this),
                now + 600
            );
            
            uint256 diffWbnb = IERC20(wbnbAddress).balanceOf(address(this)).sub(currWbnb);
            IERC20(wbnbAddress).safeIncreaseAllowance(
                rewardAddress,
                diffWbnb
            );
            
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
        if (_earnedAmt > 0 && rewardRate > 0) {
            // Performance fee
            uint256 fee = _earnedAmt.mul(controllerFee).div(controllerFeeMax);
            IERC20(earnedAddress).safeIncreaseAllowance(
                pcsRouterAddress,
                fee
            );
    
            // One must hope for a BNB pairing
            IPancakeRouter02(pcsRouterAddress).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                fee,
                0,
                earnedToBnbPath,
                devAddress,
                now + 600
            );
            
            _earnedAmt = _earnedAmt.sub(fee);
        }

        return _earnedAmt;
    }

    /**
     * Every time earn() is called dust will accumulate
     * We call this function to convert the dust as well
     */
    function convertDustToEarned() external nonReentrant whenNotPaused {
        require(!isCAKEStaking, "isCAKEStaking");

        // Converts dust tokens into earned tokens, which will be reinvested on the next earn().

        // Converts token0 dust (if any) to earned tokens
        uint256 token0Amt = IERC20(token0Address).balanceOf(address(this));
        if (token0Amt > 0 && token0Address != earnedAddress) {
            IERC20(token0Address).safeIncreaseAllowance(
                pcsRouterAddress,
                token0Amt
            );

            // Swap all dust tokens to earned tokens
            IPancakeRouter02(pcsRouterAddress).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                token0Amt,
                0,
                token0ToEarnedPath,
                address(this),
                now + 600
            );
        }

        // Converts token1 dust (if any) to earned tokens
        uint256 token1Amt = IERC20(token1Address).balanceOf(address(this));
        if (token1Amt > 0 && token1Address != earnedAddress) {
            IERC20(token1Address).safeIncreaseAllowance(
                pcsRouterAddress,
                token1Amt
            );

            // Swap all dust tokens to earned tokens
            IPancakeRouter02(pcsRouterAddress).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                token1Amt,
                0,
                token1ToEarnedPath,
                address(this),
                now + 600
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
    }

    function setGov(address _govAddress) external govOnly {
        govAddress = _govAddress;
    }

    function setOnlyGov(bool _onlyGov) external govOnly {
        onlyGov = _onlyGov;
    }
    
    /** 
     *  Accidentally send your tokens to this address? We can help!
     *  Explicitly cannot call the only token stored in this contract
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
}