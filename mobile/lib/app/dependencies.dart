import '../core/network/api_client.dart';
import '../core/network/token_store.dart';
import '../features/auth/auth_controller.dart';
import '../features/auth/data/auth_repository.dart';
import '../features/auth/models/auth_user.dart';
import '../features/files/data/api_file_repository.dart';
import '../features/files/data/file_repository.dart';
import '../features/files/data/in_memory_file_repository.dart';
import '../features/shared/data/api_share_repository.dart';
import '../features/shared/data/share_repository.dart';
import '../features/uploads/data/fake_transfer_repository.dart';
import '../features/uploads/data/transfer_repository.dart';

/// Everything the app is built out of, wired once.
///
/// The single place that decides whether the app talks to the real backend or
/// to fakes. Screens never see this — they take controllers, and controllers
/// take interfaces.
class Dependencies {
  Dependencies._({
    required this.api,
    required this.tokens,
    required this.auth,
    required this.files,
    required this.shares,
    required TransferRepository Function() transfers,
  }) : _makeTransfers = transfers;

  /// Wires the real backend.
  factory Dependencies.live({String? baseUrl}) {
    final tokens = createTokenStore();
    final api = ApiClient(tokens, baseUrl: baseUrl);
    final files = ApiFileRepository(api);

    return Dependencies._(
      api: api,
      tokens: tokens,
      auth: AuthController(ApiAuthRepository(api, tokens), client: api),
      files: files,
      shares: ApiShareRepository(api),
      // Still a fake: sending bytes needs a file picker and the Telegram Bot
      // API client, neither of which exists yet. Everything around it — the
      // queue, the routes, the failure states — is real.
      transfers: FakeTransferRepository.new,
    );
  }

  /// Wires the in-memory drive, for UI work without a server.
  ///
  /// Kept because it is genuinely useful: the fakes reproduce latency, name
  /// clashes and the encrypted-share refusal, so screens can be built and
  /// reviewed offline.
  factory Dependencies.fake() {
    final tokens = InMemoryTokenStore();
    final api = ApiClient(tokens);
    final files = InMemoryFileRepository();

    return Dependencies._(
      api: api,
      tokens: tokens,
      auth: AuthController(_AlwaysSignedInRepository()),
      files: files,
      shares: InMemoryShareRepository(),
      transfers: FakeTransferRepository.new,
    );
  }

  final ApiClient api;
  final TokenStore tokens;
  final AuthController auth;
  final FileRepository files;
  final ShareRepository shares;

  final TransferRepository Function() _makeTransfers;
  TransferRepository? _transfers;

  /// Built on first use. The fake drives a periodic ticker, so constructing it
  /// eagerly would run a timer for the whole session even if the Upload tab is
  /// never opened — and leave one pending after teardown.
  TransferRepository get transfers => _transfers ??= _makeTransfers();

  void dispose() {
    auth.dispose();
    _transfers?.dispose();
    api.dispose();
  }
}

/// Skips the sign-in screen when running against fakes.
///
/// Fake mode exists to look at screens, and making someone sign in to a
/// non-existent server first would defeat that.
class _AlwaysSignedInRepository implements AuthRepository {
  static const _user = AuthUser(
    id: 'local',
    email: 'you@example.com',
    displayName: 'Nimbus User',
    encryptionEnabled: true,
    hasPassword: true,
    linkedProviders: [],
  );

  @override
  Future<AuthUser> register({
    required String email,
    required String password,
    String? displayName,
  }) async => _user;

  @override
  Future<AuthUser> signIn({
    required String email,
    required String password,
  }) async => _user;

  @override
  Future<AuthUser?> restore() async => _user;

  @override
  Future<void> signOut() async {}

  @override
  Future<void> signOutEverywhere() async {}

  @override
  Future<List<AuthSession>> sessions() async => const [];
}
