/*
 * Description: eBPF program accounting socket-layer network bytes per process for ebpf_exporter.
 * Created by: Mustafa Can Caliskan
 * Date: 2026-08-23
 */

/*
 * vmlinux.h is generated from kernel BTF and contains forward declarations
 * that clang flags as empty; the suppression is scoped to that header only.
 */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wmissing-declarations"
#include <vmlinux.h>
#pragma clang diagnostic pop

#include <bpf/bpf_core_read.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

#define TASK_COMM_LEN 16

/*
 * How much of the process command line (argv) to capture. The dashboard only
 * needs the first ~60 characters, so 64 bytes (60 chars + NUL) is plenty.
 */
#define CMDLINE_LEN 64

/*
 * Upper bound on distinct (pid, proto, comm) tuples held in kernel memory.
 * LRU eviction keeps memory flat on nodes that churn through short-lived
 * processes, at the cost of losing the least recently active entries.
 */
#define MAX_TRACKED_PROCESSES 16384

/* IANA protocol numbers, decoded back into "tcp"/"udp" by the exporter config. */
#define PROTO_TCP 6
#define PROTO_UDP 17

/*
 * Map key layout is part of the contract with process-network.yaml: the
 * exporter slices the raw key bytes according to the label sizes declared
 * there, so field order and sizes must stay in sync. Sizes are chosen so the
 * struct carries no padding (4 + 4 + 16 + 64 = 88 bytes).
 */
struct process_key_t {
    u32 pid;
    u32 proto;
    u8 comm[TASK_COMM_LEN];
    u8 cmdline[CMDLINE_LEN];
};

struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, MAX_TRACKED_PROCESSES);
    __type(key, struct process_key_t);
    __type(value, u64);
} process_network_tx_bytes_total SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, MAX_TRACKED_PROCESSES);
    __type(key, struct process_key_t);
    __type(value, u64);
} process_network_rx_bytes_total SEC(".maps");

/*
 * Copies the process command line (argv, as shown by `ps -ef`) into dst, up to
 * len-1 bytes, leaving the final byte as the NUL terminator. The argv region is
 * [mm->arg_start, mm->arg_end). Kernel threads have no mm, so nothing is
 * written and dst stays zeroed. bpf_probe_read_user leaves dst untouched on
 * fault, so a torn read is not possible.
 */
static __always_inline void read_cmdline(struct task_struct *task, u8 *dst, u32 len)
{
    struct mm_struct *mm;
    u64 arg_start, arg_end;
    u32 size;

    mm = BPF_CORE_READ(task, mm);
    if (!mm)
        return;

    arg_start = BPF_CORE_READ(mm, arg_start);
    arg_end = BPF_CORE_READ(mm, arg_end);
    if (arg_end <= arg_start)
        return;

    size = arg_end - arg_start;
    if (size > len - 1)
        size = len - 1;

    bpf_probe_read_user(dst, size, (void *) arg_start);
}

/*
 * Adds bytes to the counter of the currently running task in the given map.
 * Runs in the caller's process context, so the current task identifies the
 * process that owns the traffic. The name is read from the thread group leader
 * rather than via bpf_get_current_comm(), which would return the name of the
 * calling thread and disagree with the thread group id used as `pid`.
 * Silently drops the sample if the map is full and no entry can be created.
 */
static __always_inline void account(void *map, u32 proto, u64 bytes)
{
    struct task_struct *task = (struct task_struct *) bpf_get_current_task_btf();
    struct process_key_t key = {};
    u64 zero = 0;
    u64 *counter;

    key.pid = bpf_get_current_pid_tgid() >> 32;
    key.proto = proto;
    BPF_CORE_READ_INTO(&key.comm, task, group_leader, comm);
    read_cmdline(task, key.cmdline, sizeof(key.cmdline));

    counter = bpf_map_lookup_elem(map, &key);
    if (!counter) {
        bpf_map_update_elem(map, &key, &zero, BPF_NOEXIST);
        counter = bpf_map_lookup_elem(map, &key);
        if (!counter) {
            return;
        }
    }

    __sync_fetch_and_add(counter, bytes);
}

/*
 * tcp_sendmsg is the common entry point for both IPv4 and IPv6, and `size` is
 * the payload the application handed to the kernel. This is not wire traffic:
 * headers, retransmits and TSO segmentation are not reflected here.
 */
SEC("kprobe/tcp_sendmsg")
int BPF_KPROBE(tcp_sendmsg, struct sock *sk, struct msghdr *msg, size_t size)
{
    account(&process_network_tx_bytes_total, PROTO_TCP, size);
    return 0;
}

/*
 * tcp_cleanup_rbuf is preferred over tcp_recvmsg because it reports the bytes
 * actually consumed from the receive queue, including data drained by splice
 * or by the socket being closed.
 */
SEC("kprobe/tcp_cleanup_rbuf")
int BPF_KPROBE(tcp_cleanup_rbuf, struct sock *sk, int copied)
{
    if (copied <= 0) {
        return 0;
    }

    account(&process_network_rx_bytes_total, PROTO_TCP, copied);
    return 0;
}

SEC("kprobe/udp_sendmsg")
int BPF_KPROBE(udp_sendmsg, struct sock *sk, struct msghdr *msg, size_t len)
{
    account(&process_network_tx_bytes_total, PROTO_UDP, len);
    return 0;
}

/* IPv6 UDP takes a separate path and needs its own probe. */
SEC("kprobe/udpv6_sendmsg")
int BPF_KPROBE(udpv6_sendmsg, struct sock *sk, struct msghdr *msg, size_t len)
{
    account(&process_network_tx_bytes_total, PROTO_UDP, len);
    return 0;
}

/*
 * skb_consume_udp runs in the receiving process context for both IPv4 and
 * IPv6, unlike udp_recvmsg where the copied length is not known on entry.
 */
SEC("kprobe/skb_consume_udp")
int BPF_KPROBE(skb_consume_udp, struct sock *sk, struct sk_buff *skb, int len)
{
    if (len <= 0) {
        return 0;
    }

    account(&process_network_rx_bytes_total, PROTO_UDP, len);
    return 0;
}

char LICENSE[] SEC("license") = "GPL";
