import 'package:anxin_companion/src/speech_input.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('prefers a Hong Kong Cantonese locale', () {
    expect(
      selectCantoneseLocaleId(['zh-TW', 'yue-HK', 'zh-HK'], isWeb: false),
      'yue-HK',
    );
    expect(
      selectCantoneseLocaleId(['zh-HK', 'yue-HK'], isWeb: false),
      'yue-HK',
    );
    expect(selectCantoneseLocaleId(['zh_TW', 'zh-HK'], isWeb: false), 'zh-HK');
  });

  test('falls back to an available Chinese locale', () {
    expect(
      selectCantoneseLocaleId(['en-US', 'zh-CN'], isWeb: false),
      'zh-CN',
    );
  });

  test('uses Hong Kong Chinese on web when no locales are exposed', () {
    expect(
      selectCantoneseLocaleId(const [], isWeb: true),
      webCantoneseLocaleId,
    );
  });

  test('does not silently use an unrelated native language', () {
    expect(selectCantoneseLocaleId(['en-US', 'fr-FR'], isWeb: false), isNull);
  });

  test('uses a discovered English locale when one is available', () {
    expect(
      selectEnglishLocaleId(['fr-FR', 'en-GB'], isWeb: false),
      'en-GB',
    );
  });

  test('uses en-US for an explicitly requested English locale on web', () {
    expect(selectEnglishLocaleId(const [], isWeb: true), 'en-US');
  });

  test('keeps native locale validation strict', () {
    expect(selectEnglishLocaleId(['fr-FR'], isWeb: false), isNull);
  });

  test('uses en-US on web when only non-English locales are exposed', () {
    expect(selectEnglishLocaleId(['fr-FR'], isWeb: true), 'en-US');
  });
}
