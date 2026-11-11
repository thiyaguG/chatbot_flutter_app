import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/models.dart';
import 'chat_state.dart';

const _avatarSize = 32.0;
const _avatarGap = 8.0;

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.onOption,
    this.onRetry,
  });

  final ChatMessage message;

  /// Null disables the option buttons (a request is in flight).
  final ValueChanged<ChatOption>? onOption;

  /// Set on the error bubble of a request that can be sent again.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return switch (message.role) {
      ChatRole.user => _UserBubble(text: message.text),
      ChatRole.bot => _BotMessage(
        message: message,
        onOption: onOption,
        onRetry: onRetry,
      ),
    };
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(left: 56),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.primary,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(18),
            topRight: Radius.circular(18),
            bottomLeft: Radius.circular(18),
            bottomRight: Radius.circular(4),
          ),
        ),
        child: Text(
          text,
          style: TextStyle(color: scheme.onPrimary, fontSize: 15, height: 1.35),
        ),
      ),
    );
  }
}

class _BotMessage extends StatelessWidget {
  const _BotMessage({
    required this.message,
    required this.onOption,
    required this.onRetry,
  });
  final ChatMessage message;
  final ValueChanged<ChatOption>? onOption;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final textColor = message.isError
        ? scheme.onErrorContainer
        : scheme.onSurface;
    final body = theme.textTheme.bodyMedium!.copyWith(
      color: textColor,
      fontSize: 15,
      height: 1.4,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        BotRow(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: message.isError
                  ? scheme.errorContainer
                  : scheme.surfaceContainerHigh,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(4),
                topRight: Radius.circular(18),
                bottomLeft: Radius.circular(18),
                bottomRight: Radius.circular(18),
              ),
            ),
            child: MarkdownBody(
              data: message.streaming ? '${message.text} ▍' : message.text,
              softLineBreak: true,
              onTapLink: (_, href, _) => _openLink(href),
              styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                p: body,
                listBullet: body,
                a: body.copyWith(
                  color: scheme.primary,
                  decoration: TextDecoration.underline,
                ),
                strong: body.copyWith(fontWeight: FontWeight.w700),
                blockSpacing: 8,
              ),
            ),
          ),
        ),
        if (onRetry != null)
          Padding(
            padding: const EdgeInsets.only(left: _avatarSize + _avatarGap),
            child: TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry'),
            ),
          ),
        if (message.options.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(
              left: _avatarSize + _avatarGap,
              top: 8,
            ),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in message.options)
                  OutlinedButton(
                    onPressed: onOption == null
                        ? null
                        : () => onOption!(option),
                    style: OutlinedButton.styleFrom(
                      shape: const StadiumBorder(),
                      side: BorderSide(color: scheme.primary),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      // Long labels wrap instead of overflowing the screen.
                      tapTargetSize: MaterialTapTargetSize.padded,
                    ),
                    child: Text(option.label, textAlign: TextAlign.center),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  static Future<void> _openLink(String? href) async {
    if (href == null) return;
    var uri = Uri.tryParse(href.trim());
    if (uri == null) return;
    // The backend often gives bare links such as "www.digisol.com/support".
    if (!uri.hasScheme) uri = Uri.tryParse('https://${href.trim()}');
    if (uri == null ||
        !const {'http', 'https', 'mailto', 'tel'}.contains(uri.scheme)) {
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

/// Avatar + content, laid out like a bot message.
class BotRow extends StatelessWidget {
  const BotRow({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: _avatarSize,
            height: _avatarSize,
            margin: const EdgeInsets.only(right: _avatarGap),
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.smart_toy_outlined,
              size: 18,
              color: scheme.onPrimaryContainer,
            ),
          ),
          Flexible(child: child),
        ],
      ),
    );
  }
}

/// Three pulsing dots shown while waiting for the reply to start.
class TypingIndicator extends StatefulWidget {
  const TypingIndicator({super.key});

  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Assistant is typing',
      child: BotRow(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(18),
          ),
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < 3; i++)
                  Padding(
                    padding: EdgeInsets.only(left: i == 0 ? 0 : 5),
                    child: Opacity(
                      opacity: _dotOpacity(i),
                      child: CircleAvatar(
                        radius: 4,
                        backgroundColor: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  double _dotOpacity(int index) {
    // Each dot peaks a fifth of a cycle after the previous one.
    final phase = (_controller.value - index * 0.2) % 1.0;
    final wave = phase < 0.5 ? phase * 2 : (1 - phase) * 2;
    return 0.3 + 0.7 * wave;
  }
}
