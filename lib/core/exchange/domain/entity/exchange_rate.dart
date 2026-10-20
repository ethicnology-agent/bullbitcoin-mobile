/// Prices of one bitcoin in the quoted fiat currency.
final class ExchangeRate {
  final String currencyCode;
  final double indexPrice;
  final double userPrice;

  ExchangeRate({
    required this.currencyCode,
    required this.indexPrice,
    required this.userPrice,
  }) {
    if (currencyCode.isEmpty) {
      throw ArgumentError.value(currencyCode, 'currencyCode');
    }
    if (!indexPrice.isFinite || indexPrice <= 0) {
      throw ArgumentError.value(indexPrice, 'indexPrice');
    }
    if (!userPrice.isFinite || userPrice <= 0) {
      throw ArgumentError.value(userPrice, 'userPrice');
    }
  }
}
