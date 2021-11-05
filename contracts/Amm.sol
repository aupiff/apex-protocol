pragma solidity ^0.8.0;

import "./interfaces/IAmm.sol";
import "./interfaces/IVault.sol";
import "./LiquidityERC20.sol";
import "./libraries/Math.sol";
import "./libraries/UQ112x112.sol";
import "./libraries/AMMLibrary.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IPriceOracle.sol";
import "./libraries/FullMath.sol";
import "./interfaces/IConfig.sol";
import "./utils/Reentrant.sol";

contract Amm is IAmm, LiquidityERC20, Reentrant {
    using UQ112x112 for uint224;

    uint256 public constant MINIMUM_LIQUIDITY = 10**3;

    address public override factory;
    address public override baseToken;
    address public override quoteToken;
    address public override config;
    address public override margin;

    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;

    bytes4 private constant SELECTOR = bytes4(keccak256(bytes("transfer(address,uint256)")));
    uint112 private baseReserve; // uses single storage slot, accessible via getReserves
    uint112 private quoteReserve; // uses single storage slot, accessible via getReserves
    uint32 private blockTimestampLast; // uses single storage slot, accessible via getReserves

    modifier onlyMargin() {
        require(margin == msg.sender, "AMM: ONLY_MARGIN");
        _;
    }

    constructor() {
        factory = msg.sender;
    }

    function initialize(
        address baseToken_,
        address quoteToken_,
        address config_,
        address margin_
    ) external override {
        require(msg.sender == factory, "Amm: FORBIDDEN"); // sufficient check
        baseToken = baseToken_;
        quoteToken = quoteToken_;
        config = config_;
        margin = margin_;
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

    function estimateSwap(
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount
    ) public view override returns (uint256[2] memory amounts) {
        require(inputAmount > 0 || outputAmount > 0, "AMM: INSUFFICIENT_OUTPUT_AMOUNT");

        (uint112 _baseReserve, uint112 _quoteReserve, ) = getReserves();
        //todo
        //   require(inputAmount < _baseReserve && outputAmount < _quoteReserve, "AMM: INSUFFICIENT_LIQUIDITY");

        uint256 _inputAmount;
        uint256 _outputAmount;

        if (inputToken != address(0x0) && inputAmount != 0) {
            _outputAmount = _swapInputQuery(inputToken, inputAmount);
            _inputAmount = inputAmount;
        } else {
            _inputAmount = _swapOutputQuery(outputToken, outputAmount);
            _outputAmount = outputAmount;
        }

        return [_inputAmount, _outputAmount];
    }

    function estimateSwapWithMarkPrice(
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount
    ) external view override returns (uint256[2] memory amounts) {
        (uint112 _baseReserve, uint112 _quoteReserve, ) = getReserves();

        uint256 quoteAmount;
        uint256 baseAmount;
        if (inputAmount != 0) {
            quoteAmount = inputAmount;
        } else {
            quoteAmount = outputAmount;
        }

        uint256 inputSquare = quoteAmount * quoteAmount;
        // price = (sqrt(y/x)+ betal * deltaY/L).**2;
        // deltaX = deltaY/price
        // deltaX = (deltaY * L)/(y + betal * deltaY)**2
        uint256 L = uint256(_baseReserve) * uint256(_quoteReserve);
        uint8 beta = IConfig(config).beta();
        require(beta >= 50 && beta <= 100, "beta error");
        //112
        uint256 denominator = (_quoteReserve + (beta * quoteAmount) / 100);
        //224
        denominator = denominator * denominator;
        baseAmount = FullMath.mulDiv(quoteAmount, L, denominator);
        return inputAmount == 0 ? [baseAmount, quoteAmount] : [quoteAmount, baseAmount];
    }

    function mint(address to) external override nonReentrant returns (uint256 quoteAmount, uint256 liquidity) {
        (uint112 _baseReserve, uint112 _quoteReserve, ) = getReserves(); // gas savings
        uint256 baseAmount = IERC20(baseToken).balanceOf(address(this));

        uint256 _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        uint256 quoteAmountMinted;
        if (_totalSupply == 0) {
            quoteAmountMinted = getQuoteAmountByPriceOracle(baseAmount);
            liquidity = Math.sqrt(baseAmount * quoteAmountMinted) - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            quoteAmountMinted = getQuoteAmountByCurrentPrice(baseAmount);
            liquidity = Math.minU(
                (baseAmount * _totalSupply) / _baseReserve,
                (quoteAmountMinted * _totalSupply) / _quoteReserve
            );
        }
        require(liquidity > 0, "AMM: INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity);

        _update(_baseReserve + baseAmount, _quoteReserve + quoteAmountMinted, _baseReserve, _quoteReserve);
        _safeTransfer(baseToken, margin, baseAmount);
        IVault(margin).deposit(msg.sender, baseAmount);
        quoteAmount = quoteAmountMinted;
        emit Mint(msg.sender, to, baseAmount, quoteAmountMinted, liquidity);
    }

    function burn(address to) external override nonReentrant returns (uint256 amount0, uint256 amount1) {
        (uint112 _baseReserve, uint112 _quoteReserve, ) = getReserves(); // gas savings
        address _baseToken = baseToken; // gas savings

        // uint256 vaultAmount = IERC20(_baseToken).balanceOf(address(vault));
        // uint256 vaultAmount = IVault(margin).reserve();
        uint256 liquidity = balanceOf[address(this)];

        uint256 _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        amount0 = (liquidity * _baseReserve) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = (liquidity * _quoteReserve) / _totalSupply; // using balances ensures pro-rata distribution
        require(amount0 > 0 && amount1 > 0, "AMM: INSUFFICIENT_LIQUIDITY_BURNED");
        // require(amount0 <= vaultAmount, "AMM: not enough base token withdraw");

        _burn(address(this), liquidity);

        uint256 balance0 = _baseReserve - amount0;
        uint256 balance1 = _quoteReserve - amount1;

        _update(balance0, balance1, _baseReserve, _quoteReserve);
        //  if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        // vault withdraw
        IVault(margin).withdraw(msg.sender, to, amount0);
        emit Burn(msg.sender, to, amount0, amount1);
    }

    function swap(
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount
    ) external override onlyMargin nonReentrant returns (uint256[2] memory amounts) {
        require(inputAmount > 0 || outputAmount > 0, "AMM: INSUFFICIENT_OUTPUT_AMOUNT");

        (uint112 _baseReserve, uint112 _quoteReserve, ) = getReserves();

        // require(inputAmount < _baseReserve && outputAmount < _quoteReserve, "AMM: INSUFFICIENT_LIQUIDITY");

        uint256 _inputAmount;
        uint256 _outputAmount;
        //@audit
        if (inputToken != address(0x0) && inputAmount != 0) {
            _outputAmount = _swapInput(inputToken, inputAmount);
            _inputAmount = inputAmount;
        } else {
            _inputAmount = _swapOutput(outputToken, outputAmount);
            _outputAmount = outputAmount;
        }
        emit Swap(inputToken, outputToken, _inputAmount, _outputAmount);
        return [_inputAmount, _outputAmount];
    }

    function forceSwap(
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount
    ) external override nonReentrant onlyMargin {
        require((inputToken == baseToken || inputToken == quoteToken), " wrong input address");
        require((outputToken == baseToken || outputToken == quoteToken), " wrong output address");
        (uint112 _baseReserve, uint112 _quoteReserve, ) = getReserves();
        uint256 balance0;
        uint256 balance1;
        if (inputToken == baseToken) {
            balance0 = baseReserve + inputAmount;
            balance1 = quoteReserve - outputAmount;
        } else {
            balance0 = baseReserve - outputAmount;
            balance1 = quoteReserve + inputAmount;
        }
        _update(balance0, balance1, _baseReserve, _quoteReserve);
        emit ForceSwap(inputToken, outputToken, inputAmount, outputAmount);
    }

    function rebase() public override nonReentrant returns (uint256 amount) {
        (uint112 _baseReserve, uint112 _quoteReserve, ) = getReserves();
        uint256 quoteReserveDesired = getQuoteAmountByPriceOracle(_baseReserve);
        //todo config
        if (
            quoteReserveDesired * 100 >= uint256(_quoteReserve) * 105 ||
            quoteReserveDesired * 100 <= uint256(_quoteReserve) * 95
        ) {
            _update(_baseReserve, quoteReserveDesired, _baseReserve, _quoteReserve);

            amount = (quoteReserveDesired > _quoteReserve)
                ? (quoteReserveDesired - _quoteReserve)
                : (_quoteReserve - quoteReserveDesired);

            emit Rebase(_quoteReserve, quoteReserveDesired, _baseReserve);
        }
    }

    function getQuoteAmountByCurrentPrice(uint256 baseAmount) internal view returns (uint256 quoteAmount) {
        return AMMLibrary.quote(baseAmount, uint256(baseReserve), uint256(quoteReserve));
    }

    function getQuoteAmountByPriceOracle(uint256 baseAmount) internal view returns (uint256 quoteAmount) {
        // get price oracle
        (uint112 _baseReserve, uint112 _quoteReserve, ) = getReserves();
        address priceOracle = IConfig(config).priceOracle();
        quoteAmount = IPriceOracle(priceOracle).quote(baseToken, quoteToken, baseAmount);
    }

    function _swapInput(address inputToken, uint256 inputAmount) internal returns (uint256 amountOut) {
        require((inputToken == baseToken || inputToken == quoteToken), "AMM: wrong input address");

        (uint112 _baseReserve, uint112 _quoteReserve, ) = getReserves(); // gas savings
        uint256 balance0;
        uint256 balance1;

        // require( outputAmount < _quoteReserve, "AMM: INSUFFICIENT_LIQUIDITY");

        if (inputToken == baseToken) {
            amountOut = AMMLibrary.getAmountOut(inputAmount, _baseReserve, _quoteReserve);
            balance0 = _baseReserve + inputAmount;
            balance1 = _quoteReserve - amountOut;
            // if necessary open todo
            // uint balance0Adjusted = balance0.mul(1000).sub(inputAmount.mul(3));
            // uint balance1Adjusted = balance1.mul(1000);
            // require(balance0Adjusted.mul(balance1Adjusted) >= uint(_baseReserve).mul(_quoteReserve).mul(1000**2), 'AMM: K');
        } else {
            amountOut = AMMLibrary.getAmountOut(inputAmount, _quoteReserve, _baseReserve);
            //
            balance0 = _baseReserve - amountOut;
            balance1 = _quoteReserve + inputAmount;
        }
        _update(balance0, balance1, _baseReserve, _quoteReserve);
    }

    function _swapOutput(address outputToken, uint256 outputAmount) internal returns (uint256 amountIn) {
        require((outputToken == baseToken || outputToken == quoteToken), "AMM: wrong output address");
        uint256 balance0;
        uint256 balance1;

        (uint112 _baseReserve, uint112 _quoteReserve, ) = getReserves(); // gas savings
        if (outputToken == baseToken) {
            require(outputAmount < _baseReserve, "AMM: INSUFFICIENT_LIQUIDITY");

            amountIn = AMMLibrary.getAmountIn(outputAmount, _quoteReserve, _baseReserve);
            balance0 = _baseReserve - outputAmount;
            balance1 = _quoteReserve + amountIn;
        } else {
            require(outputAmount < _quoteReserve, "AMM: INSUFFICIENT_LIQUIDITY");

            amountIn = AMMLibrary.getAmountIn(outputAmount, _baseReserve, _quoteReserve);
            balance0 = _baseReserve + amountIn;
            balance1 = _quoteReserve - outputAmount;
        }
        _update(balance0, balance1, _baseReserve, _quoteReserve);
    }

    function _swapInputQuery(address inputToken, uint256 inputAmount) internal view returns (uint256 amountOut) {
        require((inputToken == baseToken || inputToken == quoteToken), "AMM: wrong input address");

        (uint112 _baseReserve, uint112 _quoteReserve, ) = getReserves(); // gas savings

        if (inputToken == baseToken) {
            amountOut = AMMLibrary.getAmountOut(inputAmount, _baseReserve, _quoteReserve);
        } else {
            amountOut = AMMLibrary.getAmountOut(inputAmount, _quoteReserve, _baseReserve);
        }
    }

    function _swapOutputQuery(address outputToken, uint256 outputAmount) internal view returns (uint256 amountIn) {
        require((outputToken == baseToken || outputToken == quoteToken), "AMM: wrong output address");

        (uint112 _baseReserve, uint112 _quoteReserve, ) = getReserves(); // gas savings

        if (outputToken == baseToken) {
            require(outputAmount < _baseReserve, "AMM: INSUFFICIENT_LIQUIDITY");
            amountIn = AMMLibrary.getAmountIn(outputAmount, _quoteReserve, _baseReserve);
        } else {
            require(outputAmount < _quoteReserve, "AMM: INSUFFICIENT_LIQUIDITY");
            amountIn = AMMLibrary.getAmountIn(outputAmount, _baseReserve, _quoteReserve);
        }
    }

    function _update(
        uint256 balance0,
        uint256 balance1,
        uint112 _reserve0,
        uint112 _reserve1
    ) private {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, "AMM: OVERFLOW");
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            price0CumulativeLast += uint256(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint256(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        baseReserve = uint112(balance0);
        quoteReserve = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(baseReserve, quoteReserve);
    }

    function _safeTransfer(
        address token,
        address to,
        uint256 value
    ) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "AMM: TRANSFER_FAILED");
    }
}
