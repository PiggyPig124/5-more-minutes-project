import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('asset bundle supplies CanvasKit default and Traditional Chinese fonts',
      () async {
    final manifest = (jsonDecode(await rootBundle.loadString('FontManifest.json'))
            as List<dynamic>)
        .cast<Map<String, dynamic>>();
    for (final family in ['Roboto', 'NotoSansTC']) {
      final entries = manifest.where((entry) => entry['family'] == family);
      expect(entries, isNotEmpty,
          reason: '$family must be available before external fonts are fetched');
      for (final font in entries.single['fonts'] as List<dynamic>) {
        final bytes = await rootBundle.load(font['asset'] as String);
        expect(bytes.lengthInBytes, greaterThan(0));
        // Both bundled upstream files are TrueType, not HTML download errors.
        expect(bytes.getUint32(0), 0x00010000);
      }
    }
  });

  test('font redistribution licenses ship in the asset bundle', () async {
    expect(await rootBundle.loadString('assets/fonts/Roboto-LICENSE.txt'),
        contains('Apache License'));
    expect(await rootBundle.loadString('assets/fonts/NotoSansTC-OFL.txt'),
        contains('SIL OPEN FONT LICENSE Version 1.1'));
  });
}
