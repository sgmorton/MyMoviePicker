import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';
import '../../main.dart' show MovieEntry;
import 'package:hive/hive.dart';

class DbHelper {
  static final DbHelper _instance = DbHelper._internal();
  factory DbHelper() => _instance;
  DbHelper._internal();

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDatabase();
    return _db!;
  }

  Future<Database> _initDatabase() async {
    print('Initializing SQLite Database...');
    if (kIsWeb) {
      databaseFactory = databaseFactoryFfiWeb;
      print('Using databaseFactoryFfiWeb');
    } else if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      print('Using databaseFactoryFfi');
    }

    final dbPath = await getDatabasesPath();
    final path = '$dbPath/movie_picker.db';
    print('Database path: $path');

    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        print('Creating tables in SQLite database...');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS key_value_store (
            key TEXT PRIMARY KEY,
            value TEXT
          )
        ''');

        await db.execute('''
          CREATE TABLE IF NOT EXISTS movies (
            id TEXT PRIMARY KEY,
            title TEXT,
            year TEXT,
            genres TEXT,
            mediaType TEXT,
            mediaTypes TEXT,
            runtime TEXT,
            frontImageFilename TEXT,
            imageUrl TEXT,
            mpaa TEXT,
            isCollectionParent INTEGER,
            collectionNumber TEXT,
            overview TEXT,
            rottenTomatoesScore TEXT
          )
        ''');

        await db.execute('''
          CREATE TABLE IF NOT EXISTS image_cache (
            filename TEXT PRIMARY KEY,
            bytes BLOB
          )
        ''');
        print('Tables created successfully.');
      },
    );
  }

  // Settings Key-Value Store Operations
  Future<void> saveSetting(String key, String value) async {
    final db = await database;
    await db.insert(
      'key_value_store',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> getSetting(String key) async {
    final db = await database;
    final results = await db.query(
      'key_value_store',
      where: 'key = ?',
      whereArgs: [key],
    );
    if (results.isEmpty) return null;
    return results.first['value'] as String?;
  }

  Future<void> deleteSetting(String key) async {
    final db = await database;
    await db.delete(
      'key_value_store',
      where: 'key = ?',
      whereArgs: [key],
    );
  }

  // Movie Database Operations
  Future<void> insertMovie(MovieEntry movie) async {
    final db = await database;
    await db.insert(
      'movies',
      _movieToMap(movie),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> insertMovies(List<MovieEntry> movies) async {
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final m in movies) {
        batch.insert(
          'movies',
          _movieToMap(m),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<MovieEntry>> getAllMovies() async {
    final db = await database;
    final results = await db.query('movies');
    return results.map((map) => _movieFromMap(map)).toList();
  }

  Future<void> deleteMovies(List<String> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final id in ids) {
        batch.delete(
          'movies',
          where: 'id = ?',
          whereArgs: [id],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> clearMovies() async {
    final db = await database;
    await db.delete('movies');
  }

  // Image Cache Operations
  Future<void> cacheImage(String filename, List<int> bytes) async {
    final db = await database;
    await db.insert(
      'image_cache',
      {'filename': filename.toLowerCase(), 'bytes': bytes},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, dynamic>> getAllCachedImages() async {
    final db = await database;
    final results = await db.query('image_cache');
    final map = <String, dynamic>{};
    for (final row in results) {
      final filename = row['filename'] as String;
      final bytes = row['bytes'] as List<int>;
      map[filename] = bytes;
    }
    return map;
  }

  Future<void> clearCachedImages() async {
    final db = await database;
    await db.delete('image_cache');
  }

  // Migration Helper from Hive
  Future<void> migrateFromHiveIfNeeded() async {
    try {
      final db = await database;

      // Check if migration is already done by checking key_value_store for a flag
      final migratedFlag = await getSetting('hive_migrated');
      if (migratedFlag == 'true') {
        print('Hive data migration was already completed.');
        return;
      }

      print('Checking for Hive data to migrate...');
      if (await Hive.boxExists('movie_picker')) {
        print('Hive box "movie_picker" found! Starting migration...');
        final hiveBox = await Hive.openBox('movie_picker');

        // 1. Migrate settings
        final keys = ['tmdb_api_key', 'omdb_api_key', 'last_xml', 'data_version'];
        for (final k in keys) {
          final val = hiveBox.get(k);
          if (val != null) {
            await saveSetting(k, val.toString());
            print('Migrated setting: $k = $val');
          }
        }

        // 2. Migrate image files
        final imageFiles = hiveBox.get('image_files') as Map?;
        if (imageFiles != null) {
          print('Migrating ${imageFiles.length} cached images from Hive...');
          int count = 0;
          for (final entry in imageFiles.entries) {
            final filename = entry.key as String;
            final bytes = entry.value as List<int>;
            await cacheImage(filename, bytes);
            count++;
          }
          print('Successfully migrated $count images.');
        }

        // 3. Migrate movie entries
        final entriesList = hiveBox.get('entries') as List?;
        if (entriesList != null) {
          print('Migrating ${entriesList.length} movies from Hive...');
          final movies = <MovieEntry>[];
          for (final raw in entriesList) {
            final map = Map<String, dynamic>.from(raw as Map);
            movies.add(MovieEntry.fromMap(map));
          }
          await insertMovies(movies);
          print('Successfully migrated ${movies.length} movies.');
        }

        // Mark as migrated in SQLite
        await saveSetting('hive_migrated', 'true');

        // Delete Hive box data and clear it to clean up
        await hiveBox.clear();
        await hiveBox.close();
        print('Hive box cleared and closed.');
      } else {
        print('No Hive box found, marking migration flag as true.');
        await saveSetting('hive_migrated', 'true');
      }
    } catch (e, s) {
      print('ERROR DURING HIVE-TO-SQLITE MIGRATION: $e\n$s');
    }
  }

  // Serialization helpers
  Map<String, dynamic> _movieToMap(MovieEntry m) {
    return {
      'id': m.id,
      'title': m.title,
      'year': m.year,
      'genres': m.genres,
      'mediaType': m.mediaType,
      'mediaTypes': m.mediaTypes.join(','), // CSV in database
      'runtime': m.runtime,
      'frontImageFilename': m.frontImageFilename,
      'imageUrl': m.imageUrl,
      'mpaa': m.mpaa,
      'isCollectionParent': m.isCollectionParent ? 1 : 0,
      'collectionNumber': m.collectionNumber,
      'overview': m.overview,
      'rottenTomatoesScore': m.rottenTomatoesScore,
    };
  }

  MovieEntry _movieFromMap(Map<String, dynamic> map) {
    final mediaTypesStr = map['mediaTypes'] as String? ?? '';
    final mediaTypesList = mediaTypesStr.isNotEmpty 
        ? mediaTypesStr.split(',').map((e) => e.trim()).toList()
        : <String>[];

    final rawUrl = map['imageUrl'] as String? ?? '';
    final sanitizedUrl = rawUrl.contains('invelos.com') ? '' : rawUrl;

    return MovieEntry(
      id: map['id'] as String,
      title: map['title'] as String,
      year: map['year'] as String?,
      genres: map['genres'] as String?,
      mediaType: map['mediaType'] as String?,
      mediaTypes: mediaTypesList,
      runtime: map['runtime'] as String?,
      frontImageFilename: map['frontImageFilename'] as String?,
      imageUrl: sanitizedUrl,
      mpaa: map['mpaa'] as String?,
      isCollectionParent: (map['isCollectionParent'] as int? ?? 0) == 1,
      collectionNumber: map['collectionNumber'] as String?,
      overview: map['overview'] as String?,
      rottenTomatoesScore: map['rottenTomatoesScore'] as String?,
    );
  }
}
