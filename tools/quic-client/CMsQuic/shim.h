#include <msquic.h>
/* Helpers for the anonymous-union event fields (awkward from Swift). */
static inline uint32_t ins_recv_count(const QUIC_STREAM_EVENT *e) { return e->RECEIVE.BufferCount; }
static inline const QUIC_BUFFER *ins_recv_buffers(const QUIC_STREAM_EVENT *e) { return e->RECEIVE.Buffers; }
