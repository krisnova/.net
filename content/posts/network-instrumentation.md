---
title: "Network Instrumentation and TCP File Descriptor Hijacking"
date: 2023-05-22
author: Kris Nóva
description: Dreaming about instrumenting the network such that I can better understand the performance of GitHub.
math: true
tags:
  - Linux
  - Kernel
  - TCP
  - Hijacking
  - Spoofing
  - Tracing
  - Telemetry
  - Observability
  - C Programming
  - Performance Engineering
---

Recently, I have been trying to speed up GitHub. Part of improving GitHub's performance has involved deeply understanding how the infrastructure works. Which, is no small undertaking given the amount of uncertainty on a given day.

Earlier this year I started digging into inbound connection queueing using eBPF as a means of understanding latency in our stack. You can see my public work on the topic in this article: [Observing and Understanding Accept Queues in Linux](https://krisnova.net/posts/linux-accept-queues/).

The topic of dynamic kernel instrumentation with eBPF is well understood in general, and is something I have been working with professionally since my time instrumenting the kernel at Sysdig.

At GitHub, I have started using Rust and eBPF and to instrument our stack such that we can observe TCP connection queues during an increase in load. I hope to open source this work one day in the future when the tooling is more mature so that others can leverage my work.

While thinking about dynamic kernel instrumentation, I began to wonder if "instrumentation" could be applied to other parts of the stack in a more general sense? Specifically I have been wondering what types of signals "the wire" could provide? Would it be possible to find other performance bottlenecks and opportunities simply by examining the behavior of the network? Are there specific things we could deliberately do to the network such that we can learn more about it?

So I began to wonder...

### Would it be possible to instrument the "network" itself?

For clarity, I am not suggesting instrumenting the TCP/IP functions and tracepoints in the kernel of a client or server. I am suggesting something else entirely. I am considering interfering with established connection's data on the network such that we can gain insights to the performance and topology of the network itself.

This thought has kept me up at night.

For now, we can refer to this concept as **Network Instrumentation**. This is either a very new, or very old paradigm depending on your background and what exactly comes to mind when you begin to think about it. I'll use the term network instrumentation to refer to mutating the network for analysis purposes for the rest of my post.

## Learning from Traceroute

So [traceroute(8)](https://linux.die.net/man/8/traceroute) is a very old, but very useful example of instrumenting a network. I started to wonder if there was more we could be doing in this space than we are doing today, and how much of this would be relevant to my quest to make GitHub more performant.

By default `traceroute(8)` uses UDP and ICMP echo packets complete with a Time to Live (TTL) value set.

### Traceroute and TCP

For well over a decade `traceroute(8)` has supported the `-T` flag which uses TCP SYN packets to trace a network. Using the TCP SYN `-T` flag causes `traceroute(8)` to work effectively the same as the newer [tcptraceroute(1)](https://linux.die.net/man/1/tcptraceroute) command.

Leveraging TCP packets for tracing are exciting for anyone working with a modern network fabric where pesky hardware might want to block or filter ICMP and UDP packets.

### Tracing Semantics

In the diagram below, a client forms a TCP SYN packet destined for a server 4 hops away, with a time to live (TTL) set to "2".

Each hop in the path will decrement the TTL value as the packet is translated and forwarded off to the next hop in the path. When the TTL reaches 0, the network hardware will drop the packet and respond back to the client with an ICMP message.

**Example: Diagram of Traceroute**

```goat
                       ICMP
    ┌────────────┐   Response
    │ TCP Packet ◄────────────┐
    │  TTL = 2   │            │
    └─────┬──────┘            │
          │                   │
   ┌──────▼───────┐   ┌───────┴──────┐   ┌──────────────┐
   │ Router Alpha ├───► Router Beta  ├─┐ │ *Unknown Hop │
   └──────────────┘   └──────────────┘ │ └──────────────┘
       TTL = 1            TTL = 0      X
                      ┌──────────────┐   ┌──────────────┐
                      │ *Unknown Hop │   │Router Charlie│
                      └──────────────┘   └──────┬───────┘
                                                X   
                                         ┌─────────────┐
                                         │ Destination │
                                         └─────────────┘


```

In the example above, the TTL expired at "Router Beta" and the router sends an ICMP "time exceeded" message back to the client. The ICMP response packet contains information about Router Beta and where the packet was dropped.

Both `traceroute(8)` and `tcptraceroute(1)` leverage the TTL and ICMP response behavior of the networking hardware to model a request path.

### Tracing Hop by Hop

These commands work first by setting TTL to "1", sending a packet destined for an unknown host, and finally tracking the response. The ICMP responses is decoded and the first hop is modelled. Next, a new packet with TTL set to "2" is sent, and the 2nd hop in the path is modelled. This process repeats until the packet arrives at the destination and the path is completely modelled.

There are shortcomings with this method such as missed ICMP responses packets (which is the source of the `*` asterisks in traceroute output). Remember, modern network hardware loves to drop ICMP packets.

Another shortcoming of traceroute is that there is no guarantee that the path taken for each iteration of the process is the same path that will be traversed during a future transmission. In theory, a packet could take an en entirely unique path each time.

### Latency and Traceroute

Any performance engineer can tell you the importance of measuring latency in a system. Latency, or the amount of time spent waiting, can surface all kinds of interesting conclusions around the capacity and limits of a system. This, particularly, is exciting for my work at GitHub.

The beauty of how traceroute is implemented is that each packet that leaves the client can be timestamped such that the round trip time can be measured. This is where the latency information in a traceroute response comes from.

# TCP Hijacking

I started to dream about ways I could understand more about the existing TCP connections at GitHub, which on a given day we typically have millions.

Specifically route and latency details were front of mind for me. I knew no matter what I did I would want it to be as transparent and dynamic as possible for our infrastructure.

Also I knew that I wanted to model our topology entirely. This means, I need more than what is available using [Open Telemetry Distributed Tracing over HTTP](https://opentelemetry.io/docs/concepts/signals/traces/).

For example, I want to model our routes and latency on the wire against our databases. This means raw TCP streams. Additionally, I want to visualize other non-HTTP TCP streams in our stack as well such as SSH tunnels.

My immediate conclusion was that I was going to need to start spoofing and stealing TCP connections somehow. While I wasn't certain exactly what types of packets I would want to send out into the abyss of the network, I was pretty confident I would need to send **some** packets out if I intended to instrument the network fabric continuously.

### How can I instrument existing TCP streams?

Over the weekend, I was able to [Livestream my initial research](https://www.youtube.com/watch?v=spuugsDp1Gg) which is a YouTube recording of my [Twitch stream](https://twitch.tv/krisnova). I began to explore this question.

As part of my research I was introduced to a tool known as [paratrace](https://man.cx/paratrace) written by [Dan Kaminsky](https://en.wikipedia.org/wiki/Dan_Kaminsky) in the [Paketto Keiretsu](https://dankaminsky.com/2002/12/24/60/) package.

I was able to pull a tar archive of the source code from an internet archive and host it [here on GitHub](https://github.com/krisnova/paketto) for quick reference. All of this work belongs to Dan, except for maybe the parts of his source code where he attributes others he worked with. 

As I read through his code, I discovered an old, but very exciting library [libnet](https://github.com/libnet/libnet) which ironically is likely already present on most Linux user's filesystems.
Libnet instantly had my attention. I found an example of the "Ping of Death" as well as some examples of how to inject packets into existing Layer 2 and Layer 3 network stream!

This seemed like a promising start for my efforts, although I think there was still quite a few unknowns at this time.

### tcpjack 

I decided to mock up some C code to serve as a rough proof of concept for my research, and I decided to call the project `tcpjack` which is hosted [here on GitHub](https://github.com/krisnova/tcpjack). 

I knew I wanted `tcpjack` to be able to perform a few basic tasks just to get some initial functionality out of the way. 

 1. I want to be able to hijack an existing TCP connection on a filesystem, and use the stolen connection as I would use a tool like [ncat(1)](https://linux.die.net/man/1/ncat).
 2. I want to be able to list established TCP connections on a server, similar to [ss(8)](https://linux.die.net/man/8/ss) or [netstat(8)](https://linux.die.net/man/8/netstat).
 3. I want to be able to have finer grain control over a TCP trace, and even point the tool at a single specific connection at runtime.

### Stealing File Descriptors 

As I began to work through my project, I wanted to build a quick and simple scenario where I could send specific packets over a specific socket that was established by another process. This wasn't immediately possible with any of the tools and libraries I had researched.

As a reminder, I don't want to have to touch any existing application code, and I want to target a specific connection. I want the ability to "walk up" to a system and start instrumenting the network the same way that I can use eBPF in the kernel. I want to be able to toggle it on/off quickly without changing anything else at the application level, and I want to be very precise about the work I am doing.

Traditionally, doing something like this would either be a security threat or at least a very impressive demonstration of abusing some features of a Linux kernel. In January, 2020 ["Add pidfd_getfd" syscall](https://lwn.net/ml/linux-kernel/20200107175927.4558-1-sargun@sargun.me/) was merged into the kernel.

According to [Jonathon Corbet](https://lwn.net/Articles/808997/) this feature was originally added to address the increased desire to control groups of processes from another. Presumably to manage the demand for containerized workloads, such as the workloads we run in Kubernetes at GitHub.

The `pidfd_getfd()` system call (and related `pidfd_open()` system call) allow for one process to access a file descriptor of another process. I was immediately intrigued, as before this feature landed the state of the art would have involved passing a file descriptor over a Unix domain socket or using [ptrace(2)](https://linux.die.net/man/2/ptrace) to disrupt a process to steal the socket using [SCM_RIGHTS](https://man7.org/linux/man-pages/man7/unix.7.html). The first approach would require touching application code, and the latter would require an unreasonable amount of runtime gymnastics to pull it off. 

The new features were implemented directly in the kernel, and made for quick and easy work of stealing a file descriptor! I was shocked at how well these new system calls worked! The implementation was as straight forward as calling the system calls directly in C.

```c 
/**
 * Example function of stealing a file descriptor for an inode value in /proc/net/tcp
 * Copyright 2023 Apache 2.0
 * Author: Kris Nóva <admin@krisnova.net>
 */
int fd_from_ino(ino_t ino) {
  struct dirent *procdentry;  // Procfs
  char needle[64] = "";
  snprintf(needle, 64, "socket:[%lu]", ino);
  DIR *procdp = opendir("/proc");
  if (procdp == NULL) return -1;
  while ((procdentry = readdir(procdp)) != NULL) {
    struct dirent *procsubdentry;  // Procfs Subdir
    char proc_dir[64];
    snprintf(proc_dir, 64, "/proc/%s/fd", procdentry->d_name);
    DIR *procsubdp = opendir(proc_dir);
    if (procsubdp == NULL) {
      continue;
    }
    while ((procsubdentry = readdir(procsubdp)) != NULL) {
      char proc_fd_path[64];
      char fd_content[64] = "";
      snprintf(proc_fd_path, 64, "/proc/%s/fd/%s", procdentry->d_name,
               procsubdentry->d_name);
      readlink(proc_fd_path, fd_content, 64);
      if (strcmp(fd_content, needle) == 0) {
        pid_t pid = atoi(procdentry->d_name);
        closedir(procdp);
        closedir(procsubdp);
        int pidfd = syscall(SYS_pidfd_open, pid, 0);
        return syscall(SYS_pidfd_getfd, pidfd, atoi(procsubdentry->d_name), 0);
      }
    }
    closedir(procsubdp);
  }
  closedir(procdp);
  return -1;
}
```

To be honest, knowing that I can quickly steal a file descriptor opens the door for many, many more exciting opportunities in my work. However, in this case it specifically means I can quickly form packets for network instrumentation in send them over a specific connection without touching a single line of application code!

This will be relevant as local network sockets begin to traverse the ever-complicated mesh of a modern day containerized service mesh topology.

# Conclusion

This small amount of research proves it is possible to instrument an active TCP connection at runtime. Moving forward it will be possible to follow the same tracing mechanics of traceroute and calculate the routing path, and average latency of each hop in the network. 

**Example: Diagram of TCP Instrumentation**

```goat
   ┌────────────────┐   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌───────────┐
   │ TCP Connection │   │   Hop: 01   │  │   Hop: 02   │  │   Hop: 03   │  │           │
   │    75278       ├──►│Latency: 43ms├─►│Latency: 71ms├─►│Latency: 12ms├─►│Destination│
   └────────────────┘   └─────────────┘  └────────────┬┘  └─────────────┘  └───────────┘
                                         ▲            │                     ▲
   ┌────────────────┐   ┌─────────────┐  │            │   ┌─────────────┐   │
   │ TCP Connection │   │   Hop: 01   │  │            │   │   Hop: 03   │   │
   │    49582       ├──►│Latency: 07ms├──┘            └──►│Latency: 07ms├───┘
   └────────────────┘   └─────────────┘                   └─────────────┘

```

The difference between my work and a traditional traceroute will be the ability to target specific processes instead of hosts. Additionally, we can be confident we will be tracing the same path that a current TCP connection is traversing. Specific connections can be targeted for analysis, and can be quickly instrumented regardless of any changes to DNS or TCP/IP semantics from overlay networks.

This will open the door for topology modelling, as well as latency analysis of the network fabric itself.

I hope I can finish my sample code of `tcpjack` in the coming weeks, and eventually cut a release of a lightweight executable which can be used for quick and easy network instrumentation.

### Demo

```bash 
# Terminal 1
# Start a ncat server, and hang
ncat -l 9074

# Terminal 2 
# Start a ncat client, and hang
ncat localhost 9074

# Terminal 3 
# Find the inode to instrument
tcpjack -l | grep ncat # List established connections
  ncat   9321  72294 127.0.0.1:48434 ->  127.0.0.1:9074
  ncat   9237  76747  127.0.0.1:9074 -> 127.0.0.1:48434 

# Terminal 3  
# Send a bogus payload over the stolen connection
echo "PAYLOAD" | sudo tcpjack -j 72294

# See the "PAYLOAD" string sent to the ncat server 
# using the hijacked file descriptor

# Terminal 1
# Type a message and press enter, to verify the original
# connection remains intact!

```









### Resources

- [tcpjack](https://github.com/krisnova/tcpjack)
- [Grabbing file descriptors with pidfd_getfd() by Jonathan Corbet](https://lwn.net/Articles/808997/)
- [pidfd_getfd(2) System Call](https://man7.org/linux/man-pages/man2/pidfd_getfd.2.html)
- [pidfd_open(2) System Call](https://man7.org/linux/man-pages/man2/pidfd_open.2.html)
- [Add pidfd_getfd kernel patch](https://lwn.net/ml/linux-kernel/20200107175927.4558-1-sargun@sargun.me/)
- [Paketto Keiretsu by Dan Kaminsky Archive](https://github.com/krisnova/paketto)
- [netstat(8)](https://linux.die.net/man/8/netstat)
- [ncat(1)](https://linux.die.net/man/1/ncat)
- [ss(8)](https://linux.die.net/man/8/ss)
- [ptrace(2)](https://linux.die.net/man/2/ptrace)
- [tcptraceroute(1)](https://linux.die.net/man/1/tcptraceroute)
- [traceroute(8)](https://linux.die.net/man/8/traceroute)
- [SCM_RIGHTS](https://man7.org/linux/man-pages/man7/unix.7.html)
- [libnet](https://github.com/libnet/libnet)