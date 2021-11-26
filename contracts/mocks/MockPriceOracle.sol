pragma solidity ^0.8.0;

contract MockPriceOracle {
    constructor() {}

    int256 public pf = 0;

    //premiumFraction is (markPrice - indexPrice) * fundingRatePrecision / 8h / indexPrice
    function getPremiumFraction(address amm) external view returns (int256) {
        return pf;
    }

    function setPf(int256 _pf) external {
        pf = _pf;
    }

    function getMarkPriceAcc(
        address amm,
        uint8 beta,
        uint256 quoteAmount,
        bool negative
    ) public view returns (uint256 price) {
        return 1;
    }

    function quote(
        address baseToken,
        address quoteToken,
        uint256 baseAmount
    ) external view  returns (uint256 quoteAmount) {
        quoteAmount = 100000 * 10**6;
    }
}
