import 'dart:ui' show Color;
import 'dart:async';

import 'package:digisol_support/api/chat_api.dart';
import 'package:digisol_support/api/models.dart';
import 'package:digisol_support/config/app_config.dart';

const guidedUi = TenantUiConfig(
  title: 'Test Support',
  subtitle: '',
  primaryColor: Color(0xFF1A56A0),
  welcomeMessage: 'Welcome!',
  inputPlaceholder: 'Ask something',
  quickQuestions: [],
  hasGuidedFlow: true,
  hasFeedbackFlow: true,
);

const menuReply = <ChatEvent>[
  MetaEvent(conversationId: 'conv-1'),
  OptionsEvent(
    text: 'Pick a category:',
    options: [
      ChatOption(label: 'Product Enquiry', value: 'product_enquiry'),
      ChatOption(label: 'Warranty', value: 'warranty_check'),
    ],
  ),
  DoneEvent(),
];

/// Records requests and plays back scripted replies, one per call to [send].
class FakeChatApi implements ChatApi {
  FakeChatApi({this.ui = guidedUi});

  /// Null makes [fetchUiConfig] fail, like a server without the endpoint.
  TenantUiConfig? ui;

  final replies = <Stream<ChatEvent>>[];
  final requests = <Map<String, Object>>[];
  final conversationIds = <String?>[];
  final resets = <String>[];

  void reply(List<ChatEvent> events) =>
      replies.add(Stream.fromIterable(events));

  @override
  AppConfig get config =>
      const AppConfig(baseUrl: 'http://fake.test', tenantId: 'digisol');

  @override
  Stream<ChatEvent> send(ChatRequest request, {String? conversationId}) {
    requests.add(request.toJson());
    conversationIds.add(conversationId);
    if (replies.isEmpty) {
      return Stream.error(const ChatApiException('Cannot reach the server.'));
    }
    return replies.removeAt(0);
  }

  @override
  Future<void> reset(String conversationId) async => resets.add(conversationId);

  @override
  Future<TenantUiConfig> fetchUiConfig() async =>
      ui ?? (throw const ChatApiException('nope', statusCode: 404));

  @override
  void close() {}
}
