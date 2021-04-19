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

Fork from AutoFarm
Autocompounding for Venus
Earned and want tokens are stored here.
*/

// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./Ownable.sol";
import "./SafeERC20.sol";
import "./Pausable.sol";
import "./ReentrancyGuard.sol";
import "./IPancakeRouter02.sol";
import "./IStratA.sol";
import "./IUnitroller.sol";
import "./IVBNB.sol";
import "./IVToken.sol";
import "./IWBNB.sol";

contract StratV is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    bool public wantIsWBNB = false;
    address public wantAddress;
    address public vTokenAddress;
    address[] public venusMarkets;
    address public constant pcsRouterAddress = 0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F; // uniswap, pancakeswap etc

    address public constant wbnbAddress = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant venusAddress = 0xcF6BB5389c92Bdda8a3747Ddb454cB7a64626C63;
    
    address public constant unitrollerAddress = 0xfD36E2c2a6789Db23113685031d7F16329158384;

    address public autoFarmAddress;
    address public balloonAddress;
    address public govAddress; // timelock contract
    address public rewardAddress; // StratA
    address public constant devAddress = 0x47231b2EcB18b7724560A78cd7191b121f53FABc;

    uint256 public sharesTotal = 0;
    uint256 public lastEarnBlock = 0;

    uint256 public constant controllerFee = 100;
    uint256 public constant controllerFeeMax = 10000; // 100 = 1%

    uint256 public constant rewardRate = 100;
    uint256 public constant rewardRateMax = 10000; // 100 = 1%

    uint256 public constant buyBackRate = 100;
    uint256 public constant buyBackRateMax = 10000; // 100 = 1%
    address public buyBackAddress = 0x000000000000000000000000000000000000dEaD;

    uint256 public entranceFeeFactor = 9990; // < 0.1% entrance fee - goes to pool
    uint256 public constant entranceFeeFactorMax = 10000;
    uint256 public constant entranceFeeFactorLL = 9950; // 0.5% is the max entrance fee settable. LL = lowerlimit

    uint256 public deleverAmtFactorMax = 50; // 0.5% is the max amt to delever for deleverageOnce()
    uint256 public constant deleverAmtFactorMaxUL = 500;

    uint256 public deleverAmtFactorSafe = 20; // 0.2% is the safe amt to delever for deleverageOnce()
    uint256 public constant deleverAmtFactorSafeUL = 500;

    uint256 public slippageFactor = 950; // 5% default slippage tolerance
    uint256 public constant slippageFactorUL = 995;

    address[] public venusToWantPath;
    address[] public earnedToBalloonPath;
    address[] public earnedToWbnbPath;

    /**
     * @dev Variables that can be changed to config profitability and risk:
     * {borrowRate}          - What % of our collateral do we borrow per leverage level.
     * {borrowDepth}         - How many levels of leverage do we take.
     * {BORROW_RATE_MAX}     - A limit on how much we can push borrow risk.
     * {BORROW_DEPTH_MAX}    - A limit on how many steps we can leverage.
     */
    uint256 public borrowRate = 580;
    uint256 public borrowDepth = 4;
    uint256 public constant BORROW_RATE_MAX = 590;
    uint256 public constant BORROW_DEPTH_MAX = 6;
    bool onlyGov = true;

    uint256 public supplyBal = 0; // Cached want supplied to venus
    uint256 public borrowBal = 0; // Cached want borrowed from venus
    uint256 public supplyBalTargeted = 0; // Cached targeted want supplied to venus to achieve desired leverage
    uint256 public supplyBalMin = 0;

    constructor(
        address _autoFarmAddress,
        address _rewardAddress,
        address _balloonAddress,
        address _wantAddress,
        address _vTokenAddress
    ) public {
        govAddress = msg.sender;
        autoFarmAddress = _autoFarmAddress;
        rewardAddress = _rewardAddress;
        balloonAddress = _balloonAddress;

        wantAddress = _wantAddress;
        if (wantAddress == wbnbAddress) {
            wantIsWBNB = true;
        }
        venusToWantPath = [venusAddress, wantAddress];
        earnedToBalloonPath = [venusAddress, wbnbAddress, balloonAddress];
        earnedToWbnbPath = [venusAddress, wbnbAddress];

        vTokenAddress = _vTokenAddress;
        venusMarkets = [vTokenAddress];

        transferOwnership(autoFarmAddress);

        _resetAllowances();

        IUnitroller(unitrollerAddress).enterMarkets(venusMarkets);
    }

    event SetSettings(
        uint256 _entranceFeeFactor,
        uint256 _slippageFactor,
        uint256 _deleverAmtFactorMax,
        uint256 _deleverAmtFactorSafe
    );

    modifier govOnly() {
        require(msg.sender == govAddress, "!gov");
        _;
    }

    function _supply(uint256 _amount) internal {
        if (wantIsWBNB) {
            IVBNB(vTokenAddress).mint{value: _amount}();
        } else {
            IVToken(vTokenAddress).mint(_amount);
        }
    }

    function _removeSupply(uint256 _amount) internal {
        IVToken(vTokenAddress).redeemUnderlying(_amount);
    }

    function _borrow(uint256 _amount) internal {
        IVToken(vTokenAddress).borrow(_amount);
    }

    function _repayBorrow(uint256 _amount) internal {
        if (wantIsWBNB) {
            IVBNB(vTokenAddress).repayBorrow{value: _amount}();
        } else {
            IVToken(vTokenAddress).repayBorrow(_amount);
        }
    }

    /**
     * @dev Receives new deposits from user, can only be called by MasterChef
     * _userAddress not used, possibly used by other strats
     */
    function deposit(address _userAddress, uint256 _wantAmt) external onlyOwner nonReentrant whenNotPaused returns (uint256) {
        updateBalance();

        uint256 sharesAdded = _wantAmt;
        if (wantLockedTotal() > 0 && sharesTotal > 0) {
            sharesAdded = _wantAmt
                .mul(sharesTotal)
                .mul(entranceFeeFactor)
                .div(wantLockedTotal())
                .div(entranceFeeFactorMax);
        }

        sharesTotal = sharesTotal.add(sharesAdded);

        IERC20(wantAddress).safeTransferFrom(
            msg.sender,
            address(this),
            _wantAmt
        );

        _farm(true);

        return sharesAdded;
    }

    // If want tokens ever get stuck
    function farm(bool _withLev) external nonReentrant {
        _farm(_withLev);
    }

    function _farm(bool _withLev) internal {
        if (wantIsWBNB) {
            _unwrapBNB(); // WBNB -> BNB. Venus accepts BNB, not WBNB.
        }

        _leverage(_withLev);

        updateBalance();

        deleverageUntilNotOverLevered(); // It is possible to still be over-levered after depositing.
    }

    /**
     * @dev Repeatedly supplies and borrows bnb following the configured {borrowRate} and {borrowDepth}
     * into the vToken contract.
     */
    function _leverage(bool _withLev) internal {
        if (_withLev) {
            for (uint256 i = 0; i < borrowDepth; i++) {
                uint256 amount = venusWantBal();
                _supply(amount);
                amount = amount.mul(borrowRate).div(1000);
                _borrow(amount);
            }
        }

        _supply(venusWantBal()); // Supply remaining want that was last borrowed.
    }

    function leverageOnce() external govOnly {
        _leverageOnce();
    }

    function _leverageOnce() internal {
        updateBalance(); // Updates borrowBal & supplyBal & supplyBalTargeted & supplyBalMin
        uint256 borrowAmt = supplyBal.mul(borrowRate).div(1000).sub(borrowBal);
        if (borrowAmt > 0) {
            _borrow(borrowAmt);
            _supply(venusWantBal());
        }
        updateBalance(); // Updates borrowBal & supplyBal & supplyBalTargeted & supplyBalMin
    }

    /**
     * @dev Redeem to the desired leverage amount, then use it to repay borrow.
     * If already over leverage, redeem max amt redeemable, then use it to repay borrow.
     */
    function deleverageOnce() external govOnly {
        _deleverageOnce();
    }

    function _deleverageOnce() internal {
        updateBalance(); // Updates borrowBal & supplyBal & supplyBalTargeted & supplyBalMin

        if (supplyBal <= 0) {
            return;
        }

        uint256 deleverAmt;
        uint256 deleverAmtMax = supplyBal.mul(deleverAmtFactorMax).div(10000); // 0.5%

        if (supplyBal <= supplyBalMin) {
            // If very over levered, delever 0.2% at a time
            deleverAmt = supplyBal.mul(deleverAmtFactorSafe).div(10000);
        } else if (supplyBal <= supplyBalTargeted) {
            deleverAmt = supplyBal.sub(supplyBalMin);
        } else {
            deleverAmt = supplyBal.sub(supplyBalTargeted);
        }

        if (deleverAmt > deleverAmtMax) {
            deleverAmt = deleverAmtMax;
        }

        _removeSupply(deleverAmt);

        if (wantIsWBNB) {
            _unwrapBNB(); // WBNB -> BNB
            _repayBorrow(address(this).balance);
        } else {
            _repayBorrow(wantLockedInHere());
        }

        updateBalance(); // Updates borrowBal & supplyBal & supplyBalTargeted & supplyBalMin
    }

    /**
     * @dev Redeem the max possible, use it to repay borrow
     */
    function deleverageUntilNotOverLevered() public {
        // updateBalance(); // To be more accurate, call updateBalance() first to cater for changes due to interest rates

        // If borrowRate slips below targetted borrowRate, withdraw the max amt first.
        // Further actual deleveraging will take place later on.
        // (This can happen in when net interest rate < 0, and supplied balance falls below targeted.)
        while (supplyBal > 0 && supplyBal <= supplyBalTargeted) {
            _deleverageOnce();
        }
    }

    /**
     * @dev Incrementally alternates between paying part of the debt and withdrawing part of the supplied
     * collateral. Continues to do this untill all want tokens is withdrawn. For partial deleveraging,
     * this continues until at least _minAmt of want tokens is reached.
     */

    function _deleverage(uint256 _minAmt) internal {
        updateBalance(); // Updates borrowBal & supplyBal & supplyBalTargeted & supplyBalMin

        deleverageUntilNotOverLevered();

        if (wantIsWBNB) {
            _wrapBNB(); // WBNB -> BNB
        }

        uint256 supplyRemovableMax = supplyBal.sub(supplyBalMin);
        if (_minAmt < supplyRemovableMax) {
            // If _minAmt to deleverage is less than supplyRemovableMax, just remove _minAmt
            supplyRemovableMax = _minAmt;
        }
        _removeSupply(supplyRemovableMax);

        uint256 wantBal = wantLockedInHere();

        // Recursively repay borrowed + remove more from supplied
        while (wantBal < borrowBal) {
            // If only partially deleveraging, when sufficiently deleveraged, do not repay anymore
            if (wantBal >= _minAmt) {
                return;
            }

            _repayBorrow(wantBal);

            updateBalance(); // Updates borrowBal & supplyBal & supplyBalTargeted & supplyBalMin

            supplyRemovableMax = supplyBal.sub(supplyBalMin);
            if (_minAmt < supplyRemovableMax) {
                // If _minAmt to deleverage is less than supplyRemovableMax, just remove _minAmt
                supplyRemovableMax = _minAmt;
            }
            _removeSupply(supplyRemovableMax);

            wantBal = wantLockedInHere();
        }

        // When sufficiently deleveraged, do not repay
        if (wantBal >= _minAmt) {
            return;
        }

        // Make a final repayment of borrowed
        _repayBorrow(borrowBal);

        // remove all supplied
        uint256 vTokenBal = IERC20(vTokenAddress).balanceOf(address(this));
        IVToken(vTokenAddress).redeem(vTokenBal);
    }

    /**
     * @dev Updates the risk profile and rebalances the vault funds accordingly.
     * @param _borrowRate percent to borrow on each leverage level.
     * @param _borrowDepth how many levels to leverage the funds.
     */
    function rebalance(uint256 _borrowRate, uint256 _borrowDepth) external govOnly {
        require(_borrowRate <= BORROW_RATE_MAX, "!rate");
        require(_borrowDepth <= BORROW_DEPTH_MAX, "!depth");

        borrowRate = _borrowRate;
        borrowDepth = _borrowDepth;

        updateBalance(); // Updates borrowBal & supplyBal & supplyBalTargeted & supplyBalMin
        deleverageUntilNotOverLevered();
    }
    
    /**
     * @dev Returns deposits from user, can only be called by MasterChef
     * _userAddress not used, possibly used by other strats
     */
    function withdraw(address _userAddress, uint256 _wantAmt) external onlyOwner nonReentrant returns (uint256) {
        uint256 sharesRemoved = _wantAmt.mul(sharesTotal).div(wantLockedTotal());
        if (sharesRemoved > sharesTotal) {
            sharesRemoved = sharesTotal;
        }
        sharesTotal = sharesTotal.sub(sharesRemoved);

        uint256 wantBal = IERC20(wantAddress).balanceOf(address(this));
        if (wantBal < _wantAmt) {
            _deleverage(_wantAmt.sub(wantBal));
            if (wantIsWBNB) {
                _wrapBNB(); // wrap BNB -> WBNB before sending it back to user
            }
            wantBal = IERC20(wantAddress).balanceOf(address(this));
        }

        if (wantBal < _wantAmt) {
            _wantAmt = wantBal;
        }

        IERC20(wantAddress).safeTransfer(autoFarmAddress, _wantAmt);

        _farm(false);

        return sharesRemoved;
    }

    function earn() external nonReentrant whenNotPaused {
        if (onlyGov) {
            require(msg.sender == govAddress, "Not authorised");
        }

        IUnitroller(unitrollerAddress).claimVenus(address(this));

        uint256 earnedAmt = IERC20(venusAddress).balanceOf(address(this));

        earnedAmt = distributeFees(earnedAmt);
        earnedAmt = distributeRewards(earnedAmt);
        earnedAmt = buyBack(earnedAmt);

        if (venusAddress != wantAddress) {
            _safeSwap(
                earnedAmt,
                venusToWantPath,
                address(this)
            );
        }

        lastEarnBlock = block.number;

        _farm(false); // Supply wantToken without leverage, to cater for negative interest rates.
    }

    /**
     * 1. Takes a percentage (1%) of earned tokens
     * 2. Converts the percentage to BLN
     * 3. Burns the BLN
     */
    function buyBack(uint256 _earnedAmt) internal returns (uint256) {
        if (buyBackRate <= 0) {
            return _earnedAmt;
        }

        uint256 buyBackAmt = _earnedAmt.mul(buyBackRate).div(buyBackRateMax);

        _safeSwap(
            buyBackAmt,
            earnedToBalloonPath,
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
            uint256 fee = _earnedAmt.mul(controllerFee).div(controllerFeeMax);

            // One must hope for a WBNB pairing
            _safeSwap(
                fee,
                earnedToWbnbPath,
                devAddress
            );

            return _earnedAmt.sub(fee);
        }

        return _earnedAmt;
    }

    // Stops time
    function pause() public govOnly {
        _pause();
    }

    // The strat lives once more
    function unpause() external govOnly {
        _unpause();
        _resetAllowances();
    }

    function _resetAllowances() internal {
        IERC20(venusAddress).safeApprove(pcsRouterAddress, uint256(0));
        IERC20(venusAddress).safeIncreaseAllowance(
            pcsRouterAddress,
            uint256(-1)
        );

        IERC20(wantAddress).safeApprove(pcsRouterAddress, uint256(0));
        IERC20(wantAddress).safeIncreaseAllowance(
            pcsRouterAddress,
            uint256(-1)
        );

        if (!wantIsWBNB) {
            IERC20(wantAddress).safeApprove(vTokenAddress, uint256(0));
            IERC20(wantAddress).safeIncreaseAllowance(
                vTokenAddress,
                uint256(-1)
            );
        }
        
        IERC20(wbnbAddress).safeApprove(rewardAddress, uint256(0));
        IERC20(wbnbAddress).safeIncreaseAllowance(
            rewardAddress,
            uint256(-1)
        );
    }

    function resetAllowances() external govOnly {
        _resetAllowances();
    }

    /**
     * @dev Updates want locked in Venus after interest is accrued to this very block.
     * To be called before sensitive operations.
     */
    function updateBalance() public {
        supplyBal = IVToken(vTokenAddress).balanceOfUnderlying(address(this)); // a payable function because of acrueInterest()
        borrowBal = IVToken(vTokenAddress).borrowBalanceCurrent(address(this));
        supplyBalTargeted = borrowBal.mul(1000).div(borrowRate);
        supplyBalMin = borrowBal.mul(1000).div(BORROW_RATE_MAX);
    }

    function wantLockedTotal() public view returns (uint256) {
        return wantLockedInHere().add(supplyBal).sub(borrowBal);
    }

    function wantLockedInHere() public view returns (uint256) {
        uint256 wantBal = IERC20(wantAddress).balanceOf(address(this));
        if (wantIsWBNB) {
            uint256 bnbBal = address(this).balance;
            return bnbBal.add(wantBal);
        } else {
            return wantBal;
        }
    }

    /**
     * @dev Returns balance of want. If wantAddress is WBNB, returns BNB balance, not WBNB balance.
     */
    function venusWantBal() public view returns (uint256) {
        if (wantIsWBNB) {
            return address(this).balance;
        }
        return IERC20(wantAddress).balanceOf(address(this));
    }

    function setSettings(
        uint256 _entranceFeeFactor,
        uint256 _slippageFactor,
        uint256 _deleverAmtFactorMax,
        uint256 _deleverAmtFactorSafe
    ) external govOnly {
        require(_entranceFeeFactor >= entranceFeeFactorLL, "_entranceFeeFactor too low");
        require(_entranceFeeFactor <= entranceFeeFactorMax, "_entranceFeeFactor too high");
        entranceFeeFactor = _entranceFeeFactor;

        require(_slippageFactor <= slippageFactorUL, "_slippageFactor too high");
        slippageFactor = _slippageFactor;

        require(_deleverAmtFactorMax <= deleverAmtFactorMaxUL, "_deleverAmtFactorMax too high");
        deleverAmtFactorMax = _deleverAmtFactorMax;

        require(_deleverAmtFactorSafe <= deleverAmtFactorSafeUL, "_deleverAmtFactorSafe too high");
        deleverAmtFactorSafe = _deleverAmtFactorSafe;

        emit SetSettings(
            _entranceFeeFactor,
            _slippageFactor,
            _deleverAmtFactorMax,
            _deleverAmtFactorSafe
        );
    }

    function setGov(address _govAddress) public govOnly {
        govAddress = _govAddress;
    }

    function setOnlyGov(bool _onlyGov) public govOnly {
        onlyGov = _onlyGov;
    }

    function _wrapBNB() internal {
        // BNB -> WBNB
        uint256 bnbBal = address(this).balance;
        if (bnbBal > 0) {
            IWBNB(wbnbAddress).deposit{value: bnbBal}(); // BNB -> WBNB
        }
    }

    function _unwrapBNB() internal {
        // WBNB -> BNB
        uint256 wbnbBal = IERC20(wbnbAddress).balanceOf(address(this));
        if (wbnbBal > 0) {
            IWBNB(wbnbAddress).withdraw(wbnbBal);
        }
    }

    /**
     * @dev We should not have significant amts of BNB in this contract if any at all.
     * In case we do (eg. Venus returns all users' BNB to this contract or for any other reason),
     * We can wrap all BNB, allowing users to withdraw() as per normal.
     */
    function wrapBNB() external govOnly {
        require(wantIsWBNB, "!wantIsWBNB");
        _wrapBNB();
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
    
    receive() external payable {}
}