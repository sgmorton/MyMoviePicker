import 'package:flutter_test/flutter_test.dart';
import 'package:movie_picker/src/services/invelos_scraper.dart';

/// Sample List.aspx-style rows (Title + Coll# only — no format column).
/// Formats verified against Invelos DVD.aspx UPC parenthetical labels where noted.
const dvdLabeledRow = '''
<TR><TD id="794043554926" bgcolor="#BFE5F1"><A HREF="DVD.aspx?U=794043554926" target="entry">The Lord of the Rings: The Fellowship of the Ring: Special Extended DVD Edition</A></TD><TD align="right" bgcolor="#BFE5F1">301</TD></TR>
''';

const bluRayRow = '''
<TR><TD id="025192091360" bgcolor="#BFE5F1"><A HREF="DVD.aspx?U=025192091360" target="entry">Despicable Me: Blu-ray 3D</A></TD><TD align="right" bgcolor="#BFE5F1">747</TD></TR>
''';

const fourKRow = '''
<TR><TD id="843501650837" bgcolor="#BFE5F1"><A HREF="DVD.aspx?U=843501650837" target="entry">Project Hail Mary: 4K Ultra HD</A></TD><TD align="right" bgcolor="#BFE5F1">1101</TD></TR>
''';

/// Bare retail UPC, no format words in title. Invelos detail labels this (DVD).
const bareDvdRow = '''
<TR><TD id="IB5E158B0E88A5D9F" bgcolor="#7FCBE3"><A HREF="DVD.aspx?U=IB5E158B0E88A5D9F" target="entry">Super 8</A></TD><TD align="right" bgcolor="#7FCBE3">12</TD></TR>
''';

/// 12-digit retail UPC with no format words — must NOT become Blu-ray by UPC length alone.
const bareRetailUpcRow = '''
<TR><TD id="012345678901" bgcolor="#BFE5F1"><A HREF="DVD.aspx?U=012345678901" target="entry">Some Mystery Title</A></TD><TD align="right" bgcolor="#BFE5F1">1</TD></TR>
''';

const comboRow = '''
<TR><TD id="5039036053747.4" bgcolor="#BFE5F1"><A HREF="DVD.aspx?U=5039036053747.4" target="entry">Avatar: Blu-ray 3D + Blu-ray + DVD</A></TD><TD align="right" bgcolor="#BFE5F1">1004</TD></TR>
''';

const listHtmlHeader = '''
<HTML><BODY><TABLE class="list" width="100%">
<TR bgColor="#006098"><TD>Title</TD><TD>Coll&nbsp;#</TD></TR>
''';

const listHtmlFooter = '''
</TABLE></BODY></HTML>
''';

void main() {
  group('detectMediaTypes', () {
    test('DVD keyword in title classifies as DVD, not Blu-ray', () {
      final types = InvelosScraper.detectMediaTypes(
        upc: '794043554926',
        title:
            'The Lord of the Rings: The Fellowship of the Ring: Special Extended DVD Edition',
        rowContent: dvdLabeledRow,
      );
      expect(types, contains('DVD'));
      expect(types.first, 'DVD');
      expect(types, isNot(contains('Blu-ray')));
    });

    test('Blu-ray + 3D title classifies correctly with Blu-ray primary', () {
      final types = InvelosScraper.detectMediaTypes(
        upc: '025192091360',
        title: 'Despicable Me: Blu-ray 3D',
        rowContent: bluRayRow,
      );
      expect(types, containsAll(['Blu-ray', '3D']));
      expect(types.first, 'Blu-ray');
    });

    test('4K Ultra HD title classifies as 4K primary', () {
      final types = InvelosScraper.detectMediaTypes(
        upc: '843501650837',
        title: 'Project Hail Mary: 4K Ultra HD',
        rowContent: fourKRow,
      );
      expect(types.first, '4K');
      expect(types, contains('4K'));
    });

    test('bare retail 12-digit UPC does not default to Blu-ray', () {
      final types = InvelosScraper.detectMediaTypes(
        upc: '012345678901',
        title: 'Some Mystery Title',
        rowContent: bareRetailUpcRow,
      );
      expect(types, ['DVD']);
    });

    test('UPC alternate-version suffix .4 is not treated as 4K', () {
      final types = InvelosScraper.detectMediaTypes(
        upc: '5039036053747.4',
        title: 'Some Title Without Format Words',
        rowContent: '<TR><TD>Some Title Without Format Words</TD></TR>',
      );
      expect(types, ['DVD']);
      expect(types, isNot(contains('4K')));
    });

    test('parenthetical (DVD) label in row is respected', () {
      final types = InvelosScraper.detectMediaTypes(
        upc: '794043554926',
        title: 'The Lord of the Rings',
        rowContent: 'UPC 794043-554926 (DVD)',
      );
      expect(types.first, 'DVD');
    });

    test('parenthetical (4K UltraHD) label in row is respected', () {
      final types = InvelosScraper.detectMediaTypes(
        upc: '843501650837',
        title: 'Project Hail Mary',
        rowContent: 'UPC 843501-650837 (4K UltraHD)',
      );
      expect(types.first, '4K');
    });

    test('combo Blu-ray + DVD prioritizes Blu-ray as primary', () {
      final types = InvelosScraper.detectMediaTypes(
        upc: '5039036053747.4',
        title: 'Avatar: Blu-ray 3D + Blu-ray + DVD',
        rowContent: comboRow,
      );
      expect(types.first, 'Blu-ray');
      expect(types, containsAll(['Blu-ray', 'DVD', '3D']));
    });
  });

  group('parseHtmlCollection media types', () {
    test('parses DVD, Blu-ray, and 4K sample rows with correct primary', () {
      final html = '$listHtmlHeader$dvdLabeledRow$bluRayRow$fourKRow$listHtmlFooter';
      final entries = InvelosScraper.parseHtmlCollection(html);
      expect(entries.length, 3);

      final dvd = entries.firstWhere((e) => e.id == '794043554926');
      expect(dvd.mediaType, 'DVD');
      expect(dvd.mediaTypes, ['DVD']);

      final blu = entries.firstWhere((e) => e.id == '025192091360');
      expect(blu.mediaType, 'Blu-ray');
      expect(blu.mediaTypes, containsAll(['Blu-ray', '3D']));

      final uhd = entries.firstWhere((e) => e.id == '843501650837');
      expect(uhd.mediaType, '4K');
      expect(uhd.mediaTypes.first, '4K');
    });

    test('known DVD Super 8 without format words defaults to DVD not Blu-ray', () {
      final html = '$listHtmlHeader$bareDvdRow$listHtmlFooter';
      final entries = InvelosScraper.parseHtmlCollection(html);
      expect(entries, hasLength(1));
      expect(entries.first.title, 'Super 8');
      expect(entries.first.mediaType, 'DVD');
      expect(entries.first.mediaTypes, ['DVD']);
    });
  });

  group('prioritizeMediaTypes', () {
    test('orders 4K above Blu-ray above DVD', () {
      expect(
        InvelosScraper.prioritizeMediaTypes(['DVD', '4K', 'Blu-ray']),
        ['4K', 'Blu-ray', 'DVD'],
      );
    });
  });
}