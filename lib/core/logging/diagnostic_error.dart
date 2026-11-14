/// 在业务异常包装和跨语言调用之间保留底层故障依据。
///
/// 内容由日志出口统一脱敏；异常本身不负责输出或持久化。
abstract interface class DiagnosticError {
  /// 导致当前异常的原始错误。
  Object? get cause;

  /// 原始错误发生时的堆栈，不用包装处的堆栈替代。
  StackTrace? get causeStackTrace;

  /// 固定错误码、阶段、接口别名等诊断上下文。
  Map<String, Object?> get diagnosticContext;
}

/// 具有稳定分类和原始原因的通用诊断异常。
class DiagnosticException implements Exception, DiagnosticError {
  const DiagnosticException(
    this.message, {
    required this.code,
    this.stage,
    this.cause,
    this.causeStackTrace,
    this.context = const {},
  });

  final String message;
  final String code;
  final String? stage;
  final Map<String, Object?> context;

  @override
  final Object? cause;

  @override
  final StackTrace? causeStackTrace;

  @override
  Map<String, Object?> get diagnosticContext => {
    ...context,
    'reason_code': code,
    if (stage != null) 'stage': stage,
  };

  @override
  String toString() => message;
}
