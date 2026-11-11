import 'package:digisol_support/api/models.dart';
import 'package:digisol_support/chat/chat_controller.dart';
import 'package:digisol_support/chat/connectivity.dart';
import 'package:digisol_support/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_chat_api.dart';

void main() {
  late FakeChatApi api;

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatApiProvider.overrideWithValue(api),
          onlineProvider.overrideWith((ref) => Stream.value(true)),
        ],
        child: const SupportApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder rich(String text) => find.textContaining(text, findRichText: true);

  setUp(() {
    api = FakeChatApi()..reply(menuReply);
  });

  testWidgets('shows the welcome, the menu text and its buttons', (
    tester,
  ) async {
    await pumpApp(tester);

    expect(find.text('Test Support'), findsOneWidget);
    expect(rich('Welcome!'), findsOneWidget);
    expect(rich('Pick a category:'), findsOneWidget);
    expect(
      find.widgetWithText(OutlinedButton, 'Product Enquiry'),
      findsOneWidget,
    );
    expect(find.widgetWithText(OutlinedButton, 'Warranty'), findsOneWidget);
  });

  testWidgets(
    'tapping a button answers with its label and removes the buttons',
    (tester) async {
      await pumpApp(tester);
      api.reply(const [
        CompleteEvent('Share the **model number**.'),
        DoneEvent(),
      ]);

      await tester.tap(find.text('Warranty'));
      await tester.pumpAndSettle();

      expect(api.requests.last, {'question': 'warranty_check'});
      expect(find.byType(OutlinedButton), findsNothing);
      expect(find.text('Warranty'), findsOneWidget); // now the user's bubble
      expect(rich('model number'), findsOneWidget);
    },
  );

  testWidgets('typing and pressing send posts the question', (tester) async {
    await pumpApp(tester);
    api.reply(const [CompleteEvent('Two years.'), DoneEvent()]);

    await tester.enterText(find.byType(TextField), 'warranty period?');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    expect(api.requests.last, {'question': 'warranty period?'});
    expect(find.text('warranty period?'), findsOneWidget);
    expect(rich('Two years.'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
  });

  testWidgets('new chat asks for confirmation before discarding', (
    tester,
  ) async {
    await pumpApp(tester);

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New chat'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Start a new chat?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(api.resets, isEmpty);

    api.reply(menuReply);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New chat'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(api.resets, ['conv-1']);
    expect(find.widgetWithText(OutlinedButton, 'Warranty'), findsOneWidget);
  });

  testWidgets('a failed request shows the error in the chat', (tester) async {
    await pumpApp(tester);
    // No scripted reply: the fake fails like an unreachable server.

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    expect(rich('Cannot reach the server.'), findsOneWidget);
  });
}
