import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../models/chat.dart';
import '../services/api.dart';
import '../services/chat_api.dart';

/// [person]'s photo in a circle, or their initial while it loads or when they have none.
class ChatAvatar extends StatelessWidget {
  final ChatApi chat; final ChatPerson person; final double radius;
  const ChatAvatar({super.key, required this.chat, required this.person, this.radius = 20});
  @override Widget build(BuildContext context) {
    final initial = CircleAvatar(radius: radius,
      child: Text(person.displayName.isEmpty ? '?' : person.displayName.characters.first.toUpperCase()));
    if (!person.hasPhoto) return initial;
    return FutureBuilder<Uint8List?>(future: chat.photo(person), builder: (_, snap) => snap.data == null ? initial
      : CircleAvatar(radius: radius, backgroundImage: MemoryImage(snap.data!)));
  }
}

/// The icon of a conversation type.
IconData conversationIcon(ChatConversation c) => c.isDirect ? Icons.person
  : c.family ? Icons.family_restroom : c.isSubgroup ? Icons.forum : Icons.groups;

/// "14:05" today, else "7.11 14:05".
String chatTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  final now = DateTime.now();
  final clock = '${two(t.hour)}:${two(t.minute)}';
  return t.year == now.year && t.month == now.month && t.day == now.day ? clock : '${t.day}.${t.month} $clock';
}

void showChatError(BuildContext context, Object e) {
  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(readableError(e))));
}
