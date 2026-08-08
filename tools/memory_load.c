/*
 * memory_load.c — synthetic guest memory-pressure workload for issue #24.
 *
 * Reproduces the crash precondition WITHOUT the real apps (VS Code/Edge/QQ):
 * free memory pinned low with nothing quick-reclaimable, compressor holding
 * real content. Two components, filled interleaved so the pageout daemon can
 * compress in the background (avoids a transient physical spike -> OOM):
 *
 *   hot  — INCOMPRESSIBLE random pages. Can't be compressed, must stay
 *          resident -> pins free near the floor and locks physical memory.
 *          Kept re-touched so it stays in the active list.
 *   cold — pages that compress ~2.5:1 (6KB random + 10KB pattern per 16KB
 *          page), like real app data that went cold. Under pressure the
 *          kernel squeezes these into the compressor (CC grows), exactly
 *          like the real 26-minute buildup, just compressed in time.
 *
 * Breathing: when free drops below --min-free-mb, pause briefly so the
 * pageout daemon compresses cold and free recovers — reproducing the real
 * "compressor at ~45%, free ~90MB, with an inactive reserve still left"
 * state, which is what makes swap_priming's ratio-crossing work.
 *
 * Each snapshot prints CC/(ANC+CC) — the quantity that must exceed 60% for
 * swapout condition ① (the operative trigger). The PRE-state should sit
 * below it (no organic swapout), then swap_priming pushes it over.
 *
 * Usage: ./memory_load [--hot MB] [--cold MB] [--min-free-mb MB]
 *   defaults: --hot 3500 --cold 7000 --min-free-mb 512
 * Holds the pressure (re-touches hot, prints vm_stat every 10s) until killed.
 */
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>

#define PAGESIZE (16 * 1024) /* arm64 macOS guest */
#define CHUNK    (64 * 1024 * 1024)

typedef struct {
	long long free_pages, active_pages, inactive_pages, spec_pages, cc_pages;
} vmstate;

static uint64_t x = 88172645463325252ULL;
static inline uint64_t
rnd(void)
{
	x ^= x << 13;
	x ^= x >> 7;
	x ^= x << 17;
	return x;
}

static long long
parse_pages(const char *line, const char *key)
{
	const char *p = strstr(line, key);
	if (p == NULL) {
		return -1;
	}
	p += strlen(key);
	while (*p && !isdigit((unsigned char)*p)) {
		p++;
	}
	long long v = 0;
	while (*p >= '0' && *p <= '9') {
		v = v * 10 + (*p - '0');
		p++;
	}
	return v;
}

static int
read_vmstat(vmstate *s)
{
	FILE *fp = popen("vm_stat", "r");
	char line[256];
	long long v;

	if (fp == NULL) {
		return -1;
	}
	memset(s, 0, sizeof(*s));
	while (fgets(line, sizeof(line), fp) != NULL) {
		if ((v = parse_pages(line, "Pages free:")) >= 0) {
			s->free_pages = v;
		} else if ((v = parse_pages(line, "Pages active:")) >= 0) {
			s->active_pages = v;
		} else if ((v = parse_pages(line, "Pages inactive:")) >= 0) {
			s->inactive_pages = v;
		} else if ((v = parse_pages(line, "Pages speculative:")) >= 0) {
			s->spec_pages = v;
		} else if ((v = parse_pages(line, "Pages occupied by compressor:")) >= 0) {
			s->cc_pages = v;
		}
	}
	pclose(fp);
	return 0;
}

static void
snapshot(const char *tag)
{
	vmstate s;

	printf("\n=== %s ===\n", tag);
	fflush(stdout);
	(void)system("sysctl vm.swapusage; vm_stat | grep -E 'Pages free|Pages active|Pages inactive|Pages occupied|Pages stored|Swapins|Swapouts'");
	if (read_vmstat(&s) == 0) {
		long long anc = s.active_pages + s.inactive_pages + s.free_pages + s.spec_pages;
		double ratio = (anc + s.cc_pages) > 0
		    ? (double)s.cc_pages / (anc + s.cc_pages) : 0;
		printf("ANC=%lld CC=%lld  CC/(ANC+CC)=%.1f%%  (swapout needs >60%%)\n",
		    anc, s.cc_pages, ratio * 100);
	}
	fflush(stdout);
}

static void
fill_hot_page(uint8_t *pg)
{
	uint64_t *p = (uint64_t *)pg;
	for (size_t i = 0; i < PAGESIZE / 8; i++) {
		p[i] = rnd();
	}
}

/* 6KB incompressible + 10KB pattern per page -> compresses ~2.5:1 */
static void
fill_cold_page(uint8_t *pg)
{
	uint64_t *p = (uint64_t *)pg;
	size_t n = PAGESIZE / 8;
	size_t rnd_n = (6 * 1024) / 8;
	for (size_t i = 0; i < rnd_n; i++) {
		p[i] = rnd();
	}
	for (size_t i = rnd_n; i < n; i++) {
		p[i] = (uint64_t)(i - rnd_n) * 2654435761u;
	}
}

static void
fill_region(uint8_t *base, size_t bytes, void (*filler)(uint8_t *))
{
	for (size_t off = 0; off < bytes; off += PAGESIZE) {
		filler(base + off);
	}
}

int
main(int argc, char **argv)
{
	size_t hot_mb = 3500;
	size_t cold_mb = 7000;
	long long min_free_mb = 512;

	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--hot") == 0 && i + 1 < argc) {
			hot_mb = (size_t)atoll(argv[++i]);
		} else if (strcmp(argv[i], "--cold") == 0 && i + 1 < argc) {
			cold_mb = (size_t)atoll(argv[++i]);
		} else if (strcmp(argv[i], "--min-free-mb") == 0 && i + 1 < argc) {
			min_free_mb = atoll(argv[++i]);
		} else {
			fprintf(stderr, "usage: %s [--hot MB] [--cold MB] [--min-free-mb MB]\n",
			    argv[0]);
			return 2;
		}
	}
	long long min_free = min_free_mb * 1024 * 1024;

	printf("memory_load: hot=%zuMB cold=%zuMB min_free=%lldMB pid=%d\n",
	    hot_mb, cold_mb, min_free_mb, (int)getpid());
	printf("(kill me with: kill %d) — building issue #24 crash precondition\n",
	    (int)getpid());
	fflush(stdout);

	snapshot("START");

	size_t hot_bytes = hot_mb * 1024 * 1024;
	size_t cold_bytes = cold_mb * 1024 * 1024;
	uint8_t *hot = mmap(NULL, hot_bytes, PROT_READ | PROT_WRITE,
	    MAP_ANON | MAP_PRIVATE, -1, 0);
	if (hot == MAP_FAILED) {
		perror("mmap hot");
		return 1;
	}
	uint8_t *cold = mmap(NULL, cold_bytes, PROT_READ | PROT_WRITE,
	    MAP_ANON | MAP_PRIVATE, -1, 0);
	if (cold == MAP_FAILED) {
		perror("mmap cold");
		return 1;
	}

	printf("building pressure: interleaving %zuMB incompressible hot + "
	    "%zuMB ~2.5:1 compressible cold ...\n", hot_mb, cold_mb);
	fflush(stdout);

	size_t hot_off = 0, cold_off = 0;
	long long chunks = 0;
	while (hot_off < hot_bytes || cold_off < cold_bytes) {
		if (cold_off < cold_bytes) {
			fill_region(cold + cold_off, CHUNK, fill_cold_page);
			cold_off += CHUNK;
		}
		if (hot_off < hot_bytes) {
			fill_region(hot + hot_off, CHUNK, fill_hot_page);
			hot_off += CHUNK;
		}
		vmstate s;
		if (read_vmstat(&s) == 0 &&
		    s.free_pages * PAGESIZE < min_free) {
			usleep(200 * 1000); /* let pageout compress cold */
		}
		if (++chunks % 8 == 0) {
			char tag[96];
			snprintf(tag, sizeof(tag), "building (hot %zuMB / cold %zuMB)",
			    hot_off / (1024 * 1024), cold_off / (1024 * 1024));
			snapshot(tag);
		}
		usleep(5000);
	}

	snapshot("ALLOCATED — pressure built");
	printf("\nHolding pressure (re-touching hot to keep it active). "
	    "Ctrl-C to stop.\n");
	fflush(stdout);

	/* Hold: keep the hot region referenced so the kernel can't reclaim or
	 * swap it, pinning free near the floor for the display test. */
	size_t hwin = 32 * 1024 * 1024;
	size_t off = 0;
	long long tick = 0;
	for (;;) {
		fill_region(hot + off, hwin, fill_hot_page);
		off = (off + hwin) % hot_bytes;
		usleep(100 * 1000);
		if (++tick % 100 == 0) {
			snapshot("holding");
		}
	}
	return 0;
}
