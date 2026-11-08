//! ltfw — firmwarekit create 的 iOS 进程内 C ABI 包装。
//!
//! 上游（LightTouch v0.0.13）在桌面 / Android 上都把 firmwarekit 作为独立程序跑，
//! JSON Lines 事件走 stdout。iOS 的普通 App 不能 fork/exec 捆绑的可执行文件，
//! 因此把同一套制备逻辑以 staticlib 链进 App，事件经 Emit 回调直通 Swift。
//!
//! 语义与上游 `firmwarekit create` 完全一致（bin/firmwarekit.rs 的 setup()）：
//!   ltfw_create(catalog, id, ipsw, out_dir, bootrom, guest_tools, sibling_ipsw,
//!               event_cb, opaque, err, err_len)
//!     catalog      --catalog 的 firmware-catalog.json 路径（App 内置资源解出后传入）
//!     id           --id（如 n45ap-3A101a）
//!     ipsw         --ipsw 的 IPSW 路径
//!     out_dir      --out 的设备输出目录（App 在 Documents 下创建）
//!     bootrom      --bootrom（可为 NULL；n45/iPod1,1 仿真期需要用户另行提供）
//!     guest_tools  --guest-tools（可为 NULL；缺失时按上游行为警告/降级）
//!     sibling_ipsw --keybag_ramdisk_from 姊妹 IPSW（iOS4+ 机型用；可为 NULL）
//!   返回 0 成功 / 1 失败；失败时 err 写入错误消息。
//! 事件行（begin/step/progress/warning/error/done 的 JSON）逐行回调 event_cb。

use lighttouch_firmware::create::{self, Options};
use lighttouch_firmware::entry::Entry;
use lighttouch_firmware::oneshot::Helper;
use lighttouch_firmware::progress::Emit;
use std::ffi::{c_char, CStr, CString};
use std::path::PathBuf;
use std::ptr;
use std::sync::Arc;

/// 事件回调：line 为一行 UTF-8 JSON（含 NUL 结尾），仅回调期间有效。
pub type LtfwEventCb = extern "C" fn(opaque: *mut std::ffi::c_void, line: *const c_char);

const ABI_VERSION: u32 = 1;

#[no_mangle]
pub extern "C" fn ltfw_abi_version() -> u32 {
    ABI_VERSION
}

/// 把调用方传入的 C 字符串读成 Rust String（NULL → None）。
fn read_opt(p: *const c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    // SAFETY: 调用方保证指针有效且 NUL 结尾。
    let s = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
    if s.is_empty() { None } else { Some(s) }
}

fn read_req(p: *const c_char) -> Result<String, String> {
    read_opt(p).ok_or_else(|| "required argument is NULL".to_string())
}

/// 把错误消息写进调用方的缓冲区。
fn write_err(err: *mut c_char, err_len: usize, msg: &str) {
    if err.is_null() || err_len == 0 {
        return;
    }
    let bytes = msg.as_bytes();
    let n = bytes.len().min(err_len - 1);
    // SAFETY: 调用方保证缓冲区可写 err_len 字节。
    unsafe {
        ptr::copy_nonoverlapping(bytes.as_ptr() as *const c_char, err, n);
        *err.add(n) = 0;
    }
}

/// 每次调用的私有状态：事件回调 + 期间累计的错误文本。
struct Session {
    cb: Option<LtfwEventCb>,
    opaque: *mut std::ffi::c_void,
}

/// SAFETY: opaque 与回调由调用方（Swift）持有并保证在调用期间有效。
unsafe impl Send for Session {}
unsafe impl Sync for Session {}

#[no_mangle]
pub extern "C" fn ltfw_create(
    catalog: *const c_char,
    id: *const c_char,
    ipsw: *const c_char,
    out_dir: *const c_char,
    bootrom: *const c_char,
    guest_tools: *const c_char,
    sibling_ipsw: *const c_char,
    event_cb: Option<LtfwEventCb>,
    opaque: *mut std::ffi::c_void,
    err: *mut c_char,
    err_len: usize,
) -> i32 {
    let fail = |msg: String| -> i32 {
        write_err(err, err_len, &msg);
        1
    };

    // 参数读取（失败时仍要把消息送出去）
    let (catalog_s, id_s, ipsw_s, out_s) = match (read_req(catalog), read_req(id), read_req(ipsw), read_req(out_dir)) {
        (Ok(a), Ok(b), Ok(c), Ok(d)) => (a, b, c, d),
        (Err(e), _, _, _) | (_, Err(e), _, _) | (_, _, Err(e), _) | (_, _, _, Err(e)) => {
            return fail(format!("ltfw_create: {e}"))
        }
    };
    let bootrom_s = read_opt(bootrom);
    let guest_tools_s = read_opt(guest_tools);
    let sibling_s = read_opt(sibling_ipsw);

    // 事件直通：与上游 CLI 的 Emit 等价（JSON 行），只是不写 stdout 而是回调。
    let session = Arc::new(Session { cb: event_cb, opaque });
    let emit: Emit = {
        let session = session.clone();
        Arc::new(move |e: lighttouch_firmware::progress::Event| {
            if let Some(cb) = session.cb {
                if let Ok(line) = CString::new(e.json()) {
                    cb(session.opaque, line.as_ptr());
                }
            }
        })
    };

    let run = || -> Result<(), String> {
        // 与上游 setup() 对齐：catalog + id 解析条目；recipe 开关由 Swift 侧通过
        // 修改 catalog 条目 JSON 传入（wrapper 不重复 CLI 的 --gl-test 等旗标）。
        let mut entry = Entry::load_from_catalog(&PathBuf::from(&catalog_s), &id_s)
            .map_err(|e| format!("catalog: {e}"))?;
        let from = entry.recipe.as_ref().and_then(|r| r.keybag_ramdisk_from.clone());
        let sibling = match (&sibling_s, &from) {
            (Some(i), Some(from)) => Some((
                Entry::load_from_catalog(&PathBuf::from(&catalog_s), from)
                    .map_err(|e| format!("sibling catalog: {e}"))?,
                PathBuf::from(i),
            )),
            _ => None,
        };
        let helper = Helper::new(None).map_err(|e| format!("helper: {e}"))?;
        let exe = std::env::current_exe().map_err(|e| format!("current_exe: {e}"))?;
        let guest_tools = guest_tools_s
            .map(PathBuf::from)
            .unwrap_or_else(|| exe.parent().map(PathBuf::from).unwrap_or_default().join("guest-tools"));
        let options = Options {
            entry,
            ipsw: PathBuf::from(&ipsw_s),
            out: PathBuf::from(&out_s),
            seed: None,
            helper,
            helper_path: exe,
            cache: None,
            guest_tools,
            sibling,
            stop_after_volumes: false,
            built_listing: false,
            language: None,
            keyboards: None,
            bootrom: bootrom_s.map(PathBuf::from),
        };
        std::fs::create_dir_all(&out_s).map_err(|e| format!("mkdir {}: {e}", out_s))?;
        // 上游同样用 catch_unwind 把 panic 变成 error 事件；这里再兜一层返回值。
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| create::create(options, emit)));
        match result {
            Ok(Ok(())) => Ok(()),
            Ok(Err(e)) => Err(format!("firmwarekit: {}", e.message)),
            Err(_) => Err("firmwarekit: prepare panicked".to_string()),
        }
    };

    match run() {
        Ok(()) => 0,
        Err(msg) => fail(msg),
    }
}
