import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:xml/xml.dart';
import 'src/html/html_stub.dart' if (dart.library.html) 'dart:html' as html;
import 'package:file_picker/file_picker.dart';
import 'package:hive_flutter/hive_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  await Hive.openBox('movie_picker');
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    final baseTheme = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        brightness: Brightness.dark,
        seedColor: Colors.tealAccent,
      ),
      brightness: Brightness.dark,
      useMaterial3: true,
    );

    return MaterialApp(
      title: 'Movie Picker',
      theme: baseTheme,
      home: const MoviePickerPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MovieEntry {
  final String id;
  final String title;
  final String? year;
  final String? genres;
  final String? mediaType; // deprecated single type
  final List<String>
  mediaTypes; // normalized list (e.g., ['Blu-ray','DVD','4K'])
  final String? runtime;
  final String? frontImageFilename;
  String imageUrl;
  String? mpaa; // G/PG/PG-13/R/...
  bool
  isCollectionParent; // true if this is a collection parent (hide children)
  String? collectionNumber; // Collection/BoxSet number for sorting
  String? overview;
  String? rottenTomatoesScore;

  MovieEntry({
    required this.id,
    required this.title,
    this.year,
    this.genres,
    this.mediaType,
    this.mediaTypes = const [],
    this.runtime,
    this.frontImageFilename,
    required this.imageUrl,
    this.mpaa,
    this.isCollectionParent = false,
    this.collectionNumber,
    this.overview,
    this.rottenTomatoesScore,
  });

  @override
  bool operator ==(Object other) =>
      other is MovieEntry &&
      id == other.id &&
      title == other.title &&
      year == other.year &&
      genres == other.genres &&
      mediaType == other.mediaType &&
      mediaTypes == other.mediaTypes &&
      runtime == other.runtime &&
      frontImageFilename == other.frontImageFilename &&
      imageUrl == other.imageUrl &&
      mpaa == other.mpaa &&
      isCollectionParent == other.isCollectionParent &&
      collectionNumber == other.collectionNumber &&
      overview == other.overview &&
      rottenTomatoesScore == other.rottenTomatoesScore;

  @override
  int get hashCode =>
      id.hashCode ^
      title.hashCode ^
      year.hashCode ^
      genres.hashCode ^
      mediaType.hashCode ^
      mediaTypes.hashCode ^
      runtime.hashCode ^
      frontImageFilename.hashCode ^
      imageUrl.hashCode ^
      mpaa.hashCode ^
      isCollectionParent.hashCode ^
      collectionNumber.hashCode ^
      overview.hashCode ^
      rottenTomatoesScore.hashCode;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'year': year,
      'genres': genres,
      'mediaType': mediaType,
      'mediaTypes': mediaTypes,
      'runtime': runtime,
      'frontImageFilename': frontImageFilename,
      'imageUrl': imageUrl,
      'mpaa': mpaa,
      'isCollectionParent': isCollectionParent,
      'collectionNumber': collectionNumber,
      'overview': overview,
      'rottenTomatoesScore': rottenTomatoesScore,
    };
  }

  factory MovieEntry.fromMap(Map<String, dynamic> map) {
    return MovieEntry(
      id: map['id'] as String,
      title: map['title'] as String,
      year: map['year'] as String?,
      genres: map['genres'] as String?,
      mediaType: map['mediaType'] as String?,
      mediaTypes:
          (map['mediaTypes'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
      runtime: map['runtime'] as String?,
      frontImageFilename: map['frontImageFilename'] as String?,
      imageUrl: map['imageUrl'] as String? ?? '',
      mpaa: map['mpaa'] as String?,
      isCollectionParent: map['isCollectionParent'] as bool? ?? false,
      collectionNumber: map['collectionNumber'] as String?,
      overview: map['overview'],
      rottenTomatoesScore: map['rottenTomatoesScore'],
    );
  }
}

class MoviePickerPage extends StatefulWidget {
  const MoviePickerPage({super.key});

  @override
  State<MoviePickerPage> createState() => _MoviePickerPageState();
}

class _MoviePickerPageState extends State<MoviePickerPage> {
  final List<MovieEntry> _all = [];
  List<MovieEntry> _filtered = [];
  String _query = '';
  String _genreFilter = 'All';
  bool _postersOnly = false;
  final Set<String> _genres = {'All'};
  bool _dragOver = false;
  final Map<String, String> _filenameToObjectUrl = {};
  final List<String> _createdObjectUrls = [];
  late final Box _box;
  String? _tmdbApiKey;
  String? _omdbApiKey;
  String _sortBy = 'Collection Number';
  bool _isLoading = true;
  String _loadingMessage = 'Loading collection...';
  bool _isFetchingImages = false;
  double _fetchProgress = 0.0;

  static const int _kDataVersion = 5;

  final List<String> _allMediaTypes = const ['4K', 'Blu-ray', 'DVD', '3D'];
  final Set<String> _selectedMediaTypes = {'4K', 'Blu-ray', '3D'};

  final List<MovieEntry> _watchNext = [];

  @override
  void initState() {
    super.initState();
    _box = Hive.box('movie_picker');
    _initialize();
  }

  void _initialize() async {
    // Check for data version and clear old data if necessary
    final storedVersion = _box.get('data_version') as int? ?? 0;
    if (storedVersion < _kDataVersion) {
      print(
        'Old data version ($storedVersion) found. Clearing cache to force re-parse from version $_kDataVersion.',
      );
      await _box.delete('entries');
      await _box.delete('image_files');
      await _box.put(
        'data_version',
        _kDataVersion,
      ); // Update version immediately
    }

    _tmdbApiKey = _box.get('tmdb_api_key') as String?;
    _omdbApiKey = _box.get('omdb_api_key') as String?;
    _restoreFromStorage();
    // If we have no entries yet but have a saved XML, parse it now
    if (_all.isEmpty) {
      final savedXml = _box.get('last_xml') as String?;
      if (savedXml != null && savedXml.isNotEmpty) {
        print('No entries found. Reparsing last saved XML...');
        _loadFromXml(savedXml);
        // After parsing, trigger the background image fetch
        _triggerBackgroundFetch();
      }
    }
    _installDragDrop();
  }

  void _triggerBackgroundFetch() async {
    final toFetch = _all.where((e) => e.imageUrl.isEmpty).toList();

    if (toFetch.isNotEmpty) {
      print(
        'Found ${toFetch.length} items missing an image, fetching in background...',
      );
      Future.delayed(const Duration(milliseconds: 500), () async {
        bool anyChanged = false;
        int processedCount = 0;
        final total = toFetch.length;

        for (final movie in toFetch) {
          if (!mounted) break;

          // Short-circuit as soon as we find an image.
          bool found =
              await _fetchCoverFromTmdbForMovie(movie) ||
              await _fetchCoverFromItunesForMovie(movie) ||
              await _fetchCoverFromOmdbForMovie(movie);

          if (found) {
            anyChanged = true;
          }

          processedCount++;
          if (processedCount % 20 == 0) {
            print('Background fetch progress: $processedCount / $total');
            if (anyChanged && mounted) {
              _applyFilters();
            }
          }
        }

        if (anyChanged) {
          print('Finalizing background fetch...');
          if (mounted) _applyFilters();
          await _persistEntries();
        }
        print('Background image fetch complete.');
      });
    }
  }

  void _pickFile() async {
    // On web, use the html file input
    if (kIsWeb) {
      final input = html.FileUploadInputElement()
        ..accept = '.xml,image/*'
        ..multiple = true;
      input.click();
      input.onChange.first.then((_) async {
        if (input.files == null || input.files!.isEmpty) return;
        await _ingestFiles(input.files!);
      });
      return;
    }

    // On mobile/desktop, use file_picker
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['xml', 'jpg', 'jpeg', 'png', 'webp'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    // Convert picked files to our html-like abstraction
    final picked = <html.File>[];
    for (final f in result.files) {
      final name = (f.name).toLowerCase();
      // Create minimal shim objects to pass through existing ingestion logic
      picked.add(html.File(name));
      if (name.endsWith('.xml') && f.bytes != null) {
        // Directly load XML content by mocking FileReader behavior via helper
        await _ingestPickedXml(String.fromCharCodes(f.bytes!));
      } else if ((name.endsWith('.jpg') ||
              name.endsWith('.jpeg') ||
              name.endsWith('.png') ||
              name.endsWith('.webp')) &&
          f.bytes != null) {
        // Store image bytes in Hive store for later use
        await _storePickedImage(name, f.bytes!);
      }
    }

    // After pre-processing, refresh UI if needed
    setState(() {});
  }

  void _installDragDrop() {
    html.document.body?.onDragOver.listen((html.Event e) {
      e.preventDefault();
      setState(() => _dragOver = true);
    });
    html.document.body?.onDragLeave.listen((html.Event e) {
      setState(() => _dragOver = false);
    });
    html.document.body?.onDrop.listen((html.Event e) async {
      e.preventDefault();
      setState(() => _dragOver = false);
      final dt = (e as dynamic).dataTransfer;
      if (dt == null) return;
      final files = dt.files;
      if (files == null || files.length == 0) return;
      await _ingestFiles(List<html.File>.from(files));
    });
  }

  Future<void> _ingestFiles(List<html.File> files) async {
    _revokeObjectUrls();
    _filenameToObjectUrl.clear();

    String? xmlContent;
    for (final f in files) {
      final name = (f.name).toLowerCase();
      if (name.endsWith('.xml')) {
        final reader = html.FileReader();
        reader.readAsText(f);
        await reader.onLoad.first;
        xmlContent = reader.result as String;
      } else if (name.endsWith('.jpg') ||
          name.endsWith('.jpeg') ||
          name.endsWith('.png') ||
          name.endsWith('.webp')) {
        final url = html.Url.createObjectUrl(f);
        _createdObjectUrls.add(url);
        _filenameToObjectUrl[name] = url;

        // Store image file in IndexedDB for persistence
        await _storeImageFile(f);
      }
    }
    if (xmlContent != null) {
      _saveXml(xmlContent);
      _loadFromXml(xmlContent);
      _attachImagesToEntries();
      await _fetchMissingCoversFromItunes();
      await _fetchMissingCoversFromTmdb();
    }
  }

  Future<void> _ingestPickedXml(String xmlContent) async {
    _revokeObjectUrls();
    _filenameToObjectUrl.clear();
    _saveXml(xmlContent);
    _loadFromXml(xmlContent);
    _attachImagesToEntries();
    await _fetchMissingCoversFromItunes();
    await _fetchMissingCoversFromTmdb();
  }

  Future<void> _storePickedImage(String name, List<int> bytes) async {
    final storedFiles = Map<String, dynamic>.from(
      _box.get('image_files') ?? {},
    );
    storedFiles[name] = bytes;
    await _box.put('image_files', storedFiles);
  }

  // duplicate function removed

  Future<void> _fetchMissingCoversFromItunes() async {
    bool changed = false;
    for (final m in _all) {
      if (m.imageUrl.isNotEmpty) continue;
      final title = Uri.encodeQueryComponent(m.title);
      final url =
          'https://itunes.apple.com/search?term=$title&media=movie&entity=movie&limit=1';
      try {
        final resp = await http
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 10));
        if (resp.statusCode == 200) {
          final body = resp.body;
          final art = _extractJsonString(body, 'artworkUrl100');
          if (art != null && art.isNotEmpty) {
            final highRes = art.replaceAll(RegExp(r"/\d+x\d+bb"), '/600x600bb');
            m.imageUrl = highRes;
            changed = true;
          }
        }
      } catch (e, s) {
        print('ITUNES FETCH ERROR for "$title": $e\n$s');
      }
    }
    if (changed) {
      setState(() {});
      await _persistEntries();
    }
  }

  Future<bool> _fetchCoverFromItunesForMovie(MovieEntry m) async {
    if (m.imageUrl.isNotEmpty)
      return false; // Already have an image, nothing to do.
    final cleanTitle = m.title;
    final title = Uri.encodeQueryComponent(cleanTitle);
    final url =
        'https://itunes.apple.com/search?term=$title&media=movie&entity=movie&limit=1';
    try {
      final resp = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final body = resp.body;
        final art = _extractJsonString(body, 'artworkUrl100');
        if (art != null && art.isNotEmpty) {
          final highRes = art.replaceAll(RegExp(r"/\d+x\d+bb"), '/600x600bb');
          m.imageUrl = highRes;
          return true;
        }
      }
    } catch (e, s) {
      print('ITUNES FETCH ERROR for "$title": $e\n$s');
    }
    return false;
  }

  Future<bool> _fetchCoverFromTmdbForMovie(MovieEntry m) async {
    if (m.imageUrl.isNotEmpty)
      return false; // Already have an image, nothing to do.
    if (_tmdbApiKey == null || _tmdbApiKey!.isEmpty) return false;

    final cleanTitle = m.title;
    final title = Uri.encodeQueryComponent(cleanTitle);
    final year = m.year != null
        ? '&year=${Uri.encodeQueryComponent(m.year!)}'
        : '';
    final url =
        'https://api.themoviedb.org/3/search/movie?query=$title$year&api_key=$_tmdbApiKey';
    try {
      final resp = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final body = resp.body;
        final path = _extractJsonString(body, 'poster_path');

        if (path != null && path.isNotEmpty && path != 'null') {
          m.imageUrl = 'https://image.tmdb.org/t/p/w342$path';
          return true;
        }
      }
    } catch (e, s) {
      print('TMDB FETCH ERROR for "$title": $e\n$s');
    }
    return false;
  }

  Future<bool> _fetchCoverFromOmdbForMovie(MovieEntry m) async {
    // We might call this just for a score, so don't check for image url here.
    final title = Uri.encodeQueryComponent(m.title);
    final year = m.year != null
        ? '&y=${Uri.encodeQueryComponent(m.year!)}'
        : '';
    final url = 'https://www.omdbapi.com/?apikey=$_omdbApiKey&t=$title$year';

    try {
      final resp = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final body = resp.body;
        final data = jsonDecode(body);
        if (data['Response'] == 'True') {
          bool changed = false;
          if (m.imageUrl.isEmpty &&
              data['Poster'] != null &&
              data['Poster'] != 'N/A') {
            m.imageUrl = data['Poster'];
            changed = true;
          }
          if ((m.overview == null || m.overview!.isEmpty) &&
              data['Plot'] != null) {
            m.overview = data['Plot'];
            changed = true;
          }

          // Extract Rotten Tomatoes score
          if ((m.rottenTomatoesScore == null ||
                  m.rottenTomatoesScore!.isEmpty) &&
              data['Ratings'] is List) {
            final ratings = data['Ratings'] as List;
            final rtRating = ratings.firstWhere(
              (r) => r['Source'] == 'Rotten Tomatoes',
              orElse: () => null,
            );
            if (rtRating != null) {
              m.rottenTomatoesScore = rtRating['Value'];
              print('Found RT score for ${m.title}: ${m.rottenTomatoesScore}');
              changed = true;
            }
          }

          return changed;
        }
      }
    } catch (e, s) {
      print('OMDB FETCH ERROR for "$title": $e\n$s');
    }
    return false;
  }

  Future<List<String>> _fetchImageChoicesFromTmdb(
    String title,
    String? year,
  ) async {
    if (_tmdbApiKey == null || _tmdbApiKey!.isEmpty) return [];

    final titleEncoded = Uri.encodeQueryComponent(title);
    final yearParam = year != null ? '&year=${Uri.encodeComponent(year)}' : '';
    final url =
        'https://api.themoviedb.org/3/search/movie?query=$titleEncoded$yearParam&api_key=$_tmdbApiKey';

    try {
      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final results = json.decode(response.body)['results'] as List;
        return results
            .where((r) => r['poster_path'] != null)
            .map((r) => 'https://image.tmdb.org/t/p/w342${r['poster_path']}')
            .toList();
      }
    } catch (e) {
      print('Error fetching choices from TMDB for $title: $e');
    }
    return [];
  }

  void _attachImagesToEntries() {
    bool changed = false;
    for (final m in _all) {
      final fname = _extractFilename(m.frontImageFilename ?? '');
      if (fname.isEmpty) continue;
      final url = _filenameToObjectUrl[fname.toLowerCase()];
      if (url != null && m.imageUrl != url) {
        m.imageUrl = url;
        changed = true;
      }
    }
    if (changed) {
      _persistEntries();
    }
    _applyFilters();
  }

  String _extractFilename(String path) {
    if (path.isEmpty) return '';
    final parts = path.replaceAll('\\', '/').split('/');
    return parts.isEmpty ? path : parts.last;
  }

  void _revokeObjectUrls() {
    for (final url in _createdObjectUrls) {
      try {
        html.Url.revokeObjectUrl(url);
      } catch (_) {}
    }
    _createdObjectUrls.clear();
  }

  Future<void> _storeImageFile(html.File file) async {
    try {
      final reader = html.FileReader();
      reader.readAsArrayBuffer(file);
      await reader.onLoad.first;
      final bytes = reader.result as List<int>;

      final storedFiles = Map<String, dynamic>.from(
        _box.get('image_files') ?? {},
      );
      storedFiles[file.name.toLowerCase()] = bytes;
      _box.put('image_files', storedFiles);
    } catch (e) {
      print('Failed to store image file ${file.name}: $e');
    }
  }

  void _restoreObjectUrls() {
    // Restore object URLs for local images from stored files
    final storedFiles = _box.get('image_files') as Map<String, dynamic>?;
    if (storedFiles == null) return;

    for (final m in _all) {
      if (m.frontImageFilename == null) continue;
      final filename = _extractFilename(m.frontImageFilename!).toLowerCase();
      final fileData = storedFiles[filename];
      if (fileData != null) {
        try {
          // Recreate object URL from stored file data
          final bytes = List<int>.from(fileData as List);
          final blob = html.Blob([bytes]);
          final url = html.Url.createObjectUrl(blob);
          m.imageUrl = url;
          _createdObjectUrls.add(url);
        } catch (e) {
          print('Failed to restore image for $filename: $e');
        }
      }
    }
    // Don't persist here as it might overwrite existing network URLs
  }

  @override
  void dispose() {
    _revokeObjectUrls();
    super.dispose();
  }

  void _loadFromXml(String xmlString) {
    final document = XmlDocument.parse(xmlString);
    final items = <MovieEntry>[];
    for (final dvd in document.findAllElements('DVD')) {
      String id =
          dvd.getAttribute('id') ??
          _firstText(dvd, const ['ID', 'ProfileID', 'UPC']) ??
          '';
      String? title = _firstText(dvd, const [
        'Title',
        'OriginalTitle',
        'SortTitle',
      ]);
      if (title == null || title.trim().isEmpty) {
        // As a last resort, try attribute
        title = dvd.getAttribute('Title');
      }
      final year = _firstText(dvd, const ['ProductionYear', 'Year']);
      String genres = _firstText(dvd, const ['Genres']) ?? '';
      if (genres.trim().isEmpty) {
        genres = dvd
            .findAllElements('Genre')
            .map((e) => e.innerText)
            .join(', ');
      }
      final mediaTypeRaw = _firstText(dvd, const ['MediaType', 'MediaTypes']);
      final mpaa = _firstText(dvd, const ['Rating', 'MPAA', 'Certification']);
      final collectionNumber = _firstText(dvd, const ['CollectionNumber']);
      final mediaTypes = _extractMediaTypesFromDvd(dvd);
      final overview = _firstText(dvd, const ['Overview']);

      // Check if this is a collection parent or child
      final isCollectionParent =
          _firstText(dvd, const ['BoxSetParent', 'CollectionParent']) == null &&
          _firstText(dvd, const ['BoxSetChild', 'CollectionChild']) != null;
      final isCollectionChild =
          _firstText(dvd, const ['BoxSetParent', 'CollectionParent']) != null;
      final runtime = _normalizeRuntime(
        _firstText(dvd, const ['RunningTime', 'Length', 'Runtime']),
      );

      // Skip clearly empty/placeholder entries
      if ((title == null || title.trim().isEmpty) && id.isEmpty) {
        continue;
      }

      // Skip collection children (only show parent)
      if (isCollectionChild) {
        continue;
      }

      // Per user, only show items that have a collection number.
      if (collectionNumber == null || collectionNumber.trim().isEmpty) {
        continue;
      }

      title ??= 'Untitled';
      if (id.isEmpty) id = '${title}_${year ?? ''}';

      items.add(
        MovieEntry(
          id: id,
          title: title,
          year: year,
          genres: genres.isEmpty ? null : genres,
          mediaType: mediaTypes.isNotEmpty ? mediaTypes.first : mediaTypeRaw,
          mediaTypes: mediaTypes,
          runtime: runtime,
          frontImageFilename: _firstText(dvd, const [
            'FrontImage',
            'FrontCover',
            'Front',
          ]),
          imageUrl: '',
          mpaa: mpaa,
          isCollectionParent: isCollectionParent,
          collectionNumber: collectionNumber,
          overview: overview,
        ),
      );
    }
    setState(() {
      _all
        ..clear()
        ..addAll(items);
      _genres
        ..clear()
        ..add('All')
        ..addAll(
          items
              .expand((m) => (m.genres ?? '').split(',').map((s) => s.trim()))
              .where((s) => s.isNotEmpty),
        );
      _applyFilters();
    });
    _persistEntries();
  }

  void _saveXml(String content) {
    _box.put('last_xml', content);
  }

  Future<void> _persistEntries() async {
    final data = _all
        .map(
          (m) => {
            'id': m.id,
            'title': m.title,
            'year': m.year,
            'genres': m.genres,
            'mediaType': m.mediaType,
            'mediaTypes': m.mediaTypes,
            'runtime': m.runtime,
            'frontImageFilename': m.frontImageFilename,
            'imageUrl': m.imageUrl,
            'mpaa': m.mpaa,
            'isCollectionParent': m.isCollectionParent,
            'collectionNumber': m.collectionNumber,
            'overview': m.overview,
            'rottenTomatoesScore': m.rottenTomatoesScore,
          },
        )
        .toList();

    // Debug: Count items with images being saved
    final withImages = data
        .where((m) => (m['imageUrl'] as String).isNotEmpty)
        .length;
    print('Saving ${data.length} items, ${withImages} with images');

    await _box.put('entries', data);
  }

  void _restoreFromStorage() {
    final data = _box.get('entries') as List?;
    if (data == null) return;
    final items = <MovieEntry>[];
    for (final raw in data) {
      final map = Map<String, dynamic>.from(raw as Map);
      items.add(
        MovieEntry(
          id: map['id'] as String,
          title: map['title'] as String,
          year: map['year'] as String?,
          genres: map['genres'] as String?,
          mediaType: map['mediaType'] as String?,
          mediaTypes:
              (map['mediaTypes'] as List?)?.map((e) => e.toString()).toList() ??
              const [],
          runtime: map['runtime'] as String?,
          frontImageFilename: map['frontImageFilename'] as String?,
          imageUrl: map['imageUrl'] as String? ?? '',
          mpaa: map['mpaa'] as String?,
          isCollectionParent: map['isCollectionParent'] as bool? ?? false,
          collectionNumber: map['collectionNumber'] as String?,
          overview: map['overview'],
          rottenTomatoesScore: map['rottenTomatoesScore'],
        ),
      );
    }

    // Debug: Count items with images
    final withImages = items.where((m) => m.imageUrl.isNotEmpty).length;
    print('Restored ${items.length} items, ${withImages} with images');

    setState(() {
      _all
        ..clear()
        ..addAll(items);
      _genres
        ..clear()
        ..add('All')
        ..addAll(
          items
              .expand((m) => (m.genres ?? '').split(',').map((s) => s.trim()))
              .where((s) => s.isNotEmpty),
        );
      _applyFilters();
    });

    // Restore object URLs for local images
    _restoreObjectUrls();

    // If we have items but no images, try to fetch them
    _triggerBackgroundFetch();
  }

  Future<void> _fetchMissingCoversFromTmdb() async {
    if (_tmdbApiKey == null || _tmdbApiKey!.isEmpty) return;
    bool changed = false;
    for (final m in _all) {
      if (m.imageUrl.isNotEmpty) continue;
      final title = Uri.encodeQueryComponent(m.title);
      final year = m.year != null
          ? '&year=${Uri.encodeQueryComponent(m.year!)}'
          : '';
      final url =
          'https://api.themoviedb.org/3/search/movie?query=$title$year&api_key=$_tmdbApiKey';
      try {
        final resp = await http
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 10));
        if (resp.statusCode == 200) {
          final body = resp.body;
          final path = _extractJsonString(body, 'poster_path');
          final mpaa = _extractJsonString(body, 'rating');
          if (path != null && path.isNotEmpty && path != 'null') {
            m.imageUrl = 'https://image.tmdb.org/t/p/w342$path';
            changed = true;
          }
        }
      } catch (_) {}
    }
    if (changed) {
      setState(() {});
      _persistEntries();
    }
  }

  Future<void> _refreshMissingImages() async {
    final toFetch = _all.where((e) => e.imageUrl.isEmpty).toList();
    if (toFetch.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No missing images to refresh!')),
      );
      return;
    }

    setState(() {
      _isFetchingImages = true;
      _fetchProgress = 0.0;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Fetching ${toFetch.length} missing images...')),
    );

    try {
      int current = 0;
      final total = toFetch.length;
      int successCount = 0;

      for (final movie in toFetch) {
        if (!mounted) break;
        current++;
        bool found =
            await _fetchCoverFromTmdbForMovie(movie) ||
            await _fetchCoverFromItunesForMovie(movie) ||
            await _fetchCoverFromOmdbForMovie(movie);
        if (found) {
          successCount++;
        }

        setState(() {
          _fetchProgress = current / total;
        });

        if (current % 20 == 0) {
          await _persistEntries();
          _applyFilters();
          await Future.delayed(const Duration(milliseconds: 100));
        }
      }
      await _persistEntries();
      _applyFilters();
      print(
        'Background image fetch complete. Found $successCount of $total images.',
      );

      // AFTER automatic search, check for failures and start manual search
      final failures = _all.where((e) => e.imageUrl.isEmpty).toList();
      if (failures.isNotEmpty && mounted) {
        _startManualFuzzySearch(failures);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Image fetch complete. All images found!'),
          ),
        );
      }
    } finally {
      setState(() {
        _isFetchingImages = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Image fetch complete.')));
    }
  }

  Future<void> _startManualFuzzySearch(List<MovieEntry> failures) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Manual Search'),
        content: Text(
          '${failures.length} movies could not be found automatically. Would you like to search for them manually?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Yes, Start Search'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      for (final movie in failures) {
        if (!mounted) break;
        final result = await showDialog<String?>(
          context: context,
          barrierDismissible: false,
          builder: (context) => _FuzzySearchDialog(
            entry: movie,
            onSearch: _fetchImageChoicesFromTmdb,
          ),
        );

        if (result != null && result != 'skip') {
          setState(() {
            movie.imageUrl = result;
          });
          await _persistEntries();
          _applyFilters();
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Manual search complete!')),
        );
      }
    }
  }

  Future<void> _debugBatman() async {
    final batman = _all.firstWhere(
      (m) => m.title.toLowerCase() == 'batman' && m.year == '1989',
      orElse: () =>
          MovieEntry(id: 'debug', title: 'Batman', year: '1989', imageUrl: ''),
    );

    print('--- DEBUGGING BATMAN (1989) ---');

    print('\n--- Testing iTunes ---');
    final itunesCleanTitle = batman.title;
    final itunesTitle = Uri.encodeQueryComponent(itunesCleanTitle);
    final itunesUrl =
        'https://itunes.apple.com/search?term=$itunesTitle&media=movie&entity=movie&limit=1';
    print('Requesting URL: $itunesUrl');
    try {
      final itunesResp = await http
          .get(Uri.parse(itunesUrl))
          .timeout(const Duration(seconds: 10));
      print('iTunes Response Status: ${itunesResp.statusCode}');
      print('iTunes Response Body: ${itunesResp.body}');
      if (itunesResp.statusCode == 200) {
        final art = _extractJsonString(itunesResp.body, 'artworkUrl100');
        print('iTunes Extracted Poster URL: $art');
      }
    } catch (e, s) {
      print('iTunes Fetch Error: $e\n$s');
    }

    print('\n--- Testing TMDB ---');
    if (_tmdbApiKey == null || _tmdbApiKey!.isEmpty) {
      print('TMDB API Key is not set.');
    } else {
      final tmdbCleanTitle = batman.title;
      final tmdbTitle = Uri.encodeQueryComponent(tmdbCleanTitle);
      final tmdbYear = '&year=${Uri.encodeQueryComponent(batman.year!)}';
      final tmdbUrl =
          'https://api.themoviedb.org/3/search/movie?query=$tmdbTitle$tmdbYear&api_key=$_tmdbApiKey';
      print('Requesting URL: $tmdbUrl');
      try {
        final tmdbResp = await http
            .get(Uri.parse(tmdbUrl))
            .timeout(const Duration(seconds: 10));
        print('TMDB Response Status: ${tmdbResp.statusCode}');
        print('TMDB Response Body: ${tmdbResp.body}');
        if (tmdbResp.statusCode == 200) {
          final path = _extractJsonString(tmdbResp.body, 'poster_path');
          print('TMDB Extracted Poster Path: $path');
        }
      } catch (e, s) {
        print('TMDB Fetch Error: $e\n$s');
      }
    }

    print('\n--- Testing OMDb ---');
    if (_omdbApiKey == null || _omdbApiKey!.isEmpty) {
      print('OMDb API Key is not set.');
    } else {
      final omdbCleanTitle = batman.title;
      final omdbTitle = Uri.encodeQueryComponent(omdbCleanTitle);
      final omdbYear = '&y=${Uri.encodeQueryComponent(batman.year!)}';
      final omdbUrl =
          'https://www.omdbapi.com/?apikey=$_omdbApiKey&t=$omdbTitle$omdbYear';
      print('Requesting URL: $omdbUrl');
      try {
        final omdbResp = await http
            .get(Uri.parse(omdbUrl))
            .timeout(const Duration(seconds: 10));
        print('OMDb Response Status: ${omdbResp.statusCode}');
        print('OMDb Response Body: ${omdbResp.body}');
        if (omdbResp.statusCode == 200) {
          final poster = _extractJsonString(omdbResp.body, 'Poster');
          print('OMDb Extracted Poster URL: $poster');
        }
      } catch (e, s) {
        print('OMDb Fetch Error: $e\n$s');
      }
    }

    print('\n--- DEBUGGING COMPLETE ---');
  }

  Future<void> _debugTronLegacy() async {
    final lastXml = _box.get('last_xml') as String?;
    if (lastXml == null || lastXml.isEmpty) {
      print('--- Cannot run debug: No XML has been loaded yet. ---');
      return;
    }

    print('--- DEBUGGING "Tron: Legacy" ---');

    try {
      final document = XmlDocument.parse(lastXml);
      final dvds = document.findAllElements('DVD');
      final tronEntry = dvds.firstWhere(
        (dvd) => (_firstText(dvd, ['Title']) ?? '').toLowerCase().contains(
          'tron: legacy',
        ),
      );

      print('Found entry for "Tron: Legacy". Checking media type tags...');

      final dim3dBluRay = _firstText(tronEntry, [
        'Dim3DBluRay',
      ], recursive: true);
      final bluRay = _firstText(tronEntry, ['BluRay']);
      final dvd = _firstText(tronEntry, ['DVD']);
      final mediaTypesNode = tronEntry.findElements('MediaTypes').firstOrNull;

      print('  <Dim3DBluRay>: $dim3dBluRay (Is it "true"?)');
      print('  <BluRay>: $bluRay');
      print('  <DVD>: $dvd');

      if (mediaTypesNode != null) {
        print('  Found <MediaTypes> node. Children:');
        for (final child in mediaTypesNode.children.whereType<XmlElement>()) {
          print('    <${child.name.local}>: ${child.innerText.trim()}');
        }
      } else {
        print('  No <MediaTypes> node found.');
      }
    } catch (e) {
      print('Could not find an entry with "Tron: Legacy" in the title.');
      print('Error details: $e');
    }

    print('\n--- DEBUGGING COMPLETE ---');
  }

  void _openSettings() async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) {
        return _SettingsDialog(
          initialTmdbApiKey: _tmdbApiKey,
          initialOmdbApiKey: _omdbApiKey,
        );
      },
    );

    if (result != null) {
      // Use setState to update the UI and trigger a rebuild
      setState(() {
        _tmdbApiKey = result['tmdb'];
        _omdbApiKey = result['omdb'];
      });
      // Persist the keys to storage
      await _box.put('tmdb_api_key', _tmdbApiKey);
      await _box.put('omdb_api_key', _omdbApiKey);

      // Optionally, show a confirmation and refresh images
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('API Keys saved!')));
        await _refreshMissingImages();
      }
    }
  }

  String? _firstText(
    XmlElement el,
    List<String> names, {
    bool recursive = false,
  }) {
    for (final name in names) {
      XmlElement? foundEl;
      if (recursive) {
        // Search recursively through all descendants
        try {
          foundEl = el.findAllElements(name).first;
        } catch (e) {
          // not found
        }
      } else {
        // Search only direct children
        try {
          foundEl = el.findElements(name).first;
        } catch (e) {
          // not found
        }
      }

      if (foundEl != null) {
        return foundEl.innerText.trim();
      }
    }
    return null;
  }

  String? _firstCoverFromCovers(XmlElement dvd) {
    final covers = dvd.getElement('Covers');
    if (covers == null) return null;
    final front = covers.getElement('Front') ?? covers.getElement('FrontImage');
    final v = front?.innerText.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  String? _normalizeRuntime(String? v) {
    if (v == null) return null;
    final m = RegExp(r"(\d+)").firstMatch(v);
    return m != null ? m.group(1) : v;
  }

  List<String> _normalizeMediaTypes(String? raw) {
    if (raw == null || raw.trim().isEmpty) return [];
    final v = raw.toLowerCase();
    final types = <String>{};
    if (v.contains('4k') || v.contains('uhd') || v.contains('ultra'))
      types.add('4K');
    if (v.contains('blu')) types.add('Blu-ray');
    if (v.contains('dvd')) types.add('DVD');
    if (v.contains('3d')) types.add('3D');
    if (types.isEmpty) types.add(raw.trim());
    return types.toList();
  }

  List<String> _extractMediaTypesFromDvd(XmlElement dvd) {
    final types = <String>{};
    final title = _firstText(dvd, ['Title']) ?? '';

    // Verbose logging for specific movies
    if (title.toLowerCase().contains('tron')) {
      print('--- PARSING MEDIA TYPES for "$title" ---');
    }

    final booleanFields = {
      'BluRay': 'Blu-ray',
      'Blu-ray': 'Blu-ray',
      'DVD': 'DVD',
      'UHD': '4K',
      'UltraHD': '4K',
      '4K': '4K',
      'Dim3DBluRay': '3D',
      'HD-DVD': 'HD-DVD',
      'VHS': 'VHS',
      'LaserDisc': 'LaserDisc',
    };

    // Check for nested <Format><Dimensions><Dim3DBluRay>
    final dim3d = _firstText(dvd, ['Dim3DBluRay'], recursive: true);
    if (title.toLowerCase().contains('tron')) {
      print('  Recursive search for <Dim3DBluRay> found: "$dim3d"');
    }
    if (dim3d != null && (dim3d.toLowerCase() == 'true' || dim3d == '1')) {
      types.add('3D');
      if (title.toLowerCase().contains('tron')) {
        print('  >>> ADDED "3D" to types set.');
      }
    }

    // Nested <MediaTypes><BluRay>true</BluRay>...</MediaTypes>
    final mediaTypesNodes = dvd.findElements('MediaTypes');
    if (mediaTypesNodes.isNotEmpty) {
      final mt = mediaTypesNodes.first;
      for (final child in mt.children.whereType<XmlElement>()) {
        final key = child.name.local;
        final displayName = booleanFields[key] ?? key;
        final val = child.innerText.trim().toLowerCase();
        if (val == 'true' || val == '1' || val == 'yes') {
          types.add(displayName);
        }
      }
    }

    for (final entry in booleanFields.entries) {
      final fieldName = entry.key;
      final displayName = entry.value;

      // Check if this field exists and is true
      final fieldValue = _firstText(dvd, [fieldName]);
      if (fieldValue != null &&
          (fieldValue.toLowerCase() == 'true' || fieldValue == '1')) {
        types.add(displayName);
      }
    }

    // Fallback to the old method if no boolean fields found
    if (types.isEmpty) {
      final raw = _firstText(dvd, const ['MediaType', 'MediaTypes']);
      return _normalizeMediaTypes(raw);
    }

    if (title.toLowerCase().contains('tron')) {
      print('  Final types for "$title": ${types.toList()}');
      print('--- FINISHED PARSING for "$title" ---');
    }
    return types.toList();
  }

  String? _extractJsonString(String body, String key) {
    final re = RegExp('"$key"\\s*:\\s*(".*?"|true|false|null|[0-9.]+)');
    final m = re.firstMatch(body);
    if (m == null) return null;
    var val = m.group(1)!;
    if (val.startsWith('"') && val.endsWith('"')) {
      val = val.substring(1, val.length - 1);
    }
    return val;
  }

  void _applyFilters() {
    List<MovieEntry> results = _all;
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      results = results
          .where(
            (m) =>
                m.title.toLowerCase().contains(q) ||
                (m.genres ?? '').toLowerCase().contains(q),
          )
          .toList();
    }
    if (_genreFilter != 'All') {
      results = results
          .where(
            (m) => (m.genres ?? '')
                .split(',')
                .map((s) => s.trim())
                .contains(_genreFilter),
          )
          .toList();
    }
    if (_selectedMediaTypes.isNotEmpty) {
      results = results
          .where(
            (m) => m.mediaTypes.any((t) => _selectedMediaTypes.contains(t)),
          )
          .toList();
    }
    if (_postersOnly) {
      results = results.where((m) => m.imageUrl.isNotEmpty).toList();
    }
    results.sort((a, b) {
      switch (_sortBy) {
        case 'Collection Number':
          final acn = a.collectionNumber ?? '';
          final bcn = b.collectionNumber ?? '';
          if (acn.isEmpty && bcn.isEmpty) {
            return a.title.toLowerCase().compareTo(b.title.toLowerCase());
          }
          if (acn.isEmpty) return 1;
          if (bcn.isEmpty) return -1;
          // Try numeric comparison first, then string (descending order)
          final anum = int.tryParse(acn);
          final bnum = int.tryParse(bcn);
          if (anum != null && bnum != null) {
            return bnum.compareTo(anum); // Reversed for descending
          }
          return bcn.toLowerCase().compareTo(
            acn.toLowerCase(),
          ); // Reversed for descending
        case 'Media Type':
          final ai = _mediaRankList(a.mediaTypes);
          final bi = _mediaRankList(b.mediaTypes);
          if (ai != bi) return ai.compareTo(bi);
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        case 'Title':
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        case 'Year':
          final ay = int.tryParse(a.year ?? '') ?? -1;
          final by = int.tryParse(b.year ?? '') ?? -1;
          final cmp = by.compareTo(ay);
          return cmp != 0
              ? cmp
              : a.title.toLowerCase().compareTo(b.title.toLowerCase());
        case 'Runtime':
          final ar = int.tryParse(a.runtime ?? '') ?? -1;
          final br = int.tryParse(b.runtime ?? '') ?? -1;
          final cmp = br.compareTo(ar);
          return cmp != 0
              ? cmp
              : a.title.toLowerCase().compareTo(b.title.toLowerCase());
        default:
          return 0;
      }
    });
    setState(() {
      _filtered = results;
    });
  }

  int _mediaRankList(List<String> types) {
    if (types.any((t) => t.toLowerCase().contains('4k'))) return 0;
    if (types.any((t) => t.toLowerCase().contains('blu'))) return 1;
    if (types.any((t) => t.toLowerCase().contains('dvd'))) return 2;
    return 3;
  }

  void _randomPick() async {
    if (_filtered.isEmpty) return;
    final random = Random();
    final movie = _filtered[random.nextInt(_filtered.length)];

    // Fetch RT score just-in-time if it's missing
    if (movie.rottenTomatoesScore == null ||
        movie.rottenTomatoesScore!.isEmpty) {
      await _fetchCoverFromOmdbForMovie(movie);
      await _persistEntries();
    }

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) => _SurpriseDialog(entry: movie),
    );
  }

  void _pickFromWatchNext() async {
    if (_watchNext.isEmpty) return;
    final random = Random();
    final movie = _watchNext[random.nextInt(_watchNext.length)];

    // Fetch RT score just-in-time if it's missing
    if (movie.rottenTomatoesScore == null ||
        movie.rottenTomatoesScore!.isEmpty) {
      await _fetchCoverFromOmdbForMovie(movie);
      await _persistEntries();
    }

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) => _SurpriseDialog(entry: movie),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Movie Picker'),
        actions: [
          IconButton(
            tooltip: 'Refresh Missing Images',
            onPressed: _refreshMissingImages,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings),
          ),
          IconButton(
            tooltip: 'Open XML',
            onPressed: _pickFile,
            icon: const Icon(Icons.upload_file),
          ),
        ],
      ),
      body: _all.isEmpty
          ? Center(
              child: DottedBorderContainer(
                highlight: _dragOver,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(Icons.cloud_upload, size: 48),
                    SizedBox(height: 12),
                    Text(
                      'Drop your DVD Profiler XML here or click the upload icon',
                    ),
                  ],
                ),
              ),
            )
          : Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: _buildFilterBar(),
                      ),
                      Expanded(child: _buildBody()),
                    ],
                  ),
                ),
                // Watch Next Panel
                Expanded(
                  flex: 1,
                  child: Container(
                    color: Theme.of(context).colorScheme.surfaceContainer,
                    child: Column(
                      children: [
                        _buildWatchNextHeader(),
                        Expanded(child: _buildWatchNextList()),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildBody() {
    final grid = GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 187,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
        childAspectRatio: 0.52,
      ),
      itemCount: _filtered.length,
      itemBuilder: (context, index) {
        final m = _filtered[index];
        return InkWell(
          onTap: () {
            setState(() {
              if (_watchNext.length < 16 && !_watchNext.contains(m)) {
                _watchNext.add(m);
              }
            });
          },
          child: _MovieCard(entry: m),
        );
      },
    );
    return grid;
  }

  Widget _buildWatchNextHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            'What are we watching?',
            style: Theme.of(context).textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            '(choose up to sixteen)',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              SizedBox(
                width: 180,
                child: FilledButton.icon(
                  onPressed: _watchNext.isNotEmpty ? _pickFromWatchNext : null,
                  icon: const Icon(Icons.casino),
                  label: const Text('Random'),
                ),
              ),
              SizedBox(
                width: 180,
                child: FilledButton.icon(
                  onPressed: _watchNext.isNotEmpty
                      ? () {
                          setState(() {
                            _watchNext.clear();
                          });
                        }
                      : null,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Clear'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildWatchNextList() {
    if (_watchNext.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16.0),
          child: Text(
            'Click a movie in the main list to add it to your queue.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(2),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.75,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
      ),
      itemCount: _watchNext.length,
      itemBuilder: (context, index) {
        final movie = _watchNext[index];
        return _WatchNextCard(
          entry: movie,
          onRemove: () {
            setState(() {
              _watchNext.removeAt(index);
            });
          },
        );
      },
    );
  }

  Widget _buildFilterBar() {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 12,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: TextField(
            onChanged: (v) {
              _query = v;
              _applyFilters();
            },
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search title or genre',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        DropdownButton<String>(
          value: _genreFilter,
          items: _genres
              .map((g) => DropdownMenuItem(value: g, child: Text(g)))
              .toList(),
          onChanged: (v) {
            if (v == null) return;
            setState(() => _genreFilter = v);
            _applyFilters();
          },
        ),
        const SizedBox(width: 16),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: _allMediaTypes.map((type) {
              final isSelected = _selectedMediaTypes.contains(type);
              return Padding(
                padding: const EdgeInsets.only(right: 8.0),
                child: FilterChip(
                  label: Text(type),
                  selected: isSelected,
                  onSelected: (selected) {
                    setState(() {
                      if (selected) {
                        _selectedMediaTypes.add(type);
                      } else {
                        _selectedMediaTypes.remove(type);
                      }
                      _applyFilters();
                    });
                  },
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(width: 12),
        Switch(
          value: _postersOnly,
          onChanged: (v) {
            setState(() => _postersOnly = v);
            _applyFilters();
          },
        ),
        const Text('Posters only'),
        DropdownButton<String>(
          value: _sortBy,
          items: const [
            DropdownMenuItem(
              value: 'Collection Number',
              child: Text('Sort: Collection Number'),
            ),
            DropdownMenuItem(
              value: 'Media Type',
              child: Text('Sort: Media Type'),
            ),
            DropdownMenuItem(value: 'Title', child: Text('Sort: Title')),
            DropdownMenuItem(value: 'Year', child: Text('Sort: Year')),
            DropdownMenuItem(value: 'Runtime', child: Text('Sort: Runtime')),
          ],
          onChanged: (v) {
            if (v == null) return;
            setState(() => _sortBy = v);
            _applyFilters();
          },
        ),
        FilledButton.icon(
          onPressed: _randomPick,
          icon: const Icon(Icons.casino),
          label: const Text('Surprise Me'),
        ),
      ],
    );
  }
}

class _MovieCard extends StatelessWidget {
  final MovieEntry entry;
  const _MovieCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withOpacity(0.6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: Stack(
              children: [
                _Poster(imageUrl: entry.imageUrl, title: entry.title),
                Positioned(
                  top: 8,
                  left: 8,
                  child: _CollectionNumberBadge(value: entry.collectionNumber),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    if ((entry.runtime ?? '').isNotEmpty)
                      _Chip(label: '${entry.runtime} min'),
                    if ((entry.mpaa ?? '').isNotEmpty)
                      _Chip(label: entry.mpaa!),
                    ...entry.mediaTypes
                        .where(
                          (t) =>
                              t.trim().isNotEmpty &&
                              t.toLowerCase() != 'true' &&
                              t.toLowerCase() != 'false',
                        )
                        .map((t) => _MediaTypeChip(label: t)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Poster extends StatelessWidget {
  final String imageUrl;
  final String title;
  const _Poster({required this.imageUrl, required this.title});

  @override
  Widget build(BuildContext context) {
    if (imageUrl.isEmpty) {
      return Container(
        width: double.infinity,
        height: double.infinity,
        color: Colors.black26,
        child: const Icon(Icons.image_not_supported_outlined),
      );
    }
    return Image.network(
      imageUrl,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              value: progress.expectedTotalBytes != null
                  ? progress.cumulativeBytesLoaded /
                        (progress.expectedTotalBytes ?? 1)
                  : null,
            ),
          ),
        );
      },
      errorBuilder: (context, error, stackTrace) {
        print('IMAGE LOAD ERROR: $error - URL: $imageUrl');
        return Container(
          color: Colors.black38,
          alignment: Alignment.center,
          padding: const EdgeInsets.all(12),
          child: const Icon(Icons.broken_image_outlined),
        );
      },
    );
  }
}

class _CollectionNumberBadge extends StatelessWidget {
  final String? value;
  const _CollectionNumberBadge({required this.value});

  @override
  Widget build(BuildContext context) {
    if (value == null || value!.trim().isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.8),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white30),
      ),
      child: Text(
        value!,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: Colors.white,
          fontSize: 11,
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  const _Chip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withOpacity(0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: Theme.of(context).textTheme.labelSmall),
    );
  }
}

class _MediaTypeChip extends StatelessWidget {
  final String label;
  const _MediaTypeChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final lower = label.toLowerCase();
    Color bg;
    Color border;
    if (lower.contains('blu')) {
      bg = Colors.blue.withOpacity(0.20);
      border = Colors.blue.withOpacity(0.35);
    } else if (lower.contains('4k') || lower.contains('ultra')) {
      bg = Colors.red.withOpacity(0.20);
      border = Colors.red.withOpacity(0.35);
    } else if (lower.contains('3d')) {
      bg = Colors.green.withOpacity(0.20);
      border = Colors.green.withOpacity(0.35);
    } else {
      bg = Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withOpacity(0.25);
      border = Colors.white24;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: Text(label, style: Theme.of(context).textTheme.labelSmall),
    );
  }
}

class DottedBorderContainer extends StatelessWidget {
  final Widget child;
  final bool highlight;
  const DottedBorderContainer({
    super.key,
    required this.child,
    required this.highlight,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      margin: const EdgeInsets.all(24),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHigh.withOpacity(0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: highlight
              ? Theme.of(context).colorScheme.primary
              : Colors.white24,
          width: 2,
          style: BorderStyle.solid,
        ),
      ),
      child: child,
    );
  }
}

class _SettingsDialog extends StatefulWidget {
  final String? initialTmdbApiKey;
  final String? initialOmdbApiKey;

  const _SettingsDialog({this.initialTmdbApiKey, this.initialOmdbApiKey});

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late final TextEditingController _tmdbController;
  late final TextEditingController _omdbController;

  @override
  void initState() {
    super.initState();
    _tmdbController = TextEditingController(
      text: widget.initialTmdbApiKey ?? '',
    );
    _omdbController = TextEditingController(
      text: widget.initialOmdbApiKey ?? '',
    );
  }

  @override
  void dispose() {
    _tmdbController.dispose();
    _omdbController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Settings'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _tmdbController,
              decoration: const InputDecoration(
                labelText: 'TMDb API Key',
                hintText: 'Enter your The Movie Database API key',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _omdbController,
              decoration: const InputDecoration(
                labelText: 'OMDb API Key',
                hintText: 'Enter your Open Movie Database API key',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final result = {
              'tmdb': _tmdbController.text.trim(),
              'omdb': _omdbController.text.trim(),
            };
            Navigator.pop(context, result);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _WatchNextCard extends StatelessWidget {
  final MovieEntry entry;
  final VoidCallback onRemove;

  const _WatchNextCard({required this.entry, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 2),
      elevation: 0,
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withOpacity(0.6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      clipBehavior: Clip.antiAlias,
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(
          children: [
            _Poster(imageUrl: entry.imageUrl, title: entry.title),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(
                      entry.title,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      entry.year ?? '',
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                icon: const Icon(
                  Icons.remove_circle_outline,
                  color: Colors.red,
                ),
                onPressed: onRemove,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SurpriseDialog extends StatelessWidget {
  final MovieEntry entry;
  const _SurpriseDialog({required this.entry});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 900,
          maxHeight: MediaQuery.of(context).size.height * 0.9,
        ),
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Enjoy the movie!',
                style: Theme.of(context).textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                entry.title,
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Flexible(
                child: SingleChildScrollView(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 2,
                        child: AspectRatio(
                          aspectRatio: 2 / 3,
                          child: _Poster(
                            imageUrl: entry.imageUrl,
                            title: entry.title,
                          ),
                        ),
                      ),
                      const SizedBox(width: 24),
                      Expanded(
                        flex: 3,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entry.overview ?? 'No summary available.',
                              style: Theme.of(context).textTheme.bodyLarge,
                            ),
                            const SizedBox(height: 16),
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: [
                                if ((entry.year ?? '').isNotEmpty)
                                  _Chip(label: entry.year!),
                                if ((entry.rottenTomatoesScore ?? '')
                                    .isNotEmpty)
                                  _Chip(
                                    label: '🍅 ${entry.rottenTomatoesScore!}',
                                  ),
                                if ((entry.runtime ?? '').isNotEmpty)
                                  _Chip(label: '${entry.runtime} min'),
                                if ((entry.mpaa ?? '').isNotEmpty)
                                  _Chip(label: entry.mpaa!),
                                ...entry.mediaTypes
                                    .where(
                                      (t) =>
                                          t.trim().isNotEmpty &&
                                          t.toLowerCase() != 'true' &&
                                          t.toLowerCase() != 'false',
                                    )
                                    .map((t) => _MediaTypeChip(label: t)),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  child: const Text('OK'),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

List<String> _getFuzzyTitles(String originalTitle) {
  final titles = <String>{}; // Use a Set to avoid duplicates
  titles.add(originalTitle);

  // Remove content in parentheses (e.g., year, edition)
  titles.add(originalTitle.replaceAll(RegExp(r'\s*\([^)]*\)'), '').trim());

  // Remove content after a colon (e.g., subtitle)
  titles.add(originalTitle.split(':').first.trim());

  // Combination: remove subtitle, then parentheses
  final noSubtitle = originalTitle.split(':').first.trim();
  titles.add(noSubtitle.replaceAll(RegExp(r'\s*\([^)]*\)'), '').trim());

  return titles.where((t) => t.isNotEmpty).toList();
}

class _FuzzySearchDialog extends StatefulWidget {
  final MovieEntry entry;
  final Future<List<String>> Function(String title, String? year) onSearch;

  const _FuzzySearchDialog({required this.entry, required this.onSearch});

  @override
  State<_FuzzySearchDialog> createState() => _FuzzySearchDialogState();
}

class _FuzzySearchDialogState extends State<_FuzzySearchDialog> {
  late final List<String> _searchTerms;
  int _currentSearchTermIndex = 0;
  late final TextEditingController _textController;

  List<String> _imageChoices = [];
  String? _selectedImageUrl;
  bool _isLoading = true;
  bool _noMoreTerms = false;

  @override
  void initState() {
    super.initState();
    _searchTerms = _getFuzzyTitles(widget.entry.title);
    _textController = TextEditingController(
      text: _searchTerms[_currentSearchTermIndex],
    );
    _fetchChoices();
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _fetchChoices({String? customSearchTerm}) async {
    setState(() {
      _isLoading = true;
      _imageChoices = [];
      _selectedImageUrl = null;
    });

    final searchTerm =
        customSearchTerm ?? _searchTerms[_currentSearchTermIndex];
    if (customSearchTerm == null) {
      _textController.text = searchTerm;
    }
    final results = await widget.onSearch(searchTerm, widget.entry.year);

    if (mounted) {
      setState(() {
        _imageChoices = results;
        _isLoading = false;
        _noMoreTerms = _currentSearchTermIndex >= _searchTerms.length - 1;
      });
    }
  }

  void _nextSearchTerm() {
    if (!_noMoreTerms) {
      _currentSearchTermIndex++;
      _textController.text = _searchTerms[_currentSearchTermIndex];
      _fetchChoices();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Manual Search: ${widget.entry.title}'),
      content: SizedBox(
        width: 800,
        height: 500,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _textController,
                    decoration: const InputDecoration(
                      labelText: 'Search Term',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: () =>
                      _fetchChoices(customSearchTerm: _textController.text),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _imageChoices.isEmpty
                  ? const Center(child: Text('No results found.'))
                  : GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 150,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8,
                            childAspectRatio: 2 / 3,
                          ),
                      itemCount: _imageChoices.length,
                      itemBuilder: (context, index) {
                        final url = _imageChoices[index];
                        final isSelected = url == _selectedImageUrl;
                        return InkWell(
                          onTap: () {
                            setState(() {
                              _selectedImageUrl = url;
                            });
                          },
                          child: GridTile(
                            child: Container(
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: isSelected
                                      ? Theme.of(context).colorScheme.primary
                                      : Colors.transparent,
                                  width: 4,
                                ),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: _Poster(
                                  imageUrl: url,
                                  title: widget.entry.title,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, 'skip'),
          child: const Text('Skip Movie'),
        ),
        FilledButton(
          onPressed: _noMoreTerms ? null : _nextSearchTerm,
          child: const Text('Next Variation'),
        ),
        FilledButton(
          onPressed: _selectedImageUrl != null
              ? () => Navigator.pop(context, _selectedImageUrl)
              : null,
          child: const Text('Accept'),
        ),
      ],
    );
  }
}
