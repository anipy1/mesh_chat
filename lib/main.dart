import 'package:flutter/material.dart';

import 'ui/home_page.dart';

void main() {
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
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE mesh spike',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const HomePage(),
    );
  }
}
