import 'package:flutter_test/flutter_test.dart';
import 'package:nimbus_drive/features/auth/auth_controller.dart';
import 'package:nimbus_drive/features/auth/data/auth_repository.dart';
import 'package:nimbus_drive/features/auth/models/auth_user.dart';

/// A repository whose `restore` misbehaves in a specific way.
class _Repo implements AuthRepository {
  _Repo(this._restore);

  final Future<AuthUser?> Function() _restore;

  @override
  Future<AuthUser?> restore() => _restore();

  @override
  Future<AuthUser> register({
    required String email,
    required String password,
    String? displayName,
  }) => throw UnimplementedError();

  @override
  Future<AuthUser> signIn({required String email, required String password}) =>
      throw UnimplementedError();

  @override
  Future<void> signOut() async {}

  @override
  Future<void> signOutEverywhere() async {}

  @override
  Future<List<AuthSession>> sessions() async => const [];
}

/// Polls until [condition] holds, so a test does not guess at timings.
Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not met in $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  group('restore always reaches a usable state', () {
    test('a thrown error lands on sign-in, not the splash', () async {
      // This is the shipped bug: reading the keystore threw, the exception
      // escaped `restore`, and the splash screen stayed up forever with
      // nothing on it the user could act on.
      final controller = AuthController(
        _Repo(() async => throw Exception('keystore unavailable')),
      );
      addTearDown(controller.dispose);

      await _until(() => controller.status != AuthStatus.restoring);
      expect(controller.status, AuthStatus.signedOut);
    });

    test('a synchronous throw is caught too', () async {
      final controller = AuthController(_Repo(() => throw StateError('boom')));
      addTearDown(controller.dispose);

      await _until(() => controller.status != AuthStatus.restoring);
      expect(controller.status, AuthStatus.signedOut);
    });

    test('no stored session goes straight to sign-in', () async {
      final controller = AuthController(_Repo(() async => null));
      addTearDown(controller.dispose);

      await _until(() => controller.status != AuthStatus.restoring);
      expect(controller.status, AuthStatus.signedOut);
    });

    test('a valid session signs in', () async {
      const user = AuthUser(
        id: 'u1',
        email: 'you@example.com',
        encryptionEnabled: false,
        hasPassword: true,
        linkedProviders: [],
      );

      final controller = AuthController(_Repo(() async => user));
      addTearDown(controller.dispose);

      await _until(() => controller.status != AuthStatus.restoring);
      expect(controller.status, AuthStatus.signedIn);
      expect(controller.user?.email, 'you@example.com');
    });

    test('the slow flag only appears while still restoring', () async {
      final controller = AuthController(_Repo(() async => null));
      addTearDown(controller.dispose);

      await _until(() => controller.status != AuthStatus.restoring);
      // A fast restore must never leave "waking the server" on screen.
      expect(controller.restoreIsSlow, isFalse);
    });
  });
}
