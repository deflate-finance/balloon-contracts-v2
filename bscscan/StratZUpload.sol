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
Autocompounding for Autofarm and clones, for single token
Is it wrong to autocompound our fork?
Earned and want tokens are stored here.
*/

// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./Ownable.sol";
import "./SafeERC20.sol";
import "./EnumerableSet.sol";
import "./Pausable.sol";
import "./ReentrancyGuard.sol";

import "./IAutoFarm.sol";
import "./IPancakeRouter02.sol";
import "./IStrategy.sol";
import "./IStratA.sol";

contract StratZ is Ownable, ReentrancyGuard, Pausable {
    // Maximises yields in autofarm

    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public farmContractAddress; // address of farm, eg, Auto, Swamp, etc
    address public farmStrat;
    uint256 public pid; // pid of pool in farmContractAddress
    address public wantAddress;
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
    uint256 public sharesTotal = 0;

    uint256 public constant controllerFee = 150;
    uint256 public constant controllerFeeMax = 10000; // 150 = 1.5%

    uint256 public constant rewardRate = 150;
    uint256 public constant rewardRateMax = 10000; // 150 = 1.5%

    uint256 public constant buyBackRate = 150;
    uint256 public constant buyBackRateMax = 10000; // 150 = 1.5%
    address public constant buyBackAddress = 0x000000000000000000000000000000000000dEaD;

    uint256 public slippageFactor = 950; // 5% default slippage tolerance
    uint256 public constant slippageFactorUL = 995;

    address[] public earnedToBnbPath;
    address[] public earnedToBLNPath;
    address[] public earnedToWantPath;

    constructor(
        address _autoFarmAddress,
        address _rewardAddress,
        address _balloonAddress,
        address _farmContractAddress,
        address _farmStrat,
        uint256 _farmPid,
        address _wantAddress,
        address _earnedAddress
    ) public {
        govAddress = msg.sender;
        autoFarmAddress = _autoFarmAddress;
        rewardAddress = _rewardAddress;
        balloonAddress = _balloonAddress;
        
        wantAddress = _wantAddress;

        farmContractAddress = _farmContractAddress;
        farmStrat = _farmStrat;
        pid = _farmPid;
        earnedAddress = _earnedAddress;

        earnedToBnbPath = [earnedAddress, wbnbAddress];

        earnedToBLNPath = [earnedAddress, wbnbAddress, balloonAddress];
        if (wbnbAddress == earnedAddress) {
            earnedToBLNPath = [wbnbAddress, balloonAddress];
        }

        earnedToWantPath = [earnedAddress, wbnbAddress, wantAddress];
        if (wbnbAddress == wantAddress) {
            earnedToWantPath = [earnedAddress, wantAddress];
        }

        transferOwnership(autoFarmAddress);
        
        _resetAllowances();
    }
    
    event SetSettings(uint256 _slippageFactor);
    
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

        // Also make sure you account for farm fees
        uint256 sharesAdded = _farm();

        sharesTotal = sharesTotal.add(sharesAdded);

        return sharesAdded;
    }

    // If want tokens ever get stuck
    function farm() public nonReentrant {
        _farm();
    }

    // Deposit into the yield farm we're autocompounding
    function _farm() internal returns (uint256) {
        uint256 wantAmt = IERC20(wantAddress).balanceOf(address(this));
        if(wantAmt == 0) return 0;

        (uint256 sharesBefore,) = IAutoFarm(farmContractAddress).userInfo(pid, address(this));
        IAutoFarm(farmContractAddress).deposit(pid, wantAmt);
        (uint256 sharesAfter,) = IAutoFarm(farmContractAddress).userInfo(pid, address(this));
        uint256 sharesAmount = sharesAfter.sub(sharesBefore); // Entrance fees
        return sharesAmount;
    }

    /**
     * Returns deposits from user, can only be called by MasterChef
     * _userAddress not used, possibly used by other strats
     */
    function withdraw(address _userAddress, uint256 _wantAmt) external onlyOwner nonReentrant returns (uint256) {
        require(_wantAmt > 0, "_wantAmt is 0");
        
        // If we use farm shares and stakedWantTokens
        // we need to also use their strat numbers
        uint256 stratShares = IStrategy(farmStrat).sharesTotal();
        uint256 stratWantLocked = IStrategy(farmStrat).wantLockedTotal();
        uint256 sharesRemoved = _wantAmt.mul(stratShares).div(stratWantLocked);

        IAutoFarm(farmContractAddress).withdraw(pid, _wantAmt);

        uint256 wantAmt = IERC20(wantAddress).balanceOf(address(this));
        if (_wantAmt > wantAmt) {
            _wantAmt = wantAmt;
        }
        
        if (sharesRemoved > sharesTotal) {
            sharesRemoved = sharesTotal;
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
    function earn() external nonReentrant whenNotPaused {
        if (onlyGov) {
            require(msg.sender == govAddress, "Not authorised");
        }
        require(sharesTotal > 0, "No stakers");

        IAutoFarm(farmContractAddress).withdraw(pid, 0);

        // Converts farm tokens into want tokens
        uint256 earnedAmt = IERC20(earnedAddress).balanceOf(address(this));

        earnedAmt = distributeFees(earnedAmt);
        earnedAmt = distributeRewards(earnedAmt);
        earnedAmt = buyBack(earnedAmt);

        if (earnedAddress != wantAddress) {
            _safeSwap(
                earnedAmt,
                earnedToWantPath,
                address(this)
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
            
            // One must hope for a BNB pairing
            _safeSwap(
                fee,
                earnedToBnbPath,
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
        if (_earnedAmt > 0 && rewardRate > 0) {
            // Performance fee
            uint256 fee = _earnedAmt.mul(controllerFee).div(controllerFeeMax);
    
            // One must hope for a BNB pairing
            _safeSwap(
                fee,
                earnedToBnbPath,
                devAddress
            );
            
            _earnedAmt = _earnedAmt.sub(fee);
        }

        return _earnedAmt;
    }
    
    function wantLockedTotal() public view returns (uint256) {
        return IAutoFarm(farmContractAddress).stakedWantTokens(pid, address(this));
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
        
        IERC20(wbnbAddress).safeApprove(rewardAddress, uint256(0));
        IERC20(wbnbAddress).safeIncreaseAllowance(
            rewardAddress,
            uint256(-1)
        );
    }
    
    function setSettings(uint256 _slippageFactor) external govOnly {
        require(_slippageFactor <= slippageFactorUL, "_slippageFactor too high");
        slippageFactor = _slippageFactor;

        emit SetSettings(_slippageFactor);
    }

    function setGov(address _govAddress) external govOnly {
        govAddress = _govAddress;
    }

    function setOnlyGov(bool _onlyGov) external govOnly {
        onlyGov = _onlyGov;
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