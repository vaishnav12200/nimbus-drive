// ignore_for_file: avoid_print — this is a diagnostic tool, not app code.
// Not part of the default suite (no `_test` suffix): this one needs a real
// backend on 127.0.0.1:8000. Run it deliberately:
//
//   flutter test test/live_backend_check.dart
//
// It exists because a mocked adapter proves the client is self-consistent, not
// that it agrees with the server.
import 'package:flutter_test/flutter_test.dart';
import 'package:nimbus_drive/core/network/api_client.dart';
import 'package:nimbus_drive/core/network/token_store.dart';
import 'package:nimbus_drive/features/auth/data/auth_repository.dart';
import 'package:nimbus_drive/features/files/data/api_file_repository.dart';
import 'package:nimbus_drive/features/files/models/file_query.dart';

void main() {
  test('round-trips against the live API', () async {
    final tokens = InMemoryTokenStore();
    final api = ApiClient(tokens, baseUrl: 'http://127.0.0.1:8000/api');
    final auth = ApiAuthRepository(api, tokens);
    final files = ApiFileRepository(api);

    final email =
        'live${DateTime.now().millisecondsSinceEpoch}@nimbus.example.com';

    final user = await auth.register(
      email: email,
      password: 'correct-horse-battery',
    );
    expect(user.email, email);
    print('register   -> ${user.email} (${user.name})');

    expect((await auth.restore())?.email, email);
    print('restore    -> ok');

    final folder = await files.createFolder(name: 'From Flutter');
    print('mkdir      -> ${folder.name}');

    var listing = await files.list(query: const FileQuery());
    expect(listing.items.map((i) => i.name), contains('From Flutter'));
    print('list root  -> ${listing.items.map((i) => i.name).join(", ")}');

    final inside = await files.list(
      folderId: folder.id,
      query: const FileQuery(),
    );
    expect(inside.breadcrumbs.map((f) => f.name), ['From Flutter']);
    print('breadcrumb -> ${inside.breadcrumbs.map((f) => f.name).join(" / ")}');

    await files.rename(folder.id, 'Renamed by Flutter');
    listing = await files.list(query: const FileQuery());
    expect(listing.items.first.name, 'Renamed by Flutter');
    print('rename     -> ${listing.items.first.name}');

    final summary = await files.summary();
    print('summary    -> used=${summary.storageUsed} bytes');

    await files.delete(folder.id);
    listing = await files.list(query: const FileQuery());
    expect(listing.items, isEmpty);
    print('delete     -> empty again');

    await auth.signOut();
    expect(await tokens.read(), isNull);
    print('signout    -> tokens cleared');
  });
}
