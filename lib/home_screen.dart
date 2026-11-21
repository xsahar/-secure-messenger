import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'contacts_screen.dart';
import 'profile_screen.dart';
import 'chat_media_content.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selected = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
              child: Row(
                children: [
                  Container(
                    width: 43, height: 43,
                    decoration: BoxDecoration(
                      color: AppTheme.mine,
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: const Icon(Icons.shield_rounded,
                        color: AppTheme.accent, size: 25),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_selected == 0 ? 'Conversations' : 'My profile',
                          style: const TextStyle(fontSize: 23,
                              color: AppTheme.text, fontWeight: FontWeight.w800,
                              letterSpacing: -0.6)),
                        const Text('SECURE MESSENGER',
                          style: TextStyle(color: AppTheme.secondary,
                            fontWeight: FontWeight.w700, fontSize: 10,
                            letterSpacing: 2)),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Sign out',
                    icon: const Icon(Icons.logout_rounded,
                        color: AppTheme.secondary),
                    onPressed: () async {
                      ChatMediaContent.clearSessionMedia();
                      await FirebaseAuth.instance.signOut();
                    },
                  ),
                ],
              ),
            ),
            Expanded(
              child: IndexedStack(
                index: _selected,
                children: const [ContactsScreen(), ProfileScreen()],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: NavigationBar(
          selectedIndex: _selected,
          onDestinationSelected: (index) => setState(() => _selected = index),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline_rounded),
              selectedIcon: Icon(Icons.chat_bubble_rounded),
              label: 'Chats',
            ),
            NavigationDestination(
              icon: Icon(Icons.person_outline_rounded),
              selectedIcon: Icon(Icons.person_rounded),
              label: 'Profile',
            ),
          ],
        ),
      ),
    );
  }
}
