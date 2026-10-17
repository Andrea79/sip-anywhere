#ifndef SIPCORE_H
#define SIPCORE_H

/* Thin C facade over pjsua so Swift never touches pjsip types directly. */

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    const char *display_name;   /* optional */
    const char *user;           /* SIP username, e.g. "+15551234567" */
    const char *auth_user;      /* digest username, e.g. "+15551234567@sip.example.com" */
    const char *password;       /* SIP key */
    const char *domain;         /* SIP domain, e.g. "sip.example.com" */
    const char *proxy;          /* outbound proxy URI, e.g. "sip:192.0.2.1;transport=udp";
                                   all SIP traffic is sent there */
    int transport;              /* SIP_TRANSPORT_* */
    int tls_verify;             /* 1 = verify the server certificate (TLS only) */
    int srtp;                   /* SIP_SRTP_* */
    int local_port;             /* 0 = any */
    int use_vpn;                /* 1: send SIP and audio through the in-app VPN tunnel (UDP only) */
    int vpn_fd;                 /* tunnel packets (see ovpnbridge.h); sip_start takes ownership */
    const char *vpn_ip;         /* address the VPN server assigned to us */
    int vpn_mtu;                /* tunnel MTU */
    int reg_timeout;            /* seconds */
    int quiet_log;              /* 1: only errors and warnings, no SIP messages, in the log */
    const char *instance_id;    /* optional: stable device UUID ("urn:uuid:..."), sent as +sip.instance */
    int g729;                   /* G.729: 0 offered last, 1 preferred (low bandwidth), -1 not offered */
} sip_config;

enum { SIP_TRANSPORT_UDP = 0, SIP_TRANSPORT_TCP, SIP_TRANSPORT_TLS };
enum { SIP_SRTP_OFF = 0, SIP_SRTP_OPTIONAL, SIP_SRTP_REQUIRED };

/* Same values as pjsip_inv_state. */
enum {
    SIP_CALL_NULL = 0,
    SIP_CALL_CALLING,
    SIP_CALL_INCOMING,
    SIP_CALL_EARLY,
    SIP_CALL_CONNECTING,
    SIP_CALL_CONFIRMED,
    SIP_CALL_DISCONNECTED,
};

typedef struct {
    void (*on_reg_state)(void *ctx, int status_code, const char *reason, int expires);
    void (*on_incoming_call)(void *ctx, int call_id, const char *remote);
    void (*on_call_state)(void *ctx, int call_id, int state, int last_code,
                          const char *last_reason, const char *remote);
    void (*on_log)(void *ctx, int level, const char *msg);
    /* Progress of a transfer started with sip_transfer*(); final != 0 on the last report. */
    void (*on_transfer_status)(void *ctx, int call_id, int code, const char *reason, int final);
} sip_callbacks;

/* Same values as pjsua_call_media_status. */
enum { SIP_MEDIA_NONE = 0, SIP_MEDIA_ACTIVE, SIP_MEDIA_LOCAL_HOLD, SIP_MEDIA_REMOTE_HOLD, SIP_MEDIA_ERROR };

typedef struct {
    int media_status;   /* SIP_MEDIA_* */
    int encrypted;      /* 1 when the audio is protected by SRTP */
    int quality;        /* -1 unknown, 0 no audio received, 1 (poor) .. 4 (excellent) */
    double loss_pct;    /* packet loss since the previous call of sip_call_media_info */
    int jitter_ms;
    int rtt_ms;
    char codec[32];     /* e.g. "PCMA/8000" */
} sip_media_info;

/* All functions return 0 on success; on failure err (if given) is filled. */
int  sip_start(const sip_config *cfg, const sip_callbacks *cb, void *ctx,
               char *err, int err_len);
void sip_stop(void);
/* Like sip_stop() but sends nothing (no un-REGISTER), for when the proxy is unreachable. */
void sip_stop_quick(void);
int  sip_is_running(void);
/* Local port of the SIP transport (useful when started with local_port 0). */
int  sip_local_port(void);

int  sip_reregister(void);

/* number: digits as dialled; it is sent as sip:<number>@<domain>;user=phone */
int  sip_make_call(const char *number, int *call_id, char *err, int err_len);
int  sip_answer(int call_id, int code);
int  sip_hangup(int call_id, int code);
void sip_hangup_all(void);
int  sip_set_mute(int call_id, int mute);
int  sip_set_hold(int call_id, int hold);
/* How loud we hear this call, 0...1 (1 = as the system volume): lowers only the call,
 * not the ringtone or the rest of the Mac. New calls start at 1. */
int  sip_set_volume(int call_id, float level);
int  sip_send_dtmf(int call_id, const char *digits);
/* Plays keypad tones (0-9 * #) on our speaker during a call, as feedback; the other
 * party does not hear them (it gets the digits from sip_send_dtmf). */
int  sip_play_keypad_tone(const char *digits);
/* Records the call (the other party and us, mixed) to a WAV file until
 * sip_record_stop or the end of the call. */
int  sip_record_start(int call_id, const char *path);
int  sip_record_stop(int call_id);
/* Answering machine: answers the incoming call, plays `greeting` (a WAV file, ending
 * with its beep), then records the caller to `message` for up to max_seconds and hangs
 * up. Our microphone and speaker are not connected. */
int  sip_voicemail_answer(int call_id, const char *greeting, const char *message, int max_seconds);
/* Picks the call up from the answering machine: normal call from now on. */
int  sip_voicemail_takeover(int call_id);
/* Conference: join two calls so that they also hear each other, or separate them. */
int  sip_conference(int call_a, int call_b, int join);

/* Live media state and quality; call periodically (e.g. every 2 s). */
int  sip_call_media_info(int call_id, sip_media_info *out);

/* Blind transfer to a number, or attended transfer to another call of ours. */
int  sip_transfer(int call_id, const char *number, char *err, int err_len);
int  sip_transfer_to_call(int call_id, int dest_call_id, char *err, int err_len);

/* Audio devices. Index -1 = system default input, -2 = system default output. */
int  sip_audio_dev_count(void);
int  sip_audio_dev_info(int index, char *name, int name_len, int *inputs, int *outputs);
int  sip_get_audio_devs(int *capture, int *playback);
int  sip_set_audio_devs(int capture, int playback);
/* Re-reads the system's device list (e.g. after plugging in a headset). */
void sip_refresh_audio_devs(void);
/* Refreshes the device list and selects devices by name ("" or NULL: system default;
 * a missing device falls back to the default and sets *_found to 0). During a call the
 * sound device is closed first and reopened, so it also follows a new system default.
 * Returns 1 if the sound device is still open just after a call (try again shortly). */
int  sip_apply_audio_devs(const char *capture_name, const char *playback_name, int in_call,
                          int *capture_found, int *playback_found);

/* In-app VPN traffic, for diagnostics. */
typedef struct {
    int active;                             /* 1 while SIP runs through the VPN */
    unsigned long long rx_packets, rx_bytes;    /* IP packets received from the tunnel */
    unsigned long long rx_sip, rx_media;    /* UDP datagrams handed to SIP and to the audio */
    unsigned long long rx_dropped;          /* no receiver, or SIP far behind */
    unsigned long long tx_packets, tx_bytes, tx_errors;
    int ms_since_rx, ms_since_tx;           /* -1: nothing yet */
    int max_delivery_ms;                    /* slowest hand-off of one received packet, since last read */
    int max_send_ms;                        /* slowest write into the tunnel, since last read */
} sip_vpn_stats;
void sip_vpn_stats_get(sip_vpn_stats *out);

/* The VPN tunnel is gone for the moment (OpenVPN is reconnecting): keep SIP and the
 * calls; packets are dropped until sip_vpn_switch_tunnel. Returns -1 if not on the VPN. */
int  sip_vpn_tunnel_lost(void);
/* The VPN is back (possibly with another address): move SIP and audio to the new
 * tunnel, renew the registration and re-INVITE calls in progress with the new Contact.
 * Takes ownership of fd. Returns -1 if SIP could not be kept (restart it instead). */
int  sip_vpn_switch_tunnel(int fd, const char *ip, int mtu);

#ifdef __cplusplus
}
#endif

#endif
