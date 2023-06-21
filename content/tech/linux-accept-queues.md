---
title: "Observing and Understanding Accept Queues in Linux"
date: 2023-03-13
author: Kris Nóva
description: Every Linux socket server is subject to inbound connection and request queueing at runtime. Learn how the kernel accept queue works, and how to observe it at runtime.
math: true
tags:
  - Linux
  - Kernel
  - TCP
  - Unix domain sockets
  - Queues
  - Queueing theory
  - eBPF
  - Observability
---

All complex systems can, and in my opinion should, be modelled and reasoned about as a collection of queues, caches, connections, and workers.
In Linux, this type of abstract modeling is not only just a good idea, it reflects quite literally how the kernel is built.

```goat
               Inbound Connections

                  │  │  │  │  │
                  │  │  │  │  │
                  │  │  │  │  │
                  │  │  │  │  │    ┌──────────┐
                  │  │  │  │  │    │ listen() │
                  ▼  ▼  ▼  ▼  ▼    └─┬────────┘
                ┌───────────────┐    │
                │               │    │      ┌──────────┐ 
          ┌──►  │  FIFO  Queue  ├──► ├─────►│ accept() │    Set of 1 or     
          │     │               │    │      └──────────┘    more workers.   
          │     └─────────────┬─┘    │                                    
          │                   │      │      ┌──────────┐    Worker strategy 
          │                   ├────► ├─────►│ accept() │    subject to      
                              │      │      └──────────┘    change based    
   Requests queue here        │      │                      on design of    
                              │      │      ┌──────────┐    service.        
                              └────► └─────►│ accept() │                  
                                            └──────────┘ 

```

The Linux kernel is composed of thousands of interdependent code paths that are capable of producing millions of events per second.
These code paths heavily leverage queue and stack mechanics in order to keep the kernel operating smoothly.

```c
// include/net/inet_connection_sock.h v6.2

/** inet_connection_sock - INET connection oriented sock
 *
 * @icsk_accept_queue:	   FIFO of established children
 * @icsk_bind_hash:	   Bind node
 * @icsk_bind2_hash:	   Bind node in the bhash2 table
 * @icsk_timeout:	   Timeout
 * @icsk_retransmit_timer: Resend (no ack)
 * @icsk_rto:		   Retransmit timeout
 * @icsk_pmtu_cookie	   Last pmtu seen by socket
 * @icsk_ca_ops		   Pluggable congestion control hook
 * @icsk_af_ops		   Operations which are AF_INET{4,6} specific
 * @icsk_ulp_ops	   Pluggable ULP control hook
 * @icsk_ulp_data	   ULP private data
 * @icsk_clean_acked	   Clean acked data hook
 * @icsk_ca_state:	   Congestion control state
 * @icsk_retransmits:	   Number of unrecovered [RTO] timeouts
 * @icsk_pending:	   Scheduled timer event
 * @icsk_backoff:	   Backoff
 * @icsk_syn_retries:      Number of allowed SYN (or equivalent) retries
 * @icsk_probes_out:	   unanswered 0 window probes
 * @icsk_ext_hdr_len:	   Network protocol overhead (IP/IPv6 options)
 * @icsk_ack:		   Delayed ACK control data
 * @icsk_mtup;		   MTU probing control data
 * @icsk_probes_tstamp:    Probe timestamp (cleared by non-zero window ack)
 * @icsk_user_timeout:	   TCP_USER_TIMEOUT value
 */
struct inet_connection_sock {
	/* inet_sock has to be the first member! */
	struct inet_sock	  icsk_inet;
	struct request_sock_queue icsk_accept_queue;
	struct inet_bind_bucket	  *icsk_bind_hash;
	struct inet_bind2_bucket  *icsk_bind2_hash;
	unsigned long		  icsk_timeout;
 	struct timer_list	  icsk_retransmit_timer;
 	struct timer_list	  icsk_delack_timer;
	__u32			  icsk_rto;
	__u32                     icsk_rto_min;
	__u32                     icsk_delack_max;
	__u32			  icsk_pmtu_cookie;
	const struct tcp_congestion_ops *icsk_ca_ops;
	const struct inet_connection_sock_af_ops *icsk_af_ops;
	const struct tcp_ulp_ops  *icsk_ulp_ops;
	void __rcu		  *icsk_ulp_data;
	void (*icsk_clean_acked)(struct sock *sk, u32 acked_seq);
	unsigned int		  (*icsk_sync_mss)(struct sock *sk, u32 pmtu);
	__u8			  icsk_ca_state:5,
				  icsk_ca_initialized:1,
				  icsk_ca_setsockopt:1,
				  icsk_ca_dst_locked:1;
	__u8			  icsk_retransmits;
	__u8			  icsk_pending;
	__u8			  icsk_backoff;
	__u8			  icsk_syn_retries;
	__u8			  icsk_probes_out;
	__u16			  icsk_ext_hdr_len;
	struct {
		__u8		  pending;	 /* ACK is pending			   */
		__u8		  quick;	 /* Scheduled number of quick acks	   */
		__u8		  pingpong;	 /* The session is interactive		   */
		__u8		  retry;	 /* Number of attempts			   */
		__u32		  ato;		 /* Predicted tick of soft clock	   */
		unsigned long	  timeout;	 /* Currently scheduled timeout		   */
		__u32		  lrcvtime;	 /* timestamp of last received data packet */
		__u16		  last_seg_size; /* Size of last incoming segment	   */
		__u16		  rcv_mss;	 /* MSS used for delayed ACK decisions	   */
	}icsk_ack; //...
}
```

In Linux, all inbound network requests from an arbitrary client will pass through the kernel backlog queue which is an instance of a [request_sock_queue](https://github.com/torvalds/linux/blob/v6.2/include/net/request_sock.h#L168-L188) struct and part of the normal TCP handshake.
This is true for any socket server (TCP/IPv4, TCP/IPv6, Unix domain, UDP/connectionless) built using the Linux network stack or the `/include/net` directory in the source tree.

Additionally, there is a more mature and much more exciting structure which is assembled after the TCP handshake is complete which is the complete socket structure.

```C 
 // include/linux/net.h v6.2

/**
 *  struct socket - general BSD socket
 *  @state: socket state (%SS_CONNECTED, etc)
 *  @type: socket type (%SOCK_STREAM, etc)
 *  @flags: socket flags (%SOCK_NOSPACE, etc)
 *  @ops: protocol specific socket operations
 *  @file: File back pointer for gc
 *  @sk: internal networking protocol agnostic socket representation
 *  @wq: wait queue for several uses
 */
struct socket {
	socket_state		state;

	short			type;

	unsigned long		flags;

	struct file		*file;
	struct sock		*sk;
	const struct proto_ops	*ops;

	struct socket_wq	wq;
};
```

Herein lies "The Accept Queue" which can be observed after a request has completed the TCP handshake and exited the "backlog" or "SYN queue".

Inbound requests may accumulate at runtime which exist in between the moment a server has completed the TCP handshake, and the moment a worker has called `accept()` to pop the connection pointer off the stack.

As these requests begin to queue, problems arise such as slow user experience or wasted compute resources due to saturated services.

The kernel accept queue is a trivial FIFO queue implementation, with some nuance surrounding TFO or [TCP Fast Open](https://netty.io/wiki/tcp-fast-open.html#:~:text=Preface,response%20time%20in%20certain%20cases) which speeds up TCP while also establishing SYN cookies. TFO was originally presented by Google in 2011 [TCP Fast Open 2011 PDF](http://conferences.sigcomm.org/co-next/2011/papers/1569470463.pdf) and is now the default implementation for opening sockets in the kernel.

If the network stack receives requests at a faster rate than the workers can process the requests, the accept queue grows.

In the following model, a worker is any arbitrary service that communicates with the networking stack using [accept(2)](https://linux.die.net/man/2/accept4) which can be used after a service has called [listen(3)](https://linux.die.net/man/3/listen) to begin accepting inbound connections. 

```goat 
                               ┌──────────┐  ┌──────────┐
                          ┌───►│ accept() │  │ Worker 1 │
                          │    ├──────────┤  ├──────────┤
              ┌──────────┬┤    ├──────────┤  ├──────────┤
              │ listen() │┼───►│ accept() │  │ Worker 2 │
              └──────────┴┤    ├──────────┤  ├──────────┤
                  ▲       │    ├──────────┤  ├──────────┤
                  │       └───►│ accept() │  │ Worker 3 │
                  │         ▲  └──────────┘  └──────────┘
                  │         │                     ▲
        ┌─────────┴─┐     ┌─┴─────┐               │
        │Connections│     │ Queue │           ┌───┴───┐
        └───────────┘     └───────┘           │Workers│
                                              └───────┘
```


For example a [unicast service accepting inbound TCP connections in Go](https://pkg.go.dev/net#example-Listener) which references the system call functions directly, as the Go programming language does not use in a libc implementation such as glibc. Notice how the server first calls `net.Listen()` and later calls `l.Accept()` passing each connection off to a new goroutine.

```go 
func main() {
	// Source: https://pkg.go.dev/net#example-Listener
    
	// Listen on TCP port 2000 on all available unicast and
	// anycast IP addresses of the local system.
	l, err := net.Listen("tcp", ":2000")
	if err != nil {
		log.Fatal(err)
	}
	defer l.Close()
	for {
		// Wait for a connection.
		conn, err := l.Accept()
		if err != nil {
			log.Fatal(err)
		}
		// Handle the connection in a new goroutine.
		// The loop then returns to accepting, so that
		// multiple connections may be served concurrently.
		go func(c net.Conn) {
			// Echo all incoming data.
			io.Copy(c, c)
			// Shut down the connection.
			c.Close()
		}(conn)
	}
}
```

Different servers will have different strategies for removing inbound requests from the accept queue for processing based on the implementation detail of the server.
For example the [Apache HTTP Server](https://httpd.apache.org/docs/2.4/mod/worker.html) notably will hand requests off to a worker thread, while [NGINX](http://www.aosabook.org/en/nginx.html) is event based and workers will process events based as they come in and workers are available for processing.

_Note: The Apache server is often claimed to "spawn a thread per request", which is not necessarily an accurate claim. Apache calls out [MaxConnectionsPerChild](https://httpd.apache.org/docs/2.4/mod/mpm_common.html#maxconnectionsperchild) which only would spawn a "thread per request" if set to a value of 1._

One of the primary drivers for NGINX's event based worker strategy is the need to process more throughput at runtime using a reasonable amount of resources.
NGINX's design is intended to introduce nonlinear scalability in terms of connects and requests per second. 
NGINX accomplishes this by reducing the amount of overhead it takes to process a request from the queue. 
NGINX uses [event based architecture](http://www.aosabook.org/en/nginx.html) and strong concurrency patterns to ensure that workers are ready to call `accept()` and handle a request as efficiently as possible.

NGINX Reverse Proxy
===

Recently I performed a small amount of [analysis on NGINX reverse proxy servers](https://github.com/krisnova/nginx-proxy-analysis#) which was able to demonstrate the behavior of NGINX given known dysfunctional upstream servers in which I was able to calculate the "Active Connections" metric produced by the popular [stub status module](https://nginx.org/en/docs/http/ngx_http_stub_status_module.html) as:

| Field     | Description                                                                |
|-----------|----------------------------------------------------------------------------|
| Q         | Number of items in Linux accept queue.                                     |
| A         | Number of active connections currently being processed by NGINX.           |
| 1         | The GET request used to query the stub status module itself.               |
| somaxconn | Arbitrary limit for accept queues either set by a user, or default to 1024 |

---

Note that NGINX operates with a monolithic `listen()` statement in the master process, and that `accept()` events are operated on by worker threads as events are produced within NGINX. 

```goat 
                    ┌──────────────────────────┐
        ┌───────────┤ Accept Queue ≤ somaxconn │ ◄────────────────────┐
        │           └──────────────────────────┘                      │
        │                         Q                                   │
        │                                                             │
        ▼           ┌────────────────────────┐              ┌─────────┴──────────┐
                    │                        │              │ Active Connections │
    listen(); ────► │  Nginx Master Process  │              └─────────┬──────────┘
                    │                        │                        │
                    └─┬──────────────────────┘                        │
                      │                                               │
                      │   ┌────────────────────────┐                  │
                      │   │                        │                  │
    accept(); ────►   ├──►│ Nginx Worker Thread 1  │  ◄────────┐      │
                      │   │                        │           │      ▼
                      │   └────────────────────────┘    ┌──────┴─────────────┐
                      │                                 │Accepted Connections│
                      │   ┌────────────────────────┐    └──────┬─────────────┘
                      │   │                        │           │     A
    accept(); ─────►  └──►│ Nginx Worker Thread 2  │  ◄────────┘
                          │                        │
                          └────────────────────────┘
```

$$
Active Connections = \sum_{Q + A + 1}
$$


There were 2 key takeaways from my work that are relevant in this discussion. Specifically on how NGINX is able to set an upper limit on the kernel accept queues described above.

 1. NGINX manages an internal accept queue limit known also known as "the backlog queue" which the implementation can be seen in [/src/core/ngx_connection.c](https://github.com/nginx/nginx/blob/master/src/core/ngx_connection.c) and defaults to 511 + 1 on Linux. Also see [Tuning NGINX](https://www.nginx.com/blog/tuning-nginx/).
 2. The NGINX backlog queue can be set to an arbitrary values by modifying kernel parameters using sysctl(8); `net.core.somaxconn` and `net.core.netdev_max_backlog`.

It is important to note that even despite raising the upper limit of the accept queue using [sysctl(8)](https://linux.die.net/man/8/sysctl), the [NGINX worker_connections](http://nginx.org/en/docs/ngx_core_module.html#worker_connections) directive can still impose an upper limit on connections to the server at large even if there is plenty of available room in the accept queue buffers.

Regardless of which limit (accept queue, backlog queue, or worker connections) was exceeded, I was able to demonstrate NGINX returning 5XX level HTTP responses simply by setting the various limits low enough and exceeding the limits with curl requests in a simple bash loop.

Performance
===

Despite this analysis being exciting from a conceptual perspective to any engineer hoping to operate a web server without finding their service vulnerable to a denial of service attack.
The implications on the accept queue and performance are even more exciting to understand.

On a discreet compute system, the longer an inbound request sits in an accept queue with idle system resources, the less performant your server implementation is. 
In other words the more accept queuing that can be observed without simultaneously correlating CPU utilization also at capacity, the more time your computers are sitting around doing nothing when they could otherwise be processing traffic.

Performance engineers understand these key points as **Utilization** and **Saturation**.
Utilization is the measurement of how well utilized your system resources are compared to load. 
Saturation is the point in which you have received more load than your current services can process and queuing can be observed.

### Observing Accept Queues 

Now -- the question remains how does one observe the state of these queues? More importantly: when would you want to?

In order to observe the queues you will first want to understand which specific accept queues you believe to be interesting on your servers.

Specifically there are 4 types of connections that most enterprise services will find interesting:

 - TCP/IPv4
 - TCP/IPv6
 - Unix domain
 - UDP (connectionless)

In this example we are interested in observing the moment a TCP/IPV4 connection is appended to an accept queue, as well as the moment a connection is removed from an accept queue. 
Demonstrating the queue accumulating connections behavior alone requires a special environment where a server is listening for connections, but will not accept the connections. 
Then a simple client tool such a [curl](https://curl.se/) can be used to connect to the dysfunctional server.

To do this we need to instrument the functions of the kernel where specific events occur using Extended BPF [eBPF](https://docs.kernel.org/bpf/instruction-set.html) and a special utility known as [kprobes](https://docs.kernel.org/trace/kprobes.html).

For TCP/IPv4 and TCP/IPv6 instrumentation on a 6.2 kernel here is what I use.

| Kernel Function       | Source                                                                                                | Description | Specific Field                                | Layer |
|-----------------------|-------------------------------------------------------------------------------------------------------|-------------|-----------------------------------------------|-------|
| tcp_conn_request      | [inet_connection_sock.c](https://github.com/torvalds/linux/blob/v6.2/net/ipv4/inet_connection_sock.c) | queue++     | [*sock.sk_ack_backlog](inet_csk_listen_start) | 4/TCP |
| inet_csk_accept       | [tcp_input.c](https://github.com/torvalds/linux/blob/v6.2/net/ipv4/tcp_input.c)                       | queue--     | [sock.sk_ack_backlog](inet_csk_listen_start)  | 3/IP  |
| inet_csk_listen_start | [inet_connection_sock.c](https://github.com/torvalds/linux/blob/v6.2/net/ipv4/inet_connection_sock.c) | N/A         | Informative                                   | 3/IP  | 

In my opinion it is important to measuring queues when an element is added, as well as removed from the queue.
This ensures accurate reporting to the total lifecycle of a given accumulation period such that an element can not be added or removed silently.

This methodology of measuring when an element is added, and removed is important because kprobes are executed inline with existing kernel functions.
In other words, the only way to surfacing the values out of the kernel with kprobes is for something to actually exercise the code that adds and removes elements from the queue. 

Tools such as [Python BCC](https://android.googlesource.com/platform/external/bcc/+/refs/heads/android10-c2f2-s1-release/docs/tutorial_bcc_python_developer.md) make this exercise fairly trivial.

```python
# observe.py
from bcc import BPF
BPF(text='int kprobe__tcp_conn_request(struct request_sock_ops *rsk_ops, const struct tcp_request_sock_ops *af_ops, struct sock *sk, struct sk_buff *skb) { bpf_trace_printk("qlen: *sock.sk_ack_backlog"); return 0; }').trace_print()
```

Additionally the [ss(8)](https://linux.die.net/man/8/ss) command makes extremely quick work of this exercise.

```bash 
# ss -lnt
State  Recv-Q Send-Q      Local Address:Port  Peer Address:PortProcess
LISTEN 17      4096              0.0.0.0:80         0.0.0.0:*
```

I wrote a [working example of an eBPF kprobe implementation in Rust](https://github.com/krisnova/q) as I intend on adding more advanced metrics in the future that shows the detail and some more of my research in a project called [q](https://github.com/krisnova/q).
The q project contains a directory `/servers` which houses a set of dysfunctional servers written in C that can be used to simulate the metrics.

Regardless of where you are surfacing the data, there will be trade-offs and limitations to what specific metrics you are interested in.
The kernel networking stack isn't as complicated as you might think as soon as you are sufficiently above net device (tcpdump, wireshark, network devices, etc).

Always worth a minute of my time to remember how we ended up here.

```goat 
September 1981
                                           Transmission Control Protocol
                                                Functional Specification




                              +---------+ ---------\      active OPEN
                              |  CLOSED |            \    -----------
                              +---------+<---------\   \   create TCB
                                |     ^              \   \  snd SYN
                   passive OPEN |     |   CLOSE        \   \
                   ------------ |     | ----------       \   \
                    create TCB  |     | delete TCB         \   \
                                V     |                      \   \
                              +---------+            CLOSE    |    \
                              |  LISTEN |          ---------- |     |
                              +---------+          delete TCB |     |
                   rcv SYN      |     |     SEND              |     |
                  -----------   |     |    -------            |     V
 +---------+      snd SYN,ACK  /       \   snd SYN          +---------+
 |         |<-----------------           ------------------>|         |
 |   SYN   |                    rcv SYN                     |   SYN   |
 |   RCVD  |<-----------------------------------------------|   SENT  |
 |         |                    snd ACK                     |         |
 |         |------------------           -------------------|         |
 +---------+   rcv ACK of SYN  \       /  rcv SYN,ACK       +---------+
   |           --------------   |     |   -----------
   |                  x         |     |     snd ACK
   |                            V     V
   |  CLOSE                   +---------+
   | -------                  |  ESTAB  |
   | snd FIN                  +---------+
   |                   CLOSE    |     |    rcv FIN
   V                  -------   |     |    -------
 +---------+          snd FIN  /       \   snd ACK          +---------+
 |  FIN    |<-----------------           ------------------>|  CLOSE  |
 | WAIT-1  |------------------                              |   WAIT  |
 +---------+          rcv FIN  \                            +---------+
   | rcv ACK of FIN   -------   |                            CLOSE  |
   | --------------   snd ACK   |                           ------- |
   V        x                   V                           snd FIN V
 +---------+                  +---------+                   +---------+
 |FINWAIT-2|                  | CLOSING |                   | LAST-ACK|
 +---------+                  +---------+                   +---------+
   |                rcv ACK of FIN |                 rcv ACK of FIN |
   |  rcv FIN       -------------- |    Timeout=2MSL -------------- |
   |  -------              x       V    ------------        x       V
    \ snd ACK                 +---------+delete TCB         +---------+
     ------------------------>|TIME WAIT|------------------>| CLOSED  |
                              +---------+                   +---------+

                      TCP Connection State Diagram
                               Figure 6.
```

#### More Resources 

- [TCP SYN Queue and Accept Queue Overflow Explained
  ](https://www.alibabacloud.com/blog/tcp-syn-queue-and-accept-queue-overflow-explained_599203)
- [TCP Fast Open TFO](https://www.rfc-editor.org/rfc/rfc7413)
- [A tale of two queues](http://arthurchiao.art/blog/tcp-listen-a-tale-of-two-queues/)
- [How TCP backlog works in Linux](http://veithen.io/2014/01/01/how-tcp-backlog-works-in-linux.html)
- [TCP SYN queue and accept queue explained](https://www.alibabacloud.com/blog/tcp-syn-queue-and-accept-queue-overflow-explained_599203)
