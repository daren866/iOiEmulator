/*
 * ltfw.h — firmwarekit create 的 iOS 进程内 C ABI（见 firmware-kit/src/lib.rs）。
 * Swift 侧用 @_silgen_name 绑定，无需引入本头文件；保留给 C/文档参考。
 */
#ifndef LTFW_H
#define LTFW_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 事件回调：line 为一行 UTF-8 JSON（含 NUL 结尾），仅回调期间有效。 */
typedef void (*ltfw_event_cb)(void *opaque, const char *line);

unsigned ltfw_abi_version(void);

/*
 * 与上游 `firmwarekit create` 等价：
 *   catalog/id/ipsw/out_dir 必填；bootrom/guest_tools/sibling_ipsw 可传 NULL。
 * 返回 0 成功 / 1 失败；失败时 err（err_len 字节）写入错误消息。
 */
int ltfw_create(const char *catalog, const char *id,
                const char *ipsw, const char *out_dir,
                const char *bootrom, const char *guest_tools,
                const char *sibling_ipsw,
                ltfw_event_cb cb, void *opaque,
                char *err, size_t err_len);

#ifdef __cplusplus
}
#endif
#endif /* LTFW_H */
