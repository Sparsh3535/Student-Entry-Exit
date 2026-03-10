import 'package:flutter/material.dart';

import '../server_service.dart';
import 'day_scholar.dart';
import 'hostel_screen.dart';
import 'leave_applications.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ServerService _serverService = ServerService();
  final TextEditingController _portController = TextEditingController(text: '9000');

  @override
  void initState() {
    super.initState();
    _serverService.startServer(port: int.tryParse(_portController.text) ?? 9000);
  }

  @override
  void dispose() {
    _portController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Student Entry/Exit Dashboard'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          children: [
            // Top row of cards
            Row(
              children: [
                Expanded(
                  child: _buildNavCard(
                    title: 'Hostel',
                    icon: Icons.home_work,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const HostelScreen()),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildNavCard(
                    title: 'Day Scholars',
                    icon: Icons.person,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const DayScholarScreen()),
                      );
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Second row of cards
            Row(
              children: [
                Expanded(
                  child: _buildNavCard(
                    title: 'Leave Applications',
                    icon: Icons.article,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const LeaveApplicationsScreen()),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ValueListenableBuilder<bool>(
                    valueListenable: _serverService.listening,
                    builder: (context, isListening, child) {
                      return _buildInfoCard(
                        title: 'Server Status',
                        value: isListening ? 'Listening' : 'Stopped',
                        color: isListening ? Colors.green : Colors.red,
                      );
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            // Console area
            Expanded(
              child: _buildConsoleView(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavCard({
    required String title,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              Icon(icon, size: 48, color: Theme.of(context).primaryColor),
              const SizedBox(height: 12),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoCard({
    required String title,
    required String value,
    Color? color,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Text(
              value,
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConsoleView() {
    return Card(
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: Colors.grey.shade200,
            child: Row(
              children: [
                const Text(
                  'Console',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Clear Console',
                  icon: const Icon(Icons.delete),
                  onPressed: () {
                    _serverService.clearLogs();
                  },
                ),
              ],
            ),
          ),
          Expanded(
            child: ValueListenableBuilder<List<String>>(
              valueListenable: _serverService.logsNotifier,
              builder: (context, logs, child) {
                if (logs.isEmpty) {
                  return const Center(child: Text('No logs yet.'));
                }
                return ListView.builder(
                  reverse: true,
                  itemCount: logs.length,
                  itemBuilder: (context, idx) {
                    final text = logs[idx];
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8.0, vertical: 2.0),
                      child: Text(text, style: const TextStyle(fontSize: 12)),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
