import 'dart:ui';
import 'package:flutter/material.dart';
import 'calibration_view.dart';

class CalibrationInstructionsView extends StatelessWidget {
  const CalibrationInstructionsView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Background Gradient Elements
          Positioned(
            top: -100,
            left: -100,
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.cyanAccent.withOpacity(0.15),
                boxShadow: [
                  BoxShadow(color: Colors.cyanAccent.withOpacity(0.2), blurRadius: 100, spreadRadius: 100),
                ]
              ),
            ),
          ),
          Positioned(
            bottom: -50,
            right: -50,
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.purpleAccent.withOpacity(0.15),
                boxShadow: [
                  BoxShadow(color: Colors.purpleAccent.withOpacity(0.2), blurRadius: 100, spreadRadius: 100),
                ]
              ),
            ),
          ),
          
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32.0, vertical: 24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withOpacity(0.05),
                      border: Border.all(color: Colors.white12, width: 1),
                    ),
                    child: const Icon(
                      Icons.tune,
                      size: 80,
                      color: Colors.cyanAccent,
                    ),
                  ),
                  const SizedBox(height: 40),
                  const Text(
                    "Calibration Setup",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    "To ensure accurate monitoring, we need to calibrate your personal baseline. Please follow these steps carefully:",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.white70,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 40),
                  
                  // Instruction Items
                  _buildInstructionItem(
                    icon: Icons.face_retouching_natural,
                    title: "Neutral Expression",
                    description: "Keep your face completely relaxed without smiling or frowning.",
                  ),
                  const SizedBox(height: 20),
                  _buildInstructionItem(
                    icon: Icons.straight,
                    title: "Look Straight",
                    description: "Stare directly into the camera as if looking at the road ahead.",
                  ),
                  const SizedBox(height: 20),
                  _buildInstructionItem(
                    icon: Icons.brightness_high,
                    title: "Good Lighting",
                    description: "Ensure your face is well-lit and clearly visible.",
                  ),
                  
                  const Spacer(),
                  
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () async {
                        // Push CalibrationView and wait for it
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => const CalibrationView(),
                          ),
                        );
                        // When CalibrationView completes and pops, pop this view as well
                        if (context.mounted) {
                          Navigator.pop(context);
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.cyanAccent,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30),
                        ),
                        elevation: 8,
                        shadowColor: Colors.cyanAccent.withOpacity(0.5),
                      ),
                      child: const Text(
                        "START CALIBRATION",
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, letterSpacing: 1.1),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInstructionItem({required IconData icon, required String title, required String description}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.08),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(icon, color: Colors.cyanAccent, size: 28),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                description,
                style: const TextStyle(
                  color: Colors.white60,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
