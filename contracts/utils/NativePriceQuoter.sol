// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @notice Utility library of the crypto stamp related contracts.
 *
 * @custom:website https://nft.poczta-polska.pl
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
library NativePriceQuoter {
    uint8 internal constant DEFAULT_DECIMALS = 8;

    // MATIC / USD
    address internal constant POL2USD_PRICE_FEED_CONTRACT = 0xAB594600376Ec9fD91F8e885dADF0CE036862dE0;
    // PLN / USD
    address internal constant PLN2USD_PRICE_FEED_CONTRACT = 0xB34BCE11040702f71c11529D00179B2959BcE6C0;

    // Exchange rates data feed
    AggregatorV3Interface internal constant basePriceFeed = AggregatorV3Interface(POL2USD_PRICE_FEED_CONTRACT);
    AggregatorV3Interface internal constant quotePriceFeed = AggregatorV3Interface(PLN2USD_PRICE_FEED_CONTRACT);

    /**
     * @dev ....
     */
    function derivedPrice(uint256 listPrice, uint80[2] memory rounds) internal view returns (uint256, uint80[2] memory) {
        return _derivePrice(listPrice, rounds);
    }
    /**
     * @dev Used to derive current token price from the base value in PLN.
     */
    function _derivePrice(uint256 listPrice, uint80[2] memory rounds) private view returns (uint256 price, uint80[2] memory roundIds) {
        (uint80 _baseRoundId, int256 _basePrice, uint256 _baseTimestamp, bool _callLatestBase) = (0, 0, 0, true);
        (uint80 _quoteRoundId, int256 _quotePrice, uint256 _quoteTimestamp, bool _callLatestQuote) = (0, 0, 0, true);

        if (rounds[0] != 0 && rounds[1] != 0) {
            (_baseRoundId, _basePrice,, _baseTimestamp,) = basePriceFeed.getRoundData(rounds[0]);
            (_quoteRoundId, _quotePrice,, _quoteTimestamp,) = quotePriceFeed.getRoundData(rounds[1]);
            uint256 validTimestamp = block.timestamp - 1 hours;

            _callLatestBase = (_baseTimestamp < validTimestamp);
            _callLatestQuote = (_quoteTimestamp < validTimestamp);
        } 

        if (_callLatestBase) {
            (_baseRoundId, _basePrice,, _baseTimestamp,) = basePriceFeed.latestRoundData();
        }
        if (_callLatestQuote) {
            (_quoteRoundId, _quotePrice,, _quoteTimestamp,) = quotePriceFeed.latestRoundData();
        }

        require(_basePrice > 0 && _quotePrice > 0, "Invalid rates");

        int256 _decimals = int256(10 ** uint256(DEFAULT_DECIMALS));
        _basePrice = _scalePrice(_basePrice, basePriceFeed.decimals(), DEFAULT_DECIMALS);
        _quotePrice = _scalePrice(_quotePrice, quotePriceFeed.decimals(), DEFAULT_DECIMALS);

        price = (uint256(_decimals) * listPrice) / uint256(_basePrice * _decimals / _quotePrice);
        roundIds = [_baseRoundId, _quoteRoundId];
    }

    function _scalePrice(int256 price, uint8 priceDecimals, uint8 decimals) private pure returns (int256) {
        if (priceDecimals < decimals) {
            return price * int256(10 ** uint256(decimals - priceDecimals));
        } else if (priceDecimals > decimals) {
            return price / int256(10 ** uint256(priceDecimals - decimals));
        }
        return price;
    }
}