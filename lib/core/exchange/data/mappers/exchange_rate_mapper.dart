import 'dart:math';

import 'package:bb_mobile/core/exchange/data/models/exchange_rate_model.dart';
import 'package:bb_mobile/core/exchange/domain/entity/exchange_rate.dart';

final class ExchangeRateMapper {
  static ExchangeRate toEntity(
    ExchangeRateModel model, {
    required String expectedCurrency,
  }) {
    final scale = pow(10.0, model.precision);
    final index = model.indexPrice / scale;
    final user = model.userPrice / scale;
    if ((model.currencyCode != null &&
            model.currencyCode?.toUpperCase() !=
                expectedCurrency.toUpperCase()) ||
        !index.isFinite ||
        index <= 0 ||
        !user.isFinite ||
        user <= 0) {
      throw const FormatException('Invalid exchange rate values');
    }
    return ExchangeRate(
      currencyCode: expectedCurrency.toUpperCase(),
      indexPrice: index,
      userPrice: user,
    );
  }
}
