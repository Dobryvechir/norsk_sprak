import 'package:flutter/material.dart';
import '../services/api.dart';
class LoginScreen extends StatefulWidget {
  final Api api;
  final VoidCallback onLogin;
  const LoginScreen({super.key, required this.api, required this.onLogin});
  @override State<LoginScreen> createState() => _LoginScreenState();
}
class _LoginScreenState extends State<LoginScreen> {
  final server = TextEditingController(text: 'https://your-server.example.com');
  final email = TextEditingController(); final password = TextEditingController();
  bool busy = false;
  @override void initState() { super.initState(); if (widget.api.baseUrl.isNotEmpty) server.text = widget.api.baseUrl; }
  @override void dispose() { server.dispose(); email.dispose(); password.dispose(); super.dispose(); }
  Future<void> login() async {
    setState(() => busy = true);
    try { await widget.api.login(server.text, email.text, password.text); widget.onLogin(); }
    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(readableError(e)))); }
    finally { if (mounted) setState(() => busy = false); }
  }
  @override Widget build(BuildContext context) => Scaffold(body: Center(child: SingleChildScrollView(
    padding: const EdgeInsets.all(24), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 440), child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Icon(Icons.headphones, size: 76), const SizedBox(height: 18),
        Text('Norsk Audio', style: Theme.of(context).textTheme.headlineMedium, textAlign: TextAlign.center),
        const SizedBox(height: 24),
        TextField(controller: server, decoration: const InputDecoration(labelText: 'Server URL', hintText: 'https://example.com', border: OutlineInputBorder()), keyboardType: TextInputType.url),
        const SizedBox(height: 12),
        TextField(controller: email, decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder()), keyboardType: TextInputType.emailAddress),
        const SizedBox(height: 12),
        TextField(controller: password, obscureText: true, decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()), onSubmitted: (_) => busy ? null : login()),
        const SizedBox(height: 20), FilledButton(onPressed: busy ? null : login, child: Text(busy ? 'Signing in…' : 'Sign in')),
        const SizedBox(height: 12), const Text('Use HTTPS for remote servers. HTTP is intended only for a controlled development environment.', textAlign: TextAlign.center),
      ],
    )))));
}
