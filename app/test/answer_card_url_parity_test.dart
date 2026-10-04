import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:anxin_companion/src/answer_card_models.dart';

void main() {
  final corpus = jsonDecode(
          File('test/fixtures/answer_card_url_parity.json').readAsStringSync())
      as Map<String, dynamic>;
  for (final vector in corpus['vectors'] as List) {
    final m = vector as Map<String, dynamic>;
    test('paired canonical URL policy ${m['id']}', () {
      final input = <String, Object?>{
        'source_id': 'synthetic-url',
        'organisation': 'Synthetic public authority',
        'title': 'Synthetic public guidance',
        'url': m['url'],
        'reviewed_at': null,
        'retrieved_at': null,
        'effective_date': null,
        'verification_scope': 'Synthetic public fixture only',
        'content_hash': null
      };
      if (m['allowed'] == true) {
        expect(AnswerCardSource.fromJson(input).url, m['url']);
      } else {
        expect(() => AnswerCardSource.fromJson(input), throwsFormatException);
      }
    });
  }
}
