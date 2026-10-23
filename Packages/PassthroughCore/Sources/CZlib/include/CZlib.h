#ifndef CZLIB_H
#define CZLIB_H

#include <zlib.h>

/// `inflateInit` and `deflateInit` are macros, which Swift can't call.
int cz_inflate_init(z_stream *stream);
int cz_deflate_init(z_stream *stream, int level);

#endif
