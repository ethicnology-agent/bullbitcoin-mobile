import 'package:bb_mobile/core/electrum/application/dtos/requests/add_custom_server_request.dart';
import 'package:bb_mobile/core/electrum/domain/entities/electrum_server.dart';
import 'package:bb_mobile/core/electrum/domain/entities/electrum_settings.dart';
import 'package:bb_mobile/core/electrum/domain/errors/electrum_failure.dart';
import 'package:bb_mobile/core/electrum/domain/ports/electrum_tor_session_port.dart';
import 'package:bb_mobile/core/electrum/domain/ports/server_status_port.dart';
import 'package:bb_mobile/core/electrum/domain/repositories/electrum_server_repository.dart';
import 'package:bb_mobile/core/electrum/domain/repositories/electrum_settings_repository.dart';
import 'package:bb_mobile/core/electrum/domain/value_objects/electrum_server_status.dart';
import 'package:bb_mobile/core/settings/domain/repositories/settings_repository.dart';
import 'package:bb_mobile/core/utils/logger.dart';
import 'package:bb_mobile/core/utils/result.dart';
import 'package:meta/meta.dart';

class AddCustomServerUsecase {
  final ElectrumServerRepository _electrumServerRepository;
  final ElectrumSettingsRepository _electrumSettingsRepository;
  final ServerStatusPort _serverStatusPort;
  final SettingsRepository _settingsRepository;
  final ElectrumTorSessionPort _torSessionPort;

  AddCustomServerUsecase({
    required this._electrumServerRepository,
    required this._electrumSettingsRepository,
    required this._serverStatusPort,
    required this._settingsRepository,
    required this._torSessionPort,
  });

  @useResult
  Future<Result<ElectrumServerStatus, ElectrumFailure>> execute(
    AddCustomServerRequest request,
  ) async {
    try {
      final server = ElectrumServer.createCustom(
        host: request.host,
        port: request.port,
        network: request.network,
        priority: request.priority,
        enableSsl: request.enableSsl,
      );

      final ElectrumServer? existingServer;
      switch (await _electrumServerRepository.fetchByUrl(server.url)) {
        case Ok(:final value):
          existingServer = value;
        case Err(:final failure):
          return Err(failure);
      }
      if (existingServer != null) {
        return const Err(ElectrumServerAlreadyExistsFailure());
      }

      // Fetch app settings to get Tor configuration
      final appSettings = await _settingsRepository.fetch();
      final route = await _torSessionPort.open(
        network: server.network,
        serverUrl: server.url,
        externalProxyEnabled: appSettings.useTorProxy,
        externalProxyPort: appSettings.torProxyPort,
      );
      try {
        // Step 1: verify the TCP/SSL socket is reachable.
        final socketStatus = await _serverStatusPort.checkSocket(
          url: server.url,
          proxyEndpoint: route?.endpoint,
        );
        if (socketStatus == ElectrumServerStatus.offline) {
          return const Err(ElectrumServerUnreachableFailure());
        }

        // Step 2: verify the server actually serves chain data by fetching a
        // known historical tx (falls back to server.version on testnets).
        final protocolStatus = await _serverStatusPort.checkElectrum(
          url: server.url,
          network: server.network,
          // Custom servers commonly use locally trusted certificates. Once
          // saved, the active custom-server tier uses the same relaxed policy.
          validateDomain: false,
          proxyEndpoint: route?.endpoint,
        );
        if (protocolStatus == ElectrumServerStatus.offline) {
          return const Err(ElectrumServerUnreachableFailure());
        }
      } finally {
        await route?.close();
      }

      final ElectrumSettings electrumSettings;
      switch (await _electrumSettingsRepository.fetchByNetwork(
        server.network,
      )) {
        case Ok(:final value):
          electrumSettings = value;
        case Err(:final failure):
          return Err(failure);
      }

      // A custom server is usable only after both it and the relaxed policy
      // used by the probe have been persisted.
      switch (await _electrumServerRepository.save(server)) {
        case Ok():
          break;
        case Err(:final failure):
          return Err(failure);
      }

      if (electrumSettings.validateDomain) {
        electrumSettings.update(newValidateDomain: false);
        switch (await _electrumSettingsRepository.save(electrumSettings)) {
          case Ok():
            break;
          case Err(:final failure):
            final rollback = await _electrumServerRepository.delete(
              url: server.url,
            );
            if (rollback case Err(:final failure)) {
              log.severe(
                message: 'Failed to roll back custom electrum server',
                error: failure,
                trace: StackTrace.current,
              );
            }
            return Err(failure);
        }
      }

      return const Ok(ElectrumServerStatus.online);
    } catch (e, st) {
      log.severe(
        message: 'Failed to add custom electrum server',
        error: e,
        trace: st,
      );
      return Err(ElectrumUnexpectedFailure(e.toString()));
    }
  }
}
