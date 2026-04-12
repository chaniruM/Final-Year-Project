import 'package:flutter/material.dart';
import '../data/calibration_service.dart';
import 'calibration_view.dart';
import 'widgets/profile_stat_card.dart';

class ProfileView extends StatefulWidget {
  const ProfileView({super.key});

  @override
  State<ProfileView> createState() => _ProfileViewState();
}

class _ProfileViewState extends State<ProfileView> {
  final CalibrationService _calibrationService = CalibrationService();

  bool _isLoading = true;
  double? _earThreshold;
  double? _perclosBaseline;
  double? _marThreshold;
  double? _baselinePitch;
  String _statusMessage = "Loading...";

  @override
  void initState() {
    super.initState();
    _loadProfileData();
  }

  Future<void> _loadProfileData() async {
    final baselines = await _calibrationService.getBaselines();
    setState(() {
      _earThreshold = baselines['threshold'];
      _perclosBaseline = baselines['perclos'];
      _marThreshold = baselines['mar'];
      _baselinePitch = baselines['pitch'];
      _isLoading = false;

      if (_earThreshold == null || _earThreshold == 0.0) {
        _statusMessage = "Not Calibrated Yet";
      } else {
        _statusMessage = "Calibrated Active";
      }
    });
  }

  Future<void> _navigateToCalibration() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const CalibrationView()),
    );
    _loadProfileData();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Driver Profile"),
        centerTitle: true,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const CircleAvatar(
              radius: 50,
              backgroundColor: Colors.blueAccent,
              child: Icon(Icons.person, size: 60, color: Colors.white),
            ),
            const SizedBox(height: 16),
            const Text(
              "Current Driver",
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            Text(
              _statusMessage,
              style: TextStyle(
                fontSize: 16,
                color: _earThreshold != null && _earThreshold! > 0
                    ? Colors.green
                    : Colors.grey,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 32),
            ProfileStatCard(
              earThreshold: _earThreshold,
              marThreshold: _marThreshold,
              perclosBaseline: _perclosBaseline,
              baselinePitch: _baselinePitch,
            ),
            const SizedBox(height: 30),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                onPressed: _navigateToCalibration,
                icon: const Icon(Icons.settings_accessibility),
                label: const Text("Recalibrate System"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueAccent,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              "Recalibrate if you change your driving position, wear new glasses, or drive at night.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}