import 'dart:async';
import 'dart:convert';

import 'models.dart';

/// Turns the raw bytes of a `text/event-stream` response into [ChatEvent]s.
///
/// The backend writes each event as `data: <json>\n\n`. Network chunks can
/// split an event (or a multi-byte character) anywhere, so bytes are decoded
/// incrementally and buffered until a blank line closes the event.
Stream<ChatEvent> parseChatEvents(Stream<List<int>> bytes) async* {
  var buffer = '';
  await for (final chunk in bytes.transform(utf8.decoder)) {
    buffer += chunk.replaceAll('\r\n', '\n');
    while (true) {
      final end = buffer.indexOf('\n\n');
      if (end < 0) break;
      final block = buffer.substring(0, end);
      buffer = buffer.substring(end + 2);
      final event = _parseBlock(block);
      if (event != null) yield event;
    }
  }
  // A final event without the trailing blank line.
  final event = _parseBlock(buffer);
  if (event != null) yield event;
}

ChatEvent? _parseBlock(String block) {
  final data = StringBuffer();
  for (final line in block.split('\n')) {
    if (!line.startsWith('data:')) continue; // comments, event:, id:, retry:
    var value = line.substring(5);
    if (value.startsWith(' ')) value = value.substring(1);
    if (data.isNotEmpty) data.write('\n');
    data.write(value);
  }
  if (data.isEmpty) return null;
  try {
    final json = jsonDecode(data.toString());
    return json is Map<String, dynamic> ? ChatEvent.fromJson(json) : null;
  } on FormatException {
    return null;
  }
}
