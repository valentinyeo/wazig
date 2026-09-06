// Shims for the mingw-built TDLib/OpenSSL static libraries: they reference
// the dllimport forms of a few msvcrt symbols that zig's bundled import
// libraries do not carry. Only used on the Telegram build path.
// ponytail: _timezone is fixed to 0 (UTC) because TDLib only reads it for
// local log formatting; upgrade path: link mingw's real oldnames import lib.
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>

static int shim_vsnprintf(char *buffer, size_t count, const char *format, va_list args) {
    return vsnprintf(buffer, count, format, args);
}

static int shim_vsnwprintf(wchar_t *buffer, size_t count, const wchar_t *format, va_list args) {
    return vswprintf(buffer, count, format, args);
}

int _vsnprintf(char *buffer, size_t count, const char *format, va_list args);
int _vsnwprintf(wchar_t *buffer, size_t count, const wchar_t *format, va_list args);

int _vsnprintf(char *buffer, size_t count, const char *format, va_list args) {
    return shim_vsnprintf(buffer, count, format, args);
}

int _vsnwprintf(wchar_t *buffer, size_t count, const wchar_t *format, va_list args) {
    return shim_vsnwprintf(buffer, count, format, args);
}

void *__imp__vsnprintf = (void *)&_vsnprintf;
void *__imp__vsnwprintf = (void *)&_vsnwprintf;

static long shim_timezone = 0;
void *__imp__timezone = (void *)&shim_timezone;
