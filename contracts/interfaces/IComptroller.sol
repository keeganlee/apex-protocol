// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface IComptroller {
    function addMarginAllowed(address margin, address trader, uint256 depositAmount) external;
    function addMarginVerify(address margin, address trader, uint256 depositAmount) external;

    function removeMarginAllowed(address margin, address trader, uint256 withdrawAmount) external;
    function removeMarginVerify(address margin, address trader, uint256 withdrawAmount) external;

    function openPositionAllowed(address margin, address trader, uint8 side, uint256 quoteAmount) external;
    function openPositionVerify(address margin, address trader, uint8 side, uint256 quoteAmount, uint256 baseAmount) external;

    function closePositionAllowed(address margin, address trader, uint256 quoteAmount) external;
    function closePositionVerify(address margin, address trader, uint256 quoteAmount) external;

    function liquidateAllowed(address margin, address trader) external;
    function liquidateVerify(address margin, address trader) external;

    function mintLiquidityAllowed(address amm, address sender) external;
    function mintLiquidityVerify(address amm, address sender) external;

    function burnLiquidityAllowed(address amm, address sender) external;
    function burnLiquidityVerify(address amm, address sender) external;
}