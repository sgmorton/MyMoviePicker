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
      } finally {
        client.close();
      }
    }

    onProgress?.call('Parsing movie titles...', 0.8);
    appendLog('Parsing HTML (Length: ${listHtml.length} bytes)...');

    final parsedEntries = parseHtmlCollection(listHtml);
    appendLog('Successfully parsed ${parsedEntries.length} movie entries!');

    if (parsedEntries.isEmpty) {
      appendLog('ERROR: 0 movies parsed.');
      if (kIsWeb) {
        throw Exception(
          'Invelos Online uses ASP.NET browser session cookies that modern web browsers block across domains in Chrome Web mode.\n\n'
          'To sync your online collection automatically:\n'
          '1. Run the app in Windows Desktop mode: flutter run -d windows\n'
          '2. Or upload your DVD Profiler XML file using the Open XML button.',
        );
      } else {
        throw Exception(
          'Failed to scrape collection for "$cleanUsername".\n'
          'Please verify your Invelos username spelling and ensure your collection is published online at https://www.invelos.com/DVDCollection.aspx/$cleanUsername',
        );
      }
    }

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

      // Detect media types using UPC code patterns, suffixes, and title keywords
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
            mediaType: mediaTypes.first,
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

  /// Detects media types (4K, Blu-ray, 3D, DVD) using UPC patterns, suffixes, and title keywords.
  static List<String> detectMediaTypes({
    required String upc,
    required String title,
    required String rowContent,
  }) {
    final lowerTitle = title.toLowerCase();
    // Strip DVD.aspx href URLs from rowContent to avoid false positive DVD matches from the URL path
    final cleanRowContent = rowContent.replaceAll(RegExp(r'dvd\.aspx\?u=[^">]+', caseSensitive: false), '');
    final lowerRow = cleanRowContent.toLowerCase();
    final mediaTypes = <String>{};

    // 1. Explicit Title / Row Keywords
    if (lowerTitle.contains('4k') ||
        lowerTitle.contains('ultra hd') ||
        lowerTitle.contains('uhd') ||
        lowerRow.contains('4k') ||
        lowerRow.contains('ultra hd')) {
      mediaTypes.add('4K');
      mediaTypes.add('Blu-ray');
    }
    if (lowerTitle.contains('blu-ray') ||
        lowerTitle.contains('bluray') ||
        lowerRow.contains('blu-ray') ||
        lowerRow.contains('bluray')) {
      mediaTypes.add('Blu-ray');
    }
    if (lowerTitle.contains('3d') || lowerRow.contains('3d')) {
      mediaTypes.add('3D');
      mediaTypes.add('Blu-ray');
    }
    if (lowerTitle.contains('dvd') || lowerRow.contains(' dvd') || lowerRow.contains('dvd ')) {
      mediaTypes.add('DVD');
    }

    // 2. DVD Profiler UPC Suffix / Variant Codes
    if (upc.endsWith('.4')) {
      mediaTypes.add('4K');
      mediaTypes.add('Blu-ray');
    } else if (upc.endsWith('.8') || upc.endsWith('.2') || upc.endsWith('.1')) {
      mediaTypes.add('Blu-ray');
    } else if (upc.endsWith('.3')) {
      mediaTypes.add('3D');
      mediaTypes.add('Blu-ray');
    }

    // 3. Retail UPC Barcodes (All 12/13 digit UPCs for modern movies default to Blu-ray if not 4K)
    final cleanUpc = upc.replaceAll(RegExp(r'[^0-9]'), '');
    if (cleanUpc.length >= 12) {
      if (!mediaTypes.contains('4K')) {
        mediaTypes.add('Blu-ray');
      }
    }

    // 4. Default for unspecified items
    if (mediaTypes.isEmpty) {
      mediaTypes.add('Blu-ray');
    }

    return mediaTypes.toList();
  }
}
