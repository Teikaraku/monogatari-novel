/// Data returned by a configured bookstore API (/api/v1).
library;

String? _url(Object? value) {
  if (value is! String || value.isEmpty) return null;
  final resolved = StoreConfig.absolute(value);
  return resolved.isEmpty ? null : resolved;
}

abstract final class StoreConfig {
  static const base = String.fromEnvironment('BOOKSTORE_BASE_URL', defaultValue: '');

  static bool get configured => isConfigured(base);

  static bool isConfigured(String baseUrl) {
    final uri = Uri.tryParse(baseUrl);
    return uri != null && (uri.scheme == 'https' || uri.scheme == 'http') && uri.host.isNotEmpty;
  }

  /// The API returns paths starting with `/`; absolute URLs are kept as they are.
  /// An unconfigured build never exposes remote URLs from cached responses.
  static String absolute(String path, {String baseUrl = base}) {
    if (!isConfigured(baseUrl)) return '';
    final uri = Uri.tryParse(path);
    if (uri == null || path.startsWith('//')) return '';
    if (uri.hasScheme) {
      return (uri.scheme == 'https' || uri.scheme == 'http') && uri.host.isNotEmpty ? path : '';
    }
    return Uri.parse(baseUrl).resolveUri(uri).toString();
  }
}

enum StoreStatus {
  completed,
  ongoing,
  unknown;

  static StoreStatus parse(Object? value) => switch (value) {
        'completed' => completed,
        'ongoing' => ongoing,
        _ => unknown,
      };
}

class StoreBook {
  const StoreBook({
    required this.id,
    required this.title,
    required this.author,
    required this.status,
    required this.tags,
    required this.volumes,
    required this.words,
    required this.updated,
    required this.cover,
    required this.coverLarge,
    this.description,
    this.readers,
    this.score,
    this.tv,
  });

  final String id;
  final String title;
  final String author;
  final StoreStatus status;
  final List<String> tags;
  final int volumes;
  final int words;
  final String updated;
  final String? cover;
  final String? coverLarge;

  /// Only featured entries on the home page carry a short description.
  final String? description;

  /// Distinct readers in the ranking period (rank lists only).
  final int? readers;

  /// The board's value on charts: readers, shelf count or weekly growth.
  final int? score;

  /// Anime adaptation info (TV lists and book details only).
  final StoreTv? tv;

  factory StoreBook.fromJson(Map<String, dynamic> json) => StoreBook(
        id: json['id'] as String,
        title: json['title'] as String? ?? '',
        author: json['author'] as String? ?? '',
        status: StoreStatus.parse(json['status']),
        tags: (json['tags'] as List? ?? const []).whereType<String>().toList(),
        volumes: json['volumes'] as int? ?? 0,
        words: json['words'] as int? ?? 0,
        updated: json['updated'] as String? ?? '',
        cover: _url(json['cover']),
        coverLarge: _url(json['cover_large']),
        description: json['description'] as String?,
        readers: json['readers'] as int?,
        score: json['score'] as int?,
        tv: json['tv_status'] != null
            ? StoreTv.fromJson(json)
            : json['tv'] is Map<String, dynamic>
                ? StoreTv.fromJson(json['tv'] as Map<String, dynamic>)
                : null,
      );
}

enum StoreTvStatus {
  airing,
  upcoming,
  completed;

  static StoreTvStatus parse(Object? value) => switch (value) {
        'airing' => airing,
        'completed' => completed,
        _ => upcoming,
      };
}

class StoreTv {
  const StoreTv({required this.season, required this.badge, required this.studio, required this.status});

  final String season;
  final String badge;
  final String studio;
  final StoreTvStatus status;

  factory StoreTv.fromJson(Map<String, dynamic> json) => StoreTv(
        season: json['season'] as String? ?? '',
        badge: json['badge'] as String? ?? '',
        studio: json['studio'] as String? ?? '',
        status: StoreTvStatus.parse(json['tv_status']),
      );
}

class StoreBanner {
  const StoreBanner({required this.key, required this.image, required this.imageSmall, required this.book});

  final String key;
  final String image;
  final String imageSmall;
  final StoreBook book;

  factory StoreBanner.fromJson(Map<String, dynamic> json) => StoreBanner(
        key: json['key'] as String,
        image: StoreConfig.absolute(json['image'] as String),
        imageSmall: StoreConfig.absolute(json['image_small'] as String),
        book: StoreBook.fromJson(json['book'] as Map<String, dynamic>),
      );
}

class StoreVolume {
  const StoreVolume({
    required this.n,
    required this.label,
    required this.size,
    required this.mtime,
    required this.url,
    this.chapters = 0,
  });

  final int n;
  final String label;
  final int size;
  final int mtime;
  final String url;

  /// Entries in the volume's table of contents; 0 when the server has none.
  final int chapters;

  factory StoreVolume.fromJson(Map<String, dynamic> json) => StoreVolume(
        n: json['n'] as int,
        label: json['label'] as String? ?? '',
        size: json['size'] as int? ?? 0,
        mtime: json['mtime'] as int? ?? 0,
        url: StoreConfig.absolute(json['url'] as String),
        chapters: json['chapters'] as int? ?? 0,
      );
}

/// One entry of a volume's table of contents; [href] is the full path inside the EPUB.
class StoreTocItem {
  const StoreTocItem({required this.title, required this.href, required this.level});

  final String title;
  final String href;
  final int level;

  factory StoreTocItem.fromJson(Map<String, dynamic> json) => StoreTocItem(
        title: json['title'] as String? ?? '',
        href: json['href'] as String? ?? '',
        level: json['level'] as int? ?? 0,
      );
}

class StoreBookDetail {
  const StoreBookDetail({
    required this.book,
    required this.illustrator,
    required this.publisher,
    required this.description,
    required this.chapters,
    required this.volumeList,
  });

  final StoreBook book;
  final String illustrator;
  final String publisher;
  final String description;
  final int chapters;
  final List<StoreVolume> volumeList;

  factory StoreBookDetail.fromJson(Map<String, dynamic> json) => StoreBookDetail(
        book: StoreBook.fromJson(json),
        illustrator: json['illustrator'] as String? ?? '',
        publisher: json['publisher'] as String? ?? '',
        description: json['description'] as String? ?? '',
        chapters: json['chapters'] as int? ?? 0,
        volumeList: (json['volume_list'] as List? ?? const [])
            .map((v) => StoreVolume.fromJson(v as Map<String, dynamic>))
            .toList(),
      );
}

class StoreTag {
  const StoreTag(this.name, this.count, [this.covers = const []]);

  final String name;
  final int count;

  /// Cover URLs of the tag's most read books (only when requested).
  final List<String> covers;

  factory StoreTag.fromJson(Map<String, dynamic> json) => StoreTag(
        json['name'] as String,
        json['count'] as int? ?? 0,
        (json['covers'] as List? ?? const []).whereType<String>().map(StoreConfig.absolute).toList(),
      );
}

class StoreTheme {
  const StoreTheme(
      {required this.key, required this.title, required this.tags, required this.total, required this.items});

  final String key;
  final String title;
  final List<String> tags;
  final int total;
  final List<StoreBook> items;

  factory StoreTheme.fromJson(Map<String, dynamic> json) => StoreTheme(
        key: json['key'] as String,
        title: json['title'] as String? ?? '',
        tags: (json['tags'] as List? ?? const []).whereType<String>().toList(),
        total: json['total'] as int? ?? 0,
        items: (json['items'] as List? ?? const []).map((b) => StoreBook.fromJson(b as Map<String, dynamic>)).toList(),
      );
}

class StoreDiscover {
  const StoreDiscover({required this.date, required this.pick, required this.themes});

  final String date;
  final StoreBook? pick;
  final List<StoreTheme> themes;

  factory StoreDiscover.fromJson(Map<String, dynamic> json) => StoreDiscover(
        date: json['date'] as String? ?? '',
        pick: json['pick'] is Map<String, dynamic> ? StoreBook.fromJson(json['pick'] as Map<String, dynamic>) : null,
        themes:
            (json['themes'] as List? ?? const []).map((t) => StoreTheme.fromJson(t as Map<String, dynamic>)).toList(),
      );
}

class StoreSection {
  const StoreSection(this.key, this.items);

  final String key;
  final List<StoreBook> items;
}

class StoreHome {
  const StoreHome({
    required this.version,
    required this.date,
    required this.banners,
    required this.sections,
    required this.tags,
  });

  final String version;
  final String date;
  final List<StoreBanner> banners;
  final List<StoreSection> sections;
  final List<StoreTag> tags;

  List<StoreBook> section(String key) =>
      sections.firstWhere((s) => s.key == key, orElse: () => StoreSection(key, const [])).items;

  factory StoreHome.fromJson(Map<String, dynamic> json) => StoreHome(
        version: json['version'] as String? ?? '',
        date: json['date'] as String? ?? '',
        banners:
            (json['banners'] as List? ?? const []).map((b) => StoreBanner.fromJson(b as Map<String, dynamic>)).toList(),
        sections: (json['sections'] as List? ?? const []).map((s) {
          final map = s as Map<String, dynamic>;
          return StoreSection(
            map['key'] as String,
            (map['items'] as List? ?? const []).map((b) => StoreBook.fromJson(b as Map<String, dynamic>)).toList(),
          );
        }).toList(),
        tags: (json['tags'] as List? ?? const []).map((t) => StoreTag.fromJson(t as Map<String, dynamic>)).toList(),
      );
}

class StorePage {
  const StorePage({required this.total, required this.offset, required this.items});

  final int total;
  final int offset;
  final List<StoreBook> items;

  bool get hasMore => offset + items.length < total;

  factory StorePage.fromJson(Map<String, dynamic> json) => StorePage(
        total: json['total'] as int? ?? 0,
        offset: json['offset'] as int? ?? 0,
        items: (json['items'] as List? ?? const []).map((b) => StoreBook.fromJson(b as Map<String, dynamic>)).toList(),
      );
}

enum StoreSort { updated, title, words, volumes, random }

enum StoreRankPeriod { day, week, month, total }

/// Chart boards; popular and completed take a period.
enum StoreBoard {
  popular,
  shelf,
  rising,
  completed,
  words,
  volumes,
  newest;

  String get api => this == newest ? 'new' : name;
  bool get periodic => this == popular || this == completed;
}
