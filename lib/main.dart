import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat/chat_controller.dart';
import 'chat/chat_screen.dart';
import 'chat/chat_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(
    ProviderScope(
      overrides: [keyValueStoreProvider.overrideWithValue(PrefsStore(prefs))],
      child: const SupportApp(),
    ),
  );
}

class SupportApp extends ConsumerWidget {
  const SupportApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final title = ref.watch(chatControllerProvider.select((s) => s.ui.title));
    final primary = ref.watch(
      chatControllerProvider.select((s) => s.ui.primaryColor),
    );
    return MaterialApp(
      title: title,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: primary,
        ).copyWith(primary: primary),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: primary,
          brightness: Brightness.dark,
        ),
      ),
      home: const ChatScreen(),
    );
  }
}
