// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./LiquidityERC20.sol";
import "../interfaces/IAmmFactory.sol";
import "../interfaces/IConfig.sol";
import "../interfaces/IPriceOracle.sol";
import "../interfaces/IMarginFactory.sol";
import "../interfaces/IAmm.sol";
import "../interfaces/IVault.sol";
import "../interfaces/IMargin.sol";
import "../interfaces/IPairFactory.sol";
import "../interfaces/IComptroller.sol";
import "../utils/Reentrant.sol";
import "../libraries/UQ112x112.sol";
import "../libraries/Math.sol";
import "../libraries/FullMath.sol";
import "../libraries/ChainAdapter.sol";
import "../libraries/SignedMath.sol";

contract Amm is IAmm, LiquidityERC20, Reentrant {
    using UQ112x112 for uint224;
    using SignedMath for int256;

    uint256 public constant override MINIMUM_LIQUIDITY = 10**3;

    address public immutable override factory;
    address public override comptroller;
    address public override config;
    address public override baseToken;
    address public override quoteToken;
    address public override margin;

    uint256 public override price0CumulativeLast;
    uint256 public override price1CumulativeLast;
    uint256 public override lastPrice;
    uint256 public override lastRebaseTime;

    bytes4 private constant SELECTOR = bytes4(keccak256(bytes("transfer(address,uint256)")));
    uint112 private baseReserve; // uses single storage slot, accessible via getReserves
    uint112 private quoteReserve; // uses single storage slot, accessible via getReserves
    uint32 private blockTimestampLast;
    uint256 private lastBlockNumber;

    modifier onlyMargin() {
        require(margin == msg.sender, "Amm: ONLY_MARGIN");
        _;
    }

    constructor() {
        factory = msg.sender;
    }

    function initialize(
        address baseToken_,
        address quoteToken_,
        address margin_
    ) external override {
        require(msg.sender == factory, "Amm.initialize: FORBIDDEN"); // sufficient check
        baseToken = baseToken_;
        quoteToken = quoteToken_;
        margin = margin_;
        config = IAmmFactory(factory).config();
        comptroller = IPairFactory(IAmmFactory(factory).upperFactory()).comptroller();
    }

    /// @notice add liquidity
    /// @dev  calculate the liquidity according to the real baseReserve.
    function mint(address to)
        external
        override
        nonReentrant
        returns (
            uint256 baseAmount,
            uint256 quoteAmount,
            uint256 liquidity
        )
    {
        // only router can add liquidity
        require(IConfig(config).routerMap(msg.sender), "Amm.mint: FORBIDDEN");
        baseAmount = IERC20(baseToken).balanceOf(address(this));
        (quoteAmount, liquidity) = IComptroller(comptroller).mintLiquidity(address(this), baseAmount);
        _mint(to, liquidity);
        if (totalSupply == 0) {
            _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        }

        _update(baseReserve + baseAmount, quoteReserve + quoteAmount, baseReserve, quoteReserve, false);
        _safeTransfer(baseToken, margin, baseAmount);
        IVault(margin).deposit(msg.sender, baseAmount);

        emit Mint(msg.sender, to, baseAmount, quoteAmount, liquidity);
    }

    /// @notice add liquidity
    /// @dev  calculate the liquidity according to the real baseReserve.
    function burn(address to)
        external
        override
        nonReentrant
        returns (
            uint256 baseAmount,
            uint256 quoteAmount,
            uint256 liquidity
        )
    {
        // only router can burn liquidity
        require(IConfig(config).routerMap(msg.sender), "Amm.burn: FORBIDDEN");
        liquidity = balanceOf[address(this)];
        (baseAmount, quoteAmount) = IComptroller(comptroller).burnLiquidity(address(this), liquidity);

        _burn(address(this), liquidity);
        _update(baseReserve - baseAmount, quoteReserve - quoteAmount, baseReserve, quoteReserve, false);
        IVault(margin).withdraw(msg.sender, to, baseAmount);

        emit Burn(msg.sender, to, baseAmount, quoteAmount, liquidity);
    }

    function getRealBaseReserve() public view override returns (uint256 realBaseReserve) {
        (uint112 _baseReserve, uint112 _quoteReserve, ) = getReserves();
        int256 quoteTokenOfNetPosition = IMargin(margin).netPosition();
        require(int256(uint256(_quoteReserve)) + quoteTokenOfNetPosition <= 2**112, "Amm.getRealBaseReserve: NET_POSITION_VALUE_WRONG");

        uint256 baseTokenOfNetPosition;
        if (quoteTokenOfNetPosition == 0) {
            return uint256(_baseReserve);
        }

        uint256[2] memory result;
        if (quoteTokenOfNetPosition < 0) {
            // long  （+， -）
            result = estimateSwap(baseToken, quoteToken, 0, quoteTokenOfNetPosition.abs());
            baseTokenOfNetPosition = result[0];
            realBaseReserve = uint256(_baseReserve) + baseTokenOfNetPosition;
        } else {
            //short  （-， +）
            result = estimateSwap(quoteToken, baseToken, quoteTokenOfNetPosition.abs(), 0);
            baseTokenOfNetPosition = result[1];
            realBaseReserve = uint256(_baseReserve) - baseTokenOfNetPosition;
        }
    }

    /// @notice
    function swap(
        address trader,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount
    ) external override nonReentrant onlyMargin returns (uint256[2] memory amounts) {
        uint256[2] memory reserves;
        (reserves, amounts) = _estimateSwap(inputToken, outputToken, inputAmount, outputAmount);
        //check trade slippage
        _checkTradeSlippage(reserves[0], reserves[1], baseReserve, quoteReserve);
        _update(reserves[0], reserves[1], baseReserve, quoteReserve, false);

        emit Swap(trader, inputToken, outputToken, amounts[0], amounts[1]);
    }

    /// @notice  use in the situation  of forcing closing position
    function forceSwap(
        address trader,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount
    ) external override nonReentrant onlyMargin {
        require(inputToken == baseToken || inputToken == quoteToken, "Amm.forceSwap: WRONG_INPUT_TOKEN");
        require(outputToken == baseToken || outputToken == quoteToken, "Amm.forceSwap: WRONG_OUTPUT_TOKEN");
        require(inputToken != outputToken, "Amm.forceSwap: SAME_TOKENS");
        (uint112 _baseReserve, uint112 _quoteReserve, ) = getReserves();

        uint256 reserve0;
        uint256 reserve1;
        if (inputToken == baseToken) {
            reserve0 = _baseReserve + inputAmount;
            reserve1 = _quoteReserve - outputAmount;
        } else {
            reserve0 = _baseReserve - outputAmount;
            reserve1 = _quoteReserve + inputAmount;
        }

        _update(reserve0, reserve1, _baseReserve, _quoteReserve, true);

        emit ForceSwap(trader, inputToken, outputToken, inputAmount, outputAmount);
    }

    /// @notice invoke when price gap is larger than "gap" percent;
    /// @notice gap is in config contract
    function rebase() external override nonReentrant returns (uint256 quoteReserveAfter) {
        require(msg.sender == tx.origin, "Amm.rebase: ONLY_EOA");
        (uint256 quoteReserveFromInternal, uint256 quoteReserveFromExternal) = IComptroller(comptroller).rebaseAllowed(address(this));

        quoteReserveAfter = quoteReserveFromExternal;
        lastRebaseTime = uint32(block.timestamp % 2**32);
        _update(baseReserve, quoteReserveAfter, baseReserve, quoteReserve, true);

        emit Rebase(quoteReserve, quoteReserveAfter, baseReserve, quoteReserveFromInternal, quoteReserveFromExternal);
    }

    /// notice view method for estimating swap
    function estimateSwap(
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount
    ) public view override returns (uint256[2] memory amounts) {
        (, amounts) = _estimateSwap(inputToken, outputToken, inputAmount, outputAmount);
    }

    function getReserves()
        public
        view
        override
        returns (
            uint112 reserveBase,
            uint112 reserveQuote,
            uint32 blockTimestamp
        )
    {
        reserveBase = baseReserve;
        reserveQuote = quoteReserve;
        blockTimestamp = blockTimestampLast;
    }

    function _checkTradeSlippage(
        uint256 baseReserveNew,
        uint256 quoteReserveNew,
        uint112 baseReserveOld,
        uint112 quoteReserveOld
    ) internal view {
        // check trade slippage for every transaction
        uint256 numerator = quoteReserveNew * baseReserveOld * 100;
        uint256 demominator = baseReserveNew * quoteReserveOld;
        uint256 tradingSlippage = IConfig(config).tradingSlippage();
        require(
            (numerator < (100 + tradingSlippage) * demominator) && (numerator > (100 - tradingSlippage) * demominator),
            "AMM._checkTradeSlippage: TRADINGSLIPPAGE_TOO_LARGE_THAN_LAST_TRANSACTION"
        );
        require(
            (quoteReserveNew * 100 < ((100 + tradingSlippage) * baseReserveNew * lastPrice) / 2**112) &&
                (quoteReserveNew * 100 > ((100 - tradingSlippage) * baseReserveNew * lastPrice) / 2**112),
            "AMM._checkTradeSlippage: TRADINGSLIPPAGE_TOO_LARGE_THAN_LAST_BLOCK"
        );
    }

    function _estimateSwap(
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount
    ) internal view returns (uint256[2] memory reserves, uint256[2] memory amounts) {
        require(inputToken == baseToken || inputToken == quoteToken, "Amm._estimateSwap: WRONG_INPUT_TOKEN");
        require(outputToken == baseToken || outputToken == quoteToken, "Amm._estimateSwap: WRONG_OUTPUT_TOKEN");
        require(inputToken != outputToken, "Amm._estimateSwap: SAME_TOKENS");
        require(inputAmount > 0 || outputAmount > 0, "Amm._estimateSwap: INSUFFICIENT_AMOUNT");

        (uint112 _baseReserve, uint112 _quoteReserve, ) = getReserves();
        uint256 reserve0;
        uint256 reserve1;
        if (inputAmount > 0 && inputToken != address(0)) {
            // swapInput
            if (inputToken == baseToken) {
                outputAmount = _getAmountOut(inputAmount, _baseReserve, _quoteReserve);
                reserve0 = _baseReserve + inputAmount;
                reserve1 = _quoteReserve - outputAmount;
            } else {
                outputAmount = _getAmountOut(inputAmount, _quoteReserve, _baseReserve);
                reserve0 = _baseReserve - outputAmount;
                reserve1 = _quoteReserve + inputAmount;
            }
        } else {
            // swapOutput
            if (outputToken == baseToken) {
                require(outputAmount < _baseReserve, "AMM._estimateSwap: INSUFFICIENT_LIQUIDITY");
                inputAmount = _getAmountIn(outputAmount, _quoteReserve, _baseReserve);
                reserve0 = _baseReserve - outputAmount;
                reserve1 = _quoteReserve + inputAmount;
            } else {
                require(outputAmount < _quoteReserve, "AMM._estimateSwap: INSUFFICIENT_LIQUIDITY");
                inputAmount = _getAmountIn(outputAmount, _baseReserve, _quoteReserve);
                reserve0 = _baseReserve + inputAmount;
                reserve1 = _quoteReserve - outputAmount;
            }
        }
        reserves = [reserve0, reserve1];
        amounts = [inputAmount, outputAmount];
    }

    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function _getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "Amm._getAmountOut: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "Amm._getAmountOut: INSUFFICIENT_LIQUIDITY");
        uint256 numerator = amountIn * reserveOut;
        uint256 denominator = reserveIn + amountIn;
        amountOut = numerator / denominator;
    }

    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    function _getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountIn) {
        require(amountOut > 0, "Amm._getAmountIn: INSUFFICIENT_OUTPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "Amm._getAmountIn: INSUFFICIENT_LIQUIDITY");
        uint256 numerator = reserveIn * amountOut;
        uint256 denominator = (reserveOut - amountOut);
        amountIn = (numerator / denominator) + 1;
    }

    function _update(
        uint256 baseReserveNew,
        uint256 quoteReserveNew,
        uint112 baseReserveOld,
        uint112 quoteReserveOld,
        bool isRebaseOrForceSwap
    ) private {
        require(baseReserveNew <= type(uint112).max && quoteReserveNew <= type(uint112).max, "AMM._update: OVERFLOW");

        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        // last price means last block price.
        if (timeElapsed > 0 && baseReserveOld != 0 && quoteReserveOld != 0) {
            // * never overflows, and + overflow is desired
            price0CumulativeLast += uint256(UQ112x112.encode(quoteReserveOld).uqdiv(baseReserveOld)) * timeElapsed;
            price1CumulativeLast += uint256(UQ112x112.encode(baseReserveOld).uqdiv(quoteReserveOld)) * timeElapsed;
            // update twap
            IPriceOracle(IConfig(config).priceOracle()).updateAmmTwap(address(this));
        }

        uint256 blockNumberDelta = ChainAdapter.blockNumber() - lastBlockNumber;
        //every arbi block number calculate
        if (blockNumberDelta > 0 && baseReserveOld != 0) {
            lastPrice = uint256(UQ112x112.encode(quoteReserveOld).uqdiv(baseReserveOld));
        }

        //set the last price to current price for rebase may cause price gap oversize the tradeslippage.
        if ((lastPrice == 0 && baseReserveNew != 0) || isRebaseOrForceSwap) {
            lastPrice = uint256(UQ112x112.encode(uint112(quoteReserveNew)).uqdiv(uint112(baseReserveNew)));
        }

        baseReserve = uint112(baseReserveNew);
        quoteReserve = uint112(quoteReserveNew);

        lastBlockNumber = ChainAdapter.blockNumber();
        blockTimestampLast = blockTimestamp;

        emit Sync(baseReserve, quoteReserve);
    }

    function _safeTransfer(
        address token,
        address to,
        uint256 value
    ) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "AMM._safeTransfer: TRANSFER_FAILED");
    }
}
