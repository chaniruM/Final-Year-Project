import 'package:flutter/material.dart';
import 'features/detector/presentation/detector_view.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DriveSafeApp());
}

class DriveSafeApp extends StatelessWidget {
  const DriveSafeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Drive Safe',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.red),
        useMaterial3: true,
      ),
      home: const DetectorView(),
    );
  }
}
