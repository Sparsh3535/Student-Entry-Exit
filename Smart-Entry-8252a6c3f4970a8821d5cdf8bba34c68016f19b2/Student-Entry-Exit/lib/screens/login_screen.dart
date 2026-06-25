import 'package:flutter/material.dart';
import '../managers/auth_email_service.dart';
import '../managers/google_auth_service.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  bool _isLoading = false;
  String? _statusMessage;
  bool _isError = false;
  bool _needsSetup = false;

  late AnimationController _animController;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fadeAnim = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOut,
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOut,
    ));
    _animController.forward();

    _checkSetup();
  }

  void _checkSetup() {
    final googleAuth = GoogleAuthService();
    if (!googleAuth.isConfigured) {
      setState(() => _needsSetup = true);
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  Future<void> _handleGoogleSignIn() async {
    final googleAuth = GoogleAuthService();
    if (!googleAuth.isConfigured) {
      setState(() {
        _isError = true;
        _statusMessage =
            'Google OAuth not configured. Please set up Client ID in Developers Space first.';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _statusMessage = null;
      _isError = false;
    });

    final user = await googleAuth.signInWithGoogle(
      onStatusUpdate: (status) {
        if (mounted) {
          setState(() => _statusMessage = status);
        }
      },
    );

    if (!mounted) return;

    if (user == null) {
      setState(() {
        _isLoading = false;
        _isError = true;
        _statusMessage ??= 'Sign-in failed. Please try again.';
      });
      return;
    }

    // Check if this email is allowed
    final email = user.email ?? '';
    final authSvc = AuthEmailService();
    if (!authSvc.isAllowedEmail(email)) {
      setState(() {
        _isLoading = false;
        _isError = true;
        _statusMessage =
            'Access denied. "$email" is not the authorized email.\nAuthorized: ${authSvc.allowedEmail}';
      });
      // Sign out the unauthorized user
      await googleAuth.signOut();
      return;
    }

    // Success — save login state and navigate
    await authSvc.login(email);

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  void _showSetupDialog() {
    final clientIdCtl = TextEditingController();
    final clientSecretCtl = TextEditingController();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.settings, color: Colors.blue.shade700, size: 24),
            const SizedBox(width: 10),
            const Text('Google OAuth Setup'),
          ],
        ),
        content: SizedBox(
          width: 450,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'How to get these:',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.blue.shade800,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '1. Go to console.cloud.google.com\n'
                      '2. Select project "nit-goa-gate-system"\n'
                      '3. APIs & Services → Credentials\n'
                      '4. Create OAuth 2.0 Client ID (Desktop app)\n'
                      '5. Copy Client ID and Client Secret below',
                      style: TextStyle(
                        color: Colors.blue.shade700,
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: clientIdCtl,
                decoration: InputDecoration(
                  labelText: 'Google OAuth Client ID',
                  hintText: 'xxx.apps.googleusercontent.com',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: clientSecretCtl,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Client Secret',
                  hintText: 'GOCSPX-...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue.shade700,
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              final id = clientIdCtl.text.trim();
              final secret = clientSecretCtl.text.trim();
              if (id.isEmpty || secret.isEmpty) return;

              await GoogleAuthService().saveCredentials(id, secret);
              if (ctx.mounted) Navigator.of(ctx).pop();
              setState(() => _needsSetup = false);
            },
            child: const Text('Save & Continue'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF0D1B2A),
              Color(0xFF1B2838),
              Color(0xFF253547),
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: FadeTransition(
                opacity: _fadeAnim,
                child: SlideTransition(
                  position: _slideAnim,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Logo
                        Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFF4FC3F7), Color(0xFF0288D1)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              BoxShadow(
                                color:
                                    const Color(0xFF0288D1).withOpacity(0.4),
                                blurRadius: 20,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.security_rounded,
                            color: Colors.white,
                            size: 40,
                          ),
                        ),
                        const SizedBox(height: 28),

                        // Title
                        const Text(
                          'Security Portal',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Smart Entry & Exit System',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.5),
                            fontSize: 14,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(height: 40),

                        // Login Card
                        Container(
                          padding: const EdgeInsets.all(32),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.07),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.1),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.2),
                                blurRadius: 30,
                                offset: const Offset(0, 10),
                              ),
                            ],
                          ),
                          child: Column(
                            children: [
                              Text(
                                'Sign In',
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.9),
                                  fontSize: 20,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Use your authorized Google account',
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.4),
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(height: 28),

                              // Status / Error message
                              if (_statusMessage != null) ...[
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: _isError
                                        ? Colors.red.withOpacity(0.15)
                                        : Colors.blue.withOpacity(0.15),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: _isError
                                          ? Colors.red.withOpacity(0.3)
                                          : Colors.blue.withOpacity(0.3),
                                    ),
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Icon(
                                        _isError
                                            ? Icons.error_outline
                                            : Icons.info_outline,
                                        color: _isError
                                            ? Colors.red.shade300
                                            : Colors.blue.shade300,
                                        size: 18,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          _statusMessage!,
                                          style: TextStyle(
                                            color: _isError
                                                ? Colors.red.shade300
                                                : Colors.blue.shade300,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 20),
                              ],

                              // Google Sign-In Button
                              SizedBox(
                                width: double.infinity,
                                height: 50,
                                child: ElevatedButton(
                                  onPressed:
                                      _isLoading ? null : _handleGoogleSignIn,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.white,
                                    foregroundColor:
                                        const Color(0xFF37474F),
                                    shape: RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius.circular(14),
                                    ),
                                    elevation: 0,
                                    disabledBackgroundColor:
                                        Colors.white.withOpacity(0.5),
                                  ),
                                  child: _isLoading
                                      ? Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            SizedBox(
                                              width: 20,
                                              height: 20,
                                              child:
                                                  CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: Colors.grey.shade600,
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Text(
                                              'Signing in...',
                                              style: TextStyle(
                                                color: Colors.grey.shade600,
                                                fontSize: 15,
                                              ),
                                            ),
                                          ],
                                        )
                                      : Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            // Google "G" logo
                                            Container(
                                              width: 24,
                                              height: 24,
                                              decoration: BoxDecoration(
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                              ),
                                              child: const Text(
                                                'G',
                                                style: TextStyle(
                                                  fontSize: 20,
                                                  fontWeight: FontWeight.bold,
                                                  color: Color(0xFF4285F4),
                                                ),
                                                textAlign: TextAlign.center,
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            const Text(
                                              'Sign in with Google',
                                              style: TextStyle(
                                                fontSize: 16,
                                                fontWeight: FontWeight.w600,
                                                letterSpacing: 0.3,
                                              ),
                                            ),
                                          ],
                                        ),
                                ),
                              ),

                              // Setup link if needed
                              if (_needsSetup) ...[
                                const SizedBox(height: 16),
                                TextButton.icon(
                                  onPressed: _showSetupDialog,
                                  icon: Icon(
                                    Icons.settings,
                                    size: 16,
                                    color: Colors.amber.shade300,
                                  ),
                                  label: Text(
                                    'Configure Google OAuth',
                                    style: TextStyle(
                                      color: Colors.amber.shade300,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),

                        const SizedBox(height: 32),

                        // Footer
                        Text(
                          'NIT Goa Gate System',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.25),
                            fontSize: 12,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
