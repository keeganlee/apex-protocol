// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface IComptroller {
    function addMarginAllowed(address margin, address trader, uint256 depositAmount) external returns (bool);
    function addMarginVerify(address margin, address trader, uint256 depositAmount) external;

    function removeMarginAllowed(address margin, address trader, uint256 withdrawAmount) external returns (bool);
    function removeMarginVerify(address margin, address trader, uint256 withdrawAmount) external;

    function openPositionAllowed(address margin, address trader, uint8 side, uint256 quoteAmount) external returns (bool);
    function openPositionVerify(address margin, address trader, uint8 side, uint256 quoteAmount, uint256 baseAmount) external;

    function closePositionAllowed(address margin, address trader, uint256 quoteAmount) external returns (bool);
    function closePositionVerify(address margin, address trader, uint256 quoteAmount) external;

    function liquidateAllowed(address margin, address trader) external returns (bool);
    function liquidateVerify(address margin, address trader) external;

    function mintLiquidity(address amm, uint256 baseAmount) external view returns (uint256 quoteAmount, uint256 liquidity);

    function burnLiquidity(address amm, uint256 liquidity) external view returns (uint256 baseAmount, uint256 quoteAmount);

    function rebaseAllowed(address amm) external view returns (uint256 quoteReserveFromInternal, uint256 quoteReserveFromExternal);

    function getMaxBurnLiquidity(address amm) external view returns (uint256 maxLiquidity);
}