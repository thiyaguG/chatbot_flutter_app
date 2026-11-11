import 'dart:ui' show Color;

/// One clickable choice under a bot message. Tapping it sends [value] to the
/// backend and shows [label] as the user's bubble.
class ChatOption {
  const ChatOption({required this.label, required this.value});

  final String label;
  final String value;

  static ChatOption? fromJson(Object? json) {
    if (json is! Map) return null;
    final label = json['label']?.toString() ?? '';
    final value = json['value']?.toString() ?? label;
    if (label.isEmpty && value.isEmpty) return null;
    return ChatOption(label: label.isEmpty ? value : label, value: value);
  }

  Map<String, Object> toJson() => {'label': label, 'value': value};
}

/// Events emitted by `POST /api/<tenant>/chat/stream`.
sealed class ChatEvent {
  const ChatEvent();

  /// Returns null for payloads that are not a recognised event, so newer
  /// backend event types are ignored instead of breaking the stream.
  static ChatEvent? fromJson(Map<String, dynamic> json) {
    final text = json['text']?.toString() ?? '';
    switch (json['type']) {
      case 'meta':
        return MetaEvent(
          conversationId: json['conversation_id']?.toString() ?? '',
          step: json['step']?.toString(),
        );
      case 'token':
        return TokenEvent(text);
      case 'complete':
        return CompleteEvent(text);
      case 'options':
        final raw = json['options'];
        return OptionsEvent(
          text: text,
          options: [
            if (raw is List)
              for (final o in raw) ?ChatOption.fromJson(o),
          ],
          allowFreetext: json['allow_freetext'] != false,
          terminal: json['terminal'] == true,
        );
      case 'error':
        return ErrorEvent(text);
      case 'done':
        return const DoneEvent();
      default:
        return null;
    }
  }
}

/// First event of every stream; carries the server-assigned conversation id.
class MetaEvent extends ChatEvent {
  const MetaEvent({required this.conversationId, this.step});
  final String conversationId;
  final String? step;
}

/// One streamed fragment of an LLM answer.
class TokenEvent extends ChatEvent {
  const TokenEvent(this.text);
  final String text;
}

/// A whole pre-built answer (no token streaming).
class CompleteEvent extends ChatEvent {
  const CompleteEvent(this.text);
  final String text;
}

/// A guided-flow step: a message plus buttons.
class OptionsEvent extends ChatEvent {
  const OptionsEvent({
    required this.text,
    required this.options,
    this.allowFreetext = true,
    this.terminal = false,
  });
  final String text;
  final List<ChatOption> options;
  final bool allowFreetext;
  final bool terminal;
}

/// A server-side failure reported inside the stream.
class ErrorEvent extends ChatEvent {
  const ErrorEvent(this.text);
  final String text;
}

/// Last event of every stream.
class DoneEvent extends ChatEvent {
  const DoneEvent();
}

class QuickQuestion {
  const QuickQuestion({required this.label, required this.text});
  final String label;
  final String text;
}

/// Branding and feature flags from `GET /api/<tenant>/ui-config`.
class TenantUiConfig {
  const TenantUiConfig({
    required this.title,
    required this.subtitle,
    required this.primaryColor,
    required this.welcomeMessage,
    required this.inputPlaceholder,
    required this.quickQuestions,
    required this.hasGuidedFlow,
    required this.hasFeedbackFlow,
  });

  /// Used until the server's config is fetched, and whenever the server does
  /// not expose the endpoint yet. Mirrors customers/digisol/config.yaml.
  static const fallback = TenantUiConfig(
    title: 'Digisol AI Support Agent',
    subtitle: '',
    primaryColor: Color(0xFF1A56A0),
    welcomeMessage:
        "Hello! I'm the **Digisol Support Agent**. How can I help you today?",
    inputPlaceholder: 'Ask a question about Digisol products or support...',
    quickQuestions: [],
    hasGuidedFlow: true,
    hasFeedbackFlow: true,
  );

  final String title;
  final String subtitle;
  final Color primaryColor;
  final String welcomeMessage;
  final String inputPlaceholder;
  final List<QuickQuestion> quickQuestions;
  final bool hasGuidedFlow;
  final bool hasFeedbackFlow;

  factory TenantUiConfig.fromJson(Map<String, dynamic> json) {
    String str(String key, String orElse) {
      final v = json[key]?.toString().trim() ?? '';
      return v.isEmpty ? orElse : v;
    }

    final theme = json['theme'];
    final quick = json['quick_questions'];
    return TenantUiConfig(
      title: str('title', fallback.title),
      subtitle: str('subtitle', ''),
      primaryColor:
          parseHexColor(theme is Map ? theme['primary'] : null) ??
          fallback.primaryColor,
      welcomeMessage: str('welcome_message', fallback.welcomeMessage),
      inputPlaceholder: str('input_placeholder', fallback.inputPlaceholder),
      quickQuestions: [
        if (quick is List)
          for (final q in quick)
            if (q is Map && (q['text']?.toString() ?? '').isNotEmpty)
              QuickQuestion(
                label: q['label']?.toString() ?? q['text'].toString(),
                text: q['text'].toString(),
              ),
      ],
      hasGuidedFlow: json['has_guided_flow'] == true,
      hasFeedbackFlow: json['has_feedback_flow'] == true,
    );
  }

  /// Same shape as the server's response, so a cached copy reloads through
  /// [TenantUiConfig.fromJson].
  Map<String, Object> toJson() => {
    'title': title,
    'subtitle': subtitle,
    'theme': {
      'primary':
          '#${(primaryColor.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
    },
    'welcome_message': welcomeMessage,
    'input_placeholder': inputPlaceholder,
    'quick_questions': [
      for (final q in quickQuestions) {'label': q.label, 'text': q.text},
    ],
    'has_guided_flow': hasGuidedFlow,
    'has_feedback_flow': hasFeedbackFlow,
  };
}

/// Parses `#rrggbb` / `rrggbb`; returns null for anything else.
Color? parseHexColor(Object? value) {
  if (value is! String) return null;
  final hex = value.trim().replaceFirst('#', '');
  if (hex.length != 6) return null;
  final rgb = int.tryParse(hex, radix: 16);
  return rgb == null ? null : Color(0xFF000000 | rgb);
}
