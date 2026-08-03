import '../../files/models/drive_item.dart';
import '../models/share_link.dart';

abstract interface class ShareRepository {
  Future<List<ShareLink>> list();

  /// Revokes immediately. There is no undo — the server deletes the row, and
  /// a link that came back to life after being revoked would be worse than no
  /// undo at all.
  Future<void> revoke(String id);
}

class InMemoryShareRepository implements ShareRepository {
  InMemoryShareRepository({this.latency = const Duration(milliseconds: 400)});

  final Duration latency;

  late final List<ShareLink> _links = _seed();

  @override
  Future<List<ShareLink>> list() async {
    await Future<void>.delayed(latency);
    // Newest first: the link you just made is the one you are looking for.
    return [..._links]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  @override
  Future<void> revoke(String id) async {
    await Future<void>.delayed(latency);
    _links.removeWhere((l) => l.id == id);
  }

  static List<ShareLink> _seed() {
    final now = DateTime.now();
    const mb = 1024 * 1024;

    return [
      ShareLink(
        id: 's1',
        token: 'k3f9d2ab',
        fileName: 'brand-guide.pdf',
        fileType: FileType.document,
        fileSize: 8912896,
        createdAt: now.subtract(const Duration(days: 2)),
        expiresAt: now.add(const Duration(days: 5)),
        maxDownloads: 50,
        downloadCount: 12,
      ),
      ShareLink(
        id: 's2',
        token: 'p8w1zz04',
        fileName: 'launch-teaser-final.mp4',
        fileType: FileType.video,
        fileSize: 412 * mb,
        createdAt: now.subtract(const Duration(hours: 6)),
        hasPassword: true,
      ),
      ShareLink(
        id: 's3',
        token: 'm2c7yq11',
        fileName: 'invoice-2026-07.pdf',
        fileType: FileType.document,
        fileSize: 184320,
        createdAt: now.subtract(const Duration(days: 9)),
        expiresAt: now.subtract(const Duration(days: 1)),
        downloadCount: 3,
      ),
      ShareLink(
        id: 's4',
        token: 'v5t0nn83',
        fileName: 'mockup-home.png',
        fileType: FileType.image,
        fileSize: 3145728,
        createdAt: now.subtract(const Duration(days: 4)),
        maxDownloads: 5,
        downloadCount: 5,
      ),
    ];
  }
}
