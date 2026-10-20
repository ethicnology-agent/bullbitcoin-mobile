import 'package:freezed_annotation/freezed_annotation.dart';

part 'exchange_rate_model.freezed.dart';

@freezed
sealed class ExchangeRateModel with _$ExchangeRateModel {
  const factory ExchangeRateModel({
    String? currencyCode,
    required num indexPrice,
    required num userPrice,
    required int precision,
  }) = _ExchangeRateModel;

  static ExchangeRateModel fromJson(Map<String, dynamic> json) {
    final currency = json['fromCurrency'];
    final index = json['indexPrice'];
    final user = json['userPrice'];
    final precision = json['precision'] ?? 2;
    if ((currency != null && (currency is! String || currency.isEmpty)) ||
        index is! num ||
        user is! num ||
        precision is! int ||
        precision < 0) {
      throw const FormatException('Invalid exchange rate response');
    }
    return ExchangeRateModel(
      currencyCode: currency,
      indexPrice: index,
      userPrice: user,
      precision: precision,
    );
  }
}
