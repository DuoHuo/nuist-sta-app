//! 进程内 VPN 核心。C ABI 只交换控制消息，业务字节通过鉴权的回环连接传输。

mod engine;
mod frame;
mod link;

use serde_json::{json, Value};
use std::collections::HashMap;
use std::ffi::{c_char, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

/// 业务错误与诊断上下文分离，调用方无需解析中文错误消息。
#[derive(Debug)]
struct NativeFailure {
    message: String,
    diagnostic: Value,
}

impl NativeFailure {
    fn io(error: std::io::Error, code: &str, stage: &str) -> Self {
        let diagnostic = Self::io_details(&error, code, stage);
        Self {
            message: error.to_string(),
            diagnostic,
        }
    }

    fn io_details(error: &std::io::Error, code: &str, stage: &str) -> Value {
        let mut causes = vec![error.to_string()];
        let mut source = std::error::Error::source(error);
        while let Some(cause) = source {
            causes.push(cause.to_string());
            source = cause.source();
        }
        json!({"code": code, "stage": stage, "native_kind": format!("{:?}", error.kind()),
            "os_code": error.raw_os_error(), "causes": causes})
    }
}

impl From<&str> for NativeFailure {
    fn from(message: &str) -> Self {
        Self {
            message: message.to_owned(),
            diagnostic: json!({"code": "native_control_failed", "stage": "native.control"}),
        }
    }
}

impl From<String> for NativeFailure {
    fn from(message: String) -> Self {
        Self::from(message.as_str())
    }
}

#[cfg(test)]
static REGISTRY_TEST_LOCK: Mutex<()> = Mutex::new(());

static ENGINES: OnceLock<Mutex<HashMap<u64, engine::Handle>>> = OnceLock::new();
static NEXT_ID: AtomicU64 = AtomicU64::new(1);
static STARTS: OnceLock<Mutex<HashMap<u64, Arc<engine::StartControl>>>> = OnceLock::new();

fn dispatch(request: Value) -> Result<Value, NativeFailure> {
    let engines = ENGINES.get_or_init(|| Mutex::new(HashMap::new()));
    let method = request["method"].as_str().ok_or("缺少操作名称")?;
    let starts = STARTS.get_or_init(|| Mutex::new(HashMap::new()));
    match method {
        "version" => Ok(json!({"abi": 2})),
        "prepareStart" => {
            let mut registry = starts.lock().unwrap_or_else(|e| e.into_inner());
            registry.retain(|_, control| {
                if control.status()["elapsedMs"].as_u64().unwrap_or(0) < 30000 {
                    true
                } else {
                    control.cancel();
                    false
                }
            });
            if registry.len() >= 4 {
                return Err("VPN 启动任务数量超限".into());
            }
            let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
            registry.insert(id, Arc::new(engine::StartControl::new()));
            Ok(json!({"startId": id}))
        }
        "cancelStart" => {
            let id = request["startId"].as_u64().ok_or("缺少启动编号")?;
            if let Some(control) = starts.lock().unwrap_or_else(|e| e.into_inner()).remove(&id) {
                control.cancel();
            }
            Ok(json!({}))
        }
        "startStatus" => {
            let id = request["startId"].as_u64().ok_or("缺少启动编号")?;
            let control = starts
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .get(&id)
                .cloned();
            Ok(control
                .map(|control| control.status())
                .unwrap_or_else(|| json!({"stage": "已结束"})))
        }
        "start" => {
            let start_id = request["startId"].as_u64();
            let control = match start_id {
                Some(id) => starts
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .get(&id)
                    .cloned()
                    .ok_or("VPN 启动已取消")?,
                None => Arc::new(engine::StartControl::new()),
            };
            let outcome = engine::start_controlled(&request, control.clone());
            // 先检查取消、再释放登记；cancelStart 在握手完成边界也能阻止发布。
            if let Some(id) = start_id {
                let mut registry = starts.lock().unwrap_or_else(|e| e.into_inner());
                if !registry.contains_key(&id) {
                    if let Ok((handle, _)) = outcome {
                        handle.stop();
                    }
                    return Err("VPN 启动已取消".into());
                }
                registry.remove(&id);
            }
            let (handle, info) = outcome.map_err(|e| {
                let status = control.status();
                let stage = status["stage"].as_str().unwrap_or("unknown");
                NativeFailure::io(e, "native_start_failed", stage)
            })?;
            register_engine(handle, &info, control.status())
        }
        "stop" => {
            let id = request["id"].as_u64().ok_or("缺少 VPN 实例")?;
            let handle = engines
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .remove(&id);
            if let Some(handle) = handle {
                handle.stop();
            }
            engines
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .retain(|_, handle| handle.alive());
            Ok(json!({}))
        }
        "status" | "health" | "probe" => {
            let id = request["id"].as_u64().ok_or("缺少 VPN 实例")?;
            let handle = engines
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .get(&id)
                .cloned()
                .ok_or("VPN 实例已关闭")?;
            if method == "probe" {
                let host = request["host"].as_str().ok_or("缺少目标主机")?;
                let timeout = std::time::Duration::from_millis(
                    request["timeoutMs"].as_u64().unwrap_or(3000).clamp(1, 3000),
                );
                handle
                    .probe(host.to_owned(), timeout)
                    .map_err(|e| NativeFailure::io(e, "native_probe_failed", "native.probe"))?;
            }
            Ok(handle.status())
        }
        _ => Err("未知 VPN 操作".into()),
    }
}

fn register_engine(
    handle: engine::Handle,
    info: &frame::AuthInfo,
    startup: Value,
) -> Result<Value, NativeFailure> {
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    let engines = ENGINES.get_or_init(|| Mutex::new(HashMap::new()));
    let mut registry = engines.lock().unwrap_or_else(|e| e.into_inner());
    registry.retain(|_, handle| {
        if handle.alive() {
            true
        } else {
            handle.stop();
            false
        }
    });
    if registry.len() >= 4 {
        handle.stop();
        return Err("VPN 实例数量超限".into());
    }
    let result = json!({"engineId": id, "proxyPort": handle.proxy_port, "proxyToken": handle.proxy_token,
        "virtualIp": info.address.to_string(), "dns": info.dns.to_string(), "startup": startup});
    registry.insert(id, handle.clone());
    drop(registry);
    // 回调可能同步进入 Rust 查询注册表，发布编号必须在释放注册表锁后执行。
    handle.set_id(id);
    Ok(result)
}

/// 回调的 JSON 内存由 Dart 调用 nuist_vpn_result_free 释放，指针在异步回调处理前一直有效。
type Callback = extern "C" fn(*mut c_char, usize, u64);
static EVENT_CALLBACK: OnceLock<Mutex<Option<Callback>>> = OnceLock::new();

pub(crate) fn emit_event(engine_id: u64, event: &str, reason: &str) {
    emit_diagnostic_event(engine_id, event, reason, None);
}

pub(crate) fn emit_diagnostic_event(
    engine_id: u64,
    event: &str,
    reason: &str,
    error: Option<&std::io::Error>,
) {
    emit_event_with_diagnostic(
        engine_id,
        event,
        reason,
        error.map(|error| NativeFailure::io_details(error, reason, "native.engine")),
    );
}

pub(crate) fn emit_event_with_diagnostic(
    engine_id: u64,
    event: &str,
    reason: &str,
    diagnostic: Option<Value>,
) {
    if engine_id == 0 {
        return;
    }
    let callback = *EVENT_CALLBACK
        .get_or_init(|| Mutex::new(None))
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    if let Some(callback) = callback {
        let mut value = json!({"engineId": engine_id, "event": event, "reason": reason});
        if let Some(diagnostic) = diagnostic {
            value["diagnostic"] = diagnostic;
        }
        let bytes = value.to_string();
        let length = bytes.len();
        callback(
            CString::new(bytes).expect("JSON 不包含裸零字节").into_raw(),
            length,
            0,
        );
    }
}

/// 注册进程内状态监听。调用方必须让函数指针在引擎整个生命周期保持有效。
#[no_mangle]
pub extern "C" fn nuist_vpn_set_event_callback(callback: Option<Callback>) {
    *EVENT_CALLBACK
        .get_or_init(|| Mutex::new(None))
        .lock()
        .unwrap_or_else(|e| e.into_inner()) = callback;
}

fn panic_failure(payload: Box<dyn std::any::Any + Send>, stage: &str) -> NativeFailure {
    let cause = payload
        .downcast_ref::<String>()
        .map(String::as_str)
        .or_else(|| payload.downcast_ref::<&str>().copied())
        .unwrap_or("原生 panic 未提供错误描述");
    NativeFailure {
        message: "VPN 内部错误".into(),
        diagnostic: json!({
        "code": "native_panic", "stage": stage, "causes": [cause],
        "stack_unavailable_reason": "panic_already_unwound" }),
    }
}

fn failure_response(failure: NativeFailure) -> *mut c_char {
    CString::new(
        json!({"ok": false, "error": failure.message, "diagnostic": failure.diagnostic})
            .to_string(),
    )
    .expect("JSON 不包含裸零字节")
    .into_raw()
}

unsafe fn deliver_result(callback: Callback, request_id: u64, response: *mut c_char) {
    let length = if response.is_null() {
        0
    } else {
        std::ffi::CStr::from_ptr(response).to_bytes().len()
    };
    callback(response, length, request_id);
}

fn spawn_async<F>(
    builder: std::thread::Builder,
    mut input: Vec<u8>,
    request_id: u64,
    callback: Callback,
    work: F,
) -> Result<(), NativeFailure>
where
    F: FnOnce(&[u8]) -> *mut c_char + Send + 'static,
{
    builder
        .spawn(move || {
            let response = match catch_unwind(AssertUnwindSafe(|| work(&input))) {
                Ok(response) => response,
                Err(payload) => failure_response(panic_failure(payload, "native.async.worker")),
            };
            input.fill(0);
            unsafe {
                deliver_result(callback, request_id, response);
            }
        })
        .map(|_| ())
        .map_err(|error| {
            NativeFailure::io(error, "native_async_spawn_failed", "native.async.spawn")
        })
}

/// 异步执行控制命令；线程创建或调度入口 panic 都转为回调错误，不跨越 C ABI。
///
/// # Safety
/// pointer 必须指向至少 length 字节，callback 必须在结果回调完成前有效。
#[no_mangle]
pub unsafe extern "C" fn nuist_vpn_call_async(
    pointer: *const u8,
    length: usize,
    request_id: u64,
    callback: Callback,
) {
    call_async_with_builder(
        pointer,
        length,
        request_id,
        callback,
        std::thread::Builder::new().name("nuist-vpn-control".into()),
    );
}

unsafe fn call_async_with_builder(
    pointer: *const u8,
    length: usize,
    request_id: u64,
    callback: Callback,
    builder: std::thread::Builder,
) {
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        if pointer.is_null() || length == 0 || length > 1024 * 1024 {
            return Err(NativeFailure::from("VPN 控制消息长度不合法"));
        }
        let input = std::slice::from_raw_parts(pointer, length).to_vec();
        spawn_async(builder, input, request_id, callback, call_input)
    }));
    let failure = match outcome {
        Ok(Ok(())) => return,
        Ok(Err(failure)) => failure,
        Err(payload) => panic_failure(payload, "native.async.dispatch"),
    };
    deliver_result(callback, request_id, failure_response(failure));
}

/// 分配桥接输入内存。调用方必须使用相同长度调用 nuist_vpn_free。
#[no_mangle]
pub extern "C" fn nuist_vpn_alloc(length: usize) -> *mut u8 {
    if length == 0 || length > 1024 * 1024 {
        return std::ptr::null_mut();
    }
    Box::into_raw(vec![0u8; length].into_boxed_slice()) as *mut u8
}

/// 释放输入缓冲，并清除其中的短期 token。
///
/// # Safety
/// pointer 必须由 nuist_vpn_alloc(length) 返回，且只能释放一次。
#[no_mangle]
pub unsafe extern "C" fn nuist_vpn_free(pointer: *mut u8, length: usize) {
    if !pointer.is_null() {
        let mut allocation = Box::from_raw(std::ptr::slice_from_raw_parts_mut(pointer, length));
        for byte in allocation.iter_mut() {
            std::ptr::write_volatile(byte, 0);
        }
    }
}

/// 执行控制命令；阻塞操作由 Dart 后台 isolate 调用，绝不阻塞 UI。
///
/// # Safety
/// pointer 必须指向至少 length 字节的有效内存，调用期间不可修改。
#[no_mangle]
pub unsafe extern "C" fn nuist_vpn_call(pointer: *const u8, length: usize) -> *mut c_char {
    if pointer.is_null() || length == 0 || length > 1024 * 1024 {
        return failure_response(NativeFailure::from("VPN 控制消息长度不合法"));
    }
    call_input(std::slice::from_raw_parts(pointer, length))
}

fn call_input(input: &[u8]) -> *mut c_char {
    match catch_unwind(AssertUnwindSafe(|| {
        let request: Value = serde_json::from_slice(input).map_err(|error| NativeFailure {
            message: "VPN 控制消息格式不合法".into(), diagnostic: json!({
                "code": "native_request_invalid", "stage": "native.decode", "causes": [error.to_string()],
                "line": error.line(), "column": error.column() }) })?;
        dispatch(request)
    })) {
        Ok(Ok(value)) => CString::new(json!({"ok": true, "data": value}).to_string())
            .expect("JSON 不包含裸零字节")
            .into_raw(),
        Ok(Err(failure)) => failure_response(failure),
        Err(payload) => failure_response(panic_failure(payload, "native.dispatch")),
    }
}

#[cfg(test)]
mod diagnostic_tests {
    use super::*;

    #[test]
    fn cancelled_start_reservations_do_not_permanently_exhaust_four_slots() {
        for _ in 0..8 {
            let ids: Vec<_> = (0..4)
                .map(|_| {
                    dispatch(json!({"method": "prepareStart"})).unwrap()["startId"]
                        .as_u64()
                        .unwrap()
                })
                .collect();
            assert!(dispatch(json!({"method": "prepareStart"})).is_err());
            for id in ids {
                dispatch(json!({"method": "cancelStart", "startId": id})).unwrap();
            }
            assert!(STARTS.get().unwrap().lock().unwrap().is_empty());
        }
    }

    static ASYNC_RESULTS: Mutex<Vec<(u64, Value)>> = Mutex::new(Vec::new());
    extern "C" fn collect_async(pointer: *mut c_char, length: usize, id: u64) {
        unsafe {
            let value =
                serde_json::from_slice(std::slice::from_raw_parts(pointer as *const u8, length))
                    .unwrap();
            ASYNC_RESULTS.lock().unwrap().push((id, value));
            nuist_vpn_result_free(pointer);
        }
    }

    #[test]
    fn asynchronous_thread_creation_failure_returns_one_structured_callback() {
        let input = br#"{"method":"version"}"#;
        unsafe {
            call_async_with_builder(
                input.as_ptr(),
                input.len(),
                83001,
                collect_async,
                std::thread::Builder::new().stack_size(usize::MAX - 8191),
            );
        }
        let results = ASYNC_RESULTS.lock().unwrap();
        let values: Vec<_> = results.iter().filter(|(id, _)| *id == 83001).collect();
        assert_eq!(values.len(), 1);
        assert_eq!(values[0].1["ok"], false);
        assert_eq!(
            values[0].1["diagnostic"]["code"],
            "native_async_spawn_failed"
        );
        assert_eq!(values[0].1["diagnostic"]["stage"], "native.async.spawn");
    }

    #[test]
    fn asynchronous_worker_panic_is_contained_and_keeps_ffi_alive() {
        spawn_async(
            std::thread::Builder::new(),
            vec![1],
            83002,
            collect_async,
            |_| panic!("合成后台任务panic"),
        )
        .unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(1);
        loop {
            let result = ASYNC_RESULTS
                .lock()
                .unwrap()
                .iter()
                .find(|(id, _)| *id == 83002)
                .cloned();
            if let Some((_, value)) = result {
                assert_eq!(value["ok"], false);
                assert_eq!(value["diagnostic"]["code"], "native_panic");
                assert_eq!(value["diagnostic"]["stage"], "native.async.worker");
                break;
            }
            assert!(std::time::Instant::now() < deadline);
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        let response = call_input(br#"{"method":"version"}"#);
        unsafe {
            let value: Value =
                serde_json::from_slice(std::ffi::CStr::from_ptr(response).to_bytes()).unwrap();
            assert_eq!(value["ok"], true);
            nuist_vpn_result_free(response);
        }
    }

    #[test]
    fn native_io_failure_keeps_kind_stage_and_original_message() {
        let failure = NativeFailure::io(
            std::io::Error::new(std::io::ErrorKind::TimedOut, "合成连接超时"),
            "native_start_failed",
            "TLS",
        );
        assert_eq!(failure.message, "合成连接超时");
        assert_eq!(failure.diagnostic["stage"], "TLS");
        assert_eq!(failure.diagnostic["native_kind"], "TimedOut");
        assert_eq!(failure.diagnostic["code"], "native_start_failed");
    }
}

/// 释放 nuist_vpn_call 返回的结果。
///
/// # Safety
/// pointer 必须是尚未释放的 nuist_vpn_call 返回值。
#[no_mangle]
pub unsafe extern "C" fn nuist_vpn_result_free(pointer: *mut c_char) {
    if !pointer.is_null() {
        drop(CString::from_raw(pointer));
    }
}
