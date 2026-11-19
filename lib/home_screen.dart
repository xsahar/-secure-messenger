import 'package:flutter/material.dart';

import 'contacts_screen.dart';
import 'package:secure_messenger/profile_screen.dart';

/// Place this widget in the signed-in Scaffold body in main.dart.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selected = 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: IndexedStack(
            index: _selected,
            children: const [ProfileScreen(), ContactsScreen()],
          ),
        ),
        NavigationBar(
          selectedIndex: _selected,
          onDestinationSelected: (index) {
            setState(() => _selected = index);
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.person_outline),
              selectedIcon: Icon(Icons.person),
              label: 'Profile',
            ),
            NavigationDestination(
              icon: Icon(Icons.people_outline),
              selectedIcon: Icon(Icons.people),
              label: 'Contacts & Chats',
            ),
          ],
        ),
      ],
    );
  }
}
