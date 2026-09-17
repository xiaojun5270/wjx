import 'package:flutter/material.dart';

import 'app_store.dart';
import 'workspace_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await AppStore.create();
  runApp(WjxAutoFillApp(store: store));
}

class WjxAutoFillApp extends StatelessWidget {
  const WjxAutoFillApp({super.key, required this.store});

  final AppStore store;

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF007AFF);
    return MaterialApp(
      title: '问卷自动填写',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: accent,
          primary: accent,
          surface: Colors.white,
        ),
        scaffoldBackgroundColor: const Color(0xFFF2F2F7),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Color(0xFF1C1C1E),
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: true,
          titleTextStyle: TextStyle(
            color: Color(0xFF1C1C1E),
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
        dividerColor: const Color(0xFFD1D1D6),
        cardTheme: const CardTheme(
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(7)),
            borderSide: BorderSide(color: Color(0xFFD1D1D6)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(7)),
            borderSide: BorderSide(color: Color(0xFFD1D1D6)),
          ),
          contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 11),
        ),
        switchTheme: SwitchThemeData(
          trackColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? accent
                : const Color(0xFFE5E5EA),
          ),
        ),
        useMaterial3: true,
      ),
      home: WorkspaceScreen(store: store),
    );
  }
}
