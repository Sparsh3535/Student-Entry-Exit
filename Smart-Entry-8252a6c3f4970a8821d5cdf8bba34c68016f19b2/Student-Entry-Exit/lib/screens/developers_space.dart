import 'package:flutter/material.dart';
import '../managers/app_version_service.dart';
import '../managers/auth_email_service.dart';
import '../managers/google_auth_service.dart';

class DevelopersSpaceScreen extends StatefulWidget {
  const DevelopersSpaceScreen({super.key});

  @override
  State<DevelopersSpaceScreen> createState() => _DevelopersSpaceScreenState();
}

class _DevelopersSpaceScreenState extends State<DevelopersSpaceScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _singleController = TextEditingController();
  final TextEditingController _multiController = TextEditingController();
  final TextEditingController _authEmailController = TextEditingController();
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    final isMulti = AppVersionService().mode == 'multi';
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: isMulti ? 1 : 0,
    );
    _loadCurrentState();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _singleController.dispose();
    _multiController.dispose();
    _authEmailController.dispose();
    super.dispose();
  }

  void _loadCurrentState() {
    final svc = AppVersionService();
    if (svc.mode == 'single' && svc.isSet) {
      _singleController.text = svc.requiredVersion;
    }
  }

  // ── Single mode ──────────────────────────────────────────────────────

  Future<void> _saveSingle() async {
    final input = _singleController.text.trim();
    if (input.isEmpty) {
      _showSnack('Please enter a version', Colors.orange);
      return;
    }
    setState(() => _isSaving = true);
    await AppVersionService().saveSingle(input);
    setState(() => _isSaving = false);
    _showSnack('✓ Version set to $input', Colors.green.shade600);
  }

  // ── Multi mode ───────────────────────────────────────────────────────

  Future<void> _addVersion() async {
    final input = _multiController.text.trim();
    if (input.isEmpty) {
      _showSnack('Please enter a version to add', Colors.orange);
      return;
    }
    // Check duplicate
    final existing = AppVersionService().allowedVersions;
    if (existing.any((v) => v.toLowerCase() == input.toLowerCase())) {
      _showSnack('Version $input already in the list', Colors.orange);
      return;
    }
    await AppVersionService().addVersion(input);
    _multiController.clear();
    setState(() {});
    _showSnack('✓ Added $input', Colors.green.shade600);
  }

  Future<void> _removeVersion(String version) async {
    await AppVersionService().removeVersion(version);
    setState(() {});
    _showSnack('Removed $version', Colors.blueGrey);
  }

  Future<void> _clearAll() async {
    await AppVersionService().clear();
    _singleController.clear();
    _multiController.clear();
    setState(() {});
    _showSnack('✓ All version restrictions cleared', Colors.blueGrey);
  }

  void _showSnack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color),
    );
  }

  // ── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FA),
      appBar: AppBar(
        title: const Text(
          'Developers Space',
          style: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0.3),
        ),
        elevation: 0,
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF37474F), Color(0xFF546E7A)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Status card ──
                _buildStatusCard(),
                const SizedBox(height: 24),

                // ── Main card with tabs ──
                Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.06),
                        blurRadius: 16,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Heading
                      Padding(
                        padding: const EdgeInsets.fromLTRB(28, 28, 28, 0),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color:
                                    const Color(0xFF37474F).withOpacity(0.1),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(Icons.phone_android,
                                  color: Color(0xFF37474F), size: 24),
                            ),
                            const SizedBox(width: 14),
                            const Expanded(
                              child: Text(
                                'Adjust Mobile App Version',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF1A1A2E),
                                  letterSpacing: 0.3,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 28),
                        child: Text(
                          'Set which app version(s) students must have to be allowed entry.',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey.shade600,
                            height: 1.5,
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),

                      // Tab bar
                      Container(
                        margin: const EdgeInsets.symmetric(horizontal: 28),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: TabBar(
                          controller: _tabController,
                          indicator: BoxDecoration(
                            color: const Color(0xFF37474F),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          indicatorSize: TabBarIndicatorSize.tab,
                          labelColor: Colors.white,
                          unselectedLabelColor: Colors.grey.shade700,
                          labelStyle: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                          dividerHeight: 0,
                          tabs: const [
                            Tab(text: 'Single Version'),
                            Tab(text: 'Multiple Versions'),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),

                      // Tab content
                      SizedBox(
                        height: _tabController.index == 1
                            ? _calcMultiTabHeight()
                            : 220,
                        child: AnimatedBuilder(
                          animation: _tabController,
                          builder: (_, __) {
                            // Re-calculate height when tab changes
                            return IndexedStack(
                              index: _tabController.index,
                              children: [
                                _buildSingleTab(),
                                _buildMultiTab(),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 20),

                // Info box
                _buildInfoBox(),

                const SizedBox(height: 28),

                // ── Authentication Email Change ──
                _buildAuthEmailSection(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  double _calcMultiTabHeight() {
    final count = AppVersionService().allowedVersions.length;
    // Base height + chip rows (roughly 50px per row of ~3 chips)
    return 220.0 + (count > 0 ? 60.0 : 0.0);
  }

  // ── Status card ────────────────────────────────────────────────────

  Widget _buildStatusCard() {
    final svc = AppVersionService();
    if (!svc.isSet) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.orange.shade50,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.orange.shade200),
        ),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded,
                color: Colors.orange.shade700, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'No version restriction set — all app versions are currently allowed.',
                style: TextStyle(
                  color: Colors.orange.shade800,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final versions = svc.allowedVersions;
    final isMulti = versions.length > 1;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.green.shade600, Colors.green.shade400],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.green.withOpacity(0.3),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.2),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.check_circle,
                color: Colors.white, size: 28),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isMulti
                      ? 'Allowed Versions (${versions.length})'
                      : 'Active Version',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 6),
                if (isMulti)
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: versions
                        .map((v) => Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                    color: Colors.white.withOpacity(0.4)),
                              ),
                              child: Text(v,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 0.5,
                                  )),
                            ))
                        .toList(),
                  )
                else
                  Text(
                    versions.first,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            onPressed: _clearAll,
            icon: const Icon(Icons.close, color: Colors.white70),
            tooltip: 'Clear all version restrictions',
          ),
        ],
      ),
    );
  }

  // ── Single version tab ─────────────────────────────────────────────

  Widget _buildSingleTab() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Enter one version that all students must have:',
            style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 16),
          // Input field
          SizedBox(
            height: 56,
            child: TextField(
              controller: _singleController,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
              ),
              decoration: InputDecoration(
                hintText: 'e.g. 4.0.0',
                hintStyle: TextStyle(
                  color: Colors.grey.shade400,
                  fontWeight: FontWeight.normal,
                  fontSize: 18,
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(
                      color: Color(0xFF37474F), width: 2),
                ),
                filled: true,
                fillColor: Colors.grey.shade50,
              ),
              onSubmitted: (_) => _saveSingle(),
            ),
          ),
          const SizedBox(height: 16),
          // Save button
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton.icon(
              onPressed: _isSaving ? null : _saveSingle,
              icon: _isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.save, size: 20),
              label: Text(
                _isSaving ? 'Saving...' : 'Save Version',
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF37474F),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                elevation: 2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Multiple versions tab ──────────────────────────────────────────

  Widget _buildMultiTab() {
    final versions = AppVersionService().allowedVersions;

    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Add multiple allowed versions:',
            style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 16),
          // Input + Add button
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: TextField(
                    controller: _multiController,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1,
                    ),
                    decoration: InputDecoration(
                      hintText: 'e.g. 4.0.0',
                      hintStyle: TextStyle(
                        color: Colors.grey.shade400,
                        fontWeight: FontWeight.normal,
                      ),
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide:
                            BorderSide(color: Colors.grey.shade300),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide:
                            BorderSide(color: Colors.grey.shade300),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                            color: Color(0xFF37474F), width: 2),
                      ),
                      filled: true,
                      fillColor: Colors.grey.shade50,
                    ),
                    onSubmitted: (_) => _addVersion(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: _addVersion,
                  icon: const Icon(Icons.add, size: 20),
                  label: const Text('Add',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF37474F),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    elevation: 0,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Version chips
          if (versions.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(10),
                border:
                    Border.all(color: Colors.grey.shade200, style: BorderStyle.solid),
              ),
              child: Text(
                'No versions added yet.\nType a version above and tap "Add".',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.grey.shade500,
                  fontSize: 13,
                ),
              ),
            )
          else
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: versions.map((v) {
                  return Chip(
                    label: Text(
                      v,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        letterSpacing: 0.5,
                        color: Color(0xFF37474F),
                      ),
                    ),
                    deleteIcon: Icon(Icons.close,
                        size: 18, color: Colors.red.shade400),
                    onDeleted: () => _removeVersion(v),
                    backgroundColor: Colors.white,
                    side: BorderSide(
                        color: const Color(0xFF37474F).withOpacity(0.3)),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                  );
                }).toList(),
              ),
            ),

          if (versions.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              '${versions.length} version(s) allowed',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade500,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Info box ───────────────────────────────────────────────────────

  Widget _buildInfoBox() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.blue.shade100),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, color: Colors.blue.shade700, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'When a QR code is scanned, the system checks the student\'s '
              'app version against the allowed version(s). If it doesn\'t match, '
              'the scan is blocked and a warning is shown.',
              style: TextStyle(
                color: Colors.blue.shade800,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Authentication Email Change Section ──────────────────────────────
  Widget _buildAuthEmailSection() {
    final authSvc = AuthEmailService();
    final currentEmail = authSvc.allowedEmail;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0288D1).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.admin_panel_settings,
                      color: Color(0xFF0288D1), size: 24),
                ),
                const SizedBox(width: 14),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Authentication Email',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF263238),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Change the authorized login email',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ],
            ),

            const SizedBox(height: 20),

            // Current email display
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.green.shade200),
              ),
              child: Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.green.shade600, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Current: $currentEmail',
                      style: TextStyle(
                        color: Colors.green.shade800,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 18),

            // New email input
            TextField(
              controller: _authEmailController,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: 'New authorized email',
                hintText: 'e.g. user@nitgoa.ac.in',
                prefixIcon: const Icon(Icons.email_outlined, size: 20),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFF0288D1), width: 2),
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Save button
            SizedBox(
              width: double.infinity,
              height: 46,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.save_rounded, size: 20),
                label: const Text(
                  'Update Authentication Email',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0288D1),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                ),
                onPressed: () async {
                  final newEmail = _authEmailController.text.trim();
                  if (newEmail.isEmpty) {
                    _showSnack('Please enter an email address', Colors.orange);
                    return;
                  }
                  if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(newEmail)) {
                    _showSnack('Please enter a valid email address', Colors.red);
                    return;
                  }
                  await authSvc.setAllowedEmail(newEmail);
                  _authEmailController.clear();
                  setState(() {});
                  _showSnack('✓ Auth email updated to: $newEmail', Colors.green);
                },
              ),
            ),

            const SizedBox(height: 12),

            // Info text
            Text(
              'The user must sign in with this email to access the app. '
              'After changing, the current session remains active until sign-out.',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade500,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
