import '../api/chat_api.dart';
import '../api/models.dart';

enum ChatRole { user, bot }

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    this.streaming = false,
    this.isError = false,
    this.options = const [],
  });

  final int id;
  final ChatRole role;
  final String text;

  /// Tokens are still arriving for this bot message.
  final bool streaming;
  final bool isError;

  /// Buttons to show under this bot message. Cleared once the user answers.
  final List<ChatOption> options;

  ChatMessage copyWith({
    String? text,
    bool? streaming,
    bool? isError,
    List<ChatOption>? options,
  }) => ChatMessage(
    id: id,
    role: role,
    text: text ?? this.text,
    streaming: streaming ?? this.streaming,
    isError: isError ?? this.isError,
    options: options ?? this.options,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'role': role.name,
    'text': text,
    if (isError) 'error': true,
    if (options.isNotEmpty) 'options': [for (final o in options) o.toJson()],
  };

  static ChatMessage? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final text = json['text'];
    if (id is! int || text is! String) return null;
    final options = json['options'];
    return ChatMessage(
      id: id,
      role: json['role'] == 'user' ? ChatRole.user : ChatRole.bot,
      text: text,
      isError: json['error'] == true,
      options: [
        if (options is List)
          for (final o in options) ?ChatOption.fromJson(o),
      ],
    );
  }
}

class ChatState {
  const ChatState({
    this.ui = TenantUiConfig.fallback,
    this.messages = const [],
    this.busy = false,
    this.conversationId,
    this.allowFreetext = true,
    this.retryRequest,
  });

  final TenantUiConfig ui;
  final List<ChatMessage> messages;

  /// A request is in flight; input is disabled.
  final bool busy;

  /// Set by the server on the first reply; null means nothing to lose yet.
  final String? conversationId;

  /// False when the current guided step wants a button rather than typing
  /// (typing still works — it only changes the input hint).
  final bool allowFreetext;

  /// The request that just failed to reach the server, if any. While set, the
  /// last message is its error bubble and offers a retry.
  final ChatRequest? retryRequest;

  /// Waiting for the reply to start: show the typing indicator.
  bool get awaitingReply =>
      busy && !(messages.isNotEmpty && messages.last.streaming);

  ChatState copyWith({
    TenantUiConfig? ui,
    List<ChatMessage>? messages,
    bool? busy,
    String? Function()? conversationId,
    bool? allowFreetext,
    ChatRequest? Function()? retryRequest,
  }) => ChatState(
    ui: ui ?? this.ui,
    messages: messages ?? this.messages,
    busy: busy ?? this.busy,
    conversationId: conversationId != null
        ? conversationId()
        : this.conversationId,
    allowFreetext: allowFreetext ?? this.allowFreetext,
    retryRequest: retryRequest != null ? retryRequest() : this.retryRequest,
  );
}
