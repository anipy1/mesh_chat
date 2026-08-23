import 'package:flutter/material.dart';

import 'ui/home_page.dart';

void main() {
  // TODO (Part 4): show build errors on screen. In a release build the default
  // error widget is a plain grey box, so an exception thrown while building
  // looks identical to "the UI never started".
  runApp(const MeshChatApp());
}

class MeshChatApp extends StatelessWidget {
  const MeshChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'mesh chat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const HomePage(),
    );
  }
}
