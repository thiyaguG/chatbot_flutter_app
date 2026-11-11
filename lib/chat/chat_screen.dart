import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'chat_controller.dart';
import 'chat_state.dart';
import 'connectivity.dart';
import 'message_bubble.dart';

enum _MenuAction { newChat, endChat }

class ChatScreen extends ConsumerWidget {
  const ChatScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(chatControllerProvider);
    final controller = ref.read(chatControllerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final ui = state.ui;
    // Unknown (still checking, or unsupported platform) counts as online.
    final online = ref.watch(onlineProvider).value ?? true;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        titleSpacing: 16,
        title: Text(
          ui.title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        actions: [
          if (ui.hasGuidedFlow)
            IconButton(
              tooltip: 'Main menu',
              icon: const Icon(Icons.home_outlined),
              onPressed: state.busy ? null : controller.goToMenu,
            ),
          PopupMenuButton<_MenuAction>(
            tooltip: 'More',
            onSelected: (action) => _onMenuAction(context, ref, action),
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: _MenuAction.newChat,
                child: ListTile(
                  leading: Icon(Icons.refresh),
                  title: Text('New chat'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              if (ui.hasFeedbackFlow)
                PopupMenuItem(
                  value: _MenuAction.endChat,
                  enabled: !state.busy,
                  child: const ListTile(
                    leading: Icon(Icons.logout),
                    title: Text('End chat'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (!online) const _OfflineBanner(),
          Expanded(child: _MessageList(state: state)),
          if (!ui.hasGuidedFlow && ui.quickQuestions.isNotEmpty)
            SizedBox(
              height: 48,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: ui.quickQuestions.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final q = ui.quickQuestions[i];
                  return Center(
                    child: ActionChip(
                      label: Text(q.label),
                      onPressed: state.busy
                          ? null
                          : () => controller.sendText(q.text),
                    ),
                  );
                },
              ),
            ),
          _InputBar(state: state, onSend: controller.sendText),
        ],
      ),
    );
  }

  Future<void> _onMenuAction(
    BuildContext context,
    WidgetRef ref,
    _MenuAction action,
  ) async {
    final controller = ref.read(chatControllerProvider.notifier);
    // Nothing to lose before the server has opened a conversation.
    final needsConfirm =
        ref.read(chatControllerProvider).conversationId != null;

    switch (action) {
      case _MenuAction.newChat:
        if (!needsConfirm ||
            await _confirm(
              context,
              'Start a new chat? Your current conversation will be lost.',
            )) {
          await controller.newChat();
        }
      case _MenuAction.endChat:
        if (!needsConfirm ||
            await _confirm(
              context,
              "End this conversation? You won't be able to continue it "
              'afterwards.',
            )) {
          await controller.endChat();
        }
    }
  }

  Future<bool> _confirm(BuildContext context, String message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }
}

class _MessageList extends ConsumerWidget {
  const _MessageList({required this.state});
  final ChatState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(chatControllerProvider.notifier);
    final messages = state.messages;
    final showTyping = state.awaitingReply;
    final count = messages.length + (showTyping ? 1 : 0);

    // Reversed so the newest message stays pinned above the input bar as
    // tokens stream in and when the keyboard opens.
    // Shrink-wrapped and top-aligned so a short conversation starts under the
    // app bar instead of floating at the bottom of an empty screen.
    return Align(
      alignment: Alignment.topCenter,
      child: ListView.separated(
        reverse: true,
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
        itemCount: count,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          if (showTyping && index == 0) return const TypingIndicator();
          final message =
              messages[messages.length - 1 - (index - (showTyping ? 1 : 0))];
          return MessageBubble(
            key: ValueKey(message.id),
            message: message,
            onOption: state.busy ? null : controller.chooseOption,
            onRetry:
                state.retryRequest != null &&
                    !state.busy &&
                    message.isError &&
                    identical(message, messages.last)
                ? controller.retry
                : null,
          );
        },
      ),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        color: scheme.errorContainer,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.wifi_off, size: 18, color: scheme.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'No internet connection',
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InputBar extends StatefulWidget {
  const _InputBar({required this.state, required this.onSend});
  final ChatState state;
  final Future<void> Function(String) onSend;

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
  final _text = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _text.text.trim();
    if (value.isEmpty || widget.state.busy) return;
    _text.clear();
    widget.onSend(value);
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = widget.state;
    final hint = state.allowFreetext
        ? state.ui.inputPlaceholder
        : 'Choose an option above, or type your question';

    return Material(
      color: scheme.surface,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _text,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: 4,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    hintText: hint,
                    hintMaxLines: 1,
                    filled: true,
                    fillColor: scheme.surfaceContainerHigh,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              IconButton.filled(
                tooltip: 'Send',
                icon: const Icon(Icons.send_rounded),
                onPressed: state.busy ? null : _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
