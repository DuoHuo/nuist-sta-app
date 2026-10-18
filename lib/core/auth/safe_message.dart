/// 用户可见错误文案的统一净化。
///
/// 服务端返回的 message 只有在「短小的纯文本」时才可以展示给用户；HTML、JSON、
/// 以及可能夹带 Cookie / 会话标识的内容一律替换为固定文案，原始细节只在
/// kDebugMode 下经 portalLog 输出。
library;

/// 无法安全展示服务端原文时使用的固定文案。
const String kLoginFailedText = '登录失败，请稍后重试';

/// 用户可见文案的最大长度。
const int kMaxUserMessageLength = 100;

final RegExp _unsafe = RegExp(
  r'[<>{}]|JSESSIONID|CASTGC|Set-Cookie|<!DOCTYPE',
  caseSensitive: false,
);

/// [message] 是否可以原样展示给用户。
bool isSafeUserMessage(
  Object? message, {
  int maxLength = kMaxUserMessageLength,
}) {
  if (message is! String) return false;
  final text = message.trim();
  if (text.isEmpty || text.length > maxLength) return false;
  return !_unsafe.hasMatch(text);
}

/// 返回可展示的服务端文案；不安全时返回 [fallback]。
String safeServerMessage(
  Object? message, {
  String fallback = kLoginFailedText,
  int maxLength = kMaxUserMessageLength,
}) => isSafeUserMessage(message, maxLength: maxLength)
    ? (message as String).trim()
    : fallback;

/// 「前缀：服务端文案」的拼接，整体长度不超过 [kMaxUserMessageLength]；
/// 服务端文案不安全时只给 [fallback]。
String prefixedServerMessage(
  String prefix,
  Object? message, {
  String fallback = kLoginFailedText,
}) {
  final room = kMaxUserMessageLength - prefix.length;
  return isSafeUserMessage(message, maxLength: room)
      ? '$prefix${(message as String).trim()}'
      : fallback;
}
