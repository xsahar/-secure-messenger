import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide User;

import 'supabase_config.dart';
import 'firebase_options.dart';
import 'auth_screen.dart';
import 'home_screen.dart';
import 'biometric_gate.dart';
import 'app_theme.dart';
import 'chat_media_content.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  await Supabase.initialize(
    url: SupabaseConfig.url,
    publishableKey: SupabaseConfig.publishableKey,
    accessToken: () async => FirebaseAuth.instance.currentUser?.getIdToken(),
  );
  String? lastUid = FirebaseAuth.instance.currentUser?.uid;
  FirebaseAuth.instance.authStateChanges().listen((user) {
    if (user?.uid != lastUid) ChatMediaContent.clearSessionMedia();
    lastUid = user?.uid;
  });
  runApp(const SecureMessengerApp());
}

class SecureMessengerApp extends StatelessWidget {
  const SecureMessengerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Secure Messenger',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (snapshot.hasError) {
            return const Scaffold(
              body: Center(child: Text('Unable to check login status.')),
            );
          }
          final user = snapshot.data;
          if (user == null) return const AuthScreen();
          // Chat, profile, media viewer and QR routes remain underneath the lock.
          return BiometricGate(
            key: ValueKey(user.uid),
            child: Navigator(
              onGenerateRoute: (settings) => MaterialPageRoute<void>(
                settings: settings,
                builder: (_) => const HomeScreen(),
              ),
            ),
          );
        },
      ),
    );
  }
}
