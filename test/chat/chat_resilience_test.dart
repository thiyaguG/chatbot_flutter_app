import 'dart:async';
import 'dart:convert';

import 'package:digisol_support/api/models.dart';
import 'package:digisol_support/chat/chat_controller.dart';
import 'package:digisol_support/chat/chat_state.dart';
import 'package:digisol_support/chat/chat_store.dart';
import 'package:digisol_support/chat/connectivity.dart';
import 'package:digisol_support/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_chat_api.dart';

void main() {
  late FakeChatApi api;
  late MemoryStore disk;
  late StreamController<bool> online;

  setUp(() {
    api = FakeChatApi();
    disk = MemoryStore();
    online = StreamController<bool>.broadcast();
    addTearDown(online.close);
  });

  /// A fresh app process sharing the same [disk].
  ProviderContainer launch() {
    final container = ProviderContainer(
      overrides: [
        chatApiProvider.overrideWithValue(api),
        keyValueStoreProvider.overrideWithValue(disk),
        onlineProvider.overrideWith((ref) => online.stream),
      ],
    );
    addTearDown(container.dispose);
    container.listen(chatControllerProvider, (_, _) {});
    return container;
  }

  Future<void> settle(ProviderContainer c) async {
    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(Duration.zero);
      if (!c.read(chatControllerProvider).busy) return;
    }
    fail('controller stayed busy');
  }

  group('saved conversation', () {
    test('is restored after a restart without contacting the server', () async {
      api.reply(menuReply);
      final first = launch();
      await settle(first);
      api.reply(const [CompleteEvent('Two years.'), DoneEvent()]);
      await first.read(chatControllerProvider.notifier).sendText('warranty?');
      final sentBefore = api.requests.length;
      first.dispose();

      final second = launch();
      final state = second.read(chatControllerProvider);

      expect(state.busy, isFalse);
      expect(state.conversationId, 'conv-1');
      expect(state.messages.map((m) => m.text), [
        'Welcome!',
        'Pick a category:',
        'warranty?',
        'Two years.',
      ]);
      expect(state.messages[2].role, ChatRole.user);
      await settle(second);
      expect(api.requests, hasLength(sentBefore), reason: 'no new init');
    });

    test('restores pending option buttons and continues the same '
        'conversation', () async {
      api.reply(menuReply);
      final first = launch();
      await settle(first);
      first.dispose();

      final second = launch();
      final options = second.read(chatControllerProvider).messages.last.options;
      expect(options.map((o) => o.label), ['Product Enquiry', 'Warranty']);

      api.reply(const [CompleteEvent('Model number?'), DoneEvent()]);
      await second
          .read(chatControllerProvider.notifier)
          .chooseOption(options.last);

      expect(api.conversationIds.last, 'conv-1');
      // Ids keep counting up, so restored and new messages never collide.
      final ids = second
          .read(chatControllerProvider)
          .messages
          .map((m) => m.id)
          .toList();
      expect(ids.toSet(), hasLength(ids.length));
    });

    test('older than a day is discarded and a new chat starts', () async {
      disk.write(
        ChatStore.chatKey,
        jsonEncode({
          'saved_at': DateTime.now()
              .subtract(const Duration(hours: 25))
              .toIso8601String(),
          'conversation_id': 'old',
          'messages': [
            {'id': 0, 'role': 'bot', 'text': 'stale'},
          ],
        }),
      );
      api.reply(menuReply);

      final c = launch();
      await settle(c);

      final state = c.read(chatControllerProvider);
      expect(state.messages.first.text, 'Welcome!');
      expect(state.conversationId, 'conv-1');
      expect(api.conversationIds, [null]);
    });

    test('corrupt saved data is ignored', () async {
      disk.write(ChatStore.chatKey, '{not json');
      disk.write(ChatStore.uiKey, '[]');
      api.reply(menuReply);

      final c = launch();
      await settle(c);

      expect(c.read(chatControllerProvider).messages, hasLength(2));
    });

    test('new chat wipes the saved transcript', () async {
      api.reply(menuReply);
      final first = launch();
      await settle(first);
      api.reply(const [CompleteEvent('secret answer'), DoneEvent()]);
      await first.read(chatControllerProvider.notifier).sendText('hello');
      api.reply(menuReply);
      await first.read(chatControllerProvider.notifier).newChat();
      first.dispose();

      final texts = launch()
          .read(chatControllerProvider)
          .messages
          .map((m) => m.text);
      expect(texts, ['Welcome!', 'Pick a category:']);
    });
  });

  test(
    'branding is cached, so the next launch is themed while offline',
    () async {
      api.reply(menuReply);
      final first = launch();
      await settle(first);
      first.dispose();

      api.ui = null; // server unreachable for config
      disk.remove(ChatStore.chatKey);
      final second = launch();

      expect(second.read(chatControllerProvider).ui.title, 'Test Support');
      await settle(second);
      expect(second.read(chatControllerProvider).ui.title, 'Test Support');
    },
  );

  test('TenantUiConfig survives a save/load round trip', () {
    const ui = TenantUiConfig(
      title: 'T',
      subtitle: 'S',
      primaryColor: Color(0xFF0A0B0C),
      welcomeMessage: 'W',
      inputPlaceholder: 'P',
      quickQuestions: [QuickQuestion(label: 'L', text: 'X')],
      hasGuidedFlow: false,
      hasFeedbackFlow: true,
    );
    final back = TenantUiConfig.fromJson(
      jsonDecode(jsonEncode(ui.toJson())) as Map<String, dynamic>,
    );

    expect(back.title, 'T');
    expect(back.subtitle, 'S');
    expect(back.primaryColor, const Color(0xFF0A0B0C));
    expect(back.quickQuestions.single.text, 'X');
    expect(back.hasGuidedFlow, isFalse);
    expect(back.hasFeedbackFlow, isTrue);
  });

  group('retry', () {
    test('a request that never reached the server can be retried', () async {
      api.reply(menuReply);
      final c = launch();
      await settle(c);
      final controller = c.read(chatControllerProvider.notifier);

      await controller.sendText('hello'); // no scripted reply → fails
      var state = c.read(chatControllerProvider);
      expect(state.messages.last.isError, isTrue);
      expect(state.retryRequest, isNotNull);

      api.reply(const [CompleteEvent('Hi!'), DoneEvent()]);
      await controller.retry();
      state = c.read(chatControllerProvider);

      expect(api.requests.sublist(1), [
        {'question': 'hello'},
        {'question': 'hello'},
      ]);
      expect(state.retryRequest, isNull);
      expect(
        state.messages.map((m) => m.text).toList().sublist(2),
        ['hello', 'Hi!'],
        reason: 'one user bubble, error bubble replaced by the answer',
      );
    });

    test('a failed first load can be retried', () async {
      final c = launch(); // no scripted reply for init
      await settle(c);
      expect(c.read(chatControllerProvider).retryRequest, isNotNull);

      api.reply(menuReply);
      await c.read(chatControllerProvider.notifier).retry();

      expect(c.read(chatControllerProvider).messages.map((m) => m.text), [
        'Welcome!',
        'Pick a category:',
      ]);
    });

    test('sending something else drops the failed attempt\'s error', () async {
      api.reply(menuReply);
      final c = launch();
      await settle(c);
      final controller = c.read(chatControllerProvider.notifier);
      await controller.sendText('first');

      api.reply(const [CompleteEvent('answer'), DoneEvent()]);
      await controller.sendText('second');

      final state = c.read(chatControllerProvider);
      expect(state.retryRequest, isNull);
      expect(state.messages.where((m) => m.isError), isEmpty);
      expect(state.messages.last.text, 'answer');
    });

    test('coming back online retries automatically', () async {
      api.reply(menuReply);
      final c = launch();
      await settle(c);
      online.add(false);
      await Future<void>.delayed(Duration.zero);
      await c.read(chatControllerProvider.notifier).sendText('hello');
      expect(c.read(chatControllerProvider).retryRequest, isNotNull);

      api.reply(const [CompleteEvent('Hi!'), DoneEvent()]);
      online.add(true);
      await Future<void>.delayed(Duration.zero);
      await settle(c);

      expect(c.read(chatControllerProvider).messages.last.text, 'Hi!');
    });
  });

  group('screen', () {
    Future<void> pumpApp(WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            chatApiProvider.overrideWithValue(api),
            keyValueStoreProvider.overrideWithValue(disk),
            onlineProvider.overrideWith((ref) => online.stream),
          ],
          child: const SupportApp(),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('shows a banner while the device is offline', (tester) async {
      api.reply(menuReply);
      await pumpApp(tester);
      expect(find.text('No internet connection'), findsNothing);

      online.add(false);
      await tester.pumpAndSettle();
      expect(find.text('No internet connection'), findsOneWidget);

      online.add(true);
      await tester.pumpAndSettle();
      expect(find.text('No internet connection'), findsNothing);
    });

    testWidgets('a failed message offers Retry, which sends it again', (
      tester,
    ) async {
      api.reply(menuReply);
      await pumpApp(tester);
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(find.text('Retry'), findsOneWidget);

      api.reply(const [CompleteEvent('Hi there!'), DoneEvent()]);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(find.text('Retry'), findsNothing);
      expect(find.text('hello'), findsOneWidget);
      expect(
        find.textContaining('Hi there!', findRichText: true),
        findsOneWidget,
      );
    });
  });
}
