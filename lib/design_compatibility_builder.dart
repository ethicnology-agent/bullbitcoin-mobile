import 'package:bb_mobile/core/utils/build_context_x.dart';
import 'package:material_ui/material_ui.dart';

Widget buildDesignCompatibility(BuildContext context, Widget? child) {
  if (child == null) {
    return Center(child: Text(context.loc.oopsSomethingWentWrong));
  }
  // keyboard_actions still builds its overlay with Flutter Material widgets.
  // The official bridge is intentionally deprecated during this transition.
  // ignore: deprecated_member_use
  return MaterialUiCompatibilityBridge(child: child);
}
