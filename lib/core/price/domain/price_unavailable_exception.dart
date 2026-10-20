import 'package:bb_mobile/core/errors/bull_exception.dart';
import 'package:bb_mobile/core/price/domain/price_failure.dart';

/// Thrown by the legacy conversion use cases when the price repository
/// returns an [Err], so their throwing signatures stay intact while the
/// repository already speaks `Result` (staged migration, #1895).
///
/// Carries the typed [failure] for the feature boundaries that catch it.
/// Consumers migrated to `Result` will read the repository failure directly
/// and never see this.
class PriceUnavailableException extends BullException {
  final PriceFailure failure;

  PriceUnavailableException(this.failure)
    : super(failure.logMessage ?? 'Price unavailable: ${failure.runtimeType}');
}
