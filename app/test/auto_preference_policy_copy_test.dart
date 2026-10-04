import 'package:anxin_companion/src/app.dart';
import 'package:anxin_companion/src/localization.dart';
import 'package:anxin_companion/src/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'memory_controls_widget_test.dart' as controls;

void main() {
  for (final locale in [englishLocale, traditionalChineseLocale]) {
    final en = locale == englishLocale;
    testWidgets('opt-in ordinary preference exception is clear in $locale', (t) async {
      final f = controls.Fixture();
      await controls.mount(t, f.controller, locale: locale);
      expect(find.textContaining(en ? 'without saving each one' : '無需逐項按保存'), findsOneWidget);
      expect(find.textContaining(en ? 'Sensitive, uncertain and other details' : '敏感、不確定及其他內容'), findsOneWidget);
      expect(find.textContaining(en ? 'Sharing with family still needs your explicit confirmation' : '分享給家人仍須你明確確認'), findsOneWidget);
      expect(find.text(en ? 'Turn memory on' : '開啟記憶'), findsOneWidget);
      expect(f.writes, isEmpty);
    });
    testWidgets('auto-saved receipt offers pause without requiring another Save in $locale', (t) async {
      final f = controls.Fixture()..enabled = true;
      f.controller.memoryConsentEnabled = true;
      final message = ChatMessage(id: 'auto', conversationId: 'c', body: 'Synthetic response',
          isFromUser: false, createdAt: null, metadata: const {'auto_saved_memory': {
            'id': 'm', 'content': 'I enjoy gardening.', 'kind': 'preference',
            'status': 'confirmed', 'capture_method': 'agent_auto'}});
      await controls.mount(t, f.controller, locale: locale,
          home: Scaffold(body: MessageBubble(message: message)));
      expect(find.textContaining(en ? 'View, edit, pause or delete it' : '查看、修改、暫停或刪除'), findsOneWidget);
      expect(find.text(en ? 'Edit and save' : '修改並保存'), findsNothing);
      expect(f.writes, isEmpty);
    });
    testWidgets('sensitive manual draft stays unsaved on Cancel in $locale', (t) async {
      final f = controls.Fixture()..enabled = true;
      f.controller.memoryConsentEnabled = true;
      final message = ChatMessage(id: 'manual', conversationId: 'c', body: 'Synthetic response',
          isFromUser: false, createdAt: null, metadata: const {'memory_suggestion': {
            'content': 'I have diabetes.', 'kind': 'fact', 'source_message_id': 'source',
            'sensitivity': 'sensitive', 'requires_confirmation': true}});
      await controls.mount(t, f.controller, locale: locale,
          home: Scaffold(body: MessageBubble(message: message)));
      await t.tap(find.text(en ? 'Edit and save' : '修改並保存'));
      await t.pumpAndSettle();
      expect(find.textContaining(en ? 'This manual draft is not saved to Memory until you choose Save' : '這份手動草稿在你按保存前不會寫入記憶'), findsOneWidget);
      await t.tap(find.text(en ? 'Cancel' : '取消'));
      await t.pumpAndSettle();
      expect(f.writes, isEmpty);
    });
  }
}
