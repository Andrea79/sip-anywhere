#ifndef VNET_H
#define VNET_H

/* "vnet": the app's own little IPv4/UDP network inside the in-app VPN tunnel.
 *
 * OpenVPN hands the tunnel to the app as a datagram socket carrying raw IP
 * packets (utun framing). vnet builds and parses the IPv4/UDP packets for the
 * app's SIP and RTP traffic, so only the app uses the VPN. It provides a PJSIP
 * SIP transport and a PJMEDIA media transport that send through the tunnel. */

#include <pjsip.h>
#include <pjmedia.h>
#include "sipcore.h"

/* Starts/stops packet processing on the tunnel. local_ip is the address the
 * VPN server assigned; mtu the tunnel MTU. vnet_start takes ownership of fd. */
pj_status_t vnet_start(int fd, const char *local_ip, int mtu);
void        vnet_stop(void);
pj_bool_t   vnet_active(void);
/* Moves vnet to a new tunnel (OpenVPN reconnected, maybe with another address),
 * keeping ports, bindings and PJSIP's transports. fd -1: the tunnel is gone for now;
 * sends are dropped until the next call. Takes ownership of fd. */
pj_status_t vnet_switch(int fd, const char *local_ip, int mtu);

/* SIP transport (UDP semantics) bound to the tunnel address and the given port. */
pj_status_t vnet_sip_transport_create(pjsip_endpoint *endpt, pj_uint16_t port,
                                      pjsip_transport **p_tp);

/* Media transport for a call: replaces the UDP transport pjsua created
 * (base_tp, which it takes over and closes), keeping its RTP/RTCP port numbers.
 * If srtp_use is not PJMEDIA_SRTP_DISABLED, an SRTP adapter is put on top. */
pjmedia_transport *vnet_media_transport_create(pjmedia_endpt *endpt,
                                               pjmedia_transport *base_tp,
                                               pjmedia_srtp_use srtp_use);

/* Traffic counters (see sip_vpn_stats_get); resets the "slowest" values. */
void vnet_get_stats(sip_vpn_stats *out);

#endif
