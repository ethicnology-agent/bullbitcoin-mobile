import 'package:bull_pricer/src/data/datasources/pricer_cache_datasource.dart';
import 'package:bull_pricer/src/data/pricer_database.dart';
import 'package:bull_pricer/src/data/pricer_repository.dart';
import 'package:bull_pricer/src/domain/entities/bitcoin_price.dart';
import 'package:bull_pricer/src/domain/entities/price_point.dart';
import 'package:bull_pricer/src/domain/entities/supported_currency.dart';
import 'package:bull_pricer/src/domain/pricer_failure.dart';
import 'package:meta/meta.dart';
import 'package:primitives/primitives.dart';

abstract final class Pricer {
  static PricerRepository? _repository;
  static PricerDatabase? _database;

  static Future<void> init({
    required String databasePath,
    Uri? regtestEndpoint,
  }) async {
    if (regtestEndpoint != null &&
        (regtestEndpoint.scheme != 'http' ||
            !const {
              '127.0.0.1',
              '::1',
              'localhost',
            }.contains(regtestEndpoint.host) ||
            regtestEndpoint.userInfo.isNotEmpty ||
            regtestEndpoint.hasQuery ||
            regtestEndpoint.hasFragment ||
            regtestEndpoint.path.isNotEmpty && regtestEndpoint.path != '/')) {
      throw ArgumentError(
        'Regtest pricing requires an explicit loopback origin',
      );
    }
    if (_repository != null) return;

    final database = PricerDatabase.open(databasePath);
    _database = database;

    _repository = PricerRepository(
      pricerCacheDatasource: PricerCacheDatasource(database),
      regtestEndpoint: regtestEndpoint,
    );
  }

  /// Call after outstanding reads settle, before removing the owned cache.
  static Future<void> close() async {
    final database = _database;
    _repository = null;
    _database = null;
    await database?.close();
  }

  /// The approximate price of one bitcoin, the same for everyone; works
  /// without login.
  @useResult
  static Future<Result<BitcoinPrice, PricerFailure>> getIndexPrice({
    required BitcoinNetwork network,
    required SupportedCurrency currency,
  }) => _call(
    (repository) => repository.indexPrice(network: network, currency: currency),
  );

  /// The price history of a chart, oldest first: the daily prices of the
  /// last 90 days and those of the last 15 minutes, fetched and stored. When
  /// a fetch fails, the stored history is used; when one of the two is still
  /// unavailable, the other is returned alone.
  @useResult
  static Future<Result<List<PricePoint>, PricerFailure>> getPriceHistory({
    required BitcoinNetwork network,
    required SupportedCurrency currency,
  }) => _call(
    (repository) =>
        repository.priceHistory(network: network, currency: currency),
  );

  static Future<Result<T, PricerFailure>> _call<T>(
    Future<Result<T, PricerFailure>> Function(PricerRepository) action,
  ) {
    final repository = _repository;
    if (repository == null) {
      throw StateError('Pricer.init was not called');
    }
    return action(repository);
  }
}
