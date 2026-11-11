import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/chat_api.dart';
import '../api/models.dart';
import '../config/app_config.dart';
import 'chat_state.dart';
import 'chat_store.dart';
import 'connectivity.dart';

final appConfigProvider = Provider<AppConfig>(
  (ref) => AppConfig.fromEnvironment,
);

final chatApiProvider = Provider<ChatApi>((ref) {
  final api = ChatApi(config: ref.watch(appConfigProvider));
  ref.onDispose(api.close);
  return api;
});

final chatControllerProvider = NotifierProvider<ChatController, ChatState>(
  ChatController.new,
);

/// Drives one conversation. Mirrors the behaviour of the web widget
/// (templates/iframe.html in the backend repo), plus what a phone needs:
/// the transcript survives an app restart and failed requests can be retried.
class ChatController extends Notifier<ChatState> {
  int _nextId = 0;

  /// Bumped by [newChat] so a reply still streaming for the discarded
  /// conversation is ignored.
  int _generation = 0;

  ChatApi get _api => ref.read(chatApiProvider);
  ChatStore get _store => ref.read(chatStoreProvider);

  @override
  ChatState build() {
    // Coming back online retries the request that failed while offline.
    ref.listen(onlineProvider, (previous, next) {
      if (previous?.value == false && next.value == true) retry();
    });

    final cachedUi = _store.loadUi();
    final saved = _store.loadChat();

    if (saved != null) {
      _nextId = saved.messages.last.id + 1;
      Future.microtask(_refreshUi);
      return ChatState(
        ui: cachedUi ?? TenantUiConfig.fallback,
        messages: saved.messages,
        conversationId: saved.conversationId,
        allowFreetext: saved.allowFreetext,
      );
    }

    Future.microtask(() => _start(hasCachedUi: cachedUi != null));
    return ChatState(ui: cachedUi ?? TenantUiConfig.fallback, busy: true);
  }

  Future<void> _start({required bool hasCachedUi}) async {
    final generation = _generation;
    if (hasCachedUi) {
      // Known branding: open at once, refresh it in the background.
      _refreshUi();
    } else {
      // First launch: wait, so the welcome message is the tenant's own.
      await _refreshUi();
      if (!ref.mounted || generation != _generation) return;
    }
    await _openConversation();
  }

  /// Fetches the tenant branding and caches it. On failure the current
  /// branding stays; a genuine connection problem is reported by the next
  /// chat request instead.
  Future<void> _refreshUi() async {
    try {
      final ui = await _api.fetchUiConfig();
      if (!ref.mounted) return;
      _store.saveUi(ui);
      state = state.copyWith(ui: ui);
    } on ChatApiException {
      // Older server or offline.
    }
  }

  Future<void> _openConversation() async {
    _addMessage(ChatRole.bot, state.ui.welcomeMessage);
    if (state.ui.hasGuidedFlow) {
      await _send(const ChatRequest.init());
    } else {
      state = state.copyWith(busy: false);
      _store.saveChat(state);
    }
  }

  /// Sends a typed message.
  Future<void> sendText(String text) async {
    final question = text.trim();
    if (question.isEmpty || state.busy) return;
    _dropFailedAttempt();
    _addMessage(ChatRole.user, question);
    await _send(ChatRequest.question(question));
  }

  /// Answers a guided step by tapping one of its buttons.
  Future<void> chooseOption(ChatOption option) async {
    if (state.busy) return;
    _dropFailedAttempt();
    _addMessage(ChatRole.user, option.label);
    await _send(ChatRequest.question(option.value));
  }

  /// Back to the guided flow's main menu; the conversation is kept.
  Future<void> goToMenu() async {
    if (state.busy) return;
    _dropFailedAttempt();
    _addMessage(ChatRole.user, 'Back to main menu');
    await _send(const ChatRequest.menu());
  }

  /// Ends the chat, which starts the feedback questions.
  Future<void> endChat() async {
    if (state.busy) return;
    _dropFailedAttempt();
    _addMessage(ChatRole.user, 'End chat');
    await _send(const ChatRequest.endChat());
  }

  /// Re-sends the request that failed to reach the server. The user's bubble
  /// is already on screen, so only the error bubble is replaced.
  Future<void> retry() async {
    final request = state.retryRequest;
    if (request == null || state.busy) return;
    _dropFailedAttempt();
    await _send(request);
  }

  /// Discards the conversation and starts over.
  Future<void> newChat() async {
    _generation++;
    final old = state.conversationId;
    state = ChatState(ui: state.ui, busy: true);
    _store.clearChat();
    if (old != null) await _api.reset(old);
    if (!ref.mounted) return;
    await _openConversation();
  }

  /// Removes the error bubble of a failed request once the user moves on.
  void _dropFailedAttempt() {
    if (state.retryRequest == null) return;
    final messages = state.messages;
    state = state.copyWith(
      messages: messages.isNotEmpty && messages.last.isError
          ? messages.sublist(0, messages.length - 1)
          : messages,
      retryRequest: () => null,
    );
  }

  Future<void> _send(ChatRequest request) async {
    final generation = _generation;
    _clearOptions();
    state = state.copyWith(busy: true, allowFreetext: true);
    _store.saveChat(state);

    // Id of the bot bubble currently receiving tokens, if any.
    int? streamingId;
    var gotReply = false;

    void finish({String? text, bool isError = false, OptionsEvent? options}) {
      gotReply = true;
      if (streamingId == null) {
        _addMessage(
          ChatRole.bot,
          text ?? '',
          isError: isError,
          options: options?.options ?? const [],
        );
      } else {
        _update(
          streamingId!,
          (m) => m.copyWith(
            text: text ?? m.text,
            streaming: false,
            isError: isError,
            options: options?.options,
          ),
        );
        streamingId = null;
      }
    }

    try {
      await for (final event in _api.send(
        request,
        conversationId: state.conversationId,
      )) {
        if (!ref.mounted || generation != _generation) return;
        switch (event) {
          case MetaEvent(:final conversationId):
            if (conversationId.isNotEmpty) {
              state = state.copyWith(conversationId: () => conversationId);
            }
          case TokenEvent(:final text):
            if (streamingId == null) {
              streamingId = _addMessage(ChatRole.bot, text, streaming: true);
            } else {
              _update(streamingId!, (m) => m.copyWith(text: m.text + text));
            }
          case CompleteEvent(:final text):
            finish(text: text);
          case OptionsEvent():
            finish(text: event.text, options: event);
            state = state.copyWith(allowFreetext: event.allowFreetext);
          case ErrorEvent(:final text):
            finish(text: '⚠️ $text', isError: true);
          case DoneEvent():
            if (streamingId != null) finish();
        }
      }
      if (!ref.mounted || generation != _generation) return;
      if (streamingId != null) finish();
    } on ChatApiException catch (e) {
      if (!ref.mounted || generation != _generation) return;
      if (streamingId != null) {
        // Part of the answer arrived: keep it. Re-sending would make the
        // server answer the same message twice, so no retry is offered.
        finish();
        _addMessage(ChatRole.bot, e.message, isError: true);
      } else if (gotReply) {
        _addMessage(ChatRole.bot, e.message, isError: true);
      } else {
        // Nothing came back: safe to offer a retry.
        _addMessage(ChatRole.bot, e.message, isError: true);
        state = state.copyWith(retryRequest: () => request);
      }
    } finally {
      if (ref.mounted && generation == _generation) {
        state = state.copyWith(busy: false);
        _store.saveChat(state);
      }
    }
  }

  int _addMessage(
    ChatRole role,
    String text, {
    bool streaming = false,
    bool isError = false,
    List<ChatOption> options = const [],
  }) {
    final id = _nextId++;
    state = state.copyWith(
      messages: [
        ...state.messages,
        ChatMessage(
          id: id,
          role: role,
          text: text,
          streaming: streaming,
          isError: isError,
          options: options,
        ),
      ],
    );
    return id;
  }

  void _update(int id, ChatMessage Function(ChatMessage) change) {
    state = state.copyWith(
      messages: [for (final m in state.messages) m.id == id ? change(m) : m],
    );
  }

  void _clearOptions() {
    if (state.messages.every((m) => m.options.isEmpty)) return;
    state = state.copyWith(
      messages: [
        for (final m in state.messages)
          m.options.isEmpty ? m : m.copyWith(options: const []),
      ],
    );
  }
}
