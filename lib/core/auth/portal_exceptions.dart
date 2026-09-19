/// 统一门户登录的异常分层。
///
/// 分三类是为了让 UI 能说人话：网络不通让用户重试，凭据失效让用户重新绑定，
/// 两者的处置方式完全不同，混成一个 Exception 就只能提示「登录失败」。
sealed class PortalException implements Exception {
  const PortalException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 网络层面的失败：超时、连不上、DNS 挂了、校园网没连上。
///
/// 这类失败**不能**推断 Passkey 已吊销，重试即可。
class PortalNetworkError extends PortalException {
  const PortalNetworkError(super.message);
}

/// 凭据不可用：bundle 缺字段、私钥解析失败，或服务端拒绝了本次断言。
///
/// 对应 Python 版的 CredentialError。落到这里基本等于「门户那边的通行密钥
/// 已被吊销或删除」，UI 应当显式提示用户重新绑定，而不是让他反复重试。
class PortalCredentialError extends PortalException {
  const PortalCredentialError(super.message);
}

/// 其他登录失败：响应结构对不上、service 不正确、跳回认证页等。
class PortalLoginError extends PortalException {
  const PortalLoginError(super.message);
}
