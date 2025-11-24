import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter/foundation.dart';
import 'package:scoreboard_widget/scoreboard_widget.dart';

void main() async {
  await dotenv.load(fileName: '.env');
  if (kIsWeb) {
    WidgetsFlutterBinding.ensureInitialized();
  }
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: ScoreboardWidget(),
      ),
    );
  }
}
