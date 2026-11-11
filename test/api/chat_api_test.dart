import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:digisol_support/api/chat_api.dart';
import 'package:digisol_support/api/models.dart';
import 'package:digisol_support/config/app_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _config = AppConfig(baseUrl: 'http://server.test/', tenantId: 'digisol');

http.StreamedResponse _sse(String body, {int status = 200}) =>
    http.StreamedResponse(Stream.value(utf8.encode(body)), status);

void main() {
  group('send', () {
    test(
      'posts a question with the conversation id and streams events',
      () async {
        late http.BaseRequest seen;
        late String seenBody;
        final api = ChatApi(
          config: _config,
          client: MockClient.streaming((request, body) async {
            seen = request;
            seenBody = await body.bytesToString();
            return _sse(
              'data: {"type": "meta", "conversation_id": "c1"}\n\n'
              'data: {"type": "complete", "text": "Hi"}\n\n'
              'data: {"type": "done"}\n\n',
            );
          }),
        );

        final events = await api
            .send(const ChatRequest.question('hello'), conversationId: 'c1')
            .toList();

        expect(seen.method, 'POST');
        expect(
          seen.url.toString(),
          'http://server.test/api/digisol/chat/stream',
        );
        expect(jsonDecode(seenBody), {
          'question': 'hello',
          'conversation_id': 'c1',
        });
        expect(events.map((e) => e.runtimeType), [
          MetaEvent,
          CompleteEvent,
          DoneEvent,
        ]);
      },
    );

    test(
      'init / menu / end_chat send their flag and no conversation id',
      () async {
        final bodies = <Object?>[];
        final api = ChatApi(
          config: _config,
          client: MockClient.streaming((request, body) async {
            bodies.add(jsonDecode(await body.bytesToString()));
            return _sse('data: {"type": "done"}\n\n');
          }),
        );

        await api.send(const ChatRequest.init()).drain<void>();
        await api.send(const ChatRequest.menu()).drain<void>();
        await api.send(const ChatRequest.endChat()).drain<void>();

        expect(bodies, [
          {'init': true},
          {'menu': true},
          {'end_chat': true},
        ]);
      },
    );

    test('a non-200 response becomes a ChatApiException', () async {
      final api = ChatApi(
        config: _config,
        client: MockClient.streaming(
          (_, _) async => _sse('{"error": "boom"}', status: 500),
        ),
      );

      await expectLater(
        api.send(const ChatRequest.question('hi')).toList(),
        throwsA(
          isA<ChatApiException>().having((e) => e.statusCode, 'status', 500),
        ),
      );
    });

    test('an unreachable server becomes a ChatApiException', () async {
      final api = ChatApi(
        config: _config,
        client: MockClient.streaming(
          (_, _) async => throw const SocketException('no route'),
        ),
      );

      await expectLater(
        api.send(const ChatRequest.question('hi')).toList(),
        throwsA(
          isA<ChatApiException>().having(
            (e) => e.message,
            'message',
            contains('Cannot reach'),
          ),
        ),
      );
    });

    test(
      'a connection dropped mid-answer delivers what arrived, then errors',
      () async {
        final api = ChatApi(
          config: _config,
          client: MockClient.streaming((_, _) async {
            final controller = StreamController<List<int>>();
            controller.add(
              utf8.encode('data: {"type": "token", "text": "par"}\n\n'),
            );
            controller.addError(http.ClientException('connection closed'));
            unawaited(controller.close());
            return http.StreamedResponse(controller.stream, 200);
          }),
        );

        final received = <ChatEvent>[];
        Object? error;
        try {
          await for (final event in api.send(
            const ChatRequest.question('hi'),
          )) {
            received.add(event);
          }
        } catch (e) {
          error = e;
        }

        expect((received.single as TokenEvent).text, 'par');
        expect(error, isA<ChatApiException>());
      },
    );
  });

  group('fetchUiConfig', () {
    test('parses the server config', () async {
      final api = ChatApi(
        config: _config,
        client: MockClient((request) async {
          expect(request.url.path, '/api/digisol/ui-config');
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'title': 'Digisol AI Support Agent',
                'subtitle': 'Ask away',
                'theme': {'primary': '#2e7d32', 'primary_dark': null},
                'welcome_message': 'Hello — नमस्ते',
                'input_placeholder': 'Type here',
                'quick_questions': [
                  {'label': 'No Internet', 'text': 'Internet is down'},
                  {'label': 'Empty', 'text': ''},
                ],
                'has_guided_flow': true,
                'has_feedback_flow': false,
              }),
            ),
            200,
          );
        }),
      );

      final ui = await api.fetchUiConfig();

      expect(ui.title, 'Digisol AI Support Agent');
      expect(ui.primaryColor.toARGB32(), 0xFF2E7D32);
      expect(ui.welcomeMessage, 'Hello — नमस्ते');
      expect(ui.quickQuestions.single.label, 'No Internet');
      expect(ui.hasGuidedFlow, isTrue);
      expect(ui.hasFeedbackFlow, isFalse);
    });

    test('missing fields fall back to defaults', () {
      final ui = TenantUiConfig.fromJson({
        'theme': {'primary': 'blue'},
      });

      expect(ui.title, TenantUiConfig.fallback.title);
      expect(ui.primaryColor, TenantUiConfig.fallback.primaryColor);
      expect(ui.quickQuestions, isEmpty);
    });

    test('a server without the endpoint throws', () async {
      final api = ChatApi(
        config: _config,
        client: MockClient((_) async => http.Response('Not found', 404)),
      );

      await expectLater(
        api.fetchUiConfig(),
        throwsA(
          isA<ChatApiException>().having((e) => e.statusCode, 'status', 404),
        ),
      );
    });
  });

  test('reset posts the conversation id and swallows failures', () async {
    Object? body;
    final ok = ChatApi(
      config: _config,
      client: MockClient((request) async {
        expect(request.url.path, '/api/digisol/reset-conversation');
        body = jsonDecode(request.body);
        return http.Response('{}', 200);
      }),
    );
    await ok.reset('c1');
    expect(body, {'conversation_id': 'c1'});

    final broken = ChatApi(
      config: _config,
      client: MockClient((_) async => throw const SocketException('down')),
    );
    await broken.reset('c1'); // must not throw
  });
}
