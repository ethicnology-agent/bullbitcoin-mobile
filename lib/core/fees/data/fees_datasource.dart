import 'dart:convert';
import 'dart:io';

import 'package:bb_mobile/core/errors/bull_exception.dart';
import 'package:bb_mobile/core/fees/data/models/mempool_fees_model.dart';
import 'package:bb_mobile/core/mempool/application/usecases/get_active_mempool_server_usecase.dart';
import 'package:bb_mobile/core/mempool/domain/repositories/mempool_settings_repository.dart';
import 'package:bb_mobile/core/mempool/domain/value_objects/mempool_server_network.dart';
import 'package:bb_mobile/core/settings/data/settings_repository.dart';
import 'package:bb_mobile/core/utils/constants.dart';
import 'package:bull_tor/tor.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';

class FeesDatasource {
  final GetActiveMempoolServerUsecase _getActiveMempoolServerUsecase;
  final MempoolSettingsRepository _mempoolSettingsRepository;
  final SettingsRepository? _settingsRepository;
  final TorHttpClientFactory _torHttpClientFactory;

  /// Builds the HTTP client for a resolved base URL. Injected so tests can
  /// supply a mock; defaults to a real Dio. The base URL is only known at
  /// call time (custom server vs BB, mainnet vs testnet), so this is a
  /// builder rather than a pre-built client.
  final Dio Function(String baseUrl, bool validateDomain) _dioBuilder;

  FeesDatasource({
    required this._getActiveMempoolServerUsecase,
    required this._mempoolSettingsRepository,
    this._settingsRepository,
    this._torHttpClientFactory = const TorHttpClientFactory(),
    Dio Function(String baseUrl, bool validateDomain)? dioBuilder,
  }) : _dioBuilder = dioBuilder ?? _defaultDioBuilder;

  static Dio _defaultDioBuilder(String baseUrl, bool validateDomain) {
    final http = Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 10),
        sendTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        followRedirects: false,
        validateStatus: (status) => status == 200,
      ),
    );
    if (!validateDomain) {
      (http.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () =>
          HttpClient()..badCertificateCallback = (_, _, _) => true;
    }
    return http;
  }

  Future<Dio> _buildHttp(String baseUrl, {required bool validateDomain}) async {
    final http = _dioBuilder(baseUrl, validateDomain);
    final settings = _settingsRepository == null
        ? null
        : await _settingsRepository.fetch();
    if (settings?.useTorProxy == true) {
      final proxyPort = settings!.torProxyPort;
      final adapter = IOHttpClientAdapter(
        createHttpClient: () => _torHttpClientFactory.create(
          TorProxyEndpoint(
            host: InternetAddress.loopbackIPv4.address,
            port: proxyPort,
          ),
          allowBadCertificate: !validateDomain,
        ),
      );
      http.httpClientAdapter = adapter;
    }
    return http;
  }

  /// Fetches precise (sub-1 sat/vByte) fee rates from the mempool API.
  ///
  /// Tries `/api/v1/fees/precise` first. If it fails for any reason — a
  /// server too old to expose it (404), a transient error, or a malformed
  /// body — falls back to the rounded `/api/v1/fees/recommended` so a
  /// custom/self-hosted mempool keeps working. Both endpoints return the
  /// same JSON shape, so the same model parses either. Throws only when
  /// neither endpoint yields a usable response.
  Future<MempoolFeesModel> fetchBitcoinNetworkFees({
    required bool isTestnet,
  }) async {
    final network = MempoolServerNetwork.fromEnvironment(
      isTestnet: isTestnet,
      isLiquid: false,
    );
    final settings = (await _mempoolSettingsRepository.fetchByNetwork(network))
        .fold(
          (value) => value,
          (_) => throw Exception('Failed to fetch mempool settings'),
        );

    // Determine which mempool server to use.
    String baseUrl;
    var validateDomain = true;
    if (settings.useForFeeEstimation) {
      // Use custom or default mempool server from settings
      final server =
          (await _getActiveMempoolServerUsecase.execute(
            isTestnet: isTestnet,
            isLiquid: false,
          )).fold(
            (s) => s,
            (_) => throw Exception('Failed to fetch active mempool server'),
          );
      baseUrl = server.fullUrl;
      validateDomain = server.validateDomain;
    } else {
      // Fall back to BB's mempool.
      baseUrl = isTestnet
          ? 'https://${ApiServiceConstants.testnetMempoolUrlPath}'
          : 'https://${ApiServiceConstants.bbMempoolUrlPath}';
    }

    final http = await _buildHttp(baseUrl, validateDomain: validateDomain);

    final fees =
        await _getFees(http, ApiServiceConstants.mempoolPreciseFeesPath) ??
        await _getFees(http, ApiServiceConstants.mempoolRecommendedFeesPath);
    if (fees == null) {
      throw MempoolFeesException('No mempool fee endpoint available');
    }

    return fees;
  }

  /// GETs a fee endpoint and parses it. Returns the model on a 200 with a
  /// well-formed body, or `null` on any failure — non-200, network/Dio
  /// error, non-object body, or a 200 whose body is missing or has a
  /// non-numeric fee field — so the caller can fall back to the next path.
  /// Parsing happens here (not at the call site) so a malformed-but-200
  /// precise response falls back to recommended instead of throwing.
  Future<MempoolFeesModel?> _getFees(Dio http, String path) async {
    try {
      final resp = await http.get<dynamic>(path);
      if (resp.statusCode != 200) return null;
      var data = resp.data;
      // Dio only auto-decodes when the server sends a JSON content-type. A
      // working-but-misconfigured self-hosted mempool returning the body as
      // text/plain would otherwise silently drop precise → recommended,
      // losing the sub-1 sat/vByte rates this whole path exists for. Decode
      // a string body before the Map check; a non-JSON string throws and is
      // caught below (→ fallback).
      if (data is String && data.isNotEmpty) {
        data = jsonDecode(data);
      }
      if (data is Map<String, dynamic>) {
        return MempoolFeesModel.fromJson(data);
      }
      return null;
    } on DioException {
      return null;
    } catch (_) {
      // A 200 with a malformed/partial body — `fromJson` throws on a missing
      // or non-numeric fee field. Fall back rather than failing the fetch.
      return null;
    }
  }
}

class MempoolFeesException extends BullException {
  MempoolFeesException(super.message);
}
