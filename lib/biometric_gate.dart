
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

/// Protects the signed-in app using device biometrics.
///
/// This is an app lock, not Firebase authentication
/// or end-to-end encryption.
class BiometricGate extends StatefulWidget {
  const BiometricGate({
    super.key,
    required this.child,
  });

  final Widget child;

  @override
  State<BiometricGate> createState() => _BiometricGateState();
}

class _BiometricGateState extends State<BiometricGate>
    with WidgetsBindingObserver {
  final LocalAuthentication _auth = LocalAuthentication();

  bool _locked = true;
  bool _authenticating = false;
  bool _manualRetryRequired = false;

  String? _error;

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
    if (!mounted || _authenticating) return;

    setState(() {
      _authenticating = true;
      _manualRetryRequired = false;
      _error = null;
    });

    try {
      // Check whether biometrics are enrolled.
      final biometrics = await _auth.getAvailableBiometrics();

      if (!mounted) return;

      if (biometrics.isEmpty) {
        setState(() {
          _manualRetryRequired = true;
          _error =
              'No biometrics are enrolled. '
              'Set up fingerprint or face recognition '
              'in your device settings.';
        });
        return;
      }

      // Ask Android or iOS to authenticate.
      final authenticated = await _auth.authenticate(
        localizedReason:
            'Use your biometrics to unlock Secure Messenger',
        biometricOnly: true,

        // We handle background locking ourselves.
        // This avoids automatic plugin retries.
        persistAcrossBackgrounding: false,
      );

      if (!mounted) return;

      setState(() {
        _locked = !authenticated;

        // Do not automatically prompt again after
        // a canceled or unsuccessful attempt.
        _manualRetryRequired = !authenticated;

        _error = authenticated
            ? null
            : 'Authentication canceled. '
                'Tap Unlock to try again.';
      });
    } on LocalAuthException catch (error) {
      if (!mounted) return;

      setState(() {
        _manualRetryRequired = true;
        _error =
            'Biometric authentication failed: '
            '${error.code.name}';
      });
    } catch (_) {
      if (!mounted) return;

      setState(() {
        _manualRetryRequired = true;
        _error = 'Could not use biometric authentication.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _authenticating = false;
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;

    // Lock the app when it leaves the foreground.
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      if (!_locked) {
        setState(() {
          _locked = true;
        });
      }

      return;
    }

    // Automatically ask for fingerprint when
    // returning from the background.
    //
    // But NEVER reopen the prompt automatically
    // after the user cancels or authentication fails.
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
    // Show the actual app only after successful unlock.
    if (!_locked) {
      return widget.child;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Secure Messenger'),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.lock_outline,
                  size: 62,
                ),

                const SizedBox(height: 18),

                Text(
                  'App locked',
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall,
                ),

                const SizedBox(height: 8),

                const Text(
                  'Verify your fingerprint or face '
                  'to access Secure Messenger.',
                  textAlign: TextAlign.center,
                ),

                if (_error != null) ...[
                  const SizedBox(height: 16),

                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context)
                          .colorScheme
                          .error,
                    ),
                  ),
                ],

                const SizedBox(height: 22),

                FilledButton.icon(
                  onPressed: _authenticating
                      ? null
                      : _unlock,
                  icon: const Icon(Icons.fingerprint),
                  label: Text(
                    _authenticating
                        ? 'Checking...'
                        : 'Unlock',
                  ),
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
