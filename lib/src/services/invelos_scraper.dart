import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:http/http.dart' as http;
import '../../main.dart' show MovieEntry;

/// Service for scraping DVD collection data directly from Invelos Online (DVDCollection.aspx).
class InvelosScraper {
  /// Fetches and parses the online collection for the given [username].
  static Future<List<MovieEntry>> fetchCollection(
    String username, {
    void Function(String message, double? progress)? onProgress,
  }) async {
    final cleanUsername = username.trim();
    if (cleanUsername.isEmpty) {
      throw Exception('Invelos username cannot be empty.');
    }

    _log('Starting Invelos collection fetch for username: "$cleanUsername" (Web mode: $kIsWeb)');
    onProgress?.call('Connecting to Invelos Online...', 0.1);

    final initUrl = 'https://www.invelos.com/DVDCollection.aspx/${Uri.encodeComponent(cleanUsername)}';
    final listUrl = 'https://www.invelos.com/onlinecollections/dvd/InBlue/List.aspx';
    final aliasListUrl = 'https://www.invelos.com/onlinecollections/dvd/InBlue/List.aspx?alias=${Uri.encodeComponent(cleanUsername)}';

    String listHtml = '';
    final logBuffer = StringBuffer();

    void appendLog(String logStr) {
      debugPrint('[InvelosScraper] $logStr');
      logBuffer.writeln(logStr);
    }

    if (kIsWeb) {
      appendLog('Web Mode: Browsers block cross-origin ASP.NET session cookies via CORS proxies.');
      onProgress?.call('Fetching collection page via Web Proxy...', 0.3);

      final proxyList = [
        'https://api.allorigins.win/raw?url=',
        'https://corsproxy.io/?',
      ];

      for (final proxy in proxyList) {
        try {
          appendLog('Trying proxy: $proxy');
          final urlToTry = '$proxy${Uri.encodeComponent(aliasListUrl)}';
          appendLog('GET $urlToTry');

          final resp = await http.get(Uri.parse(urlToTry)).timeout(const Duration(seconds: 15));
          appendLog('Response HTTP ${resp.statusCode}, Length: ${resp.body.length} bytes');

          if (resp.statusCode == 200 && resp.body.contains('DVD.aspx?U=')) {
            listHtml = resp.body;
            appendLog('Successfully loaded list page via proxy: $proxy');
            break;
          }
        } catch (e) {
          appendLog('Proxy $proxy failed: $e');
        }
      }

      if (listHtml.isEmpty) {
        appendLog('Direct CORS Web fetch fallback...');
        try {
          final directResp = await http.get(Uri.parse(initUrl)).timeout(const Duration(seconds: 10));
          appendLog('Direct HTTP ${directResp.statusCode}, Length: ${directResp.body.length}');
          listHtml = directResp.body;
        } catch (e) {
          appendLog('Direct request failed: $e');
        }
      }
    } else {
      // Desktop / Mobile HTTP Client with Cookie Session Management
      appendLog('Desktop/Mobile Mode: Running 2-step HTTP session client...');
      onProgress?.call('Initializing Invelos session...', 0.3);

      final client = http.Client();
      try {
        final headers = {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        };

        appendLog('Step 1: GET $initUrl');
        final initResp = await client.get(Uri.parse(initUrl), headers: headers).timeout(const Duration(seconds: 25));
        appendLog('Step 1 Status: ${initResp.statusCode}');

        final cookie = initResp.headers['set-cookie'];
        appendLog('Step 1 Cookie: ${cookie ?? "none"}');

        onProgress?.call('Downloading online movie list...', 0.6);
        appendLog('Step 2: GET $listUrl');

        final listResp = await client.get(
          Uri.parse(listUrl),
          headers: {
            ...headers,
            if (cookie != null && cookie.isNotEmpty) 'cookie': cookie,
          },
        ).timeout(const Duration(seconds: 25));

        appendLog('Step 2 Status: ${listResp.statusCode}, Length: ${listResp.body.length} bytes');

        if (listResp.statusCode == 200 && listResp.body.contains('DVD.aspx?U=')) {
          listHtml = listResp.body;
        } else {
          appendLog('Step 2 did not contain DVD links. Fallback to Init body.');
          listHtml = initResp.body;
        }

        onProgress?.call('Parsing movie list...', 0.6);
        final parsedEntries = parseHtmlCollection(listHtml);
        appendLog('Parsed ${parsedEntries.length} entries from list. Scraping detail format labels...');

        if (parsedEntries.isNotEmpty) {
          int processed = 0;
          final total = parsedEntries.length;
          const chunkSize = 15;

          for (var i = 0; i < total; i += chunkSize) {
            final chunk = parsedEntries.sublist(i, i + chunkSize > total ? total : i + chunkSize);
            await Future.wait(chunk.map((movie) async {
              if (movie.id.isEmpty) return;
              try {
                final detailUrl = 'https://www.invelos.com/onlinecollections/dvd/InBlue/DVD.aspx?U=${Uri.encodeComponent(movie.id)}';
                final detailResp = await client.get(
                  Uri.parse(detailUrl),
                  headers: {
                    ...headers,
                    if (cookie != null && cookie.isNotEmpty) 'cookie': cookie,
                  },
                ).timeout(const Duration(seconds: 10));

                if (detailResp.statusCode == 200) {
                  final rawLabel = extractUpcFormatLabel(detailResp.body);
                  if (rawLabel != null && rawLabel.isNotEmpty) {
                    final detected = detectMediaTypesFromText(rawLabel);
                    if (detected.isNotEmpty) {
                      movie.mediaTypes = detected;
                      movie.mediaType = detected.first;
                    }
                  }
                }
              } catch (_) {}
            }));

            processed += chunk.length;
            onProgress?.call('Reading media formats from Invelos ($processed / $total)...', 0.6 + (0.35 * (processed / total)));
          }
        }

        onProgress?.call('Done! Loaded ${parsedEntries.length} movies.', 1.0);
        return parsedEntries;
      } finally {
        client.close();
      }
    }

    onProgress?.call('Parsing movie list...', 0.6);
    final parsedEntries = parseHtmlCollection(listHtml);
    onProgress?.call('Done! Loaded ${parsedEntries.length} movies.', 1.0);
    return parsedEntries;
  }

  /// Parses the HTML output of Invelos DVDCollection.aspx / List.aspx into a list of [MovieEntry].
  static List<MovieEntry> parseHtmlCollection(String html) {
    final entries = <MovieEntry>[];
    final seenIds = <String>{};

    // Match DVD links e.g. <a href="DVD.aspx?U=843501650837">Project Hail Mary</a>
    final dvdLinkRegex = RegExp(
      r'<a\s+[^>]*href=["\x27]DVD\.aspx\?U=([^"\x27&]+)["\x27][^>]*>(.*?)</a>',
      caseSensitive: false,
      dotAll: true,
    );

    // Match <tr> rows
    final rowRegex = RegExp(r'<tr[^>]*>(.*?)</tr>', caseSensitive: false, dotAll: true);
    final tdRegex = RegExp(r'<td[^>]*>(.*?)</td>', caseSensitive: false, dotAll: true);

    final rows = rowRegex.allMatches(html);

    int fallbackCount = 1;
    for (final row in rows) {
      final rowContent = row.group(1) ?? '';
      final linkMatch = dvdLinkRegex.firstMatch(rowContent);
      if (linkMatch == null) continue;

      final upc = linkMatch.group(1)?.trim() ?? '';
      String rawTitle = _unescapeHtml(linkMatch.group(2)?.replaceAll(RegExp(r'<[^>]*>'), '').trim() ?? '');
      if (rawTitle.isEmpty) continue;

      // Extract year from title if present, e.g. "Batman (1989)"
      String? year;
      final yearMatch = RegExp(r'\((\d{4})\)').firstMatch(rawTitle);
      if (yearMatch != null) {
        year = yearMatch.group(1);
        rawTitle = rawTitle.replaceAll(RegExp(r'\s*\(\d{4}\)'), '').trim();
      }

      // Extract Collection Number from second <td> if present
      final tds = tdRegex
          .allMatches(rowContent)
          .map((m) => _unescapeHtml(m.group(1)?.replaceAll(RegExp(r'<[^>]*>'), '').trim() ?? ''))
          .toList();

      String? collectionNum;
      if (tds.length >= 2 && tds[1].isNotEmpty && RegExp(r'^\d+$').hasMatch(tds[1])) {
        collectionNum = tds[1];
      } else {
        collectionNum = null;
      }

      // Front image URL on Invelos server
      final imageUrl = '';

      // Detect media types from explicit title/row labels (not UPC guessing)
      final mediaTypes = detectMediaTypes(
        upc: upc,
        title: rawTitle,
        rowContent: rowContent,
      );

      final entryId = upc.isNotEmpty ? upc : '${rawTitle}_$fallbackCount';

      if (!seenIds.contains(entryId)) {
        seenIds.add(entryId);
        entries.add(
          MovieEntry(
            id: entryId,
            title: rawTitle,
            year: year,
            mediaType: mediaTypes.isNotEmpty ? mediaTypes.first : 'DVD',
            mediaTypes: mediaTypes,
            imageUrl: imageUrl,
            collectionNumber: collectionNum,
          ),
        );
        fallbackCount++;
      }
    }

    // Fallback: If no <tr> rows matched, attempt direct link parsing across entire document
    if (entries.isEmpty) {
      final matches = dvdLinkRegex.allMatches(html);
      for (final match in matches) {
        final upc = match.group(1)?.trim() ?? '';
        String rawTitle = _unescapeHtml(match.group(2)?.replaceAll(RegExp(r'<[^>]*>'), '').trim() ?? '');
        if (rawTitle.isEmpty) continue;

        String? year;
        final yearMatch = RegExp(r'\((\d{4})\)').firstMatch(rawTitle);
        if (yearMatch != null) {
          year = yearMatch.group(1);
          rawTitle = rawTitle.replaceAll(RegExp(r'\s*\(\d{4}\)'), '').trim();
        }

        final entryId = upc.isNotEmpty ? upc : '${rawTitle}_$fallbackCount';
        if (!seenIds.contains(entryId)) {
          seenIds.add(entryId);
          entries.add(
            MovieEntry(
              id: entryId,
              title: rawTitle,
              year: year,
              mediaType: 'DVD',
              mediaTypes: ['DVD'],
              imageUrl: '',
              collectionNumber: null,
            ),
          );
          fallbackCount++;
        }
      }
    }

    return entries;
  }

  static void _log(String msg) {
    debugPrint('[InvelosScraper] $msg');
  }

  static String _unescapeHtml(String input) {
    return input
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ');
  }

  /// Detects media types (4K, Blu-ray, 3D, DVD) from explicit labels in title/row HTML.
  ///
  /// Invelos List.aspx rows only expose Title + Coll# (no format column/icon). Detail
  /// pages label format in the UPC line as e.g. (DVD), (Blu-ray), (4K UltraHD).
  /// Do not infer format from retail UPC length or .N alternate-version suffixes -
  /// those are not media-type codes. Unknown -> DVD (not Blu-ray).
  ///
  /// Returned list is ordered by primary priority: 4K > Blu-ray > 3D > DVD.
  static List<String> detectMediaTypes({
    required String upc,
    required String title,
    required String rowContent,
  }) {
    // Strip DVD.aspx href URLs so path text cannot false-positive as DVD.
    final cleanRowContent = rowContent.replaceAll(
      RegExp(r'''dvd\.aspx\?u=[^\s"''>]+''', caseSensitive: false),
      '',
    );
    final haystack = '${title.toLowerCase()} ${cleanRowContent.toLowerCase()}';
    final mediaTypes = <String>{};

    // Explicit parenthetical format labels (present on DVD.aspx detail; harmless on List rows)
    // e.g. (DVD), (Blu-ray), (4K UltraHD), (Blu-ray & DVD Combo), (4K UltraHD & Blu-ray Combo)
    final parenFormat = RegExp(
      r'\(([^)]*(?:4k|ultra\s*hd|ultrahd|uhd|blu[-\s]?ray|hddvd|hd[-\s]?dvd|\bdvd\b)[^)]*)\)',
      caseSensitive: false,
    );
    for (final match in parenFormat.allMatches(haystack)) {
      _addFormatsFromText(mediaTypes, match.group(1) ?? '');
    }

    // Title / row keyword labels
    _addFormatsFromText(mediaTypes, haystack);

    // [upc] kept for API stability; not used for format inference.
    if (upc.isEmpty) {
      // no-op: List rows may omit UPC; format still comes from labels.
    }

    // If no explicit format label matched, return empty list so sync logic doesn't overwrite existing media types
    return prioritizeMediaTypes(mediaTypes);
  }

  /// Extracts the parenthetical format label specifically from the UPC section of a detail page.
  static String? extractUpcFormatLabel(String html) {
    final unescaped = _unescapeHtml(html);
    // Match UPC table cell content: UPC: ... <SPAN class="f2"> 043396-646926 (4K UltraHD & Blu-ray Combo) </SPAN>
    final re1 = RegExp(
      r'UPC:.*?</SPAN>\s*</TD>\s*<TD[^>]*>\s*<SPAN[^>]*>(.*?)</SPAN>',
      caseSensitive: false,
      dotAll: true,
    );
    final m1 = re1.firstMatch(unescaped);
    if (m1 != null) {
      final text = m1.group(1)!.trim();
      final paren = RegExp(r'\(([^)]+)\)').firstMatch(text);
      if (paren != null) {
        return paren.group(1)!.trim();
      }
      return text;
    }

    final re2 = RegExp(r'\b\d{5,14}[-\d.]*\s*\(([^)]+)\)', caseSensitive: false);
    final m2 = re2.firstMatch(unescaped);
    if (m2 != null) {
      return m2.group(1)!.trim();
    }

    return null;
  }

  /// Extracts media types (4K, Blu-ray, 3D, DVD) from a detail page string.
  static List<String> detectMediaTypesFromText(String text) {
    final mediaTypes = <String>{};
    _addFormatsFromText(mediaTypes, text);
    return prioritizeMediaTypes(mediaTypes);
  }

  /// Adds known format tokens found in [text] into [mediaTypes].
  static void _addFormatsFromText(Set<String> mediaTypes, String text) {
    final t = text.toLowerCase();
    if (t.contains('4k') ||
        t.contains('ultra hd') ||
        t.contains('ultrahd') ||
        RegExp(r'\buhd\b').hasMatch(t)) {
      mediaTypes.add('4K');
    }
    if (t.contains('blu-ray') ||
        t.contains('bluray') ||
        t.contains('blu ray')) {
      mediaTypes.add('Blu-ray');
    }
    if (RegExp(r'\b3d\b').hasMatch(t)) {
      mediaTypes.add('3D');
    }
    if (RegExp(r'\bdvd\b').hasMatch(t)) {
      mediaTypes.add('DVD');
    }
  }

  /// Stable primary ordering: 4K > Blu-ray > 3D > DVD.
  static List<String> prioritizeMediaTypes(Iterable<String> types) {
    const order = ['4K', 'Blu-ray', '3D', 'DVD'];
    final set = types.toSet();
    return order.where(set.contains).toList();
  }
}
