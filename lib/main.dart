import 'package:flutter/material.dart';

import 'identity/identity_store.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // In a release build the default ErrorWidget paints a plain grey rectangle,
  // so a build-time exception is indistinguishable from "the UI never ran".
  // This is a spike whose whole job is to be diagnosed on real hardware, so
  // show the exception on screen instead.
  ErrorWidget.builder = (details) => Material(
        color: const Color(0xFF7F1D1D),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(
              child: Text(
                details.exceptionAsString(),
                style: const TextStyle(
                  color: Colors.white,
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ),
      );
  // The identity has to exist before the mesh does, because the node id is
  // derived from it and goes out in the first advertisement. Reading the
  // keystore can fail, and failing here would leave the same blank screen this
  // ErrorWidget exists to avoid, so the failure gets its own screen.
  try {
    final loaded = await const IdentityStore().loadOrCreate();
    runApp(App(loaded: loaded));
  } catch (e, stack) {
    runApp(_StartupFailure('identity could not be loaded\n\n$e\n\n$stack'));
  }
}

class App extends StatelessWidget {
  const App({super.key, required this.loaded});

  final LoadedIdentity loaded;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE mesh spike',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: HomePage(loaded: loaded),
    );
  }
}

class _StartupFailure extends StatelessWidget {
  const _StartupFailure(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Material(
        color: const Color(0xFF7F1D1D),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(
              child: Text(
                message,
                style: const TextStyle(
                  color: Colors.white,
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
