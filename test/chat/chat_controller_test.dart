import 'dart:async';

import 'dart:ui' show Color;

import 'package:digisol_support/api/chat_api.dart';
import 'package:digisol_support/api/models.dart';
import 'package:digisol_support/chat/chat_controller.dart';
import 'package:digisol_support/chat/chat_state.dart';
import 'package:digisol_support/chat/connectivity.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_chat_api.dart';

void main() {
  late FakeChatApi api;
  late ProviderContainer container;

  ChatState state() => container.read(chatControllerProvider);
  ChatController controller() =>
      container.read(chatControllerProvider.notifier);

  Future<void> settle() async {
    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(Duration.zero);
      if (!state().busy) return;
    }
    fail('controller stayed busy');
  }

  /// Opens the provider and waits for the start-up sequence.
  Future<void> open() async {
    container.listen(chatControllerProvider, (_, _) {});
    await settle();
  }

  setUp(() {
    api = FakeChatApi();
    container = ProviderContainer(
      overrides: [
        chatApiProvider.overrideWithValue(api),
        onlineProvider.overrideWith((ref) => Stream.value(true)),
      ],
    );
    addTearDown(container.dispose);
  });

  test('start-up shows the welcome, then the guided menu', () async {
    api.reply(menuReply);
    await open();

    expect(api.requests, [
      {'init': true},
    ]);
    expect(state().ui.title, 'Test Support');
    expect(state().conversationId, 'conv-1');
    expect(state().messages.map((m) => m.text), [
      'Welcome!',
      'Pick a category:',
    ]);
    expect(state().messages.last.options, hasLength(2));
  });

  test('a tenant without a guided flow sends nothing at start-up', () async {
    api.ui = const TenantUiConfig(
      title: 'Edu',
      subtitle: '',
      primaryColor: Color(0xFF1A56A0),
      welcomeMessage: 'Hi student',
      inputPlaceholder: '',
      quickQuestions: [],
      hasGuidedFlow: false,
      hasFeedbackFlow: false,
    );
    await open();

    expect(api.requests, isEmpty);
    expect(state().messages.single.text, 'Hi student');
    expect(state().conversationId, isNull);
  });

  test(
    'falls back to built-in branding when ui-config is unavailable',
    () async {
      api.ui = null;
      api.reply(menuReply);
      await open();

      expect(state().ui.title, TenantUiConfig.fallback.title);
      expect(
        state().messages.first.text,
        TenantUiConfig.fallback.welcomeMessage,
      );
    },
  );

  test('tapping an option shows its label, sends its value', () async {
    api.reply(menuReply);
    await open();
    api.reply(const [
      MetaEvent(conversationId: 'conv-1'),
      CompleteEvent('Please share the model number.'),
      DoneEvent(),
    ]);

    await controller().chooseOption(state().messages.last.options.last);

    expect(api.requests.last, {'question': 'warranty_check'});
    expect(api.conversationIds.last, 'conv-1');
    final messages = state().messages;
    expect(messages[2].role, ChatRole.user);
    expect(messages[2].text, 'Warranty');
    expect(messages[3].text, 'Please share the model number.');
    expect(
      messages.every((m) => m.options.isEmpty),
      isTrue,
      reason: 'answered buttons are removed',
    );
  });

  test('tokens build up one streaming bubble', () async {
    api.reply(menuReply);
    await open();
    final stream = StreamController<ChatEvent>();
    api.replies.add(stream.stream);

    final sending = controller().sendText('  what is the warranty?  ');
    await Future<void>.delayed(Duration.zero);
    expect(state().messages.last.text, 'what is the warranty?');
    expect(state().awaitingReply, isTrue);

    stream
      ..add(const MetaEvent(conversationId: 'conv-1'))
      ..add(const TokenEvent('Two '))
      ..add(const TokenEvent('years'));
    await Future<void>.delayed(Duration.zero);
    expect(state().messages.last.text, 'Two years');
    expect(state().messages.last.streaming, isTrue);
    expect(state().awaitingReply, isFalse);
    expect(state().busy, isTrue);

    stream
      ..add(const TokenEvent('.'))
      ..add(const DoneEvent());
    await stream.close();
    await sending;

    expect(state().messages.last.text, 'Two years.');
    expect(state().messages.last.streaming, isFalse);
    expect(state().busy, isFalse);
  });

  test(
    'an answer followed by a resumed guided step makes two bubbles',
    () async {
      api.reply(menuReply);
      await open();
      api.reply(const [
        MetaEvent(conversationId: 'conv-1'),
        CompleteEvent('Ticket DIG-1 created.'),
        OptionsEvent(
          text: 'Is the power LED on?',
          options: [ChatOption(label: 'Yes', value: 'yes')],
          allowFreetext: false,
        ),
        DoneEvent(),
      ]);

      await controller().sendText('create a ticket');

      final last = state().messages.sublist(state().messages.length - 2);
      expect(last[0].text, 'Ticket DIG-1 created.');
      expect(last[0].options, isEmpty);
      expect(last[1].text, 'Is the power LED on?');
      expect(last[1].options.single.label, 'Yes');
      expect(state().allowFreetext, isFalse);
    },
  );

  test(
    'a dropped connection keeps the partial answer and reports it',
    () async {
      api.reply(menuReply);
      await open();
      final stream = StreamController<ChatEvent>();
      api.replies.add(stream.stream);

      final sending = controller().sendText('hello');
      stream
        ..add(const TokenEvent('Partial'))
        ..addError(const ChatApiException('Cannot reach the server.'));
      unawaited(stream.close());
      await sending;

      final messages = state().messages;
      expect(messages[messages.length - 2].text, 'Partial');
      expect(messages[messages.length - 2].streaming, isFalse);
      expect(messages.last.isError, isTrue);
      expect(messages.last.text, 'Cannot reach the server.');
      expect(state().busy, isFalse);
    },
  );

  test('a server-reported error becomes an error bubble', () async {
    api.reply(menuReply);
    await open();
    api.reply(const [
      MetaEvent(conversationId: 'conv-1'),
      ErrorEvent('LLM is down'),
      DoneEvent(),
    ]);

    await controller().sendText('hello');

    expect(state().messages.last.isError, isTrue);
    expect(state().messages.last.text, contains('LLM is down'));
  });

  test('menu and end chat send their flags', () async {
    api.reply(menuReply);
    await open();
    api.reply(menuReply);
    await controller().goToMenu();
    api.reply(const [CompleteEvent('How would you rate us?'), DoneEvent()]);
    await controller().endChat();

    expect(api.requests.sublist(1), [
      {'menu': true},
      {'end_chat': true},
    ]);
    expect(state().messages.last.text, 'How would you rate us?');
  });

  test('new chat resets the server conversation and starts over', () async {
    api.reply(menuReply);
    await open();
    api.reply(const [CompleteEvent('answer'), DoneEvent()]);
    await controller().sendText('hello');

    api.reply(const [
      MetaEvent(conversationId: 'conv-2'),
      OptionsEvent(text: 'Pick a category:', options: []),
      DoneEvent(),
    ]);
    await controller().newChat();

    expect(api.resets, ['conv-1']);
    expect(api.requests.last, {'init': true});
    expect(api.conversationIds.last, isNull);
    expect(state().conversationId, 'conv-2');
    expect(state().messages.map((m) => m.text), [
      'Welcome!',
      'Pick a category:',
    ]);
  });

  test('new chat ignores a reply still streaming for the old chat', () async {
    api.reply(menuReply);
    await open();
    final old = StreamController<ChatEvent>();
    api.replies.add(old.stream);
    unawaited(controller().sendText('slow question'));
    await Future<void>.delayed(Duration.zero);
    old.add(const TokenEvent('old ans'));
    await Future<void>.delayed(Duration.zero);

    api.reply(menuReply);
    await controller().newChat();
    old.add(const TokenEvent('wer'));
    await old.close();
    await settle();

    expect(state().messages.map((m) => m.text), [
      'Welcome!',
      'Pick a category:',
    ]);
    expect(state().busy, isFalse);
  });
}
