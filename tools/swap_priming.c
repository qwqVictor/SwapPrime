/*
 * swap_priming.c — force the FIRST swapout so swapfile0 gets created.
 *
 * Background (from xnu source analysis): swapfile0 is created lazily by
 * vm_swapfile_create_thread, which is ONLY woken from the swapout path
 * (vm_swap_put). No swapout ever happens in this VM because the trigger
 * condition ① — CC_physical > 0.6*(ANC+CC), i.e. the compressor must hold
 * more than 60% of the ANC+CC pool — is never reached by the normal load
 * (its compressor plateaus at ~45% of the pool). Condition ② needs an
 * external-pageout spike and ③ needs free < free_reserved-256, neither of
 * which this gradual-pressure workload produces. This program forces the
 * ratio across the line by driving compression.
 *
 * Mechanism: allocate ANONYMOUS memory filled with INCOMPRESSIBLE
 * (xorshift64) data, touching every page. Random data can't be squeezed
 * by the compressor, so to satisfy the allocation the kernel must compress
 * the existing active/inactive working set — which simultaneously shrinks
 * ANC and grows CC until CC > 0.6*(ANC+CC) (condition ①). The first
 * swapout then fires, waking the create thread, which writes swapfile0.
 *
 * Safety: incremental 128MB chunks; snapshot state after each chunk;
 * stop the moment swapfile0 exists; hard cap at total_mb so we can't run
 * away into a full OOM hang.
 *
 * === PROVEN RESULT (2026-08-09, VirtualMacOniPad guest macOS 15.6.1) ===
 * Ran on a system that had ~63MB free, compressor holding ~7GB content
 * (~2.9GB physical), Swapouts=0, no swapfile0. Per-step snapshots
 * (ANC = active+inactive+free+spec, CC = compressor physical pages):
 *   step     ANC     0.4*(ANC+CC)  ANC<thr?  free   free<1572?
 *   START  229024     166181       False    4184   False
 *   +640M  217008     166395       False     904    True   <- free below reserve
 *   +896M  197575     166762       False     925    True
 *   +1024M 171814     166180       False     914    True
 *   +1152M 161062     165963       True      952    True   <- Swapouts 0 -> 3388
 * Key observation: free was below the reserve line (condition ③) from
 * 640MB onward, yet swapout only fired at 1152MB — the exact step where
 * ANC first dropped below 0.4*(ANC+CC) (condition ①, the RATIO). The ratio
 * is the operative trigger here, not the free collapse; free is a
 * fast-oscillating quantity and snapshots below reserve were transient.
 * swapfile0 was created (1.0G, /System/Volumes/VM/swapfile0); after the
 * program exited: free recovered 63MB -> 759MB, swap stayed active
 * (total=1024M). This also REFUTES the earlier "condition ① structurally
 * unreachable" claim — it is load-specific, not structural.
 *
 * Caveats learned:
 *  - The ALREADY-frozen display did NOT recover after swap activation —
 *    the stall is a one-way trap (WindowServer frame pipeline stays wedged
 *    even when memory/swap free up). So this tool is PREVENTIVE: prime
 *    swap so a future stall can't happen; it is not a rescue for a screen
 *    that already froze.
 *  - swapfile0 does NOT persist across reboot as active swap: the kernel
 *    never scans existing swapfiles at boot; after reboot the create
 *    thread sleeps again until the next swapout (and then O_TRUNCs the
 *    stale file). To be effective every boot, re-prime at startup or run
 *    a memory-pressure-monitor daemon that forces compression when CC
 *    approaches 60% of the ANC+CC pool.
 *
 * Usage guard: the program ABORTS by default when free memory is above 2GB.
 * With that much free the kernel just hands pages out (free counts toward
 * ANC), compression never builds, and the run is futile — or, pushed too
 * far, risks OOM-killing this process. Run it once the normal workload has
 * consumed most of RAM; override with --force.
 */
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>

#define PAGESIZE (16 * 1024) /* arm64 macOS guest: 16KB pages */

static uint64_t x = 88172645463325252ULL;
static inline uint64_t
rnd(void)
{
	x ^= x << 13;
	x ^= x >> 7;
	x ^= x << 17;
	return x;
}

static int
swapfile0_exists(void)
{
	struct stat sb;
	return (stat("/System/Volumes/VM/swapfile0", &sb) == 0);
}

/* Free memory in bytes from vm_stat, or -1 on failure. */
static long long
vm_stat_free_bytes(void)
{
	FILE *fp = popen("vm_stat", "r");
	char line[256];
	long long pages = -1;

	if (fp == NULL) {
		return -1;
	}
	while (fgets(line, sizeof(line), fp) != NULL) {
		if (strncmp(line, "Pages free:", 11) == 0) {
			char *p = line + 11;
			while (*p && !isdigit((unsigned char)*p)) {
				p++;
			}
			long long v = 0;
			while (*p >= '0' && *p <= '9') {
				v = v * 10 + (*p - '0');
				p++;
			}
			pages = v;
			break;
		}
	}
	pclose(fp);
	return pages < 0 ? -1 : pages * PAGESIZE;
}

static void
snapshot(const char *tag)
{
	char cmd[256];
	printf("\n=== %s ===\n", tag);
	fflush(stdout);

	/* swapusage + free pages + compressor physical */
	snprintf(cmd, sizeof(cmd),
	    "sysctl vm.swapusage; "
	    "vm_stat | grep -E 'Pages free|Pages active|Pages inactive|Pages occupied|Pages stored|Swapins|Swapouts'");
	(void)system(cmd);

	if (swapfile0_exists()) {
		printf("*** swapfile0 PRESENT ***\n");
		(void)system("ls -lh /System/Volumes/VM/");
	}
	fflush(stdout);
}

int
main(int argc, char **argv)
{
	size_t chunk_mb = 128;
	size_t total_mb = 2048;
	int force = 0;
	int num_seen = 0;
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--force") == 0) {
			force = 1;
		} else if (num_seen == 0) {
			total_mb = (size_t)atoll(argv[i]);
			num_seen++;
		} else if (num_seen == 1) {
			chunk_mb = (size_t)atoll(argv[i]);
			num_seen++;
		}
	}

	printf("swap_priming: total_cap=%zuMB chunk=%zuMB pid=%d\n",
	    total_mb, chunk_mb, (int)getpid());
	printf("(you can kill me with: kill %d)\n", (int)getpid());
	fflush(stdout);

	snapshot("START");

	/* Pressure guard: with >2GB free the kernel hands pages out (free
	 * counts toward ANC), compression never builds, and priming is futile
	 * (or, if run to the cap, risks OOM-killing this process). */
	long long free_bytes = vm_stat_free_bytes();
	if (free_bytes >= 0) {
		printf("free memory: %lldMB\n", free_bytes / (1024 * 1024));
		if (!force && free_bytes > 2LL * 1024 * 1024 * 1024) {
			printf("\nWARNING: %lldMB free — memory pressure too low for "
			    "priming to work.\n",
			    free_bytes / (1024 * 1024));
			printf("The trigger is CC > 0.6*(ANC+CC); with lots of free\n");
			printf("pages the kernel just hands them out (free counts toward\n");
			printf("ANC), so compression never builds and the ratio never\n");
			printf("crosses. Start your normal workload first so free drops,\n");
			printf("then re-run. Override with: %s --force\n", argv[0]);
			return 2;
		}
	}

	size_t alloc_total = 0;
	void *base = NULL;
	for (size_t mb = 0; mb < total_mb; mb += chunk_mb) {
		size_t bytes = chunk_mb * 1024 * 1024;

		base = mmap(base, bytes, PROT_READ | PROT_WRITE,
		    MAP_ANON | MAP_PRIVATE, -1, 0);
		if (base == MAP_FAILED) {
			perror("mmap");
			break;
		}

		/* Touch every page with incompressible data. */
		uint64_t *p = (uint64_t *)base;
		size_t n = bytes / sizeof(uint64_t);
		for (size_t i = 0; i < n; i++) {
			p[i] = rnd();
		}

		alloc_total += chunk_mb;

		char tag[128];
		snprintf(tag, sizeof(tag), "after +%zuMB (total %zuMB)",
		    chunk_mb, alloc_total);
		snapshot(tag);

		if (swapfile0_exists()) {
			printf("\n>>> SUCCESS: swapfile0 was created at total=%zuMB\n",
			    alloc_total);
			break;
		}
	}

	snapshot("END");
	printf("total allocated & touched: %zuMB\n", alloc_total);
	printf("swapfile0 present: %s\n",
	    swapfile0_exists() ? "YES" : "NO");

	return 0;
}
