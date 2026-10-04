import 'package:flutter_test/flutter_test.dart';
import 'package:anxin_companion/src/answer_card_models.dart';
import 'answer_card_fixtures.dart';

void main() {
  test('public payload round trips without owner provenance', () {
    final model = CardPublicPayload.fromJson(answerPayloadFixture());
    expect(model.toJson(), answerPayloadFixture());
    expect(() => model.selectedSections.add('private'), throwsUnsupportedError);
    expect(() => model.publicSources.clear(), throwsUnsupportedError);
  });
  test(
      'draft requires explicitly empty selections and retains only RAM original',
      () {
    final model = AnswerCardDraftSnapshot.fromJson(answerDraftFixture());
    expect(model.sourceMessageId, 'message-1');
    expect(model.sections.length, 2);
    for (final key in ['selected_sections', 'selected_source_ids']) {
      expect(
          () => AnswerCardDraftSnapshot.fromJson(
              answerDraftFixture()..remove(key)),
          throwsFormatException);
      expect(
          () => AnswerCardDraftSnapshot.fromJson(
              answerDraftFixture()..[key] = ['secret']),
          throwsFormatException);
    }
  });
  test('all response objects reject unknown private fields and missing fields',
      () {
    final cases =
        <MapEntry<Map<String, dynamic>, void Function(Map<String, dynamic>)>>[
      MapEntry(answerPayloadFixture(), CardPublicPayload.fromJson),
      MapEntry(answerSourceFixture(), AnswerCardSource.fromJson),
      MapEntry(answerDraftFixture(), AnswerCardDraftSnapshot.fromJson),
      MapEntry(answerTemplateFixture(), AnswerCardTemplate.fromJson),
      MapEntry(answerCardFixture(), OwnedAnswerCard.fromJson),
    ];
    for (final entry in cases) {
      expect(() => entry.value(cloneAnswer(entry.key)..['memory_sources'] = []),
          throwsFormatException);
      for (final key in entry.key.keys.where((k) => ![
            'reviewed_at',
            'retrieved_at',
            'effective_date',
            'content_hash'
          ].contains(k))) {
        expect(() => entry.value(cloneAnswer(entry.key)..remove(key)),
            throwsFormatException,
            reason: key);
      }
    }
  });
  test('versions hashes mode verification and required types fail closed', () {
    for (final version in [true, '1', null, 0, -1, 1.0]) {
      expect(
          () => OwnedAnswerCard.fromJson(
              answerCardFixture()..['version'] = version),
          throwsFormatException);
    }
    for (final hash in ['short', answerHash.toUpperCase(), null]) {
      expect(
          () => OwnedAnswerCard.fromJson(
              answerCardFixture()..['public_payload_hash'] = hash),
          throwsFormatException);
    }
    expect(
        () =>
            OwnedAnswerCard.fromJson(answerCardFixture()..['mode'] = 'future'),
        throwsFormatException);
    expect(
        () => CardPublicPayload.fromJson(
            answerPayloadFixture()..['verification_state'] = 'verified'),
        throwsFormatException);
    expect(
        () => CardPublicPayload.fromJson(
            answerPayloadFixture()..['next_steps'] = [true]),
        throwsFormatException);
  });
  test('nested provenance is closed and deeply immutable', () {
    final card = OwnedAnswerCard.fromJson(answerCardFixture());
    expect(() => card.provenance['origin_hash'] = 'changed',
        throwsUnsupportedError);
    expect(
        () => (card.provenance['selected_original_excerpts'] as List).clear(),
        throwsUnsupportedError);
    expect(
        () => ((card.provenance['selected_original_excerpts'] as List).first
            as Map)['edited'] = true,
        throwsUnsupportedError);
    final raw = answerCardFixture();
    (raw['provenance'] as Map)['original_text'] = 'private';
    expect(() => OwnedAnswerCard.fromJson(raw), throwsFormatException);
    final nested = answerCardFixture();
    ((nested['provenance'] as Map)['selected_original_excerpts'] as List)
        .first['text'] = 'private';
    expect(() => OwnedAnswerCard.fromJson(nested), throwsFormatException);
  });
  test('source URL approved origin dates and personal parameters rejected', () {
    for (final url in [
      'http://www.swd.gov.hk/a',
      'https://www.swd.gov.hk/a?token=secret',
      'https://user:pass@www.swd.gov.hk/a',
      'https://www.swd.gov.hk:443/a',
      'https://www.swd.gov.hk/a#fragment',
      'https://example.com/a',
      'javascript:alert(1)'
    ]) {
      expect(
          () => AnswerCardSource.fromJson(answerSourceFixture()..['url'] = url),
          throwsFormatException);
    }
    expect(
        AnswerCardSource.fromJson(answerSourceFixture()
              ..['url'] =
                  'https://portal.csdi.gov.hk/a?datasetId=swd_rcd_1696994103126_1549')
            .sourceId,
        'swd-1');
    expect(
        () => AnswerCardSource.fromJson(
            answerSourceFixture()..['reviewed_at'] = '2026-02-30'),
        throwsFormatException);
  });
  test('source accepts canonical reviewed resource hosts alongside templates',
      () {
    for (final url in [
      'https://www.cheu.gov.hk/',
      'https://www.elderly.gov.hk/english/health/health_centres.html',
      'https://www.hkab.org.hk/zh-hk/rehabus',
      'https://www.mtr.com.hk/ch/customer/main/jp.html',
      'https://www.td.gov.hk/tc/transport_in_hong_kong/public_transport/bus/',
    ]) {
      expect(
          AnswerCardSource.fromJson(answerSourceFixture()..['url'] = url).url,
          url);
    }
  });
  test('source accepts only exact reviewed HA query URL', () {
    const url =
        'https://www.ha.org.hk/visitors/ha_visitor_guide.asp?Content_ID=100826';
    expect(AnswerCardSource.fromJson(answerSourceFixture()..['url'] = url).url,
        url);
  });
  test(
      'reviewed resource query exception cannot carry personal or redirected parameters',
      () {
    for (final url in [
      'https://www.ha.org.hk/other?Content_ID=100826',
      'https://www.ha.org.hk/visitors/ha_visitor_guide.asp?Content_ID=100827',
      'https://www.ha.org.hk/visitors/ha_visitor_guide.asp?content_id=100826',
      'https://www.ha.org.hk/visitors/ha_visitor_guide.asp?Content_ID=100826&token=secret',
      'https://www.ha.org.hk/visitors/ha_visitor_guide.asp?Content_ID=100826&redirect=https://example.com',
      'https://www.ha.org.hk/visitors/ha_visitor_guide.asp?Content_ID=100826#private',
      'https://www.ha.org.hk:443/visitors/ha_visitor_guide.asp?Content_ID=100826',
      'https://www.mtr.com.hk/ch/customer/main/jp.html?token=secret',
      'https://www.mtr.com.hk:443/ch/customer/main/jp.html',
      'https://www.mtr.com.hk.evil.example/ch/customer/main/jp.html',
    ]) {
      expect(
          () => AnswerCardSource.fromJson(answerSourceFixture()..['url'] = url),
          throwsFormatException,
          reason: url);
    }
  });
  test('display sizes rejected instead of truncated', () {
    expect(
        () => CardPublicPayload.fromJson(
            answerPayloadFixture()..['title'] = 'x' * 241),
        throwsFormatException);
    expect(
        () => CardPublicPayload.fromJson(
            answerPayloadFixture()..['selected_sections'] = ['x' * 4001]),
        throwsFormatException);
    expect(
        () => CardPublicPayload.fromJson(answerPayloadFixture()
          ..['selected_sections'] = List.filled(5, 'x' * 4000)),
        throwsFormatException);
    expect(
        () => CardPublicPayload.fromJson(
            answerPayloadFixture()..['next_steps'] = List.filled(11, 'x')),
        throwsFormatException);
    expect(
        () => CardPublicPayload.fromJson(
            answerPayloadFixture()..['selected_sections'] = []),
        throwsFormatException);
  });
  test('delete receipt requires positive version and literal true', () {
    expect(
        AnswerCardDeleteReceipt.fromJson(
            {'id': 'card-1', 'version': 2, 'deleted': true}).deleted,
        isTrue);
    for (final value in [false, 'true', null]) {
      expect(
          () => AnswerCardDeleteReceipt.fromJson(
              {'id': 'card-1', 'version': 2, 'deleted': value}),
          throwsFormatException);
    }
  });
}
