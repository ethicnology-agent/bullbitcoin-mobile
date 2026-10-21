import 'dart:async';

import 'package:bb_mobile/features/fund_exchange/presentation/bloc/fund_exchange_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

/// Drains both event loops while cancelling the bloc's droppable handler.
///
/// A plain close in widget-test teardown can leave fake-async continuations waiting for a pump after real subscription cancellation completes.
Future<void> closeFundExchangeBloc(
  WidgetTester tester,
  FundExchangeBloc bloc,
) async {
  var closed = false;
  unawaited(bloc.close().then((_) => closed = true));
  for (var i = 0; i < 10 && !closed; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }
  expect(closed, isTrue, reason: 'the funding bloc did not close');
}
