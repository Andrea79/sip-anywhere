#include "sipcore.h"
#include "vnet.h"

#include <pjsua-lib/pjsua.h>
#include <pjmedia/transport_srtp.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define MAX_CALLS 4

static int g_running = 0;
static pjmedia_srtp_use g_srtp_use = PJMEDIA_SRTP_DISABLED;
static pjsua_acc_id g_acc = PJSUA_INVALID_ID;
static pjsua_transport_id g_tid = PJSUA_INVALID_ID;
static sip_callbacks g_cb;
static void *g_ctx = NULL;
static char g_domain[256];
static int g_muted[PJSUA_MAX_CALLS];
/* What we hear of each call, 0...1 (sip_set_volume); kept here because PJSIP may
 * recreate the call's audio port (re-INVITE), which resets its level. */
static float g_volume[PJSUA_MAX_CALLS];
/* Call recording (sip_record_start): a WAV recorder per call, or PJSUA_INVALID_ID. */
static pjsua_recorder_id g_rec[PJSUA_MAX_CALLS];
static void stop_recording(pjsua_call_id call_id);
/* Conference (sip_conference): the call each call is joined with, or -1. */
static int g_partner[PJSUA_MAX_CALLS];
/* Answering machine (sip_voicemail_answer): the call is answered by the app, which
 * plays the greeting and then records the caller; our microphone and speaker stay
 * out of it. g_vm_gen invalidates timers of an earlier call with the same id. */
static int g_vm[PJSUA_MAX_CALLS];
static pjsua_player_id g_vm_player[PJSUA_MAX_CALLS];
static char g_vm_message[PJSUA_MAX_CALLS][1024];
static int g_vm_max[PJSUA_MAX_CALLS];
static unsigned g_vm_gen[PJSUA_MAX_CALLS];
static void vm_end(pjsua_call_id call_id);
static unsigned g_last_pkt[PJSUA_MAX_CALLS], g_last_loss[PJSUA_MAX_CALLS];
/* Keypad tones heard locally during a call (sip_play_keypad_tone). */
static unsigned g_clock_rate, g_frame_ptime;
static pj_pool_t *g_tone_pool;
static pjmedia_port *g_tonegen;
static pjsua_conf_port_id g_tone_slot = PJSUA_INVALID_ID;
/* While a keypad tone plays the microphone is kept off the calls: echo cancellation
 * does not remove the tone completely, and a voice menu would get each digit twice
 * (RFC 2833 and in-band), which can prevent it from recognising the digits. */
static int g_tone_mic_off;
static pj_timer_entry g_tone_timer;

/* ---------- helpers ---------- */

static void set_err(char *err, int err_len, const char *what, pj_status_t status)
{
    char msg[PJ_ERR_MSG_SIZE];
    if (!err || err_len <= 0)
        return;
    if (status == PJ_SUCCESS) {
        snprintf(err, (size_t)err_len, "%s", what);
        return;
    }
    pj_strerror(status, msg, sizeof(msg));
    snprintf(err, (size_t)err_len, "%s: %s", what, msg);
}

/* pjlib requires every thread that calls into it to be registered. Swift may
 * call us from the main thread or from arbitrary GCD threads. */
static void ensure_thread(void)
{
    static __thread pj_thread_desc desc;
    static __thread pj_thread_t *thread;
    if (!pj_thread_is_registered()) {
        pj_bzero(desc, sizeof(desc));
        pj_thread_register("swift", desc, &thread);
    }
}

static void copy_pj_str(char *dst, size_t len, const pj_str_t *s)
{
    size_t n = (size_t)s->slen < len - 1 ? (size_t)s->slen : len - 1;
    memcpy(dst, s->ptr, n);
    dst[n] = '\0';
}

/* Audio only. PJSIP also offers a real-time text stream by default, which
 * many providers reject (e.g. 606 "non-audio media not accepted"). */
static void audio_only(pjsua_call_setting *opt)
{
    pjsua_call_setting_default(opt);
    opt->aud_cnt = 1;
    opt->vid_cnt = 0;
    opt->txt_cnt = 0;
}

/* With the in-app VPN, each call's audio goes through the tunnel instead of the
 * UDP transport pjsua created (vnet takes that transport over and closes it). */
static pjmedia_transport *on_create_media_transport(pjsua_call_id call_id, unsigned media_idx,
                                                    pjmedia_transport *base_tp, unsigned flags)
{
    PJ_UNUSED_ARG(call_id);
    PJ_UNUSED_ARG(media_idx);
    PJ_UNUSED_ARG(flags);
    return vnet_media_transport_create(pjsua_get_pjmedia_endpt(), base_tp, g_srtp_use);
}

/* Every SDP we send says, at session level, that we are not recording the call
 * (RFC 7866 a=record:off). */
static void on_call_sdp_created(pjsua_call_id call_id, pjmedia_sdp_session *sdp, pj_pool_t *pool,
                                const pjmedia_sdp_session *rem_sdp)
{
    pj_str_t off = pj_str("off");
    PJ_UNUSED_ARG(call_id);
    PJ_UNUSED_ARG(rem_sdp);
    if (!pjmedia_sdp_attr_find2(sdp->attr_count, sdp->attr, "record", NULL)) {
        pjmedia_sdp_attr *a = pjmedia_sdp_attr_create(pool, "record", &off);
        if (a)
            pjmedia_sdp_attr_add(&sdp->attr_count, sdp->attr, a);
    }
}

/* Removes a value (e.g. "100rel") from one of the endpoint's capability headers
 * (Supported/Allow), which are copied into every outgoing INVITE. */
static void remove_capability(int htype, const char *value)
{
    pjsip_generic_array_hdr *h = (pjsip_generic_array_hdr *)
        pjsip_endpt_get_capability(pjsua_get_pjsip_endpt(), htype, NULL);
    pj_str_t v = pj_str((char *)value);
    unsigned i;
    if (!h)
        return;
    for (i = 0; i < h->count; ++i) {
        if (pj_stricmp(&h->values[i], &v) == 0) {
            pj_array_erase(h->values, sizeof(h->values[0]), h->count, i);
            h->count--;
            return;
        }
    }
}

/* ---------- pjsua callbacks (run on pjsua worker threads) ---------- */

static void log_writer(int level, const char *data, int len)
{
    char buf[4096];
    size_t n;
    if (!g_cb.on_log)
        return;
    n = (size_t)len < sizeof(buf) - 1 ? (size_t)len : sizeof(buf) - 1;
    memcpy(buf, data, n);
    buf[n] = '\0';
    g_cb.on_log(g_ctx, level, buf);
}

/* Registration refresh at 85% of the granted time. PJSIP by default refreshes only
 * 5 s before expiry, which leaves little margin for a slow or lost response before
 * the binding expires. */
static pj_timer_entry g_refresh_timer;

static void refresh_timer_cb(pj_timer_heap_t *th, pj_timer_entry *e)
{
    PJ_UNUSED_ARG(th);
    e->id = 0;
    if (g_running && g_acc != PJSUA_INVALID_ID)
        pjsua_acc_set_registration(g_acc, PJ_TRUE);
}

static void schedule_refresh(unsigned expiration)
{
    pj_time_val delay;
    if (g_refresh_timer.id) {
        pjsua_cancel_timer(&g_refresh_timer);
        g_refresh_timer.id = 0;
    }
    if (expiration < 20)
        return;             /* PJSIP's own refresh is early enough */
    pj_timer_entry_init(&g_refresh_timer, 0, NULL, &refresh_timer_cb);
    delay.sec = (long)(expiration * 85 / 100);
    delay.msec = 0;
    g_refresh_timer.id = 1;
    if (pjsua_schedule_timer(&g_refresh_timer, &delay) != PJ_SUCCESS)
        g_refresh_timer.id = 0;
}

/* After the VPN tunnel moved (sip_vpn_switch_tunnel): once the registration is
 * renewed from the new path and the account's public Contact settled, send a
 * re-INVITE so the provider learns the new Contact of each call in progress. */
static int g_reinvite_pending;
static pj_timer_entry g_reinvite_timer;

static void reinvite_timer_cb(pj_timer_heap_t *th, pj_timer_entry *e)
{
    pjsua_call_id ids[PJSUA_MAX_CALLS];
    unsigned i, count = PJ_ARRAY_SIZE(ids);
    PJ_UNUSED_ARG(th);
    e->id = 0;
    /* Once per tunnel move: later registration refreshes must not re-INVITE again
     * (needless re-INVITEs can be refused, e.g. with 488). */
    g_reinvite_pending = 0;
    if (!g_running)
        return;
    if (pjsua_enum_calls(ids, &count) != PJ_SUCCESS)
        return;
    for (i = 0; i < count; ++i) {
        pjsua_call_info ci;
        pjsua_call_setting opt;
        if (pjsua_call_get_info(ids[i], &ci) != PJ_SUCCESS || ci.state != PJSIP_INV_STATE_CONFIRMED)
            continue;
        pjsua_call_setting_default(&opt);
        opt.aud_cnt = 1;
        opt.vid_cnt = 0;
        opt.txt_cnt = 0;        /* audio only: some providers reject other media (606) */
        opt.flag = PJSUA_CALL_UPDATE_CONTACT | PJSUA_CALL_UPDATE_VIA;
        PJ_LOG(3, ("sipcore", "Call %d: re-INVITE with the new Contact after the VPN moved", ids[i]));
        pjsua_call_reinvite2(ids[i], &opt, NULL);
    }
}

static void schedule_reinvite(void)
{
    pj_time_val delay = { 2, 0 };   /* lets a Contact rewrite (new public port) settle */
    if (g_reinvite_timer.id) {
        pjsua_cancel_timer(&g_reinvite_timer);
        g_reinvite_timer.id = 0;
    }
    pj_timer_entry_init(&g_reinvite_timer, 0, NULL, &reinvite_timer_cb);
    g_reinvite_timer.id = 1;
    if (pjsua_schedule_timer(&g_reinvite_timer, &delay) != PJ_SUCCESS)
        g_reinvite_timer.id = 0;
}

static void on_reg_state2(pjsua_acc_id acc_id, pjsua_reg_info *info)
{
    char reason[256];
    PJ_UNUSED_ARG(acc_id);
    if (!info->cbparam)
        return;
    if (info->cbparam->code / 100 == 2 && info->cbparam->expiration > 0) {
        schedule_refresh(info->cbparam->expiration);
        if (g_reinvite_pending)
            schedule_reinvite();    /* rescheduled if a Contact rewrite registers again */
    }
    if (!g_cb.on_reg_state)
        return;
    copy_pj_str(reason, sizeof(reason), &info->cbparam->reason);
    if (info->cbparam->status != PJ_SUCCESS && info->cbparam->code == 0) {
        char msg[PJ_ERR_MSG_SIZE];
        pj_strerror(info->cbparam->status, msg, sizeof(msg));
        snprintf(reason, sizeof(reason), "%s", msg);
    }
    g_cb.on_reg_state(g_ctx, info->cbparam->code, reason, info->cbparam->expiration);
}

/* The caller as the network vouches for it: P-Asserted-Identity (RFC 3325), or the
 * older Remote-Party-ID. Providers often hide the caller in From (some send "Unsubscribed"
 * <sip:unsubscribed@unsubscribed.invalid> when caller ID is not part of the line's plan)
 * and put the number here. Returns 0 if there is none. */
static int asserted_caller(pjsip_rx_data *rdata, char *out, int out_len)
{
    static const char *names[] = { "P-Asserted-Identity", "Remote-Party-ID" };
    unsigned i;
    if (!rdata || !rdata->msg_info.msg)
        return 0;
    for (i = 0; i < PJ_ARRAY_SIZE(names); ++i) {
        pj_str_t name = pj_str((char *)names[i]);
        pjsip_generic_string_hdr *h = (pjsip_generic_string_hdr *)
            pjsip_msg_find_hdr_by_name(rdata->msg_info.msg, &name, NULL);
        if (h && h->hvalue.slen > 0) {
            copy_pj_str(out, out_len, &h->hvalue);
            return 1;
        }
    }
    return 0;
}

static void on_incoming_call(pjsua_acc_id acc_id, pjsua_call_id call_id, pjsip_rx_data *rdata)
{
    pjsua_call_info ci;
    pjsua_call_setting opt;
    char remote[256];
    PJ_UNUSED_ARG(acc_id);

    /* pjsua itself rejects calls beyond max_calls. */
    g_muted[call_id] = 0;
    g_volume[call_id] = 1.0f;
    g_last_pkt[call_id] = g_last_loss[call_id] = 0;
    audio_only(&opt);
    pjsua_call_answer2(call_id, &opt, 180, NULL, NULL);
    pjsua_call_get_info(call_id, &ci);
    if (asserted_caller(rdata, remote, sizeof(remote)))
        PJ_LOG(3, ("sipcore", "Call %d: caller from the asserted identity: %s", call_id, remote));
    else
        copy_pj_str(remote, sizeof(remote), &ci.remote_info);
    if (g_cb.on_incoming_call)
        g_cb.on_incoming_call(g_ctx, call_id, remote);
}

static void on_call_state(pjsua_call_id call_id, pjsip_event *e)
{
    pjsua_call_info ci;
    char remote[256], reason[384];
    pjsua_call_get_info(call_id, &ci);
    copy_pj_str(remote, sizeof(remote), &ci.remote_info);
    copy_pj_str(reason, sizeof(reason), &ci.last_status_text);

    /* Append the explanation from a Warning header, e.g.
     * 399 host "non-audio media not accepted", to the status text. */
    if (e && e->type == PJSIP_EVENT_TSX_STATE && e->body.tsx_state.type == PJSIP_EVENT_RX_MSG) {
        const pj_str_t name = { "Warning", 7 };
        pjsip_generic_string_hdr *w = (pjsip_generic_string_hdr *)
            pjsip_msg_find_hdr_by_name(e->body.tsx_state.src.rdata->msg_info.msg, &name, NULL);
        if (w) {
            char text[256];
            const char *q1, *q2;
            copy_pj_str(text, sizeof(text), &w->hvalue);
            q1 = strchr(text, '"');
            q2 = q1 ? strchr(q1 + 1, '"') : NULL;
            if (q1 && q2)
                snprintf(reason + strlen(reason), sizeof(reason) - strlen(reason),
                         " – %.*s", (int)(q2 - q1 - 1), q1 + 1);
        }
    }
    /* Log the media statistics (packets received/sent, loss, remote address)
     * while they are still available, to diagnose "no audio" problems. */
    if (ci.state == PJSIP_INV_STATE_DISCONNECTED) {
        static char dump[8192];
        stop_recording(call_id);
        vm_end(call_id);
        if (g_partner[call_id] >= 0) {
            g_partner[g_partner[call_id]] = -1;
            g_partner[call_id] = -1;
        }
        if (pjsua_call_dump(call_id, PJ_TRUE, dump, sizeof(dump), "  ") == PJ_SUCCESS)
            PJ_LOG(3, ("sipcore", "Call %d statistics:\n%s", call_id, dump));
    }

    if (g_cb.on_call_state)
        g_cb.on_call_state(g_ctx, call_id, (int)ci.state, (int)ci.last_status, reason, remote);
}

/* Whether the call's audio should be wired to the sound device right now. */
static int media_is_live(pjsua_call_id call_id)
{
    pjsua_call_info ci;
    unsigned i;
    if (pjsua_call_get_info(call_id, &ci) != PJ_SUCCESS)
        return 0;
    for (i = 0; i < ci.media_cnt; ++i) {
        if (ci.media[i].type == PJMEDIA_TYPE_AUDIO)
            return ci.media[i].status == PJSUA_CALL_MEDIA_ACTIVE ||
                   ci.media[i].status == PJSUA_CALL_MEDIA_REMOTE_HOLD;
    }
    return 0;
}

/* The recorder hears the other party, and us unless the microphone is muted. */
static void wire_recorder(pjsua_call_id call_id)
{
    pjsua_conf_port_id slot, rslot;
    if (g_rec[call_id] == PJSUA_INVALID_ID)
        return;
    rslot = pjsua_recorder_get_conf_port(g_rec[call_id]);
    slot = pjsua_call_get_conf_port(call_id);
    if (rslot == PJSUA_INVALID_ID)
        return;
    if (slot != PJSUA_INVALID_ID)
        pjsua_conf_connect(slot, rslot);
    if (g_muted[call_id])
        pjsua_conf_disconnect(0, rslot);
    else
        pjsua_conf_connect(0, rslot);
}

/* Conference: two live calls hear each other (each also hears us, as usual). */
static void wire_partner(pjsua_call_id call_id, int join)
{
    int p = g_partner[call_id];
    pjsua_conf_port_id a = pjsua_call_get_conf_port(call_id), b;
    if (p < 0 || a == PJSUA_INVALID_ID)
        return;
    b = pjsua_call_get_conf_port(p);
    if (b == PJSUA_INVALID_ID)
        return;
    if (join && media_is_live(call_id) && media_is_live(p)) {
        pjsua_conf_connect(a, b);
        pjsua_conf_connect(b, a);
    } else {
        pjsua_conf_disconnect(a, b);
        pjsua_conf_disconnect(b, a);
    }
}

static void stop_recording(pjsua_call_id call_id)
{
    if (g_rec[call_id] == PJSUA_INVALID_ID)
        return;
    pjsua_recorder_destroy(g_rec[call_id]);
    g_rec[call_id] = PJSUA_INVALID_ID;
    PJ_LOG(3, ("sipcore", "Call %d: recording stopped", call_id));
}

static void on_call_media_state(pjsua_call_id call_id)
{
    pjsua_conf_port_id slot = pjsua_call_get_conf_port(call_id);
    pjsua_call_info ci;
    unsigned i;

    /* Log where the audio goes, to diagnose "no audio" problems. */
    if (pjsua_call_get_info(call_id, &ci) == PJ_SUCCESS) {
        for (i = 0; i < ci.media_cnt; ++i) {
            pjsua_stream_info si;
            char addr[PJ_INET6_ADDRSTRLEN + 10] = "-";
            if (ci.media[i].type != PJMEDIA_TYPE_AUDIO)
                continue;
            if (pjsua_call_get_stream_info(call_id, i, &si) == PJ_SUCCESS && si.type == PJMEDIA_TYPE_AUDIO)
                pj_sockaddr_print(&si.info.aud.rem_addr, addr, sizeof(addr), 3);
            PJ_LOG(3, ("sipcore", "Call %d audio: media status %d, sending RTP to %s, sound slot %d",
                       call_id, (int)ci.media[i].status, addr, slot));
        }
    }
    if (slot == PJSUA_INVALID_ID)
        return;
    if (g_vm[call_id]) {
        /* Answering machine: greeting to the caller, the caller to the recorder only. */
        if (g_vm_player[call_id] != PJSUA_INVALID_ID)
            pjsua_conf_connect(pjsua_player_get_conf_port(g_vm_player[call_id]), slot);
        wire_recorder(call_id);
        return;
    }
    if (media_is_live(call_id)) {
        pjsua_conf_adjust_rx_level(slot, g_volume[call_id]);
        pjsua_conf_connect(slot, 0);              /* remote -> speaker */
        if (!g_muted[call_id] && !g_tone_mic_off)
            pjsua_conf_connect(0, slot);          /* mic -> remote */
        wire_partner(call_id, 1);
    } else {
        /* On hold: the other party must not hear (or be heard in) other calls. */
        pjsua_conf_disconnect(slot, 0);
        pjsua_conf_disconnect(0, slot);
        wire_partner(call_id, 0);
    }
    wire_recorder(call_id);
}

/* In-dialog OPTIONS (session audits: "are you still there?") must get 200 OK.
 * Without this, PJSIP answers 500, and the provider may end the call. */
static void on_call_tsx_state(pjsua_call_id call_id, pjsip_transaction *tsx, pjsip_event *e)
{
    PJ_UNUSED_ARG(call_id);
    if (tsx->role == PJSIP_ROLE_UAS && tsx->state == PJSIP_TSX_STATE_TRYING &&
        pjsip_method_cmp(&tsx->method, &pjsip_options_method) == 0 &&
        e->type == PJSIP_EVENT_TSX_STATE && e->body.tsx_state.type == PJSIP_EVENT_RX_MSG)
    {
        pjsip_rx_data *rdata = e->body.tsx_state.src.rdata;
        pjsip_dialog *dlg = pjsip_rdata_get_dlg(rdata);
        pjsip_tx_data *tdata;
        if (dlg && pjsip_dlg_create_response(dlg, rdata, 200, NULL, &tdata) == PJ_SUCCESS)
            pjsip_dlg_send_response(dlg, tsx, tdata);
    }
}

static void on_call_transfer_status(pjsua_call_id call_id, int st_code, const pj_str_t *st_text,
                                    pj_bool_t final, pj_bool_t *p_cont)
{
    char reason[256];
    copy_pj_str(reason, sizeof(reason), st_text);
    if (g_cb.on_transfer_status)
        g_cb.on_transfer_status(g_ctx, call_id, st_code, reason, final);
    /* The other party now talks to the transfer target: leave the call. */
    if (final && st_code / 100 == 2) {
        pjsua_call_hangup(call_id, 0, NULL, NULL);
        *p_cont = PJ_FALSE;
    }
}

static void build_uri(char *uri, size_t len, const char *number)
{
    if (strncmp(number, "sip:", 4) == 0 || strncmp(number, "sips:", 5) == 0)
        snprintf(uri, len, "%s", number);
    else
        snprintf(uri, len, "sip:%s@%s;user=phone", number, g_domain);
}

/* ---------- public API ---------- */

int sip_is_running(void)
{
    return g_running;
}

int sip_local_port(void)
{
    pjsua_transport_info ti;
    if (!g_running || g_tid == PJSUA_INVALID_ID)
        return 0;
    ensure_thread();
    if (pjsua_transport_get_info(g_tid, &ti) != PJ_SUCCESS)
        return 0;
    return (int)pj_sockaddr_get_port(&ti.local_addr);
}

int sip_start(const sip_config *c, const sip_callbacks *cb, void *ctx, char *err, int err_len)
{
    pjsua_config cfg;
    pjsua_logging_config log_cfg;
    pjsua_media_config media_cfg;
    pjsua_transport_config tcfg;
    pjsua_acc_config acfg;
    pjsua_transport_id tid;
    pj_status_t status;
    char id[512], reg_uri[300], proxy[512];
    static const char *tp_param[] = { "", ";transport=tcp", ";transport=tls" };
    static const pjsip_transport_type_e tp_type[] = {
        PJSIP_TRANSPORT_UDP, PJSIP_TRANSPORT_TCP, PJSIP_TRANSPORT_TLS };
    static const pjmedia_srtp_use srtp_use[] = {
        PJMEDIA_SRTP_DISABLED, PJMEDIA_SRTP_OPTIONAL, PJMEDIA_SRTP_MANDATORY };
    int transport = c->transport >= 0 && c->transport <= SIP_TRANSPORT_TLS ? c->transport : 0;
    int srtp = c->srtp >= 0 && c->srtp <= SIP_SRTP_REQUIRED ? c->srtp : 0;
    const char *tp = tp_param[transport];

    if (g_running)
        sip_stop();

    if (c->use_vpn && transport != SIP_TRANSPORT_UDP) {
        set_err(err, err_len, "Through the in-app VPN, SIP must use UDP", PJ_SUCCESS);
        close(c->vpn_fd);
        return -1;
    }

    g_cb = *cb;
    g_ctx = ctx;
    snprintf(g_domain, sizeof(g_domain), "%s", c->domain);
    memset(g_muted, 0, sizeof(g_muted));
    {
        int k;
        for (k = 0; k < PJSUA_MAX_CALLS; ++k) {
            g_rec[k] = PJSUA_INVALID_ID;
            g_partner[k] = -1;
            g_vm[k] = 0;
            g_vm_player[k] = PJSUA_INVALID_ID;
        }
    }
    memset(g_last_pkt, 0, sizeof(g_last_pkt));
    memset(g_last_loss, 0, sizeof(g_last_loss));

    status = pjsua_create();
    if (status != PJ_SUCCESS) {
        set_err(err, err_len, "pjsua_create", status);
        if (c->use_vpn)
            close(c->vpn_fd);
        return -1;
    }

    /* Large requests (e.g. INVITE with credentials) must stay on the chosen
     * transport instead of switching to TCP, which has no listener here. */
    pjsip_cfg()->endpt.disable_tcp_switch = PJ_TRUE;

    pjsua_config_default(&cfg);
    cfg.user_agent = pj_str("SIPAnywhere/1.0");
    cfg.max_calls = MAX_CALLS;
    cfg.cb.on_reg_state2 = &on_reg_state2;
    cfg.cb.on_incoming_call = &on_incoming_call;
    cfg.cb.on_call_state = &on_call_state;
    cfg.cb.on_call_media_state = &on_call_media_state;
    cfg.cb.on_call_transfer_status = &on_call_transfer_status;
    cfg.cb.on_call_tsx_state = &on_call_tsx_state;
    cfg.cb.on_call_sdp_created = &on_call_sdp_created;
    if (c->use_vpn)
        cfg.cb.on_create_media_transport = &on_create_media_transport;

    pjsua_logging_config_default(&log_cfg);
    log_cfg.msg_logging = PJ_TRUE;   /* full SIP messages in the log tab */
    log_cfg.console_level = 4;
    log_cfg.level = 4;
    log_cfg.cb = &log_writer;
    if (c->quiet_log) {
        /* "Log detail: Off": no SIP messages (they contain phone numbers), only problems. */
        log_cfg.msg_logging = PJ_FALSE;
        log_cfg.console_level = 2;
        log_cfg.level = 2;
    }

    pjsua_media_config_default(&media_cfg);
    media_cfg.no_vad = PJ_TRUE;
    /* The small resampling filter (PJSIP's choice for telephony on small devices):
     * the conference bridge converts between its 16 kHz and the codec's 8 kHz with
     * about a third of the work of the default one, with no audible difference on
     * telephone-band audio. */
    media_cfg.quality = 4;
    g_clock_rate = media_cfg.clock_rate;
    g_frame_ptime = media_cfg.audio_frame_ptime;

    status = pjsua_init(&cfg, &log_cfg, &media_cfg);
    if (status != PJ_SUCCESS) {
        set_err(err, err_len, "pjsua_init", status);
        pjsua_destroy();
        if (c->use_vpn)
            close(c->vpn_fd);
        return -1;
    }

    /* Don't advertise reliable provisional responses (100rel, RFC 3262): some IMS
     * networks then switch to a PRACK/UPDATE early-dialog flow that is less widely
     * interoperable. A reliable 18x the network still sends is acknowledged with
     * PRACK anyway. */
    remove_capability(PJSIP_H_SUPPORTED, "100rel");
    /* Nor session timers: PJSIP's timer module lists "timer" among the endpoint's
     * capabilities, so responses to the network's session refreshes would claim timer
     * support without a Session-Expires, which RFC 4028 does not allow. Without
     * "timer", the network keeps the refresher role. */
    remove_capability(PJSIP_H_SUPPORTED, "timer");
    remove_capability(PJSIP_H_SUPPORTED, "trickle-ice");
    /* Declare that we understand call recording indications (RFC 7866) and say in
     * every SDP that we do not record (see on_call_sdp_created). Some networks route
     * calls through a recorded leg (a=record:on) and expect the endpoint to be
     * record-aware. */
    {
        pj_str_t aware = pj_str("record-aware");
        pjsip_endpt_add_capability(pjsua_get_pjsip_endpt(), NULL, PJSIP_H_SUPPORTED, NULL, 1, &aware);
    }

    if (c->use_vpn) {
        /* SIP over the in-app VPN: a UDP-like transport on the tunnel address. */
        pjsip_transport *vpn_tp = NULL;
        pj_uint16_t port = (pj_uint16_t)(c->local_port > 0 ? c->local_port : 20000 + pj_rand() % 40000);
        status = vnet_start(c->vpn_fd, c->vpn_ip, c->vpn_mtu);
        if (status == PJ_SUCCESS)
            status = vnet_sip_transport_create(pjsua_get_pjsip_endpt(), port, &vpn_tp);
        if (status == PJ_SUCCESS)
            status = pjsua_transport_register(vpn_tp, &tid);
    } else {
        pjsua_transport_config_default(&tcfg);
        tcfg.port = (unsigned)c->local_port;
        if (transport == SIP_TRANSPORT_TLS) {
            tcfg.tls_setting.method = PJSIP_SSL_DEFAULT_METHOD;
            /* Apple's TLS (Network framework) verifies against the macOS trust store. */
            if (c->tls_verify)
                tcfg.tls_setting.verify_server = PJ_TRUE;
        }
        status = pjsua_transport_create(tp_type[transport], &tcfg, &tid);
    }
    g_tid = status == PJ_SUCCESS ? tid : PJSUA_INVALID_ID;
    if (status != PJ_SUCCESS) {
        set_err(err, err_len, c->use_vpn ? "Cannot use the VPN tunnel" : "Cannot open SIP port", status);
        pjsua_destroy();
        vnet_stop();
        return -1;
    }

    status = pjsua_start();
    if (status != PJ_SUCCESS) {
        set_err(err, err_len, "pjsua_start", status);
        pjsua_destroy();
        return -1;
    }

    /* Offer the codecs every SIP provider supports: G.711 A/µ-law and G.722. */
    {
        pj_str_t off[] = { pj_str("speex"), pj_str("iLBC"), pj_str("GSM"),
                           pj_str("G7221"), pj_str("L16"), pj_str("opus") };
        unsigned i;
        for (i = 0; i < PJ_ARRAY_SIZE(off); ++i)
            pjsua_codec_set_priority(&off[i], 0);
        pj_str_t pcma = pj_str("PCMA/8000"), pcmu = pj_str("PCMU/8000"), g722 = pj_str("G722/16000");
        pj_str_t g729 = pj_str("G729/8000");
        pjsua_codec_set_priority(&pcma, 255);
        pjsua_codec_set_priority(&pcmu, 254);
        pjsua_codec_set_priority(&g722, 253);
        /* G.729 (8 kbit/s instead of 64): last by default, so it is used only when
         * the other side has nothing else; first when bandwidth matters. */
        if (c->g729 > 0) {
            pjsua_codec_set_priority(&g729, 255);
            pjsua_codec_set_priority(&pcma, 254);
            pjsua_codec_set_priority(&pcmu, 253);
            pjsua_codec_set_priority(&g722, 252);
        } else {
            pjsua_codec_set_priority(&g729, c->g729 < 0 ? 0 : 1);
        }
    }

    if (c->display_name && *c->display_name)
        snprintf(id, sizeof(id), "\"%s\" <sip:%s@%s>", c->display_name, c->user, c->domain);
    else
        snprintf(id, sizeof(id), "<sip:%s@%s>", c->user, c->domain);
    snprintf(reg_uri, sizeof(reg_uri), "sip:%s%s", c->domain, tp);
    /* Every request is routed through the outbound proxy, so the domain
     * never has to be resolved through DNS. A route without ";lr" would be
     * treated as a strict router and rewrite the Request-URI. */
    if (strcasestr(c->proxy, ";lr"))
        snprintf(proxy, sizeof(proxy), "%s", c->proxy);
    else
        snprintf(proxy, sizeof(proxy), "%s;lr", c->proxy);

    pjsua_acc_config_default(&acfg);
    acfg.id = pj_str(id);
    acfg.reg_uri = pj_str(reg_uri);
    /* Identify this device in the registration Contact (+sip.instance, RFC 5626)
     * and name the transport, so the registrar sees a refresh as the same device
     * rather than a new, anonymous registration. */
    if (c->instance_id && *c->instance_id) {
        static char params[160];
        pj_ansi_snprintf(params, sizeof(params), ";+sip.instance=\"<%s>\"", c->instance_id);
        acfg.reg_contact_params = pj_str(params);
    }
    /* Same Contact URI in the registration and in calls. */
    if (c->transport == SIP_TRANSPORT_UDP)
        acfg.contact_uri_params = pj_str(";transport=udp");
    acfg.proxy_cnt = 1;
    acfg.proxy[0] = pj_str(proxy);
    acfg.reg_timeout = c->reg_timeout > 0 ? (unsigned)c->reg_timeout : 3600;
    /* No automatic retries after a failed registration: the app decides when to
     * try again (with backoff), so a provider is not flooded with attempts. */
    acfg.reg_retry_interval = 0;
    acfg.cred_count = 1;
    acfg.cred_info[0].realm = pj_str("*");
    acfg.cred_info[0].scheme = pj_str("digest");
    acfg.cred_info[0].username = pj_str((char *)c->auth_user);
    acfg.cred_info[0].data_type = PJSIP_CRED_DATA_PLAIN_PASSWD;
    acfg.cred_info[0].data = pj_str((char *)c->password);
    acfg.sip_stun_use = PJSUA_STUN_USE_DISABLED;
    acfg.media_stun_use = PJSUA_STUN_USE_DISABLED;
    /* Random RTP ports instead of a fixed 4000 that may clash with the router's
     * own VoIP service. */
    acfg.rtp_cfg.port = 16000;
    acfg.rtp_cfg.port_range = 16000;
    acfg.rtp_cfg.randomize_port = PJ_TRUE;
    /* Behind NAT, keep the private address in Via and SDP (only Contact is updated to
     * the public address). Session border controllers detect NAT from that mismatch
     * and then latch media and keep the NAT path alive; rewriting everything to the
     * public address makes them treat us as a directly connected device, so neither
     * happens. */
    acfg.allow_via_rewrite = PJ_FALSE;
    acfg.allow_sdp_nat_rewrite = PJ_FALSE;
    acfg.use_rfc5626 = PJ_FALSE;
    /* No session timers (RFC 4028) of our own; the network refreshes calls itself. */
    acfg.use_timer = PJSUA_SIP_TIMER_INACTIVE;
    /* Keep-alive: double CRLF (RFC 5626) every 30-37 s. Border controllers may treat
     * more frequent keep-alives as abuse. PJSIP sends each keep-alive at a random
     * 80-100% of ka_interval, so 38 gives 30-37 s. */
    acfg.ka_interval = 38;
    acfg.ka_data = pj_str("\r\n\r\n");
    acfg.use_srtp = srtp_use[srtp];
    g_srtp_use = srtp_use[srtp];
    acfg.transport_id = g_tid;
    /* Allow SRTP over any transport; with UDP/TCP the keys travel unencrypted. */
    acfg.srtp_secure_signaling = 0;

    status = pjsua_acc_add(&acfg, PJ_TRUE, &g_acc);
    if (status != PJ_SUCCESS) {
        set_err(err, err_len, "Invalid account settings", status);
        pjsua_destroy();
        return -1;
    }

    g_running = 1;
    return 0;
}

static void stop(unsigned flags)
{
    if (!g_running)
        return;
    ensure_thread();
    pjsua_call_hangup_all();
    if (g_refresh_timer.id) {
        pjsua_cancel_timer(&g_refresh_timer);
        g_refresh_timer.id = 0;
    }
    if (g_reinvite_timer.id) {
        pjsua_cancel_timer(&g_reinvite_timer);
        g_reinvite_timer.id = 0;
    }
    g_reinvite_pending = 0;
    {
        int k;
        for (k = 0; k < PJSUA_MAX_CALLS; ++k) {
            stop_recording(k);
            vm_end(k);
        }
    }
    if (g_tone_timer.id) {
        pjsua_cancel_timer(&g_tone_timer);
        g_tone_timer.id = 0;
    }
    g_tone_mic_off = 0;
    if (g_tone_slot != PJSUA_INVALID_ID) {
        pjsua_conf_remove_port(g_tone_slot);
        g_tone_slot = PJSUA_INVALID_ID;
    }
    if (g_tonegen) {
        pjmedia_port_destroy(g_tonegen);
        g_tonegen = NULL;
    }
    if (g_tone_pool) {
        pj_pool_release(g_tone_pool);
        g_tone_pool = NULL;
    }
    g_running = 0;
    g_acc = PJSUA_INVALID_ID;
    pjsua_destroy2(flags);
    vnet_stop();
}

void sip_stop(void)
{
    stop(0);
}

void sip_stop_quick(void)
{
    stop(PJSUA_DESTROY_NO_NETWORK);
}

int sip_reregister(void)
{
    if (!g_running)
        return -1;
    ensure_thread();
    return pjsua_acc_set_registration(g_acc, PJ_TRUE) == PJ_SUCCESS ? 0 : -1;
}

int sip_make_call(const char *number, int *call_id, char *err, int err_len)
{
    char uri[512];
    pj_str_t dst;
    pjsua_call_id cid;
    pjsua_call_setting opt;
    pj_status_t status;

    if (!g_running) {
        set_err(err, err_len, "Not connected", PJ_SUCCESS);
        return -1;
    }
    ensure_thread();
    build_uri(uri, sizeof(uri), number);
    dst = pj_str(uri);

    audio_only(&opt);
    status = pjsua_call_make_call(g_acc, &dst, &opt, NULL, NULL, &cid);
    if (status != PJ_SUCCESS) {
        set_err(err, err_len, "Call failed", status);
        return -1;
    }
    g_muted[cid] = 0;
    g_volume[cid] = 1.0f;
    g_last_pkt[cid] = g_last_loss[cid] = 0;
    if (call_id)
        *call_id = cid;
    return 0;
}

int sip_answer(int call_id, int code)
{
    pjsua_call_setting opt;
    if (!g_running)
        return -1;
    ensure_thread();
    audio_only(&opt);
    return pjsua_call_answer2(call_id, &opt, (unsigned)code, NULL, NULL) == PJ_SUCCESS ? 0 : -1;
}

int sip_hangup(int call_id, int code)
{
    if (!g_running)
        return -1;
    ensure_thread();
    return pjsua_call_hangup(call_id, (unsigned)code, NULL, NULL) == PJ_SUCCESS ? 0 : -1;
}

void sip_hangup_all(void)
{
    if (!g_running)
        return;
    ensure_thread();
    pjsua_call_hangup_all();
}

int sip_set_mute(int call_id, int mute)
{
    pjsua_conf_port_id slot;
    if (!g_running || call_id < 0 || call_id >= PJSUA_MAX_CALLS)
        return -1;
    ensure_thread();
    g_muted[call_id] = mute;
    slot = pjsua_call_get_conf_port(call_id);
    if (slot == PJSUA_INVALID_ID)
        return 0;
    if (mute)
        pjsua_conf_disconnect(0, slot);
    else if (media_is_live(call_id) && !g_tone_mic_off)
        pjsua_conf_connect(0, slot);
    wire_recorder(call_id);
    return 0;
}

int sip_record_start(int call_id, const char *path)
{
    pj_str_t file;
    pjsua_recorder_id rid;
    pj_status_t status;
    if (!g_running || call_id < 0 || call_id >= PJSUA_MAX_CALLS || !path)
        return -1;
    ensure_thread();
    if (g_rec[call_id] != PJSUA_INVALID_ID)
        return 0;
    file = pj_str((char *)path);
    status = pjsua_recorder_create(&file, 0, NULL, -1, 0, &rid);
    if (status != PJ_SUCCESS) {
        PJ_PERROR(2, ("sipcore", status, "Call %d: cannot record to %s", call_id, path));
        return -1;
    }
    g_rec[call_id] = rid;
    wire_recorder(call_id);
    PJ_LOG(3, ("sipcore", "Call %d: recording to %s", call_id, path));
    return 0;
}

int sip_record_stop(int call_id)
{
    if (!g_running || call_id < 0 || call_id >= PJSUA_MAX_CALLS)
        return -1;
    ensure_thread();
    stop_recording(call_id);
    return 0;
}

/* --- answering machine --- */

static void *vm_key(pjsua_call_id call_id)
{
    return (void *)(pj_ssize_t)((g_vm_gen[call_id] << 8) | (unsigned)call_id);
}

/* The timer or callback belongs to the answering machine still running on this call. */
static int vm_current(void *key, pjsua_call_id *call_id)
{
    pj_ssize_t k = (pj_ssize_t)key;
    pjsua_call_id cid = (pjsua_call_id)(k & 0xff);
    if (!g_running || cid < 0 || cid >= PJSUA_MAX_CALLS || !g_vm[cid] ||
        g_vm_gen[cid] != (unsigned)(k >> 8))
        return 0;
    *call_id = cid;
    return 1;
}

static void vm_end(pjsua_call_id call_id)
{
    if (g_vm_player[call_id] != PJSUA_INVALID_ID) {
        pjsua_player_destroy(g_vm_player[call_id]);
        g_vm_player[call_id] = PJSUA_INVALID_ID;
    }
    if (g_vm[call_id]) {
        g_vm[call_id] = 0;
        g_vm_gen[call_id]++;
    }
}

static void vm_time_up(void *key)
{
    pjsua_call_id cid;
    if (!vm_current(key, &cid))
        return;
    PJ_LOG(3, ("sipcore", "Call %d: answering machine: message time is up", cid));
    pjsua_call_hangup(cid, 0, NULL, NULL);
}

/* After the greeting (and its beep): record the caller. */
static void vm_record(void *key)
{
    pjsua_call_id cid;
    pjsua_recorder_id rid;
    pj_str_t file;
    if (!vm_current(key, &cid))
        return;
    if (g_vm_player[cid] != PJSUA_INVALID_ID) {
        pjsua_player_destroy(g_vm_player[cid]);
        g_vm_player[cid] = PJSUA_INVALID_ID;
    }
    file = pj_str(g_vm_message[cid]);
    if (pjsua_recorder_create(&file, 0, NULL, -1, 0, &rid) != PJ_SUCCESS) {
        PJ_LOG(2, ("sipcore", "Call %d: answering machine cannot record to %s", cid, g_vm_message[cid]));
        pjsua_call_hangup(cid, 0, NULL, NULL);
        return;
    }
    g_rec[cid] = rid;
    wire_recorder(cid);         /* the caller only: the microphone is muted */
    PJ_LOG(3, ("sipcore", "Call %d: answering machine recording to %s", cid, g_vm_message[cid]));
    pjsua_schedule_timer2(&vm_time_up, key, (unsigned)g_vm_max[cid] * 1000);
}

/* Runs in the media thread: hand over to the SIP thread. */
static void vm_greeting_done(pjmedia_port *port, void *key)
{
    PJ_UNUSED_ARG(port);
    pjsua_schedule_timer2(&vm_record, key, 0);
}

int sip_voicemail_answer(int call_id, const char *greeting, const char *message, int max_seconds)
{
    pjsua_call_setting opt;
    pj_str_t file;
    pjsua_player_id pid;
    pjmedia_port *port = NULL;
    if (!g_running || call_id < 0 || call_id >= PJSUA_MAX_CALLS || !greeting || !message)
        return -1;
    ensure_thread();
    vm_end(call_id);
    file = pj_str((char *)greeting);
    if (pjsua_player_create(&file, PJMEDIA_FILE_NO_LOOP, &pid) != PJ_SUCCESS) {
        PJ_LOG(2, ("sipcore", "Call %d: answering machine cannot play %s", call_id, greeting));
        return -1;
    }
    g_vm[call_id] = 1;
    g_vm_player[call_id] = pid;
    g_vm_max[call_id] = max_seconds > 0 ? max_seconds : 120;
    snprintf(g_vm_message[call_id], sizeof(g_vm_message[call_id]), "%s", message);
    g_muted[call_id] = 1;       /* keep our microphone out of the call and the message */
    if (pjsua_player_get_port(pid, &port) == PJ_SUCCESS && port)
        pjmedia_wav_player_set_eof_cb2(port, vm_key(call_id), &vm_greeting_done);
    audio_only(&opt);
    PJ_LOG(3, ("sipcore", "Call %d: answered by the answering machine", call_id));
    if (pjsua_call_answer2(call_id, &opt, 200, NULL, NULL) != PJ_SUCCESS) {
        vm_end(call_id);
        return -1;
    }
    return 0;
}

int sip_voicemail_takeover(int call_id)
{
    if (!g_running || call_id < 0 || call_id >= PJSUA_MAX_CALLS || !g_vm[call_id])
        return -1;
    ensure_thread();
    vm_end(call_id);
    stop_recording(call_id);    /* what was recorded so far is kept */
    g_muted[call_id] = 0;
    PJ_LOG(3, ("sipcore", "Call %d: taken over from the answering machine", call_id));
    on_call_media_state(call_id);   /* microphone and speaker on the call, as usual */
    return 0;
}

int sip_conference(int call_a, int call_b, int join)
{
    if (!g_running || call_a < 0 || call_b < 0 || call_a >= PJSUA_MAX_CALLS ||
        call_b >= PJSUA_MAX_CALLS || call_a == call_b)
        return -1;
    ensure_thread();
    if (join) {
        g_partner[call_a] = call_b;
        g_partner[call_b] = call_a;
        wire_partner(call_a, 1);    /* now if both are live; else when they resume */
    } else {
        wire_partner(call_a, 0);
        g_partner[call_a] = -1;
        g_partner[call_b] = -1;
    }
    return 0;
}

int sip_set_volume(int call_id, float level)
{
    pjsua_conf_port_id slot;
    if (!g_running || call_id < 0 || call_id >= PJSUA_MAX_CALLS)
        return -1;
    ensure_thread();
    g_volume[call_id] = level < 0 ? 0 : level > 1 ? 1 : level;
    slot = pjsua_call_get_conf_port(call_id);
    if (slot != PJSUA_INVALID_ID)
        pjsua_conf_adjust_rx_level(slot, g_volume[call_id]);
    return 0;
}

int sip_set_hold(int call_id, int hold)
{
    pj_status_t status;
    if (!g_running)
        return -1;
    ensure_thread();
    if (hold)
        status = pjsua_call_set_hold(call_id, NULL);
    else
        status = pjsua_call_reinvite(call_id, PJSUA_CALL_UNHOLD, NULL);
    return status == PJ_SUCCESS ? 0 : -1;
}

int sip_send_dtmf(int call_id, const char *digits)
{
    pjsua_call_send_dtmf_param p;
    if (!g_running)
        return -1;
    ensure_thread();
    pjsua_call_send_dtmf_param_default(&p);
    p.method = PJSUA_DTMF_METHOD_RFC2833;
    p.digits = pj_str((char *)digits);
    return pjsua_call_send_dtmf(call_id, &p) == PJ_SUCCESS ? 0 : -1;
}

/* Microphone off (on = 0) or back on the live, unmuted calls. */
static void connect_mic_to_calls(int on)
{
    pjsua_call_id ids[PJSUA_MAX_CALLS];
    unsigned i, count = PJ_ARRAY_SIZE(ids);
    if (pjsua_enum_calls(ids, &count) != PJ_SUCCESS)
        return;
    for (i = 0; i < count; ++i) {
        pjsua_conf_port_id slot = pjsua_call_get_conf_port(ids[i]);
        if (slot == PJSUA_INVALID_ID)
            continue;
        if (!on)
            pjsua_conf_disconnect(0, slot);
        else if (!g_muted[ids[i]] && media_is_live(ids[i]))
            pjsua_conf_connect(0, slot);
    }
}

static void tone_timer_cb(pj_timer_heap_t *th, pj_timer_entry *e)
{
    PJ_UNUSED_ARG(th);
    e->id = 0;
    g_tone_mic_off = 0;
    if (g_running)
        connect_mic_to_calls(1);
}

int sip_play_keypad_tone(const char *digits)
{
    pjmedia_tone_digit d[16];
    unsigned n = 0;
    if (!g_running || !digits)
        return -1;
    ensure_thread();
    if (g_tone_slot == PJSUA_INVALID_ID) {
        /* A tone generator on the conference bridge, connected to the speaker only:
         * the other party gets the digits as RFC 2833 events, not as sound. Being part
         * of what the speaker plays, the tones are also removed by echo cancellation. */
        g_tone_pool = pjsua_pool_create("keytones", 1024, 1024);
        if (!g_tone_pool ||
            pjmedia_tonegen_create(g_tone_pool, g_clock_rate, 1,
                                   g_clock_rate * g_frame_ptime / 1000, 16, 0,
                                   &g_tonegen) != PJ_SUCCESS ||
            pjsua_conf_add_port(g_tone_pool, g_tonegen, &g_tone_slot) != PJ_SUCCESS)
        {
            if (g_tonegen) {
                pjmedia_port_destroy(g_tonegen);
                g_tonegen = NULL;
            }
            if (g_tone_pool) {
                pj_pool_release(g_tone_pool);
                g_tone_pool = NULL;
            }
            g_tone_slot = PJSUA_INVALID_ID;
            return -1;
        }
        pjsua_conf_connect(g_tone_slot, 0);
    }
    for (; *digits && n < PJ_ARRAY_SIZE(d); ++digits) {
        pj_bzero(&d[n], sizeof(d[n]));
        d[n].digit = *digits;
        d[n].on_msec = 120;
        d[n].off_msec = 40;
        d[n].volume = 4000;     /* quieter than the voice (full scale 32767) */
        ++n;
    }
    if (pjmedia_tonegen_play_digits(g_tonegen, n, d, 0) != PJ_SUCCESS)
        return -1;
    /* Microphone off for the tones plus the echo's tail (the speaker's sound reaches
     * the microphone a little later); a new key extends the pause. */
    {
        pj_time_val delay;
        long ms = (long)n * 160 + 250;
        delay.sec = ms / 1000;
        delay.msec = ms % 1000;
        if (g_tone_timer.id)
            pjsua_cancel_timer(&g_tone_timer);
        g_tone_mic_off = 1;
        connect_mic_to_calls(0);
        pj_timer_entry_init(&g_tone_timer, 0, NULL, &tone_timer_cb);
        g_tone_timer.id = 1;
        if (pjsua_schedule_timer(&g_tone_timer, &delay) != PJ_SUCCESS) {
            g_tone_timer.id = 0;
            g_tone_mic_off = 0;
            connect_mic_to_calls(1);
        }
    }
    return 0;
}

int sip_call_media_info(int call_id, sip_media_info *out)
{
    pjsua_call_info ci;
    pjsua_stream_info si;
    pjsua_stream_stat st;
    pjmedia_transport_info ti;
    unsigned i, med = (unsigned)-1;

    memset(out, 0, sizeof(*out));
    out->quality = -1;
    if (!g_running || call_id < 0 || call_id >= PJSUA_MAX_CALLS)
        return -1;
    ensure_thread();
    if (pjsua_call_get_info(call_id, &ci) != PJ_SUCCESS)
        return -1;
    for (i = 0; i < ci.media_cnt; ++i) {
        if (ci.media[i].type == PJMEDIA_TYPE_AUDIO) {
            med = i;
            break;
        }
    }
    if (med == (unsigned)-1)
        return 0;
    out->media_status = (int)ci.media[med].status;

    pjmedia_transport_info_init(&ti);
    if (pjsua_call_get_med_transport_info(call_id, med, &ti) == PJ_SUCCESS) {
        pjmedia_srtp_info *srtp = (pjmedia_srtp_info *)
            pjmedia_transport_info_get_spc_info(&ti, PJMEDIA_TRANSPORT_TYPE_SRTP);
        out->encrypted = srtp && srtp->active;
    }

    if (pjsua_call_get_stream_info(call_id, med, &si) == PJ_SUCCESS && si.type == PJMEDIA_TYPE_AUDIO) {
        snprintf(out->codec, sizeof(out->codec), "%.*s/%u",
                 (int)si.info.aud.fmt.encoding_name.slen, si.info.aud.fmt.encoding_name.ptr,
                 si.info.aud.fmt.clock_rate);
    }

    if (ci.media[med].status != PJSUA_CALL_MEDIA_ACTIVE)
        return 0;   /* on hold: no quality to report */
    if (pjsua_call_get_stream_stat(call_id, med, &st) != PJ_SUCCESS)
        return 0;

    {
        /* Score the interval since the previous poll, not the whole call. */
        unsigned pkt = st.rtcp.rx.pkt - g_last_pkt[call_id];
        unsigned loss = st.rtcp.rx.loss - g_last_loss[call_id];
        g_last_pkt[call_id] = st.rtcp.rx.pkt;
        g_last_loss[call_id] = st.rtcp.rx.loss;

        out->loss_pct = pkt + loss ? 100.0 * loss / (pkt + loss) : 0;
        out->jitter_ms = (int)(st.rtcp.rx.jitter.mean / 1000);
        out->rtt_ms = (int)(st.rtcp.rtt.mean / 1000);

        if (pkt == 0)
            out->quality = 0;
        else if (out->loss_pct < 1 && out->jitter_ms < 20 && out->rtt_ms < 150)
            out->quality = 4;
        else if (out->loss_pct < 3 && out->jitter_ms < 40 && out->rtt_ms < 300)
            out->quality = 3;
        else if (out->loss_pct < 8 && out->jitter_ms < 80)
            out->quality = 2;
        else
            out->quality = 1;
    }
    return 0;
}

int sip_transfer(int call_id, const char *number, char *err, int err_len)
{
    char uri[512];
    pj_str_t dst;
    pj_status_t status;
    if (!g_running)
        return -1;
    ensure_thread();
    build_uri(uri, sizeof(uri), number);
    dst = pj_str(uri);
    status = pjsua_call_xfer(call_id, &dst, NULL);
    if (status != PJ_SUCCESS) {
        set_err(err, err_len, "Transfer failed", status);
        return -1;
    }
    return 0;
}

int sip_transfer_to_call(int call_id, int dest_call_id, char *err, int err_len)
{
    pj_status_t status;
    if (!g_running)
        return -1;
    ensure_thread();
    status = pjsua_call_xfer_replaces(call_id, dest_call_id, 0, NULL);
    if (status != PJ_SUCCESS) {
        set_err(err, err_len, "Transfer failed", status);
        return -1;
    }
    return 0;
}

int sip_audio_dev_count(void)
{
    if (!g_running)
        return 0;
    ensure_thread();
    return (int)pjmedia_aud_dev_count();
}

int sip_audio_dev_info(int index, char *name, int name_len, int *inputs, int *outputs)
{
    pjmedia_aud_dev_info info;
    if (!g_running)
        return -1;
    ensure_thread();
    if (pjmedia_aud_dev_get_info(index, &info) != PJ_SUCCESS)
        return -1;
    snprintf(name, (size_t)name_len, "%s", info.name);
    *inputs = (int)info.input_count;
    *outputs = (int)info.output_count;
    return 0;
}

int sip_get_audio_devs(int *capture, int *playback)
{
    if (!g_running)
        return -1;
    ensure_thread();
    return pjsua_get_snd_dev(capture, playback) == PJ_SUCCESS ? 0 : -1;
}

/* macOS voice processing (built-in echo cancellation) always uses the system
 * default devices, so specific devices need the software canceller. */
static void choose_echo_canceller(int capture, int playback)
{
    unsigned tail = 0;
    pjsua_get_ec_tail(&tail);
    if (capture == PJMEDIA_AUD_DEFAULT_CAPTURE_DEV && playback == PJMEDIA_AUD_DEFAULT_PLAYBACK_DEV)
        pjsua_set_ec(tail, 0);
    else
        pjsua_set_ec(tail, PJMEDIA_ECHO_USE_SW_ECHO);
}

int sip_set_audio_devs(int capture, int playback)
{
    if (!g_running)
        return -1;
    ensure_thread();
    choose_echo_canceller(capture, playback);
    {
        /* Don't open the devices now (that would switch on the microphone while
         * idle); they are opened for the next call, or right away during a call. */
        pjsua_snd_dev_param prm;
        pjsua_snd_dev_param_default(&prm);
        prm.capture_dev = capture;
        prm.playback_dev = playback;
        prm.mode = PJSUA_SND_DEV_NO_IMMEDIATE_OPEN;
        return pjsua_set_snd_dev2(&prm) == PJ_SUCCESS ? 0 : -1;
    }
}

/* Index of the device with this name in PJSIP's list, or -1. */
static int find_audio_dev(const char *name, int input)
{
    unsigned i, n = pjmedia_aud_dev_count();
    for (i = 0; i < n; ++i) {
        pjmedia_aud_dev_info info;
        if (pjmedia_aud_dev_get_info((pjmedia_aud_dev_index)i, &info) != PJ_SUCCESS)
            continue;
        if (strcmp(info.name, name) == 0 && (input ? info.input_count : info.output_count) > 0)
            return (int)i;
    }
    return -1;
}

int sip_apply_audio_devs(const char *capture_name, const char *playback_name, int in_call,
                         int *capture_found, int *playback_found)
{
    pjsua_snd_dev_param prm;
    int capture, playback;
    pj_bool_t was_open;

    *capture_found = *playback_found = 1;
    if (!g_running)
        return -1;
    ensure_thread();
    was_open = pjsua_snd_is_active();
    /* PJSIP's device list must not change under an open sound device (its device
     * numbers would point outside the new list): close it first, then refresh. */
    if (was_open && !in_call)
        return 1;           /* still open for a moment after a call; try again later */
    if (was_open) {
        PJ_LOG(3, ("sipcore", "Audio devices changed: reopening the sound device"));
        pjsua_set_null_snd_dev();   /* the call keeps running on the null device meanwhile */
    }
    pjmedia_aud_dev_refresh();
    capture = PJMEDIA_AUD_DEFAULT_CAPTURE_DEV;
    playback = PJMEDIA_AUD_DEFAULT_PLAYBACK_DEV;
    if (capture_name && *capture_name) {
        int i = find_audio_dev(capture_name, 1);
        if (i >= 0)
            capture = i;
        else
            *capture_found = 0;
    }
    if (playback_name && *playback_name) {
        int i = find_audio_dev(playback_name, 0);
        if (i >= 0)
            playback = i;
        else
            *playback_found = 0;
    }
    choose_echo_canceller(capture, playback);
    pjsua_snd_dev_param_default(&prm);
    prm.capture_dev = capture;
    prm.playback_dev = playback;
    /* During a call open now; otherwise at the next call (don't switch the microphone on). */
    prm.mode = was_open ? 0 : PJSUA_SND_DEV_NO_IMMEDIATE_OPEN;
    return pjsua_set_snd_dev2(&prm) == PJ_SUCCESS ? 0 : -1;
}

void sip_refresh_audio_devs(void)
{
    if (!g_running)
        return;
    ensure_thread();
    pjmedia_aud_dev_refresh();
}

void sip_vpn_stats_get(sip_vpn_stats *out)
{
    vnet_get_stats(out);
}

int sip_vpn_tunnel_lost(void)
{
    if (!g_running || !vnet_active())
        return -1;
    ensure_thread();
    return vnet_switch(-1, NULL, 0) == PJ_SUCCESS ? 0 : -1;
}

int sip_vpn_switch_tunnel(int fd, const char *ip, int mtu)
{
    if (!g_running || !vnet_active()) {
        if (fd >= 0)
            close(fd);
        return -1;
    }
    ensure_thread();
    if (vnet_switch(fd, ip, mtu) != PJ_SUCCESS)
        return -1;
    /* Renew the registration from the new path (new NAT mappings); the calls follow
     * with a re-INVITE once it is accepted (on_reg_state2). */
    g_reinvite_pending = 1;
    pjsua_acc_set_registration(g_acc, PJ_TRUE);
    return 0;
}
