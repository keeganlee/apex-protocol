// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../interfaces/IComptroller.sol";
import "../interfaces/IAmm.sol";
import "../interfaces/IMargin.sol";
import "../interfaces/IConfig.sol";
import "../interfaces/IPriceOracle.sol";
import "../libraries/Math.sol";
import "../libraries/SignedMath.sol";

contract Comptroller is IComptroller {
    using SignedMath for int256;

    function addMarginAllowed(address margin, uint256 depositAmount) external view override returns (bool) {
        address baseToken = IMargin(margin).baseToken();
        uint256 reserve = IMargin(margin).reserve();
        uint256 balance = IERC20(baseToken).balanceOf(margin);
        require(depositAmount <= balance - reserve, "Comptroller.addMarginAllowed: WRONG_DEPOSIT_AMOUNT");
        return true;
    }

    function removeMarginAllowed(address margin, address trader, uint256 withdrawAmount) external override returns (bool) {

    }

    function removeMarginVerify(address margin, address trader, uint256 withdrawAmount) external override {

    }

    function openPositionAllowed(address margin, address trader, uint8 side, uint256 quoteAmount) external override returns (bool) {

    }

    function openPositionVerify(address margin, address trader, uint8 side, uint256 quoteAmount, uint256 baseAmount) external override {

    }

    function closePositionAllowed(address margin, address trader, uint256 quoteAmount) external override returns (bool) {

    }

    function closePositionVerify(address margin, address trader, uint256 quoteAmount) external override {

    }

    function liquidateAllowed(address margin, address trader) external override returns (bool) {

    }

    function liquidateVerify(address margin, address trader) external override {

    }

    function getWithdrawable(address margin, address holder) external view returns (uint256 amount) {
        (int256 baseSize, int256 quoteSize, uint256 tradeSize) = IMargin(margin).getPosition(holder);
        int256 fundingFee = IMargin(margin).calFundingFee(holder);
        baseSize = baseSize + fundingFee;
        IConfig config = IConfig(IMargin(margin).config());
        if (quoteSize == 0) {
            amount = baseSize <= 0 ? 0 : baseSize.abs();
        } else if (quoteSize < 0) {
            uint256 baseAmount = IPriceOracle(config.priceOracle()).getMarkPriceAcc(
                IMargin(margin).amm(),
                IConfig(config).beta(),
                quoteSize.abs(),
                true
            );

            uint256 a = baseAmount * 10000;
            uint256 b = (10000 - IConfig(config).initMarginRatio());
            //calculate how many base needed to maintain current position
            uint256 baseNeeded = a / b;
            if (a % b != 0) {
                baseNeeded += 1;
            }
            //borrowed - repay, earn when borrow more and repay less
            unrealizedPnl = int256(1).mulU(tradeSize).subU(baseAmount);
            amount = baseSize.abs() <= baseNeeded ? 0 : baseSize.abs() - baseNeeded;
        } else {
            uint256 baseAmount = IPriceOracle(config.priceOracle()).getMarkPriceAcc(
                IMargin(margin).amm(),
                IConfig(config).beta(),
                quoteSize.abs(),
                false
            );

            uint256 baseNeeded = (baseAmount * (10000 - config.initMarginRatio())) / 10000;
            //repay - lent, earn when lent less and repay more
            unrealizedPnl = int256(1).mulU(baseAmount).subU(tradeSize);
            int256 remainBase = baseSize.addU(baseNeeded);
            amount = remainBase <= 0 ? 0 : remainBase.abs();
        }
    }

    function getUnrealizePnl(address margin, address holder) external view returns (uint256 unrealizedPnl) {
        (int256 baseSize, int256 quoteSize, uint256 tradeSize) = IMargin(margin).getPosition(holder);
        int256 fundingFee = IMargin(margin).calFundingFee(holder);
        baseSize = baseSize + fundingFee;
        IConfig config = IConfig(IMargin(margin).config());
        if (quoteSize == 0) {
            unrealizedPnl = 0;
        } else if (quoteSize < 0) {
            uint256 baseAmount = IPriceOracle(config.priceOracle()).getMarkPriceAcc(
                IMargin(margin).amm(),
                IConfig(config).beta(),
                quoteSize.abs(),
                true
            );
            //borrowed - repay, earn when borrow more and repay less
            unrealizedPnl = int256(1).mulU(tradeSize).subU(baseAmount);
        } else {
            uint256 baseAmount = IPriceOracle(config.priceOracle()).getMarkPriceAcc(
                IMargin(margin).amm(),
                IConfig(config).beta(),
                quoteSize.abs(),
                false
            );
            //repay - lent, earn when lent less and repay more
            unrealizedPnl = int256(1).mulU(baseAmount).subU(tradeSize);
        }
    }

    function mintLiquidity(address amm, uint256 baseAmount) external view override returns (uint256 quoteAmount, uint256 liquidity) {
        require(baseAmount > 0, "Comptroller.mintLiquidity: ZERO_BASE_AMOUNT");
        IAmm iAmm = IAmm(amm);
        (uint112 baseReserve, uint112 quoteReserve, ) = iAmm.getReserves();
        uint256 totalSupply = iAmm.totalSupply();

        if (totalSupply == 0) {
            address baseToken = iAmm.baseToken();
            address quoteToken = iAmm.quoteToken();
            uint256 MINIMUM_LIQUIDITY = iAmm.MINIMUM_LIQUIDITY();

            (quoteAmount, ) = IPriceOracle(IConfig(iAmm.config()).priceOracle()).quote(baseToken, quoteToken, baseAmount);
            require(quoteAmount > 0, "Comptroller.mintLiquidity: INSUFFICIENT_QUOTE_AMOUNT");
            liquidity = Math.sqrt(baseAmount * quoteAmount) - MINIMUM_LIQUIDITY;
        } else {
            quoteAmount = (baseAmount * quoteReserve) / baseReserve;
            uint256 realBaseReserve = iAmm.getRealBaseReserve();
            liquidity = (baseAmount * totalSupply) / realBaseReserve;
        }
        require(liquidity > 0, "Comptroller.mintLiquidity: INSUFFICIENT_LIQUIDITY_MINTED");

        // price check  0.1%
        require(
            (baseReserve + baseAmount) * quoteReserve * 999 <= (quoteReserve + quoteAmount) * baseReserve * 1000,
            "Comptroller.mintLiquidity: PRICE_BEFORE_AND_AFTER_MUST_BE_THE_SAME"
        );
        require(
            (quoteReserve + quoteAmount) * baseReserve * 1000 <= (baseReserve + baseAmount) * quoteReserve * 1001,
            "Comptroller.mintLiquidity: PRICE_BEFORE_AND_AFTER_MUST_BE_THE_SAME"
        );
    }

    function burnLiquidity(address amm, uint256 liquidity) external view override returns (uint256 baseAmount, uint256 quoteAmount) {
        IAmm iAmm = IAmm(amm);
        (uint112 baseReserve, uint112 quoteReserve, ) = iAmm.getReserves(); // gas savings
        uint256 realBaseReserve = iAmm.getRealBaseReserve();
        uint256 totalSupply = iAmm.totalSupply();

        baseAmount = (liquidity * realBaseReserve) / totalSupply;
        quoteAmount = (baseAmount * quoteReserve) / baseReserve;
        require(baseAmount > 0 && quoteAmount > 0, "Comptroller.burnLiquidity: INSUFFICIENT_LIQUIDITY_BURNED");

        // check max burnable
        int256 quoteTokenOfNetPosition = IMargin(iAmm.margin()).netPosition();
        uint256 quoteTokenOfTotalPosition = IMargin(iAmm.margin()).totalPosition();
        uint256 lpWithdrawThresholdForNet = IConfig(iAmm.config()).lpWithdrawThresholdForNet();
        uint256 lpWithdrawThresholdForTotal = IConfig(iAmm.config()).lpWithdrawThresholdForTotal();
        require(
            quoteTokenOfNetPosition.abs() * 100 <= (quoteReserve - quoteAmount) * lpWithdrawThresholdForNet,
            "Amm.burn: TOO_LARGE_LIQUIDITY_WITHDRAW_FOR_NET_POSITION"
        );
        require(
            quoteTokenOfTotalPosition * 100 <= (quoteReserve - quoteAmount) * lpWithdrawThresholdForTotal,
            "Amm.burn: TOO_LARGE_LIQUIDITY_WITHDRAW_FOR_TOTAL_POSITION"
        );

        // price check  0.1%
        require(
            (baseReserve - baseAmount) * quoteReserve * 999 <= (quoteReserve - quoteAmount) * baseReserve * 1000,
            "Comptroller.burnLiquidity: PRICE_BEFORE_AND_AFTER_MUST_BE_THE_SAME"
        );
        require(
            (quoteReserve - quoteAmount) * baseReserve * 1000 <= (baseReserve - baseAmount) * quoteReserve * 1001,
            "Comptroller.burnLiquidity: PRICE_BEFORE_AND_AFTER_MUST_BE_THE_SAME"
        );
    }

    function rebaseAllowed(address amm) external view override returns (uint256 quoteReserveFromInternal, uint256 quoteReserveFromExternal) {
        IAmm iAmm = IAmm(amm);
        uint256 interval = IConfig(iAmm.config()).rebaseInterval();
        uint256 lastRebaseTime = iAmm.lastRebaseTime();
        require(block.timestamp - lastRebaseTime >= interval, "Comptroller.rebaseAllowed: NOT_REACH_NEXT_REBASE_TIME");

        address baseToken = iAmm.baseToken();
        address quoteToken = iAmm.quoteToken();
        (uint112 baseReserve, , ) = iAmm.getReserves();

        IPriceOracle oracle = IPriceOracle(IConfig(iAmm.config()).priceOracle());
        uint8 priceSource;
        (quoteReserveFromExternal, priceSource) = oracle.quote(
            baseToken,
            quoteToken,
            baseReserve
        );
        if (priceSource == 0) {
            // external price use UniswapV3Twap, internal price use ammTwap
            quoteReserveFromInternal = oracle.quoteFromAmmTwap(
                address(this),
                baseReserve
            );
        } else {
            // otherwise, use lastPrice as internal price
            quoteReserveFromInternal = (iAmm.lastPrice() * baseReserve) / 2**112;
        }

        uint256 gap = IConfig(iAmm.config()).rebasePriceGap();
        require(
            quoteReserveFromExternal * 100 >= quoteReserveFromInternal * (100 + gap) ||
                quoteReserveFromExternal * 100 <= quoteReserveFromInternal * (100 - gap),
            "Comptroller.rebaseAllowed: NOT_BEYOND_PRICE_GAP"
        );
    }

    // query max burn liquidity
    function getMaxBurnLiquidity(address amm) external view override returns (uint256 maxLiquidity) {
        IAmm iAmm = IAmm(amm);
        (uint112 _baseReserve, uint112 _quoteReserve, ) = iAmm.getReserves(); // gas savings
        // get real baseReserve
        uint256 realBaseReserve = iAmm.getRealBaseReserve();
        int256 quoteTokenOfNetPosition = IMargin(iAmm.margin()).netPosition();
        uint256 quoteTokenOfTotalPosition = IMargin(iAmm.margin()).totalPosition();
        uint256 _totalSupply = iAmm.totalSupply();

        uint256 lpWithdrawThresholdForNet = IConfig(iAmm.config()).lpWithdrawThresholdForNet();
        uint256 lpWithdrawThresholdForTotal = IConfig(iAmm.config()).lpWithdrawThresholdForTotal();

        //  for net position  case
        uint256 maxQuoteLeftForNet = (quoteTokenOfNetPosition.abs() * 100) / lpWithdrawThresholdForNet;
        uint256 maxWithdrawQuoteAmountForNet;
        if (_quoteReserve > maxQuoteLeftForNet) {
            maxWithdrawQuoteAmountForNet = _quoteReserve - maxQuoteLeftForNet;
        }

        //  for total position  case
        uint256 maxQuoteLeftForTotal = (quoteTokenOfTotalPosition * 100) / lpWithdrawThresholdForTotal;
        uint256 maxWithdrawQuoteAmountForTotal;
        if (_quoteReserve > maxQuoteLeftForTotal) {
            maxWithdrawQuoteAmountForTotal = _quoteReserve - maxQuoteLeftForTotal;
        }

        uint256 maxWithdrawBaseAmount;
        // use the min quote amount;
        if (maxWithdrawQuoteAmountForNet > maxWithdrawQuoteAmountForTotal) {
            maxWithdrawBaseAmount = (maxWithdrawQuoteAmountForTotal * _baseReserve) / _quoteReserve;
        } else {
            maxWithdrawBaseAmount = (maxWithdrawQuoteAmountForNet * _baseReserve) / _quoteReserve;
        }

        maxLiquidity = (maxWithdrawBaseAmount * _totalSupply) / realBaseReserve;
    }
}