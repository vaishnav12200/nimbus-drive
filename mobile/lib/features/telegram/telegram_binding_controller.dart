import 'package:flutter/foundation.dart';

import '../../core/network/api_exception.dart';
import 'data/bot_token_store.dart';
import 'data/telegram_repository.dart';

/// The steps of the guided binding.
///
/// Two of them are instructions and two collect a value. They are separate
/// screens rather than one long form because each requires leaving the app for
/// Telegram and coming back — a single form would lose its place every time.
enum BindingStep {
  channel('Create a channel'),
  botToken('Create a bot'),
  admin('Add the bot'),
  channelId('Find the channel ID'),
  test('Connect');

  const BindingStep(this.title);

  final String title;
}

class TelegramBindingController extends ChangeNotifier {
  TelegramBindingController(this._repository, this._tokens);

  final TelegramRepository _repository;
  final BotTokenStore _tokens;

  BindingStep _step = BindingStep.channel;
  String _botToken = '';
  String _channelId = '';
  String _channelName = '';

  bool _busy = false;
  String? _error;
  TelegramTestResult? _result;

  BindingStep get step => _step;
  String get botToken => _botToken;
  String get channelId => _channelId;
  bool get busy => _busy;
  String? get error => _error;
  TelegramTestResult? get result => _result;

  bool get isFirst => _step.index == 0;
  bool get isLast => _step == BindingStep.test;
  double get progress => (_step.index + 1) / BindingStep.values.length;

  /// `<digits>:<secret>`, the shape BotFather issues.
  ///
  /// Checked here so an obviously wrong paste is caught before a round trip;
  /// the server rejects the same shape with `BOT_TOKEN_MALFORMED`.
  static bool isValidTokenShape(String value) {
    final parts = value.trim().split(':');
    if (parts.length != 2) return false;
    return int.tryParse(parts[0]) != null && parts[1].length >= 20;
  }

  /// Channel ids are always negative — a positive value is a user id pasted by
  /// mistake, which the server also rejects outright.
  static bool isValidChannelId(String value) {
    final parsed = int.tryParse(value.trim());
    return parsed != null && parsed < 0;
  }

  String? get stepIssue => switch (_step) {
    BindingStep.botToken when !isValidTokenShape(_botToken) =>
      'A bot token looks like 123456789:AA... — paste the whole line',
    BindingStep.channelId when !isValidChannelId(_channelId) =>
      'A channel ID is negative, like -1001234567890',
    _ => null,
  };

  bool get canAdvance => stepIssue == null;

  void setBotToken(String value) {
    _botToken = value.trim();
    _error = null;
    notifyListeners();
  }

  void setChannelId(String value) {
    _channelId = value.trim();
    _error = null;
    notifyListeners();
  }

  void setChannelName(String value) {
    _channelName = value.trim();
    notifyListeners();
  }

  void next() {
    if (!canAdvance || isLast) return;
    _step = BindingStep.values[_step.index + 1];
    _error = null;
    notifyListeners();
  }

  void back() {
    if (isFirst) return;
    _step = BindingStep.values[_step.index - 1];
    _error = null;
    notifyListeners();
  }

  /// Saves the binding, then runs the server's end-to-end check.
  ///
  /// Both happen here because a binding that saved but cannot post is not
  /// usable, and finding that out on the next screen would be worse.
  Future<bool> submit() async {
    _busy = true;
    _error = null;
    _result = null;
    notifyListeners();

    try {
      await _repository.bind(
        botToken: _botToken,
        channelId: int.parse(_channelId),
        channelName: _channelName.isEmpty ? null : _channelName,
      );

      // Kept on the device deliberately: files at or under 20 MB go straight
      // from here to the Bot API, and the server never returns the token in
      // full — only a mask. Without this copy the direct upload path cannot
      // exist.
      await _tokens.write(_botToken);

      _result = await _repository.test();
      if (!_result!.ok) {
        _error = _result!.detail ?? 'Telegram refused the connection';
      }
      return _result!.ok;
    } on ApiException catch (e) {
      _error = _explain(e);
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Maps the server's Telegram error codes onto the step that can fix them.
  ///
  /// `docs/API.md` writes these for display, but they describe Telegram's
  /// complaint rather than the user's next action, so the action is appended.
  static String _explain(ApiException e) => switch (e.code) {
    'BOT_TOKEN_MALFORMED' =>
      'That does not look like a bot token. Copy the whole line from BotFather.',
    'BOT_TOKEN_INVALID' =>
      'Telegram rejected the token. It may have been revoked — use /token in '
          'BotFather to get a fresh one.',
    'CHANNEL_INVALID' =>
      'No channel with that ID, or the bot is not a member of it. Check the ID '
          'and that you added the bot.',
    'CHAT_WRITE_FORBIDDEN' =>
      'The bot is in the channel but cannot post. Make it an administrator '
          'with "Post messages" enabled.',
    'BOT_BLOCKED' =>
      'The bot is blocked. Unblock it in Telegram and try again.',
    _ => e.message,
  };

  /// The step whose input caused [error], so the flow can jump back to it.
  BindingStep? get stepToFix => switch (_error) {
    null => null,
    _ when _error!.contains('bot token') || _error!.contains('BotFather') =>
      BindingStep.botToken,
    _ when _error!.contains('channel ID') => BindingStep.channelId,
    _ when _error!.contains('administrator') => BindingStep.admin,
    _ => null,
  };

  void goTo(BindingStep step) {
    _step = step;
    notifyListeners();
  }
}

/// Removes a binding, and the locally held token with it.
Future<void> unbindTelegram(
  TelegramRepository repository,
  BotTokenStore tokens,
) async {
  await repository.unbind();
  // The token is useless once the binding is gone, and leaving a live
  // credential in storage after the user asked to disconnect is not defensible.
  await tokens.clear();
}
