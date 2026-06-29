#include <msquic.h>
#include <openssl/x509.h>
#include <openssl/sha.h>
#include <stdio.h>
/* Helpers for the anonymous-union event fields (awkward from Swift). */
static inline uint32_t ins_recv_count(const QUIC_STREAM_EVENT *e) { return e->RECEIVE.BufferCount; }
static inline const QUIC_BUFFER *ins_recv_buffers(const QUIC_STREAM_EVENT *e) { return e->RECEIVE.Buffers; }

/* The peer's leaf certificate as a DER buffer (msquic must be configured with
 * QUIC_CREDENTIAL_FLAG_USE_PORTABLE_CERTIFICATES so Certificate is a QUIC_BUFFER*). */
static inline const QUIC_BUFFER *ins_cert_buffer(const QUIC_CONNECTION_EVENT *e) {
    return (const QUIC_BUFFER *)e->PEER_CERTIFICATE_RECEIVED.Certificate;
}

/* hex(SHA256(SubjectPublicKeyInfo)) of a DER certificate into out (>= 65 bytes), matching the
 * helper's pin (sha256.Sum256(cert.RawSubjectPublicKeyInfo)). Returns 0 on success. */
static inline int ins_spki_sha256_hex(const uint8_t *der, long len, char *out) {
    const unsigned char *p = der;
    X509 *x = d2i_X509(NULL, &p, len);
    if (!x) return -1;
    unsigned char *spki = NULL;
    int spki_len = i2d_X509_PUBKEY(X509_get_X509_PUBKEY(x), &spki);
    if (spki_len <= 0) { X509_free(x); return -2; }
    unsigned char hash[SHA256_DIGEST_LENGTH];
    SHA256(spki, (size_t)spki_len, hash);
    for (int i = 0; i < SHA256_DIGEST_LENGTH; i++) sprintf(out + i * 2, "%02x", hash[i]);
    out[64] = 0;
    OPENSSL_free(spki);
    X509_free(x);
    return 0;
}
