use crate::{Tunnel, start_client, start_host};
use std::{
    ffi::{CStr, CString, c_char},
    panic::{AssertUnwindSafe, catch_unwind},
    ptr,
    sync::OnceLock,
};

pub(crate) fn runtime() -> &'static tokio::runtime::Runtime {
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("remote runtime")
    })
}

// All borrowed pointers are supplied by the bridge and remain valid for the call.
// Handles are immutable after creation. Swift serializes destruction against use.
unsafe fn string<'a>(value: *const c_char) -> anyhow::Result<&'a str> {
    anyhow::ensure!(!value.is_null(), "Missing argument");
    Ok(unsafe { CStr::from_ptr(value) }.to_str()?)
}
fn result(error: *mut *mut c_char, action: impl FnOnce() -> anyhow::Result<Tunnel>) -> *mut Tunnel {
    let result = catch_unwind(AssertUnwindSafe(action))
        .unwrap_or_else(|_| Err(anyhow::anyhow!("Remote transport failed")));
    match result {
        Ok(tunnel) => Box::into_raw(Box::new(tunnel)),
        Err(err) => {
            if !error.is_null() {
                let message = CString::new(format!("{err:#}").replace('\0', "")).unwrap();
                unsafe {
                    *error = message.into_raw();
                }
            }
            ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nocturne_remote_host(
    url: *const c_char,
    key: *const u8,
    port: u16,
    error: *mut *mut c_char,
) -> *mut Tunnel {
    result(error, || {
        anyhow::ensure!(!key.is_null(), "Missing endpoint key");
        let key: [u8; 32] = unsafe { std::slice::from_raw_parts(key, 32) }.try_into()?;
        runtime().block_on(start_host(unsafe { string(url)? }, key, port))
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nocturne_remote_client(
    url: *const c_char,
    id: *const c_char,
    streaming: bool,
    error: *mut *mut c_char,
) -> *mut Tunnel {
    result(error, || {
        runtime().block_on(start_client(
            unsafe { string(url)? },
            unsafe { string(id)? },
            streaming,
        ))
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nocturne_remote_id(handle: *const Tunnel) -> *mut c_char {
    CString::new(unsafe { &*handle }.id()).unwrap().into_raw()
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nocturne_remote_port(handle: *const Tunnel) -> u16 {
    unsafe { &*handle }.workspace_port
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nocturne_remote_route(handle: *const Tunnel) -> i32 {
    unsafe { &*handle }.route()
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nocturne_remote_authorize(
    handle: *const Tunnel,
    port: u16,
    device: *const c_char,
) -> i32 {
    unsafe { string(device) }
        .map(|id| unsafe { &*handle }.authorize(port, id))
        .unwrap_or(-1)
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nocturne_remote_revoke(handle: *const Tunnel, device: *const c_char) {
    if let Ok(id) = unsafe { string(device) } {
        unsafe { &*handle }.revoke(id);
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nocturne_remote_stop(handle: *mut Tunnel) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nocturne_remote_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}
