#include "vnet.h"
#include "sipcore.h"

#include <pjmedia/transport_srtp.h>
#include <pjlib.h>

#include <arpa/inet.h>
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <string.h>
#include <time.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <unistd.h>

#define THIS_FILE   "vnet"
#define MAX_BINDINGS 16
#define MAX_PKT      65535      /* largest IPv4 packet (receive side, reassembly) */
#define MAX_UDP      8192       /* largest UDP payload the app sends (SIP <= 4000, RTP ~200) */
#define AF_PREFIX    4          /* utun framing: 4-byte address family */
#define REASM_SLOTS  4
#define REASM_TIMEOUT_SEC 5

/* data points into vnet's own receive buffer: receivers may modify it in place
 * (e.g. SRTP decryption) but must not keep it after returning. */
typedef void (*vnet_rx_cb)(void *user, const pj_sockaddr_in *src, void *data, int len);

typedef struct {
    pj_uint16_t port;           /* host order; 0 = free slot */
    vnet_rx_cb  cb;
    void       *user;
    int         busy;           /* deliveries in progress */
    int         is_sip;         /* for the statistics */
} binding;

/* One IPv4 datagram being reassembled from fragments. */
typedef struct {
    int         used;
    pj_uint32_t src;
    pj_uint16_t id;
    time_t      started;
    int         total;          /* payload length, known once the last fragment arrived */
    int         received;
    pj_uint8_t  data[MAX_PKT];
    pj_uint8_t  have[MAX_PKT / 8 + 1];   /* which 8-byte blocks arrived */
} reasm_slot;

static struct {
    int             fd;
    int             wake[2];    /* pipe: tells the reader to stop */
    pj_uint32_t     ip;         /* network order */
    char            ip_str[PJ_INET_ADDRSTRLEN];
    int             mtu;
    volatile int    running;
    volatile int    reader_quit;    /* tells the reader thread to end (stop or switch) */
    pthread_t       reader;
    pthread_mutex_t lock;       /* bindings */
    pthread_mutex_t tx_lock;    /* IP id counter and fd writes */
    pj_uint16_t     next_id;
    binding         bindings[MAX_BINDINGS];
    reasm_slot      reasm[REASM_SLOTS];
} g = { .fd = -1, .wake = { -1, -1 }, .lock = PTHREAD_MUTEX_INITIALIZER, .tx_lock = PTHREAD_MUTEX_INITIALIZER };

/* ---------- diagnostics ---------- */

/* Traffic counters, read by vnet_get_stats() for the app's VPN diagnostics.
 * Updated without locks from several threads: approximate, which is enough. */
static struct {
    volatile unsigned long long rx_packets, rx_bytes, rx_sip, rx_media, rx_dropped;
    volatile unsigned long long tx_packets, tx_bytes, tx_errors;
    volatile pj_uint64_t        last_rx_ns, last_tx_ns;
    volatile pj_uint64_t        max_delivery_ns, max_send_ns;
} st;

static pj_uint64_t now_ns(void)
{
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

static void note_max(volatile pj_uint64_t *max, pj_uint64_t value)
{
    if (value > *max)
        *max = value;
}

/* ---------- helpers ---------- */

static void register_thread(void)
{
    static __thread pj_thread_desc desc;
    static __thread pj_thread_t *thread;
    if (!pj_thread_is_registered()) {
        pj_bzero(desc, sizeof(desc));
        pj_thread_register("vnet", desc, &thread);
    }
}

static pj_uint32_t csum_add(pj_uint32_t sum, const void *data, int len)
{
    const pj_uint8_t *p = (const pj_uint8_t *)data;
    while (len > 1) {
        sum += (pj_uint32_t)((p[0] << 8) | p[1]);
        p += 2;
        len -= 2;
    }
    if (len)
        sum += (pj_uint32_t)(p[0] << 8);
    return sum;
}

static pj_uint16_t csum_fold(pj_uint32_t sum)
{
    while (sum >> 16)
        sum = (sum & 0xFFFF) + (sum >> 16);
    return (pj_uint16_t)~sum;
}

static void put16(pj_uint8_t *p, pj_uint16_t v) { p[0] = (pj_uint8_t)(v >> 8); p[1] = (pj_uint8_t)v; }
static pj_uint16_t get16(const pj_uint8_t *p) { return (pj_uint16_t)((p[0] << 8) | p[1]); }

/* ---------- bindings (port -> receiver) ---------- */

static void sip_rx(void *user, const pj_sockaddr_in *src, void *data, int len);

static pj_status_t vnet_bind(pj_uint16_t port, vnet_rx_cb cb, void *user)
{
    int i, free_slot = -1;
    pthread_mutex_lock(&g.lock);
    for (i = 0; i < MAX_BINDINGS; ++i) {
        if (g.bindings[i].port == port) {
            pthread_mutex_unlock(&g.lock);
            return PJ_EEXISTS;
        }
        if (g.bindings[i].port == 0 && free_slot < 0)
            free_slot = i;
    }
    if (free_slot < 0) {
        pthread_mutex_unlock(&g.lock);
        return PJ_ETOOMANY;
    }
    g.bindings[free_slot].port = port;
    g.bindings[free_slot].cb = cb;
    g.bindings[free_slot].user = user;
    g.bindings[free_slot].busy = 0;
    g.bindings[free_slot].is_sip = cb == &sip_rx;
    pthread_mutex_unlock(&g.lock);
    return PJ_SUCCESS;
}

/* Removes a binding and waits until no delivery to it is in progress (unless
 * called from the reader thread itself, e.g. while handling a SIP message). */
static void vnet_unbind(pj_uint16_t port)
{
    int i;
    for (;;) {
        int busy = 0;
        pthread_mutex_lock(&g.lock);
        for (i = 0; i < MAX_BINDINGS; ++i) {
            if (g.bindings[i].port == port) {
                busy = g.bindings[i].busy;
                if (!busy || (g.running && pthread_equal(pthread_self(), g.reader))) {
                    g.bindings[i].port = 0;
                    g.bindings[i].cb = NULL;
                    busy = 0;
                }
            }
        }
        pthread_mutex_unlock(&g.lock);
        if (!busy)
            return;
        usleep(1000);
    }
}

static void deliver(pj_uint16_t port, const pj_sockaddr_in *src, void *data, int len)
{
    int i;
    vnet_rx_cb cb = NULL;
    void *user = NULL;
    int is_sip = 0;
    pj_uint64_t t0;
    pthread_mutex_lock(&g.lock);
    for (i = 0; i < MAX_BINDINGS; ++i) {
        if (g.bindings[i].port == port && g.bindings[i].cb) {
            cb = g.bindings[i].cb;
            user = g.bindings[i].user;
            is_sip = g.bindings[i].is_sip;
            g.bindings[i].busy++;
            break;
        }
    }
    pthread_mutex_unlock(&g.lock);
    if (!cb) {
        st.rx_dropped++;
        return;
    }
    if (is_sip)
        st.rx_sip++;
    else
        st.rx_media++;
    t0 = now_ns();
    cb(user, src, data, len);
    note_max(&st.max_delivery_ns, now_ns() - t0);
    pthread_mutex_lock(&g.lock);
    if (g.bindings[i].busy > 0)
        g.bindings[i].busy--;
    pthread_mutex_unlock(&g.lock);
}

/* ---------- sending ---------- */

static pj_status_t write_packet(const pj_uint8_t *ip_pkt, int len)
{
    pj_uint32_t af = htonl(AF_INET);
    struct iovec iov[2] = { { &af, AF_PREFIX }, { (void *)ip_pkt, (size_t)len } };
    struct msghdr msg;
    pj_bzero(&msg, sizeof(msg));
    msg.msg_iov = iov;
    msg.msg_iovlen = 2;
    {
        pj_uint64_t t0 = now_ns(), t1;
        ssize_t sent = sendmsg(g.fd, &msg, 0);
        t1 = now_ns();
        note_max(&st.max_send_ns, t1 - t0);
        if (sent < 0) {
            st.tx_errors++;
            return PJ_RETURN_OS_ERROR(errno);
        }
        st.tx_packets++;
        st.tx_bytes += (unsigned long long)len;
        st.last_tx_ns = t1;
    }
    return PJ_SUCCESS;
}

/* Sends one UDP datagram from the tunnel address; fragments it if needed. */
static pj_status_t vnet_sendto(pj_uint16_t src_port, const pj_sockaddr_in *dst,
                               const void *data, int len)
{
    /* Small enough for the stacks of audio threads, which send RTP. */
    pj_uint8_t udp[8 + MAX_UDP];
    pj_uint8_t pkt[20 + 9000];
    pj_uint32_t sum;
    int udp_len = 8 + len, offset = 0, max_frag;
    pj_uint16_t id;
    pj_status_t status = PJ_SUCCESS;

    if (!g.running)
        return PJ_EINVALIDOP;
    if (dst->sin_family != pj_AF_INET() || len < 0 || len > MAX_UDP)
        return PJ_EINVAL;

    /* UDP header and checksum (pseudo header: src, dst, protocol, length). */
    put16(udp, src_port);
    memcpy(udp + 2, &dst->sin_port, 2);
    put16(udp + 4, (pj_uint16_t)udp_len);
    put16(udp + 6, 0);
    memcpy(udp + 8, data, (size_t)len);

    pthread_mutex_lock(&g.tx_lock);
    if (g.fd < 0) {
        /* The tunnel is being re-established (vnet_switch): lost, as UDP may be. */
        pthread_mutex_unlock(&g.tx_lock);
        st.tx_errors++;
        return PJ_SUCCESS;
    }
    sum = csum_add(0, &g.ip, 4);
    sum = csum_add(sum, &dst->sin_addr, 4);
    sum += 17 + (pj_uint32_t)udp_len;
    sum = csum_add(sum, udp, udp_len);
    put16(udp + 6, csum_fold(sum) ? csum_fold(sum) : 0xFFFF);

    id = g.next_id++;
    max_frag = ((g.mtu - 20) / 8) * 8;
    while (offset < udp_len && status == PJ_SUCCESS) {
        int chunk = udp_len - offset;
        int more = 0;
        if (chunk > max_frag) {
            chunk = max_frag;
            more = 1;
        }
        pkt[0] = 0x45;                      /* IPv4, 20-byte header */
        pkt[1] = 0;
        put16(pkt + 2, (pj_uint16_t)(20 + chunk));
        put16(pkt + 4, id);
        put16(pkt + 6, (pj_uint16_t)((more ? 0x2000 : 0) | (offset / 8)));
        pkt[8] = 64;                        /* TTL */
        pkt[9] = 17;                        /* UDP */
        put16(pkt + 10, 0);
        memcpy(pkt + 12, &g.ip, 4);
        memcpy(pkt + 16, &dst->sin_addr, 4);
        put16(pkt + 10, csum_fold(csum_add(0, pkt, 20)));
        memcpy(pkt + 20, udp + offset, (size_t)chunk);
        status = write_packet(pkt, 20 + chunk);
        offset += chunk;
    }
    pthread_mutex_unlock(&g.tx_lock);
    return status;
}

/* ---------- receiving ---------- */

static void handle_udp(pj_uint32_t src_ip, pj_uint8_t *udp, int len)
{
    pj_sockaddr_in src;
    int udp_len;
    if (len < 8)
        return;
    udp_len = get16(udp + 4);
    if (udp_len < 8 || udp_len > len)
        return;
    pj_bzero(&src, sizeof(src));
    src.sin_family = (pj_uint16_t)pj_AF_INET();
    src.sin_addr.s_addr = src_ip;
    memcpy(&src.sin_port, udp, 2);
    deliver(get16(udp + 2), &src, udp + 8, udp_len - 8);
}

/* Collects fragments; returns the slot once the datagram is complete. */
static reasm_slot *reassemble(pj_uint32_t src, pj_uint16_t id, int offset, int more,
                              const pj_uint8_t *data, int len)
{
    int i, b;
    reasm_slot *slot = NULL;
    time_t now = time(NULL);

    if (offset + len > MAX_PKT)
        return NULL;
    for (i = 0; i < REASM_SLOTS; ++i) {
        reasm_slot *s = &g.reasm[i];
        if (s->used && now - s->started > REASM_TIMEOUT_SEC)
            s->used = 0;
        if (s->used && s->src == src && s->id == id)
            slot = s;
    }
    if (!slot) {
        for (i = 0; i < REASM_SLOTS && !slot; ++i)
            if (!g.reasm[i].used)
                slot = &g.reasm[i];
        if (!slot)
            slot = &g.reasm[0];             /* evict */
        slot->used = 1;
        slot->src = src;
        slot->id = id;
        slot->started = now;
        slot->total = -1;
        slot->received = 0;
        pj_bzero(slot->have, sizeof(slot->have));
    }
    for (b = offset / 8; b * 8 < offset + len; ++b) {
        if (!slot->have[b]) {
            slot->have[b] = 1;
            slot->received += (b * 8 + 8 <= offset + len) ? 8 : (offset + len - b * 8);
        }
    }
    memcpy(slot->data + offset, data, (size_t)len);
    if (!more)
        slot->total = offset + len;
    if (slot->total >= 0 && slot->received >= slot->total)
        return slot;
    return NULL;
}

static void handle_ip(pj_uint8_t *pkt, int len)
{
    int ihl, total, flags_off, offset, more;
    pj_uint32_t src, dst;
    if (len < 20 || (pkt[0] >> 4) != 4)
        return;                             /* only IPv4 */
    ihl = (pkt[0] & 0x0F) * 4;
    total = get16(pkt + 2);
    if (ihl < 20 || total < ihl || total > len || pkt[9] != 17)
        return;
    memcpy(&src, pkt + 12, 4);
    memcpy(&dst, pkt + 16, 4);
    if (dst != g.ip)
        return;
    flags_off = get16(pkt + 6);
    offset = (flags_off & 0x1FFF) * 8;
    more = (flags_off & 0x2000) != 0;
    if (!more && offset == 0) {
        handle_udp(src, pkt + ihl, total - ihl);
    } else {
        reasm_slot *slot = reassemble(src, get16(pkt + 4), offset, more, pkt + ihl, total - ihl);
        if (slot) {
            handle_udp(slot->src, slot->data, slot->total);
            slot->used = 0;
        }
    }
}

static void *reader_main(void *arg)
{
    pj_uint8_t buf[AF_PREFIX + MAX_PKT];
    PJ_UNUSED_ARG(arg);
    register_thread();
    while (!g.reader_quit) {
        /* fd is -1 while the tunnel is being re-established: poll ignores it. */
        struct pollfd pf[2] = { { g.fd, POLLIN, 0 }, { g.wake[0], POLLIN, 0 } };
        ssize_t n;
        if (poll(pf, 2, -1) < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        if (pf[1].revents || g.reader_quit)
            break;                          /* vnet_stop or vnet_switch */
        if (g.fd < 0 || !(pf[0].revents & POLLIN))
            continue;
        n = recv(g.fd, buf, sizeof(buf), MSG_DONTWAIT);
        if (n <= 0) {
            if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK))
                continue;
            PJ_LOG(3, (THIS_FILE, "VPN tunnel closed"));
            break;
        }
        if (n > AF_PREFIX) {
            st.rx_packets++;
            st.rx_bytes += (unsigned long long)(n - AF_PREFIX);
            st.last_rx_ns = now_ns();
            handle_ip(buf + AF_PREFIX, (int)(n - AF_PREFIX));
        }
    }
    return NULL;
}

/* ---------- lifecycle ---------- */

pj_status_t vnet_start(int fd, const char *local_ip, int mtu)
{
    struct in_addr addr;
    if (g.running)
        vnet_stop();
    if (inet_pton(AF_INET, local_ip, &addr) != 1)
        return PJ_EINVAL;
    g.fd = fd;
    g.ip = addr.s_addr;
    pj_ansi_strxcpy(g.ip_str, local_ip, sizeof(g.ip_str));
    g.mtu = (mtu >= 576 && mtu <= 9000) ? mtu : 1500;
    g.next_id = (pj_uint16_t)pj_rand();
    pj_bzero(g.bindings, sizeof(g.bindings));
    pj_bzero(g.reasm, sizeof(g.reasm));
    pj_bzero((void *)&st, sizeof(st));
    if (pipe(g.wake) != 0)
        return PJ_RETURN_OS_ERROR(errno);
    {
        int on = 1;     /* a closed tunnel must not raise SIGPIPE */
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
    }
    g.running = 1;
    g.reader_quit = 0;
    if (pthread_create(&g.reader, NULL, reader_main, NULL) != 0) {
        g.running = 0;
        close(g.wake[0]);
        close(g.wake[1]);
        g.wake[0] = g.wake[1] = -1;
        return PJ_ENOMEM;
    }
    PJ_LOG(3, (THIS_FILE, "VPN network started: %s, MTU %d", g.ip_str, g.mtu));
    return PJ_SUCCESS;
}

void vnet_stop(void)
{
    if (!g.running)
        return;
    g.running = 0;
    g.reader_quit = 1;
    /* Wake the reader without shutdown(): the tunnel socket may be shared with
     * other descriptors (the app keeps the tunnel across SIP restarts). */
    (void)!write(g.wake[1], "x", 1);
    if (!pthread_equal(pthread_self(), g.reader))
        pthread_join(g.reader, NULL);
    close(g.wake[0]);
    close(g.wake[1]);
    g.wake[0] = g.wake[1] = -1;
    if (g.fd >= 0)
        close(g.fd);
    g.fd = -1;
    PJ_LOG(3, (THIS_FILE, "VPN network stopped"));
}

pj_bool_t vnet_active(void)
{
    return g.running ? PJ_TRUE : PJ_FALSE;
}


/* ---------- SIP transport ---------- */

/* Received SIP packets are handed to PJSIP on its own event thread, like the
 * normal UDP transport does: vnet's reader writes them to a local socket pair
 * whose other end is registered with PJSIP's I/O queue. (Calling into PJSIP
 * from the reader thread can block on locks PJSIP holds while it waits for a
 * response, e.g. the unregistration at shutdown.) Each datagram on the pair
 * starts with the sender's IPv4 address and port (network order). */
#define SIP_RX_HDR 6

typedef struct {
    pjsip_transport     base;
    pj_uint16_t         port;
    int                 pair[2];        /* [0]: PJSIP I/O queue side, [1]: vnet reader side */
    pj_ioqueue_key_t   *key;
    pj_ioqueue_op_key_t op_key;
    pj_pool_t          *rdata_pool;
    pjsip_rx_data      *rdata;
    volatile int        closing;
    char                host[PJ_INET_ADDRSTRLEN];   /* local_name.host: the tunnel address */
    pj_uint8_t          rbuf[SIP_RX_HDR + PJSIP_MAX_PKT_LEN];
} vnet_sip_tp;

/* The SIP transport on the tunnel, if any (vnet_switch moves it to a new address). */
static vnet_sip_tp *g_sip_tp;

static void sip_rx(void *user, const pj_sockaddr_in *src, void *data, int len)
{
    vnet_sip_tp *tp = (vnet_sip_tp *)user;
    pj_uint8_t hdr[SIP_RX_HDR];
    struct iovec iov[2];
    struct msghdr msg;

    if (len <= 0 || len >= PJSIP_MAX_PKT_LEN || tp->closing)
        return;
    memcpy(hdr, &src->sin_addr, 4);
    memcpy(hdr + 4, &src->sin_port, 2);
    iov[0].iov_base = hdr;
    iov[0].iov_len = sizeof(hdr);
    iov[1].iov_base = data;
    iov[1].iov_len = (size_t)len;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov = iov;
    msg.msg_iovlen = 2;
    if (sendmsg(tp->pair[1], &msg, MSG_DONTWAIT) < 0)   /* dropped if PJSIP is far behind, as UDP would */
        st.rx_dropped++;
}

static void sip_rdata_init(vnet_sip_tp *tp)
{
    pj_pool_reset(tp->rdata_pool);
    tp->rdata = PJ_POOL_ZALLOC_T(tp->rdata_pool, pjsip_rx_data);
    tp->rdata->tp_info.pool = tp->rdata_pool;
    tp->rdata->tp_info.transport = &tp->base;
}

static void sip_on_read(pj_ioqueue_key_t *key, pj_ioqueue_op_key_t *op_key, pj_ssize_t bytes)
{
    vnet_sip_tp *tp = (vnet_sip_tp *)pj_ioqueue_get_user_data(key);
    PJ_UNUSED_ARG(op_key);

    for (;;) {
        pj_status_t status;
        pj_ssize_t size;

        if (tp->closing)
            return;
        if (bytes > SIP_RX_HDR) {
            pjsip_rx_data *rdata = tp->rdata;
            pj_sockaddr_in *src = (pj_sockaddr_in *)&rdata->pkt_info.src_addr;
            int len = (int)bytes - SIP_RX_HDR;

            pj_bzero(src, sizeof(*src));
            src->sin_family = pj_AF_INET();
            memcpy(&src->sin_addr, tp->rbuf, 4);
            memcpy(&src->sin_port, tp->rbuf + 4, 2);
            rdata->pkt_info.src_addr_len = sizeof(pj_sockaddr_in);
            pj_sockaddr_print(&rdata->pkt_info.src_addr, rdata->pkt_info.src_name,
                              sizeof(rdata->pkt_info.src_name), 0);
            rdata->pkt_info.src_port = pj_sockaddr_get_port(&rdata->pkt_info.src_addr);
            pj_memcpy(rdata->pkt_info.packet, tp->rbuf + SIP_RX_HDR, (pj_size_t)len);
            rdata->pkt_info.len = len;
            rdata->pkt_info.zero = 0;
            pj_gettimeofday(&rdata->pkt_info.timestamp);
            pjsip_tpmgr_receive_packet(tp->base.tpmgr, rdata);
            sip_rdata_init(tp);
        }
        if (tp->closing)
            return;
        /* Read the next one; loop while data is already there. */
        size = sizeof(tp->rbuf);
        status = pj_ioqueue_recv(key, &tp->op_key, tp->rbuf, &size, PJ_IOQUEUE_ALWAYS_ASYNC);
        if (status != PJ_SUCCESS)
            return;     /* PJ_EPENDING: sip_on_read is called again when data arrives */
        bytes = size;
    }
}

static pj_status_t sip_send_msg(pjsip_transport *transport, pjsip_tx_data *tdata,
                                const pj_sockaddr_t *rem_addr, int addr_len, void *token,
                                pjsip_transport_callback callback)
{
    vnet_sip_tp *tp = (vnet_sip_tp *)transport;
    PJ_UNUSED_ARG(addr_len);
    PJ_UNUSED_ARG(token);
    PJ_UNUSED_ARG(callback);
    return vnet_sendto(tp->port, (const pj_sockaddr_in *)rem_addr, tdata->buf.start,
                       (int)(tdata->buf.cur - tdata->buf.start));
}

static void sip_close_rx(vnet_sip_tp *tp)
{
    tp->closing = 1;
    vnet_unbind(tp->port);
    if (tp->key) {
        pj_ioqueue_unregister(tp->key);     /* also closes pair[0] */
        tp->key = NULL;
        tp->pair[0] = -1;
    }
    if (tp->pair[0] >= 0)
        close(tp->pair[0]);
    if (tp->pair[1] >= 0)
        close(tp->pair[1]);
    tp->pair[0] = tp->pair[1] = -1;
    if (tp->rdata_pool) {
        pj_pool_release(tp->rdata_pool);
        tp->rdata_pool = NULL;
    }
}

static pj_status_t sip_destroy(pjsip_transport *transport)
{
    vnet_sip_tp *tp = (vnet_sip_tp *)transport;
    if (g_sip_tp == tp)
        g_sip_tp = NULL;
    sip_close_rx(tp);
    if (tp->base.lock)
        pj_lock_destroy(tp->base.lock);
    if (tp->base.ref_cnt)
        pj_atomic_destroy(tp->base.ref_cnt);
    pjsip_endpt_release_pool(tp->base.endpt, tp->base.pool);
    return PJ_SUCCESS;
}

pj_status_t vnet_sip_transport_create(pjsip_endpoint *endpt, pj_uint16_t port,
                                      pjsip_transport **p_tp)
{
    pj_pool_t *pool;
    vnet_sip_tp *tp;
    pj_status_t status;
    pj_str_t ip;

    if (!g.running)
        return PJ_EINVALIDOP;
    pool = pjsip_endpt_create_pool(endpt, "vnetsip", 1000, 1000);
    if (!pool)
        return PJ_ENOMEM;
    tp = PJ_POOL_ZALLOC_T(pool, vnet_sip_tp);
    tp->base.pool = pool;
    tp->port = port;
    tp->pair[0] = tp->pair[1] = -1;
    pj_ansi_snprintf(tp->base.obj_name, sizeof(tp->base.obj_name), "vpnsip%p", tp);
    status = pj_atomic_create(pool, 0, &tp->base.ref_cnt);
    if (status == PJ_SUCCESS)
        status = pj_lock_create_recursive_mutex(pool, "vpnsip", &tp->base.lock);
    if (status != PJ_SUCCESS)
        goto on_error;

    /* Behaves like a UDP transport whose address is the tunnel address. */
    tp->base.key.type = PJSIP_TRANSPORT_UDP;
    tp->base.key.rem_addr.addr.sa_family = (pj_uint16_t)pj_AF_INET();
    tp->base.type_name = "UDP";
    tp->base.flag = pjsip_transport_get_flag_from_type(PJSIP_TRANSPORT_UDP);
    tp->base.info = pj_pool_alloc(pool, 64);
    pj_ansi_snprintf(tp->base.info, 64, "udp via VPN %s:%u", g.ip_str, port);
    ip = pj_str(g.ip_str);
    pj_sockaddr_init(pj_AF_INET(), &tp->base.local_addr, &ip, port);
    tp->base.addr_len = sizeof(pj_sockaddr_in);
    pj_ansi_strxcpy(tp->host, g.ip_str, sizeof(tp->host));
    tp->base.local_name.host = pj_str(tp->host);
    tp->base.local_name.port = port;
    tp->base.dir = PJSIP_TP_DIR_NONE;
    tp->base.endpt = endpt;
    tp->base.tpmgr = pjsip_endpt_get_tpmgr(endpt);
    tp->base.send_msg = &sip_send_msg;
    tp->base.destroy = &sip_destroy;

    /* Receive path: socket pair polled by PJSIP's I/O queue (see above). */
    {
        pj_ioqueue_callback iocb;
        int size = 256 * 1024, on = 1;
        pj_ssize_t len = 0;

        if (socketpair(AF_UNIX, SOCK_DGRAM, 0, tp->pair) != 0) {
            tp->pair[0] = tp->pair[1] = -1;
            status = PJ_RETURN_OS_ERROR(errno);
            goto on_error;
        }
        setsockopt(tp->pair[0], SOL_SOCKET, SO_RCVBUF, &size, sizeof(size));
        setsockopt(tp->pair[1], SOL_SOCKET, SO_SNDBUF, &size, sizeof(size));
        setsockopt(tp->pair[1], SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
        tp->rdata_pool = pjsip_endpt_create_pool(endpt, "vnetrx", PJSIP_POOL_RDATA_LEN,
                                                 PJSIP_POOL_RDATA_INC);
        if (!tp->rdata_pool) {
            status = PJ_ENOMEM;
            goto on_error;
        }
        sip_rdata_init(tp);
        pj_bzero(&iocb, sizeof(iocb));
        iocb.on_read_complete = &sip_on_read;
        pj_ioqueue_op_key_init(&tp->op_key, sizeof(tp->op_key));
        status = pj_ioqueue_register_sock(pool, pjsip_endpt_get_ioqueue(endpt), tp->pair[0],
                                          tp, &iocb, &tp->key);
        if (status != PJ_SUCCESS)
            goto on_error;
        len = sizeof(tp->rbuf);
        status = pj_ioqueue_recv(tp->key, &tp->op_key, tp->rbuf, &len, PJ_IOQUEUE_ALWAYS_ASYNC);
        if (status != PJ_EPENDING && status != PJ_SUCCESS)
            goto on_error;
    }

    status = vnet_bind(port, &sip_rx, tp);
    if (status != PJ_SUCCESS)
        goto on_error;
    status = pjsip_transport_register(tp->base.tpmgr, &tp->base);
    if (status != PJ_SUCCESS)
        goto on_error;
    g_sip_tp = tp;
    *p_tp = &tp->base;
    return PJ_SUCCESS;

on_error:
    sip_close_rx(tp);
    if (tp->base.lock)
        pj_lock_destroy(tp->base.lock);
    if (tp->base.ref_cnt)
        pj_atomic_destroy(tp->base.ref_cnt);
    pjsip_endpt_release_pool(endpt, pool);
    return status;
}

/* ---------- media transport ---------- */

typedef struct {
    pjmedia_transport base;
    pj_pool_t        *pool;
    pjmedia_transport *member;      /* pjsua's original transport, closed with us */
    pj_uint16_t       rtp_port, rtcp_port;
    pj_sockaddr       rem_rtp, rem_rtcp, src_rtp, src_rtcp;
    void             *user_data;
    void            (*rtp_cb)(void *, void *, pj_ssize_t);
    void            (*rtcp_cb)(void *, void *, pj_ssize_t);
    void            (*rtp_cb2)(pjmedia_tp_cb_param *);
    pj_bool_t         bound;
} vnet_media_tp;

static void media_rtp_rx(void *user, const pj_sockaddr_in *src, void *pkt, int len)
{
    vnet_media_tp *tp = (vnet_media_tp *)user;
    register_thread();
    pj_memcpy(&tp->src_rtp, src, sizeof(*src));
    if (tp->rtp_cb2) {
        pjmedia_tp_cb_param param;
        pj_bzero(&param, sizeof(param));
        param.user_data = tp->user_data;
        param.pkt = pkt;
        param.size = len;
        param.src_addr = &tp->src_rtp;
        tp->rtp_cb2(&param);
    } else if (tp->rtp_cb) {
        tp->rtp_cb(tp->user_data, pkt, len);
    }
}

static void media_rtcp_rx(void *user, const pj_sockaddr_in *src, void *pkt, int len)
{
    vnet_media_tp *tp = (vnet_media_tp *)user;
    register_thread();
    pj_memcpy(&tp->src_rtcp, src, sizeof(*src));
    if (tp->rtcp_cb)
        tp->rtcp_cb(tp->user_data, pkt, len);
}

static void media_unbind(vnet_media_tp *tp)
{
    if (tp->bound) {
        vnet_unbind(tp->rtp_port);
        vnet_unbind(tp->rtcp_port);
        tp->bound = PJ_FALSE;
    }
}

static pj_status_t media_get_info(pjmedia_transport *t, pjmedia_transport_info *info)
{
    vnet_media_tp *tp = (vnet_media_tp *)t;
    pj_str_t ip = pj_str(g.ip_str);
    info->sock_info.rtp_sock = PJ_INVALID_SOCKET;
    info->sock_info.rtcp_sock = PJ_INVALID_SOCKET;
    pj_sockaddr_init(pj_AF_INET(), &info->sock_info.rtp_addr_name, &ip, tp->rtp_port);
    pj_sockaddr_init(pj_AF_INET(), &info->sock_info.rtcp_addr_name, &ip, tp->rtcp_port);
    pj_memcpy(&info->src_rtp_name, &tp->src_rtp, sizeof(tp->src_rtp));
    pj_memcpy(&info->src_rtcp_name, &tp->src_rtcp, sizeof(tp->src_rtcp));
    return PJ_SUCCESS;
}

static pj_status_t media_attach2(pjmedia_transport *t, pjmedia_transport_attach_param *p)
{
    vnet_media_tp *tp = (vnet_media_tp *)t;
    pj_status_t status;
    media_unbind(tp);
    pj_memcpy(&tp->rem_rtp, &p->rem_addr, sizeof(pj_sockaddr));
    pj_memcpy(&tp->rem_rtcp, &p->rem_rtcp, sizeof(pj_sockaddr));
    if (!pj_sockaddr_has_addr(&tp->rem_rtcp)) {
        pj_memcpy(&tp->rem_rtcp, &tp->rem_rtp, sizeof(pj_sockaddr));
        pj_sockaddr_set_port(&tp->rem_rtcp, (pj_uint16_t)(pj_sockaddr_get_port(&tp->rem_rtp) + 1));
    }
    tp->user_data = p->user_data;
    tp->rtp_cb = p->rtp_cb;
    tp->rtcp_cb = p->rtcp_cb;
    tp->rtp_cb2 = p->rtp_cb2;
    status = vnet_bind(tp->rtp_port, &media_rtp_rx, tp);
    if (status == PJ_SUCCESS) {
        status = vnet_bind(tp->rtcp_port, &media_rtcp_rx, tp);
        if (status != PJ_SUCCESS)
            vnet_unbind(tp->rtp_port);
    }
    tp->bound = (status == PJ_SUCCESS);
    return status;
}

static pj_status_t media_attach(pjmedia_transport *t, void *user_data,
                                const pj_sockaddr_t *rem_addr, const pj_sockaddr_t *rem_rtcp,
                                unsigned addr_len, void (*rtp_cb)(void *, void *, pj_ssize_t),
                                void (*rtcp_cb)(void *, void *, pj_ssize_t))
{
    pjmedia_transport_attach_param p;
    pj_bzero(&p, sizeof(p));
    p.user_data = user_data;
    pj_memcpy(&p.rem_addr, rem_addr, addr_len);
    if (rem_rtcp)
        pj_memcpy(&p.rem_rtcp, rem_rtcp, addr_len);
    p.addr_len = addr_len;
    p.rtp_cb = rtp_cb;
    p.rtcp_cb = rtcp_cb;
    return media_attach2(t, &p);
}

static void media_detach(pjmedia_transport *t, void *user_data)
{
    vnet_media_tp *tp = (vnet_media_tp *)t;
    PJ_UNUSED_ARG(user_data);
    media_unbind(tp);
    tp->rtp_cb = NULL;
    tp->rtcp_cb = NULL;
    tp->rtp_cb2 = NULL;
}

static pj_status_t media_send_rtp(pjmedia_transport *t, const void *pkt, pj_size_t size)
{
    vnet_media_tp *tp = (vnet_media_tp *)t;
    return vnet_sendto(tp->rtp_port, &tp->rem_rtp.ipv4, pkt, (int)size);
}

static pj_status_t media_send_rtcp2(pjmedia_transport *t, const pj_sockaddr_t *addr,
                                    unsigned addr_len, const void *pkt, pj_size_t size)
{
    vnet_media_tp *tp = (vnet_media_tp *)t;
    PJ_UNUSED_ARG(addr_len);
    return vnet_sendto(tp->rtcp_port, addr ? (const pj_sockaddr_in *)addr : &tp->rem_rtcp.ipv4,
                       pkt, (int)size);
}

static pj_status_t media_send_rtcp(pjmedia_transport *t, const void *pkt, pj_size_t size)
{
    return media_send_rtcp2(t, NULL, 0, pkt, size);
}

static pj_status_t media_create(pjmedia_transport *t, pj_pool_t *pool, unsigned options,
                                const pjmedia_sdp_session *rem, unsigned idx)
{
    PJ_UNUSED_ARG(t); PJ_UNUSED_ARG(pool); PJ_UNUSED_ARG(options);
    PJ_UNUSED_ARG(rem); PJ_UNUSED_ARG(idx);
    return PJ_SUCCESS;
}

static pj_status_t media_encode_sdp(pjmedia_transport *t, pj_pool_t *pool, pjmedia_sdp_session *local,
                                    const pjmedia_sdp_session *rem, unsigned idx)
{
    PJ_UNUSED_ARG(t); PJ_UNUSED_ARG(pool); PJ_UNUSED_ARG(local);
    PJ_UNUSED_ARG(rem); PJ_UNUSED_ARG(idx);
    return PJ_SUCCESS;
}

static pj_status_t media_start(pjmedia_transport *t, pj_pool_t *pool, const pjmedia_sdp_session *local,
                               const pjmedia_sdp_session *rem, unsigned idx)
{
    PJ_UNUSED_ARG(t); PJ_UNUSED_ARG(pool); PJ_UNUSED_ARG(local);
    PJ_UNUSED_ARG(rem); PJ_UNUSED_ARG(idx);
    return PJ_SUCCESS;
}

static pj_status_t media_stop(pjmedia_transport *t)
{
    PJ_UNUSED_ARG(t);
    return PJ_SUCCESS;
}

static pj_status_t media_simulate_lost(pjmedia_transport *t, pjmedia_dir dir, unsigned pct)
{
    PJ_UNUSED_ARG(t); PJ_UNUSED_ARG(dir); PJ_UNUSED_ARG(pct);
    return PJ_SUCCESS;
}

/* Frees the transport once nothing uses it any more (the group lock's last reference
 * is gone): the call's audio stream may be destroyed after the transport is closed,
 * later and on the conference bridge's thread, and still reads it then. */
static void media_on_destroy(void *arg)
{
    vnet_media_tp *tp = (vnet_media_tp *)arg;
    pj_pool_safe_release(&tp->pool);
}

static pj_status_t media_destroy(pjmedia_transport *t)
{
    vnet_media_tp *tp = (vnet_media_tp *)t;
    pjmedia_transport *member = tp->member;
    pj_grp_lock_t *grp_lock = tp->base.grp_lock;
    media_unbind(tp);
    tp->member = NULL;
    if (member)
        pjmedia_transport_close(member);
    /* Same as PJSIP's SRTP wrapper: the memory goes with the shared group lock. */
    if (grp_lock)
        pj_grp_lock_dec_ref(grp_lock);
    else
        pj_pool_safe_release(&tp->pool);
    return PJ_SUCCESS;
}

static pjmedia_transport_op media_op = {
    &media_get_info, &media_attach, &media_detach, &media_send_rtp, &media_send_rtcp,
    &media_send_rtcp2, &media_create, &media_encode_sdp, &media_start, &media_stop,
    &media_simulate_lost, &media_destroy, &media_attach2,
};

pjmedia_transport *vnet_media_transport_create(pjmedia_endpt *endpt, pjmedia_transport *base_tp,
                                               pjmedia_srtp_use srtp_use)
{
    pjmedia_transport_info info;
    pj_pool_t *pool;
    vnet_media_tp *tp;
    pjmedia_transport *srtp = NULL;

    if (!g.running)
        return base_tp;
    pjmedia_transport_info_init(&info);
    pjmedia_transport_get_info(base_tp, &info);

    pool = pjmedia_endpt_create_pool(endpt, "vnetmed", 512, 512);
    if (!pool)
        return base_tp;
    tp = PJ_POOL_ZALLOC_T(pool, vnet_media_tp);
    tp->pool = pool;
    tp->member = base_tp;
    tp->rtp_port = pj_sockaddr_get_port(&info.sock_info.rtp_addr_name);
    tp->rtcp_port = pj_sockaddr_get_port(&info.sock_info.rtcp_addr_name);
    if (tp->rtcp_port == 0)
        tp->rtcp_port = (pj_uint16_t)(tp->rtp_port + 1);
    pj_ansi_snprintf(tp->base.name, sizeof(tp->base.name), "vpnmed%p", tp);
    tp->base.type = PJMEDIA_TRANSPORT_TYPE_USER;
    tp->base.op = &media_op;
    /* Share the original transport's group lock, which pjsua and the audio stream use
     * for lifetime; our memory is released with it (media_on_destroy). */
    if (base_tp->grp_lock) {
        tp->base.grp_lock = base_tp->grp_lock;
        pj_grp_lock_add_ref(base_tp->grp_lock);
        pj_grp_lock_add_handler(base_tp->grp_lock, pool, tp, &media_on_destroy);
    }
    PJ_LOG(4, (THIS_FILE, "Media via VPN %s:%u", g.ip_str, tp->rtp_port));

    if (srtp_use == PJMEDIA_SRTP_DISABLED)
        return &tp->base;

    {
        pjmedia_srtp_setting opt;
        pjmedia_srtp_setting_default(&opt);
        opt.use = srtp_use;
        opt.close_member_tp = PJ_TRUE;
        if (pjmedia_transport_srtp_create(endpt, &tp->base, &opt, &srtp) != PJ_SUCCESS)
            return &tp->base;
        return srtp;
    }
}

void vnet_get_stats(sip_vpn_stats *out)
{
    pj_uint64_t now = now_ns();
    pj_bzero(out, sizeof(*out));
    out->active = g.running ? 1 : 0;
    out->rx_packets = st.rx_packets;
    out->rx_bytes = st.rx_bytes;
    out->rx_sip = st.rx_sip;
    out->rx_media = st.rx_media;
    out->rx_dropped = st.rx_dropped;
    out->tx_packets = st.tx_packets;
    out->tx_bytes = st.tx_bytes;
    out->tx_errors = st.tx_errors;
    out->ms_since_rx = st.last_rx_ns ? (int)((now - st.last_rx_ns) / 1000000) : -1;
    out->ms_since_tx = st.last_tx_ns ? (int)((now - st.last_tx_ns) / 1000000) : -1;
    out->max_delivery_ms = (int)(st.max_delivery_ns / 1000000);
    out->max_send_ms = (int)(st.max_send_ns / 1000000);
    st.max_delivery_ns = 0;
    st.max_send_ns = 0;
}

/* ---------- moving to a new tunnel ---------- */

pj_status_t vnet_switch(int fd, const char *local_ip, int mtu)
{
    struct in_addr addr;
    char old_ip[PJ_INET_ADDRSTRLEN];

    if (!g.running || pthread_equal(pthread_self(), g.reader)) {
        if (fd >= 0)
            close(fd);
        return PJ_EINVALIDOP;
    }
    if (fd >= 0 && (!local_ip || inet_pton(AF_INET, local_ip, &addr) != 1)) {
        close(fd);
        return PJ_EINVAL;
    }
    pj_ansi_strxcpy(old_ip, g.ip_str, sizeof(old_ip));

    /* Stop the reader, swap the tunnel under the send lock, start a new reader.
     * Ports, bindings and PJSIP's transports stay as they are. */
    pthread_mutex_lock(&g.tx_lock);
    g.reader_quit = 1;
    (void)!write(g.wake[1], "x", 1);
    pthread_join(g.reader, NULL);
    {
        char drain[16];
        while (read(g.wake[0], drain, sizeof(drain)) > 0) {
            struct pollfd pf = { g.wake[0], POLLIN, 0 };
            if (poll(&pf, 1, 0) <= 0)
                break;
        }
    }
    if (g.fd >= 0)
        close(g.fd);
    g.fd = fd;
    if (fd >= 0) {
        g.ip = addr.s_addr;
        pj_ansi_strxcpy(g.ip_str, local_ip, sizeof(g.ip_str));
        g.mtu = (mtu >= 576 && mtu <= 9000) ? mtu : 1500;
        pj_bzero(g.reasm, sizeof(g.reasm));
        {
            int on = 1;
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
        }
        if (g_sip_tp) {
            vnet_sip_tp *tp = g_sip_tp;
            pj_str_t ip = pj_str(g.ip_str);
            pj_lock_acquire(tp->base.lock);
            pj_sockaddr_init(pj_AF_INET(), &tp->base.local_addr, &ip, tp->port);
            pj_ansi_strxcpy(tp->host, g.ip_str, sizeof(tp->host));
            tp->base.local_name.host = pj_str(tp->host);
            pj_lock_release(tp->base.lock);
        }
    }
    g.reader_quit = 0;
    if (pthread_create(&g.reader, NULL, reader_main, NULL) != 0) {
        pthread_mutex_unlock(&g.tx_lock);
        PJ_LOG(1, (THIS_FILE, "VPN network: cannot restart the reader"));
        return PJ_ENOMEM;
    }
    pthread_mutex_unlock(&g.tx_lock);
    if (fd >= 0)
        PJ_LOG(3, (THIS_FILE, "VPN network moved to the new tunnel: %s (was %s), MTU %d",
                   g.ip_str, old_ip, g.mtu));
    else
        PJ_LOG(3, (THIS_FILE, "VPN network on hold: waiting for the tunnel to come back"));
    return PJ_SUCCESS;
}
