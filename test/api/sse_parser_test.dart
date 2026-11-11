import 'dart:convert';

import 'package:digisol_support/api/models.dart';
import 'package:digisol_support/api/sse_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// A guided-flow reply as captured from the real backend (`{"init": true}`).
const _initStream =
    'data: {"type": "meta", "conversation_id": "cb389ba3", "tenant_id": "digisol", "step": "initial"}\n\n'
    'data: {"type": "options", "text": "Hi! \\ud83d\\udc4b Pick a category:", "options": '
    '[{"label": "Product Enquiry", "value": "product_enquiry"}, {"label": "Warranty", "value": "warranty_check"}], '
    '"allow_freetext": true, "terminal": false}\n\n'
    'data: {"type": "done"}\n\n';

Future<List<ChatEvent>> _parse(List<List<int>> chunks) =>
    parseChatEvents(Stream.fromIterable(chunks)).toList();

void main() {
  test('parses a guided-flow reply', () async {
    final events = await _parse([utf8.encode(_initStream)]);

    expect(events, hasLength(3));
    expect((events[0] as MetaEvent).conversationId, 'cb389ba3');
    final options = events[1] as OptionsEvent;
    expect(options.text, 'Hi! 👋 Pick a category:');
    expect(options.options.map((o) => o.label), [
      'Product Enquiry',
      'Warranty',
    ]);
    expect(options.options.last.value, 'warranty_check');
    expect(options.allowFreetext, isTrue);
    expect(options.terminal, isFalse);
    expect(events[2], isA<DoneEvent>());
  });

  test('parses a token-streamed answer', () async {
    final events = await _parse([
      utf8.encode(
        'data: {"type": "meta", "conversation_id": "c1"}\n\n'
        'data: {"type": "token", "text": "Hello"}\n\n'
        'data: {"type": "token", "text": " there\\n"}\n\n'
        'data: {"type": "done"}\n\n',
      ),
    ]);

    final text = events.whereType<TokenEvent>().map((e) => e.text).join();
    expect(text, 'Hello there\n');
  });

  test('gives the same events whatever the chunk boundaries', () async {
    // Raw (unescaped) multi-byte characters, so byte-level splits can land
    // inside a character as well as inside an event.
    final bytes = utf8.encode(
      'data: {"type": "token", "text": "नमस्ते 👋"}\n\n'
      'data: {"type": "complete", "text": "₹500"}\n\n'
      'data: {"type": "done"}\n\n',
    );

    for (final size in [1, 2, 3, 5, 7, 64]) {
      final chunks = [
        for (var i = 0; i < bytes.length; i += size)
          bytes.sublist(i, (i + size).clamp(0, bytes.length)),
      ];
      final events = await _parse(chunks);
      expect(events, hasLength(3), reason: 'chunk size $size');
      expect((events[0] as TokenEvent).text, 'नमस्ते 👋');
      expect((events[1] as CompleteEvent).text, '₹500');
    }
  });

  test('skips malformed and unknown events, keeps the rest', () async {
    final events = await _parse([
      utf8.encode(
        ': keep-alive comment\n\n'
        'data: {not json}\n\n'
        'data: {"type": "something_new", "text": "x"}\n\n'
        'data: [1, 2]\n\n'
        'data: {"type": "error", "text": "LLM down"}\n\n',
      ),
    ]);

    expect(events, hasLength(1));
    expect((events.single as ErrorEvent).text, 'LLM down');
  });

  test('handles CRLF line endings and a missing final blank line', () async {
    final events = await _parse([
      utf8.encode(
        'data: {"type": "token", "text": "a"}\r\n\r\n'
        'data: {"type": "done"}',
      ),
    ]);

    expect(events, hasLength(2));
    expect(events.last, isA<DoneEvent>());
  });

  test('options event tolerates missing or odd fields', () {
    final event =
        ChatEvent.fromJson({
              'type': 'options',
              'text': 'Pick',
              'options': [
                {'label': 'Yes'},
                'garbage',
                {'value': 'no'},
              ],
              'allow_freetext': false,
            })
            as OptionsEvent;

    expect(event.options.map((o) => '${o.label}=${o.value}'), [
      'Yes=Yes',
      'no=no',
    ]);
    expect(event.allowFreetext, isFalse);
  });
}
