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

static ENGINES: OnceLock<Mutex<HashMap<u64, engine::Handle>>> = OnceLock::new();
static NEXT_ID: AtomicU64 = AtomicU64::new(1);
static STARTS: OnceLock<Mutex<HashMap<u64, Arc<engine::StartControl>>>> = OnceLock::new();

fn dispatch(request: Value) -> Result<Value, String> {
    let engines = ENGINES.get_or_init(|| Mutex::new(HashMap::new()));
    let method = request["method"].as_str().ok_or("缺少操作名称")?;
    let starts = STARTS.get_or_init(|| Mutex::new(HashMap::new()));
    match method {
        "version" => Ok(json!({"abi": 1})),
        "prepareStart" => {
            let mut registry = starts.lock().map_err(|_| "VPN 启动注册表不可用")?;
            if registry.len() >= 4 {
                return Err("VPN 启动任务数量超限".into());
            }
            let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
            registry.insert(id, Arc::new(engine::StartControl::new()));
            Ok(json!({"startId": id}))
        }
        "cancelStart" => {
            let id = request["startId"].as_u64().ok_or("缺少启动编号")?;
            if let Some(control) = starts
                .lock()
                .map_err(|_| "VPN 启动注册表不可用")?
                .remove(&id)
            {
                control.cancel();
            }
            Ok(json!({}))
        }
        "startStatus" => {
            let id = request["startId"].as_u64().ok_or("缺少启动编号")?;
            let control = starts
                .lock()
                .map_err(|_| "VPN 启动注册表不可用")?
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
                    .map_err(|_| "VPN 启动注册表不可用")?
                    .get(&id)
                    .cloned()
                    .ok_or("VPN 启动已取消")?,
                None => Arc::new(engine::StartControl::new()),
            };
            let outcome = engine::start_controlled(&request, control.clone());
            // 先检查取消、再释放登记；cancelStart 在握手完成边界也能阻止发布。
            if let Some(id) = start_id {
                let mut registry = starts.lock().map_err(|_| "VPN 启动注册表不可用")?;
                if !registry.contains_key(&id) {
                    if let Ok((handle, _)) = outcome {
                        handle.stop();
                    }
                    return Err("VPN 启动已取消".into());
                }
                registry.remove(&id);
            }
            let (handle, info) = outcome.map_err(|e| {
                format!(
                    "{}（阶段={}，类别={:?}）",
                    e,
                    control.status()["stage"],
                    e.kind()
                )
            })?;
            let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
            let mut registry = engines.lock().map_err(|_| "VPN 注册表不可用")?;
            if registry.len() >= 4 {
                handle.stop();
                return Err("VPN 实例数量超限".into());
            }
            registry.insert(id, handle);
            Ok(
                json!({"id": id, "virtualIp": info.address.to_string(), "dns": info.dns.to_string(), "startup": control.status()}),
            )
        }
        "stop" => {
            let id = request["id"].as_u64().ok_or("缺少 VPN 实例")?;
            let handle = engines.lock().map_err(|_| "VPN 注册表不可用")?.remove(&id);
            if let Some(handle) = handle {
                handle.stop();
            }
            Ok(json!({}))
        }
        "status" | "open" => {
            let id = request["id"].as_u64().ok_or("缺少 VPN 实例")?;
            let handle = engines
                .lock()
                .map_err(|_| "VPN 注册表不可用")?
                .get(&id)
                .cloned()
                .ok_or("VPN 实例已关闭")?;
            if method == "status" {
                return Ok(handle.status());
            }
            let host = request["host"].as_str().ok_or("缺少目标主机")?;
            let port = request["port"]
                .as_u64()
                .filter(|p| (1..=65535).contains(p))
                .ok_or("目标端口不合法")? as u16;
            let bridge = handle
                .open(host.to_owned(), port)
                .map_err(|e| e.to_string())?;
            Ok(json!({"port": bridge.port, "secret": bridge.secret}))
        }
        _ => Err("未知 VPN 操作".into()),
    }
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
    let result = catch_unwind(AssertUnwindSafe(|| {
        if pointer.is_null() || length == 0 || length > 1024 * 1024 {
            return Err("VPN 控制消息长度不合法".to_string());
        }
        let input = std::slice::from_raw_parts(pointer, length);
        let request: Value =
            serde_json::from_slice(input).map_err(|_| "VPN 控制消息格式不合法".to_string())?;
        dispatch(request)
    }));
    let response = match result {
        Ok(Ok(value)) => json!({"ok": true, "data": value}),
        Ok(Err(error)) => json!({"ok": false, "error": error}),
        Err(_) => json!({"ok": false, "error": "VPN 内部错误"}),
    };
    CString::new(response.to_string())
        .expect("JSON 不包含裸零字节")
        .into_raw()
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
