import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import 'models.dart';
import 'sse_parser.dart';

/// A failure talking to the backend, with a message fit to show the user.
class ChatApiException implements Exception {
  const ChatApiException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() => 'ChatApiException($statusCode): $message';
}

/// What a chat turn asks the backend to do.
sealed class ChatRequest {
  const ChatRequest();

  /// A typed message, or the `value` of a tapped option button.
  const factory ChatRequest.question(String text) = _Question;

  /// Start a fresh conversation's guided flow (no user input yet).
  const factory ChatRequest.init() = _Flag.init;

  /// Jump back to the main menu, keeping the conversation.
  const factory ChatRequest.menu() = _Flag.menu;

  /// End the chat (starts the feedback flow where the tenant has one).
  const factory ChatRequest.endChat() = _Flag.endChat;

  Map<String, Object> toJson();
}

class _Question extends ChatRequest {
  const _Question(this.text);
  final String text;

  @override
  Map<String, Object> toJson() => {'question': text};
}

class _Flag extends ChatRequest {
  const _Flag.init() : key = 'init';
  const _Flag.menu() : key = 'menu';
  const _Flag.endChat() : key = 'end_chat';
  final String key;

  @override
  Map<String, Object> toJson() => {key: true};
}

/// Client for the tenant-scoped chat endpoints of the RAG chatbot backend.
class ChatApi {
  ChatApi({required this.config, http.Client? client})
    : _client = client ?? http.Client();

  final AppConfig config;
  final http.Client _client;

  /// How long to wait for the server to start answering. Generous because the
  /// first request after a server restart loads models.
  static const connectTimeout = Duration(seconds: 30);

  /// Longest allowed silence in the middle of a streamed answer.
  static const idleTimeout = Duration(seconds: 90);

  /// Sends one chat turn and streams the reply's events. Cancelling the
  /// subscription aborts the request.
  ///
  /// Transport and HTTP failures surface as a [ChatApiException] error on the
  /// stream; failures the server reports itself arrive as an [ErrorEvent].
  Stream<ChatEvent> send(ChatRequest request, {String? conversationId}) async* {
    final httpRequest = http.Request('POST', config.endpoint('chat/stream'))
      ..headers['Content-Type'] = 'application/json'
      ..headers['Accept'] = 'text/event-stream'
      ..body = jsonEncode({
        ...request.toJson(),
        'conversation_id': ?conversationId,
      });

    final http.StreamedResponse response;
    try {
      response = await _client.send(httpRequest).timeout(connectTimeout);
    } on Exception catch (e) {
      throw _transportError(e);
    }

    if (response.statusCode != 200) {
      // Drain so the connection is released.
      unawaited(response.stream.drain<void>().catchError((_) {}));
      throw ChatApiException(
        'The server returned an error (${response.statusCode}). '
        'Please try again.',
        statusCode: response.statusCode,
      );
    }

    try {
      // `await for`, not `yield*`: yield* forwards stream errors straight to
      // the listener, bypassing this try/catch.
      await for (final event in parseChatEvents(
        response.stream.timeout(idleTimeout),
      )) {
        yield event;
      }
    } on Exception catch (e) {
      throw _transportError(e);
    }
  }

  /// Discards the server-side state of a conversation. Best effort: the app
  /// starts a new conversation locally whether or not this succeeds.
  Future<void> reset(String conversationId) async {
    try {
      await _client
          .post(
            config.endpoint('reset-conversation'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'conversation_id': conversationId}),
          )
          .timeout(const Duration(seconds: 10));
    } on Exception {
      // Ignored — see doc comment.
    }
  }

  /// Fetches the tenant's branding. Throws [ChatApiException] when the server
  /// is unreachable or does not expose the endpoint; callers fall back to
  /// [TenantUiConfig.fallback].
  Future<TenantUiConfig> fetchUiConfig() async {
    final http.Response response;
    try {
      response = await _client
          .get(config.endpoint('ui-config'))
          .timeout(const Duration(seconds: 10));
    } on Exception catch (e) {
      throw _transportError(e);
    }
    if (response.statusCode != 200) {
      throw ChatApiException(
        'Could not load configuration (${response.statusCode}).',
        statusCode: response.statusCode,
      );
    }
    try {
      final json = jsonDecode(utf8.decode(response.bodyBytes));
      if (json is Map<String, dynamic>) return TenantUiConfig.fromJson(json);
    } on FormatException {
      // fall through
    }
    throw const ChatApiException('Could not read configuration.');
  }

  void close() => _client.close();

  ChatApiException _transportError(Exception e) {
    if (e is ChatApiException) return e;
    if (e is TimeoutException) {
      return const ChatApiException(
        'The server took too long to respond. Please try again.',
      );
    }
    if (e is SocketException || e is http.ClientException) {
      return const ChatApiException(
        'Cannot reach the server. Check your internet connection.',
      );
    }
    return const ChatApiException('Something went wrong. Please try again.');
  }
}
