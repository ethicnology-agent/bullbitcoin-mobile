import 'package:bull_ui/bull_ui.dart' show BullInputText;
import 'package:bull_ui_catalogue/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widgetbook/widgetbook.dart';

void main() {
  testWidgets('Catalogue builds', (tester) async {
    await tester.pumpWidget(const BullUiCatalogue());
    expect(find.byType(BullUiCatalogue), findsOneWidget);
  });

  testWidgets('Input use case has standalone Material localizations', (
    tester,
  ) async {
    await tester.pumpWidget(const BullUiCatalogue());
    final configuration = tester.widget<Widgetbook>(find.byType(Widgetbook));

    await tester.pumpWidget(
      Widgetbook.material(
        initialRoute: '/?path=inputs/bullinputtext/default&preview',
        directories: configuration.directories,
        appBuilder: configuration.appBuilder,
        addons: configuration.addons,
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(BullInputText), findsOneWidget);
  });
}
