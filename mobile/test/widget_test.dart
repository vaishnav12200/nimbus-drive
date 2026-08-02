import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nimbus_drive/core/theme/app_colors.dart';
import 'package:nimbus_drive/core/theme/app_theme.dart';
import 'package:nimbus_drive/main.dart';

void main() {
  testWidgets('app boots into the showcase', (tester) async {
    await tester.pumpWidget(const NimbusApp());
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Nimbus'), findsOneWidget);
    expect(find.text('48.2'), findsOneWidget);
  });

  testWidgets('theme exposes Nimbus tokens', (tester) async {
    late NimbusTokens tokens;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Builder(
          builder: (context) {
            tokens = context.tokens;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(tokens.canvas, AppColors.canvas);
    expect(tokens.accents, hasLength(6));
  });

  test('every file type maps to a distinct accent', () {
    const tokens = NimbusTokens.dark;
    const types = ['image', 'video', 'document', 'audio', 'archive', 'other'];

    final assigned = types.map(tokens.accentForType).toSet();

    expect(assigned, hasLength(types.length));
    // An unknown type must fall through rather than throw — the server can add
    // a type before the client is rebuilt.
    expect(tokens.accentForType('model/gltf'), tokens.accentForType('other'));
  });
}
