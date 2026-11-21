import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

/// Locks the entire signed-in Navigator until a fingerprint/face check passes.
/// This is an app lock, not a replacement for Firebase login or E2EE.
class BiometricGate extends StatefulWidget {
  const BiometricGate({super.key, required this.child});

  final Widget child;

  /// A trusted Android/iOS system picker OR one-time microphone permission
  /// dialog temporarily obscures the app. Only suppress lifecycle relocking
  /// while awaiting that specific system interaction. Once it finishes, normal
  /// Home/background locking applies again.
  static Future<T> withSystemPicker<T>(
    BuildContext context,
    Future<T> Function() pick,
  ) async {
    final gate = context.findAncestorStateOfType<_BiometricGateState>();
    if (gate == null) {
      return pick();
    }
    return gate._withSystemPicker(pick);
  }

  @override
  State<BiometricGate> createState() => _BiometricGateState();
}

class _BiometricGateState extends State<BiometricGate>
    with WidgetsBindingObserver {
  final LocalAuthentication _auth = LocalAuthentication();

  bool _locked = true;
  bool _hasUnlockedOnce = false;
  bool _authenticating = false;
  bool _manualRetryRequired = false;
  int _systemPickerCount = 0;
  String? _error;

  Future<T> _withSystemPicker<T>(Future<T> Function() pick) async {
    _systemPickerCount++;
    try {
      return await pick();
    } finally {
      _systemPickerCount--;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _unlock();
      }
    });
  }

  Future<void> _unlock() async {
    if (!mounted || _authenticating || !_locked) return;
    setState(() {
      _authenticating = true;
      _manualRetryRequired = false;
      _error = null;
    });

    try {
      final biometrics = await _auth.getAvailableBiometrics();
      if (!mounted) return;

      if (biometrics.isEmpty) {
        setState(() {
          _manualRetryRequired = true;
          _error = 'No biometrics are enrolled. '
              'Set up fingerprint or face recognition in device settings.';
        });
        return;
      }

      final authenticated = await _auth.authenticate(
        localizedReason: 'Use biometrics to unlock Secure Messenger',
        biometricOnly: true,
        persistAcrossBackgrounding: false,
      );
      if (!mounted) return;

      setState(() {
        _locked = !authenticated;
        if (authenticated) _hasUnlockedOnce = true;
        _manualRetryRequired = !authenticated;
        _error = authenticated
            ? null
            : 'Authentication canceled. Tap Unlock to try again.';
      });
    } on LocalAuthException catch (error) {
      if (!mounted) return;
      setState(() {
        _manualRetryRequired = true;
        _error = 'Biometric authentication failed: ${error.code.name}';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _manualRetryRequired = true;
        _error = 'Could not use biometric authentication.';
      });
    } finally {
      if (mounted) {
        setState(() => _authenticating = false);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      // Photo/video selection opens a separate trusted Android activity.
      // A real Home/background action outside that window still locks.
      if (_systemPickerCount == 0 && !_locked) {
        setState(() => _locked = true);
      }
      return;
    }

    if (state == AppLifecycleState.resumed &&
        _locked &&
        !_authenticating &&
        !_manualRetryRequired) {
      _unlock();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Before the first unlock, do not mount any sensitive chat routes.
    if (!_hasUnlockedOnce) return _buildLockScreen();

    // After the first unlock, keep the nested Navigator mounted when the app
    // relocks. Offstage completely hides it and disables input; TickerMode
    // prevents hidden animations. The lock screen is painted on top.
    // This avoids losing the open chat route upon permission/lifecycle events.
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(
          offstage: _locked,
          child: TickerMode(
            enabled: !_locked,
            child: widget.child,
          ),
        ),
        if (_locked) _buildLockScreen(),
      ],
    );
  }

  Widget _buildLockScreen() {
    return Scaffold(
      appBar: AppBar(title: const Text('Secure Messenger')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, size: 62),
                const SizedBox(height: 18),
                Text('App locked',
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 8),
                const Text(
                  'Verify your fingerprint or face before viewing messages.',
                  textAlign: TextAlign.center,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 22),
                FilledButton.icon(
                  onPressed: _authenticating ? null : _unlock,
                  icon: const Icon(Icons.fingerprint),
                  label: Text(_authenticating ? 'Checking...' : 'Unlock'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _authenticating
                      ? null
                      : () async {
                          await FirebaseAuth.instance.signOut();
                        },
                  child: const Text('Sign out instead'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
