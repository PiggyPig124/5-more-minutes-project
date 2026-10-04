import 'dart:convert';

const answerHash =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
Map<String, dynamic> answerSourceFixture() => {
      'source_id': 'swd-1',
      'organisation': 'SWD',
      'title': 'Guidance',
      'url': 'https://www.swd.gov.hk/example',
      'reviewed_at': '2026-10-03',
      'retrieved_at': null,
      'effective_date': null,
      'verification_scope': 'Public guidance only',
      'content_hash': answerHash
    };
Map<String, dynamic> answerPayloadFixture() => {
      'title': 'Guidance',
      'selected_sections': ['Selected public text 👋'],
      'official_terms': <String>[],
      'missing_information': <String>[],
      'next_steps': ['Ask the service'],
      'public_sources': [answerSourceFixture()],
      'verification_state': 'ai_unverified',
      'verification_scope': 'AI answer not verified'
    };
Map<String, dynamic> answerDraftFixture() => {
      'source_message_id': 'message-1',
      'source_hash': answerHash,
      'original_text': 'Selected public text 👋\n\nSynthetic private text',
      'sections': [
        {'id': '$answerHash:0', 'text': 'Selected public text 👋'},
        {'id': '$answerHash:1', 'text': 'Synthetic private text'}
      ],
      'public_sources': [answerSourceFixture()],
      'selected_sections': <String>[],
      'selected_source_ids': <String>[]
    };
Map<String, dynamic> answerCardFixture() => {
      'id': 'card-1',
      'mode': 'assistant_answer',
      'version': 1,
      'public_payload': answerPayloadFixture(),
      'public_payload_hash': answerHash,
      'provenance': {
        'origin_message_id': 'message-1',
        'origin_hash': answerHash,
        'template_id': null,
        'template_version': null,
        'template_hash': null,
        'selected_original_excerpts': [
          {'id': '$answerHash:0', 'hash': answerHash, 'edited': false}
        ]
      },
      'created_at': '2026-10-04T00:00:00Z',
      'updated_at': '2026-10-04T00:00:00Z'
    };
Map<String, dynamic> answerTemplateFixture() => {
      'template_id': 'template-1',
      'template_version': 1,
      'template_hash': answerHash,
      'language': 'zh',
      'sections': [
        {'id': 'section-1', 'text': 'Selected public text 👋'}
      ],
      'public_payload': answerPayloadFixture()
        ..['verification_state'] = 'reviewed_public_guidance'
    };
Map<String, dynamic> answerCreateFixture() => {
      'origin': {'message_id': 'message-1', 'source_hash': answerHash},
      'selected_sections': [
        {'id': '$answerHash:0', 'edited_text': 'Redacted text'}
      ],
      'title': 'Guidance',
      'selected_source_ids': ['swd-1'],
      'client_operation_id': 'operation-1'
    };
Map<String, dynamic> answerUpdateFixture() => {
      'title': 'Edited guidance',
      'selected_sections': ['Redacted text'],
      'official_terms': <String>[],
      'missing_information': <String>[],
      'next_steps': <String>[],
      'selected_source_ids': ['swd-1'],
      'expected_version': 1,
      'client_operation_id': 'operation-2'
    };
Map<String, dynamic> cloneAnswer(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
