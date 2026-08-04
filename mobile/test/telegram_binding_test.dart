import 'package:flutter_test/flutter_test.dart';
import 'package:nimbus_drive/core/network/api_exception.dart';
import 'package:nimbus_drive/features/settings/models/account.dart';
import 'package:nimbus_drive/features/telegram/data/bot_token_store.dart';
import 'package:nimbus_drive/features/telegram/data/telegram_repository.dart';
import 'package:nimbus_drive/features/telegram/telegram_binding_controller.dart';

class _FakeTelegram implements TelegramRepository {
  _FakeTelegram({this.bindError, this.testOk = true});

  final ApiException? bindError;
  final bool testOk;

  String? boundToken;
  int? boundChannel;
  bool unbound = false;

  @override
  Future<TelegramBinding> bind({
    required String botToken,
    required int channelId,
    String? channelName,
  }) async {
    if (bindError != null) throw bindError!;
    boundToken = botToken;
    boundChannel = channelId;
    return TelegramBinding(
      channelId: channelId,
      channelName: channelName,
      isActive: true,
    );
  }

  @override
  Future<TelegramTestResult> test() async => TelegramTestResult(
    ok: testOk,
    detail: testOk ? 'Posted a test message' : 'Bot is not an administrator',
  );

  @override
  Future<TelegramBinding?> read() async => null;

  @override
  Future<void> unbind() async => unbound = true;
}

void main() {
  group('input shapes', () {
    test('accepts a BotFather token', () {
      expect(
        TelegramBindingController.isValidTokenShape(
          '123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw',
        ),
        isTrue,
      );
    });

    test('rejects tokens that are obviously not one', () {
      for (final bad in ['', 'abc', 'not:short', '123456789', ':::']) {
        expect(
          TelegramBindingController.isValidTokenShape(bad),
          isFalse,
          reason: bad,
        );
      }
    });

    test('channel ids must be negative', () {
      // A positive value is a user id pasted by mistake; the server rejects it
      // outright, so catching it here saves a round trip.
      expect(
        TelegramBindingController.isValidChannelId('-1001234567890'),
        isTrue,
      );
      expect(
        TelegramBindingController.isValidChannelId('1001234567890'),
        isFalse,
      );
      expect(TelegramBindingController.isValidChannelId('nope'), isFalse);
    });
  });

  group('flow', () {
    test('cannot advance past a step whose value is wrong', () {
      final c = TelegramBindingController(
        _FakeTelegram(),
        InMemoryBotTokenStore(),
      );

      c.next(); // channel -> botToken
      expect(c.step, BindingStep.botToken);

      c.next(); // blocked: no token yet
      expect(c.step, BindingStep.botToken);
      expect(c.stepIssue, isNotNull);

      c.setBotToken('123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw');
      c.next();
      expect(c.step, BindingStep.admin);
    });

    test('a successful bind stores the token for direct uploads', () async {
      final telegram = _FakeTelegram();
      final tokens = InMemoryBotTokenStore();
      final c = TelegramBindingController(telegram, tokens);

      c.setBotToken('123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw');
      c.setChannelId('-1001234567890');

      expect(await c.submit(), isTrue);
      expect(telegram.boundChannel, -1001234567890);
      // The server only ever returns a mask, so this local copy is the only
      // way the ≤20 MB direct path can reach Telegram.
      expect(await tokens.read(), telegram.boundToken);
    });

    test(
      'a failed test reports the reason and does not claim success',
      () async {
        final c = TelegramBindingController(
          _FakeTelegram(testOk: false),
          InMemoryBotTokenStore(),
        );

        c.setBotToken('123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw');
        c.setChannelId('-1001234567890');

        expect(await c.submit(), isFalse);
        expect(c.error, contains('administrator'));
      },
    );

    test('server error codes become an action, and point at a step', () async {
      final c = TelegramBindingController(
        _FakeTelegram(
          bindError: const ApiException(
            code: 'CHAT_WRITE_FORBIDDEN',
            message: 'the bot is not an administrator of the chat',
          ),
        ),
        InMemoryBotTokenStore(),
      );

      c.setBotToken('123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw');
      c.setChannelId('-1001234567890');

      expect(await c.submit(), isFalse);
      expect(c.error, contains('Post messages'));
      expect(c.stepToFix, BindingStep.admin);
    });

    test('disconnecting clears the locally held token', () async {
      final telegram = _FakeTelegram();
      final tokens = InMemoryBotTokenStore();
      await tokens.write('123456789:secret');

      await unbindTelegram(telegram, tokens);

      expect(telegram.unbound, isTrue);
      // Leaving a live credential behind after "disconnect" is not defensible.
      expect(await tokens.read(), isNull);
    });
  });
}
