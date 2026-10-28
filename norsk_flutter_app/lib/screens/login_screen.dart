import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
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
  bool busy = false, rememberName = false, keepLoggedIn = false;
  @override void initState() {
    super.initState();
    final api = widget.api;
    if (api.baseUrl.isNotEmpty) server.text = api.baseUrl;
    email.text = api.rememberedEmail;
    rememberName = api.rememberName; keepLoggedIn = api.keepLoggedIn;
    final error = api.restoreError;
    if (error != null) {
      api.restoreError = null;
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.tr('restoreFailed', {'error': readableError(error)})))); });
    }
  }
  @override void dispose() { server.dispose(); email.dispose(); password.dispose(); super.dispose(); }
  Future<void> login() async {
    setState(() => busy = true);
    try { await widget.api.login(server.text, email.text, password.text, rememberName: rememberName, keepLoggedIn: keepLoggedIn); widget.onLogin(); }
    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(readableError(e)))); }
    finally { if (mounted) setState(() => busy = false); }
  }
  @override Widget build(BuildContext context) => Scaffold(body: Center(child: SingleChildScrollView(
    padding: const EdgeInsets.all(24), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 440), child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Icon(Icons.headphones, size: 76), const SizedBox(height: 18),
        Text('Norsk Audio', style: Theme.of(context).textTheme.headlineMedium, textAlign: TextAlign.center),
        const SizedBox(height: 24),
        TextField(controller: server, decoration: InputDecoration(labelText: context.tr('serverUrl'), hintText: 'https://example.com', border: const OutlineInputBorder()), keyboardType: TextInputType.url),
        const SizedBox(height: 12),
        TextField(controller: email, decoration: InputDecoration(labelText: context.tr('email'), border: const OutlineInputBorder()), keyboardType: TextInputType.emailAddress),
        const SizedBox(height: 12),
        TextField(controller: password, obscureText: true, decoration: InputDecoration(labelText: context.tr('password'), border: const OutlineInputBorder()), onSubmitted: (_) => busy ? null : login()),
        const SizedBox(height: 8),
        CheckboxListTile(value: rememberName, onChanged: (v) => setState(() => rememberName = v ?? false),
          title: Text(context.tr('rememberName')), controlAffinity: ListTileControlAffinity.leading, contentPadding: EdgeInsets.zero),
        CheckboxListTile(value: keepLoggedIn, onChanged: (v) => setState(() => keepLoggedIn = v ?? false),
          title: Text(context.tr('keepLoggedIn')), controlAffinity: ListTileControlAffinity.leading, contentPadding: EdgeInsets.zero),
        const SizedBox(height: 12), FilledButton(onPressed: busy ? null : login, child: Text(context.tr(busy ? 'signingIn' : 'signIn'))),
        const SizedBox(height: 12), Text(context.tr('httpsNotice'), textAlign: TextAlign.center),
      ],
    )))));
}
