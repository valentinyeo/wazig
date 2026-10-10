/* Minimal config for the wazig build of libopus 1.5.2: fixed-point encoder,
   no float API, no SIMD, no custom modes. */
#ifndef WAZIG_OPUS_CONFIG_H
#define WAZIG_OPUS_CONFIG_H
#define OPUS_BUILD 1
#define FIXED_POINT 1
#define DISABLE_FLOAT_API 1
#define VAR_ARRAYS 1
#define HAVE_LRINT 1
#define HAVE_LRINTF 1
#define PACKAGE_VERSION "1.5.2"
#endif
