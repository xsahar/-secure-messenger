import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'app_theme.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _signup = false;
  bool _loading = false;
  bool _showPassword = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      final email = _email.text.trim();
      final password = _password.text;
      if (_signup) {
        await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: email, password: password);
      } else {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: email, password: password);
      }
    } on FirebaseAuthException catch (e) {
      final message = switch (e.code) {
        'email-already-in-use' => 'This email is already registered.',
        'weak-password' => 'Please choose a stronger password.',
        'invalid-email' => 'Please enter a valid email address.',
        'invalid-credential' || 'wrong-password' || 'user-not-found' =>
          'Incorrect email or password.',
        'network-request-failed' => 'Check your internet connection.',
        'too-many-requests' => 'Too many attempts. Try again later.',
        'operation-not-allowed' => 'Email/password sign-in is not enabled.',
        _ => 'Authentication failed. Please try again.',
      };
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Something went wrong. Try again.')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [Color(0xFF142B40), AppTheme.background,
              AppTheme.background],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          width: 75, height: 75,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFF276D6A), Color(0xFF17485F)],
                            ),
                            borderRadius: BorderRadius.circular(25),
                          ),
                          child: const Icon(Icons.shield_rounded,
                            color: AppTheme.accent, size: 40),
                        ),
                      ),
                      const SizedBox(height: 29),
                      const Text('YOUR CONVERSATIONS. YOUR SPACE.',
                        style: TextStyle(color: AppTheme.accent,
                          fontWeight: FontWeight.w800, fontSize: 10,
                          letterSpacing: 2.1)),
                      const SizedBox(height: 10),
                      Text(_signup ? 'Create your\naccount' : 'Welcome\nback.',
                        style: const TextStyle(fontWeight: FontWeight.w800,
                          fontSize: 41, height: 1.08, letterSpacing: -1.4)),
                      const SizedBox(height: 12),
                      Text(_signup
                          ? 'Start connecting with people you trust.'
                          : 'Sign in to pick up where you left off.',
                        style: const TextStyle(color: AppTheme.secondary,
                          fontSize: 14)),
                      const SizedBox(height: 34),
                      TextFormField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.email],
                        decoration: const InputDecoration(
                          labelText: 'Email address',
                          prefixIcon: Icon(Icons.mail_outline_rounded)),
                        validator: (value) =>
                          value == null || !value.trim().contains('@')
                              ? 'Enter a valid email address' : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _password,
                        obscureText: !_showPassword,
                        autofillHints: [_signup ? AutofillHints.newPassword
                            : AutofillHints.password],
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: const Icon(Icons.lock_outline_rounded),
                          suffixIcon: IconButton(
                            onPressed: () => setState(
                              () => _showPassword = !_showPassword),
                            icon: Icon(_showPassword
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined)),
                        ),
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return 'Enter your password';
                          }
                          if (_signup && value.length < 8) {
                            return 'Use at least 8 characters';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 26),
                      FilledButton(
                        onPressed: _loading ? null : _submit,
                        child: _loading
                          ? const SizedBox(width: 22, height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2))
                          : Text(_signup ? 'Create account' : 'Sign in',
                            style: const TextStyle(fontWeight: FontWeight.w800)),
                      ),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: _loading ? null
                            : () => setState(() => _signup = !_signup),
                        child: Text(_signup
                          ? 'Already have an account? Sign in'
                          : 'New here? Create an account'),
                      ),
                      const SizedBox(height: 24),
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.fingerprint_rounded,
                            color: AppTheme.secondary, size: 16),
                          SizedBox(width: 7),
                          Text('Biometric app lock available',
                            style: TextStyle(color: AppTheme.secondary,
                              fontSize: 12)),
                        ],
                      ),
                    ],
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
