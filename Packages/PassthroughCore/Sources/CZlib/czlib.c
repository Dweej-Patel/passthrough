#include "CZlib.h"

int cz_inflate_init(z_stream *stream) {
    return inflateInit(stream);
}

int cz_deflate_init(z_stream *stream, int level) {
    return deflateInit(stream, level);
}
