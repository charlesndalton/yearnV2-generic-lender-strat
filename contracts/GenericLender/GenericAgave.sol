// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "../Interfaces/UniswapInterfaces/IUniswapV2Router02.sol";

import "./GenericLenderBase.sol";
import "../Interfaces/Agave/IAgToken.sol";
import "../Interfaces/Aave/ILendingPool.sol";
import "../Interfaces/Aave/IProtocolDataProvider.sol";
import "../Interfaces/Agave/IAgaveIncentivesController.sol";  // Agave modified this inferface
import "../Interfaces/Aave/IReserveInterestRateStrategy.sol";
// import "../Libraries/Aave/DataTypes.sol";

import "../Interfaces/BalancerV1/IExchangeProxy.sol";
import "../Interfaces/BalancerV1/BPool.sol";

/********************
 *   A lender plugin for LenderYieldOptimiser for any erc20 asset on Agave Finance
 *   Agave is a fork of Aave, and consequently this Agave plugin is a fork of the Aave plugin
 ********************* */

contract GenericAgave is GenericLenderBase {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    IProtocolDataProvider public constant protocolDataProvider = IProtocolDataProvider(address(0xa874f66342a04c24b213BF0715dFf18818D24014));
    IAgToken public agToken;

    address public keep3r;

    bool public isIncentivised;
    
    address public constant symmetricPool_AGVE_GNO = address(0x34fA946A20e65cb1aC466275949ba382973fde2b); // Rewards are paid out in an LP token on a balancer-like AMM with a 60/40 GNO/AGVE split
    address public constant GNO = address(0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb);
    address public constant AGVE =
        address(0x3a97704a1b25F08aa230ae53B352e2e72ef52843);

    address public constant WETH =
        address(0x6A023CCd1ff6F2045C3309768eAd9E68F978f6e1);

    address public constant WXDAI =
        address(0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d);
    address public constant SYMM =
        address(0xC45b3C1c24d5F54E7a2cF288ac668c74Dd507a84);

    IExchangeProxy public constant symmetricExchangeProxy = IExchangeProxy(0x48Cf5264bCfd23e411f4Eae7B950F7b95ba0079f);

    IUniswapV2Router02 public constant router =
        IUniswapV2Router02(address(0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506)); // Sushiswap

    uint256 constant internal SECONDS_IN_YEAR = 365 days;

    constructor(
        address _strategy,
        string memory name,
        IAgToken _agToken,
        bool _isIncentivised
    ) public GenericLenderBase(_strategy, name) {
        _initialize(_agToken, _isIncentivised);
    }

    function initialize(IAgToken _agToken, bool _isIncentivised) external {
        _initialize(_agToken, _isIncentivised);
    }

    function cloneAgaveLender(
        address _strategy,
        string memory _name,
        IAgToken _agToken,
        bool _isIncentivised
    ) external returns (address newLender) {
        newLender = _clone(_strategy, _name);
        GenericAgave(newLender).initialize(_agToken, _isIncentivised);
    }

    // for the management to activate / deactivate incentives functionality
    function setIsIncentivised(bool _isIncentivised) external management {
        // NOTE: if the agToken is not incentivised, getIncentivesController() might revert (agToken won't implement it)
        // to avoid calling it, we use the OR and lazy evaluation
        require(!_isIncentivised || address(agToken.getIncentivesController()) != address(0), "!agToken does not have incentives controller set up");
        isIncentivised = _isIncentivised;
    }

    function setKeep3r(address _keep3r) external management {
        keep3r = _keep3r;
    }

    function withdraw(uint256 amount) external override management returns (uint256) {
        return _withdraw(amount);
    }

    //emergency withdraw. sends balance plus amount to governance
    function emergencyWithdraw(uint256 amount) external override onlyGovernance {
        _lendingPool().withdraw(address(want), amount, address(this));

        want.safeTransfer(vault.governance(), want.balanceOf(address(this)));
    }

    function deposit() external override management {
        uint256 balance = want.balanceOf(address(this));
        _deposit(balance);
    }

    function withdrawAll() external override management returns (bool) {
        uint256 invested = _nav();
        uint256 returned = _withdraw(invested);
        return returned >= invested;
    }

    function nav() external view override returns (uint256) {
        return _nav();
    }

    function underlyingBalanceStored() public view returns (uint256 balance) {
        balance = agToken.balanceOf(address(this));
    }

    function apr() external view override returns (uint256) {
        return _apr();
    }

    function weightedApr() external view override returns (uint256) {
        uint256 a = _apr();
        return a.mul(_nav());
    }

    // calculates APR from Liquidity Mining Program
    function _incentivesRate(uint256 totalLiquidity) public view returns (uint256) {
        // only returns != 0 if the incentives are in place at the moment.
        // it will fail if the isIncentivised is set to true but there is no incentives
        if(isIncentivised && block.timestamp < _incentivesController().getDistributionEnd()) {
            uint256 _emissionsPerSecond;
            (, _emissionsPerSecond, , ) = _incentivesController().getAssetData(address(agToken));
            if(_emissionsPerSecond > 0) {
                uint256 emissionsInWant = _rewardToWant(_emissionsPerSecond); // amount of emissions in want

                uint256 incentivesRate = emissionsInWant.mul(SECONDS_IN_YEAR).mul(1e18).div(totalLiquidity); // APRs are in 1e18

                return incentivesRate.mul(9_500).div(10_000); // 95% of estimated APR to avoid overestimations
            }
        }
        return 0;
    }

    function aprAfterDeposit(uint256 extraAmount) external view override returns (uint256) {
        // i need to calculate new supplyRate after Deposit (when deposit has not been done yet)
        DataTypes.ReserveData memory reserveData = _lendingPool().getReserveData(address(want));

        (uint256 availableLiquidity, uint256 totalStableDebt, uint256 totalVariableDebt, , , , uint256 averageStableBorrowRate, , , ) =
            protocolDataProvider.getReserveData(address(want));

        uint256 newLiquidity = availableLiquidity.add(extraAmount);

        (, , , , uint256 reserveFactor, , , , , ) = protocolDataProvider.getReserveConfigurationData(address(want));

        (uint256 newLiquidityRate, , ) =
            IReserveInterestRateStrategy(reserveData.interestRateStrategyAddress).calculateInterestRates(
                address(want),
                newLiquidity,
                totalStableDebt,
                totalVariableDebt,
                averageStableBorrowRate,
                reserveFactor
            );

        uint256 incentivesRate = _incentivesRate(newLiquidity.add(totalStableDebt).add(totalVariableDebt)); // total supplied liquidity in Agave
        return newLiquidityRate.div(1e9).add(incentivesRate); // divided by 1e9 to go from Ray to Wad
    }

    function hasAssets() external view override returns (bool) {
        return agToken.balanceOf(address(this)) > 0;
    }

    // Only for incentivised aTokens
    // this is a manual trigger to claim rewards once each 10 days
    // only callable if the token is incentivised by Aave Governance (_checkIncentivized returns true)
    function harvest() external keepers{
        require(_checkIncentivized(), "!conditions are not met");

        // claim rewards
        address[] memory assets = new address[](1);
        assets[0] = address(agToken);
        uint256 pendingRewards = _incentivesController().getRewardsBalance(assets, address(this));
        if(pendingRewards > 0) {
            _incentivesController().claimRewards(assets, pendingRewards, address(this));
        }

        _sellRewardForWant();

        // deposit want in lending protocol
        uint256 balance = want.balanceOf(address(this));
        if(balance > 0) {
            _deposit(balance);
        }
    }

    function harvestTrigger(uint256 callcost) external view returns (bool) {
        return _checkIncentivized();
    }

    function _initialize(IAgToken _agToken, bool _isIncentivised) internal {
        require(address(agToken) == address(0), "GenericAgave already initialized");

        require(!_isIncentivised || address(_agToken.getIncentivesController()) != address(0), "!agToken does not have incentives controller set up");
        isIncentivised = _isIncentivised;
        agToken = _agToken;
        require(_lendingPool().getReserveData(address(want)).aTokenAddress == address(_agToken), "WRONG AGTOKEN");
        IERC20(address(want)).safeApprove(address(_lendingPool()), type(uint256).max);
    }

    function _nav() internal view returns (uint256) {
        return want.balanceOf(address(this)).add(underlyingBalanceStored());
    }

    function _apr() internal view returns (uint256) {
        uint256 liquidityRate = uint256(_lendingPool().getReserveData(address(want)).currentLiquidityRate).div(1e9);// dividing by 1e9 to pass from ray to wad
        (uint256 availableLiquidity, uint256 totalStableDebt, uint256 totalVariableDebt, , , , , , , ) =
                    protocolDataProvider.getReserveData(address(want));
        uint256 incentivesRate = _incentivesRate(availableLiquidity.add(totalStableDebt).add(totalVariableDebt)); // total supplied liquidity in Agave
        return liquidityRate.add(incentivesRate);
    }

    //withdraw an amount including any want balance
    function _withdraw(uint256 amount) internal returns (uint256) {
        uint256 balanceUnderlying = agToken.balanceOf(address(this));
        uint256 looseBalance = want.balanceOf(address(this));
        uint256 total = balanceUnderlying.add(looseBalance);

        if (amount > total) {
            //cant withdraw more than we own
            amount = total;
        }

        if (looseBalance >= amount) {
            want.safeTransfer(address(strategy), amount);
            return amount;
        }

        //not state changing but OK because of previous call
        uint256 liquidity = want.balanceOf(address(agToken));

        if (liquidity > 1) {
            uint256 toWithdraw = amount.sub(looseBalance);

            if (toWithdraw <= liquidity) {
                //we can take all
                _lendingPool().withdraw(address(want), toWithdraw, address(this));
            } else {
                //take all we can
                _lendingPool().withdraw(address(want), liquidity, address(this));
            }
        }
        looseBalance = want.balanceOf(address(this));
        want.safeTransfer(address(strategy), looseBalance);
        return looseBalance;
    }

    function _deposit(uint256 amount) internal {
        ILendingPool lp = _lendingPool();
        // NOTE: check if allowance is enough and acts accordingly
        // allowance might not be enough if
        //     i) initial allowance has been used (should take years)
        //     ii) lendingPool contract address has changed (Aave updated the contract address)
        if(want.allowance(address(this), address(lp)) < amount){
            IERC20(address(want)).safeApprove(address(lp), 0);
            IERC20(address(want)).safeApprove(address(lp), type(uint256).max);
        }

        lp.deposit(address(want), amount, address(this), 0);
    }

    function _lendingPool() internal view returns (ILendingPool lendingPool) {
        lendingPool = ILendingPool(protocolDataProvider.ADDRESSES_PROVIDER().getLendingPool());
    }

    function _checkIncentivized() internal view returns (bool) {
        return isIncentivised;
    }    
    function _sellRewardForWant() internal {
        _redeemRewardLPForGNO();
        _sellSYMMForGNO();
        _tradeGNOForWant();
    }

    // We get SYMM rewards from the LP tokens (Symmetric is a fork of Balancer)
    function _sellSYMMForGNO() internal {
        uint256 _amount = IERC20(SYMM).balanceOf(address(this));

        symmetricExchangeProxy.smartSwapExactIn(TokenInterface(SYMM), TokenInterface(GNO), _amount, 0, 3);
    }

    function _redeemRewardLPForGNO() internal {
        uint256 _amount = IERC20(symmetricPool_AGVE_GNO).balanceOf(address(this));

        if(IERC20(symmetricPool_AGVE_GNO).allowance(address(this), symmetricPool_AGVE_GNO) < _amount){
            IERC20(symmetricPool_AGVE_GNO).safeApprove(symmetricPool_AGVE_GNO, type(uint256).max);
        }

        BPool(symmetricPool_AGVE_GNO).exitswapPoolAmountIn(GNO, _amount, 0);
    }


    function _tradeGNOForWant() internal {
        uint256 _amount = IERC20(GNO).balanceOf(address(this));

        address[] memory path;

        if(address(want) == address(WETH)) {
            path = new address[](2);
            path[0] = address(GNO);
            path[1] = address(want);
        } else {
            path = new address[](3);
            path[0] = address(GNO);
            path[1] = address(WETH);
            path[2] = address(want);
        }

        if(IERC20(GNO).allowance(address(this), address(router)) < _amount) {
            IERC20(GNO).safeApprove(address(router), type(uint256).max);
        }

        router.swapExactTokensForTokens(
            _amount,
            0,
            path,
            address(this),
            now
        );
    }

    // TODO: change _AAVEtoWant to _rewardToWant
    function _rewardToWant(uint256 _amount) internal view returns (uint256) {
        // if(_amount == 0) {
        //     return 0;
        // }

        // address[] memory path;

        // if(address(want) == address(WETH)) {
        //     path = new address[](2);
        //     path[0] = address(AAVE);
        //     path[1] = address(want);
        // } else {
        //     path = new address[](3);
        //     path[0] = address(AAVE);
        //     path[1] = address(WETH);
        //     path[2] = address(want);
        // }

        // uint256[] memory amounts = router.getAmountsOut(_amount, path);
        // return amounts[amounts.length - 1];
    }

    function _incentivesController() internal view returns (IAgaveIncentivesController) {
        if(isIncentivised) {
            return agToken.getIncentivesController();
        } else {
            return IAgaveIncentivesController(0);
        }
    }

    function protectedTokens() internal view override returns (address[] memory) {
        address[] memory protected = new address[](2);
        protected[0] = address(want);
        protected[1] = address(agToken);
        return protected;
    }

    modifier keepers() {
        require(
            msg.sender == address(keep3r) || msg.sender == address(strategy) || msg.sender == vault.governance() || msg.sender == IBaseStrategy(strategy).management(),
            "!keepers"
        );
        _;
    }
}
