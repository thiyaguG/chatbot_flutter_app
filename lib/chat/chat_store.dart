import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/models.dart';
import 'chat_state.dart';

/// Minimal synchronous string storage, so the saved conversation is available
/// on the very first frame.
abstract interface class KeyValueStore {
  String? read(String key);
  void write(String key, String value);
  void remove(String key);
}

class MemoryStore implements KeyValueStore {
  final values = <String, String>{};

  @override
  String? read(String key) => values[key];
  @override
  void write(String key, String value) => values[key] = value;
  @override
  void remove(String key) => values.remove(key);
}

class PrefsStore implements KeyValueStore {
  PrefsStore(this._prefs);
  final SharedPreferences _prefs;

  @override
  String? read(String key) => _prefs.getString(key);
  @override
  void write(String key, String value) => _prefs.setString(key, value);
  @override
  void remove(String key) => _prefs.remove(key);
}

/// In-memory by default (tests, previews); main() overrides it with
/// [PrefsStore] so the conversation survives an app restart.
final keyValueStoreProvider = Provider<KeyValueStore>((ref) => MemoryStore());

final chatStoreProvider = Provider<ChatStore>(
  (ref) => ChatStore(ref.watch(keyValueStoreProvider)),
);

class SavedChat {
  const SavedChat({
    required this.messages,
    required this.conversationId,
    required this.allowFreetext,
  });
  final List<ChatMessage> messages;
  final String? conversationId;
  final bool allowFreetext;
}

/// Persists the transcript and the tenant branding on the device.
class ChatStore {
  ChatStore(this._store, {DateTime Function() now = DateTime.now}) : _now = now;

  final KeyValueStore _store;
  final DateTime Function() _now;

  static const chatKey = 'chat_v1';
  static const uiKey = 'ui_config_v1';

  /// The server keeps conversation state in memory only, so an old transcript
  /// can no longer be continued meaningfully; start fresh after this long.
  static const maxAge = Duration(hours: 24);

  SavedChat? loadChat() {
    final json = _decode(_store.read(chatKey));
    if (json == null) return null;
    final savedAt = DateTime.tryParse(json['saved_at']?.toString() ?? '');
    final raw = json['messages'];
    if (savedAt == null ||
        _now().difference(savedAt) > maxAge ||
        raw is! List) {
      clearChat();
      return null;
    }
    final messages = [for (final m in raw) ?ChatMessage.fromJson(m)];
    if (messages.isEmpty) return null;
    return SavedChat(
      messages: messages,
      conversationId: json['conversation_id'] as String?,
      allowFreetext: json['allow_freetext'] != false,
    );
  }

  void saveChat(ChatState state) {
    _store.write(
      chatKey,
      jsonEncode({
        'saved_at': _now().toIso8601String(),
        'conversation_id': state.conversationId,
        'allow_freetext': state.allowFreetext,
        'messages': [for (final m in state.messages) m.toJson()],
      }),
    );
  }

  void clearChat() => _store.remove(chatKey);

  TenantUiConfig? loadUi() {
    final json = _decode(_store.read(uiKey));
    return json == null ? null : TenantUiConfig.fromJson(json);
  }

  void saveUi(TenantUiConfig ui) =>
      _store.write(uiKey, jsonEncode(ui.toJson()));

  static Map<String, dynamic>? _decode(String? raw) {
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw);
      return json is Map<String, dynamic> ? json : null;
    } on FormatException {
      return null;
    }
  }
}
