import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// A named web address kept in Documents → Links.
class DocLink {
  final String id, name, url;
  const DocLink(this.id, this.name, this.url);
  factory DocLink.fromJson(Map<String, dynamic> j) => DocLink('${j['id']}', '${j['name'] ?? ''}', '${j['url'] ?? ''}');
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'url': url};
}

/// [text] as an http(s) address: "example.com/a" becomes "https://example.com/a"; null when it
/// is not a valid http or https address.
String? normalizeLink(String text) {
  text = text.trim();
  if (text.isEmpty || text.contains(RegExp(r'\s'))) return null;
  if (!text.contains('://')) text = 'https://$text';
  final uri = Uri.tryParse(text);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) return null;
  return text;
}

/// The links, kept only on this device (SharedPreferences; localStorage on web), never on our server.
class DocLinks {
  static const _key = 'document_links';

  /// Every link, sorted by name.
  static Future<List<DocLink>> all() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return [];
    try {
      return [for (final j in jsonDecode(raw) as List) DocLink.fromJson(Map<String, dynamic>.from(j as Map))]
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    } catch (_) { return []; }
  }

  static Future<void> _save(List<DocLink> links) async =>
    (await SharedPreferences.getInstance()).setString(_key, jsonEncode([for (final l in links) l.toJson()]));

  static Future<DocLink> create(String name, String url) async {
    final link = DocLink('${DateTime.now().microsecondsSinceEpoch}', name, url);
    await _save([...await all(), link]);
    return link;
  }

  static Future<void> update(DocLink link) async =>
    _save([for (final l in await all()) l.id == link.id ? link : l]);

  static Future<void> delete(String id) async => _save([for (final l in await all()) if (l.id != id) l]);
}
