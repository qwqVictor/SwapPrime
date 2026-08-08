/*
 * swap_prime.m — boot-time swap priming menu-bar app for VirtualMacOniPad
 * issue #24 (framebuffer stalls when guest memory pressure starves WIRED
 * IOSurface allocations).
 *
 * At login (via LaunchAgent, see build_swap_prime.sh) it aggressively builds
 * guest memory pressure until the kernel activates swap, then exits. If swap
 * isn't up within --timeout seconds it posts a notification and exits. Shows
 * a status-bar icon while working.
 *
 * Why it works (see docs/issue-24-framebuffer-stall-postmortem.md §4.6/§4.9,
 * docs/memory_load.c): swapout condition ① fires when CC > 0.6*(ANC+CC).
 * A large compressible "cold" region gets squeezed into the compressor
 * (CC grows) while incompressible "hot" pages pin free low; during the
 * build the ratio crosses 60% → first swapout → swapfile0 created → swap
 * stays active for the whole boot — a permanent escape valve so WIRED
 * display allocations never stall. swapfile0 does NOT persist across reboot
 * (kernel never scans existing swapfiles), so this must re-run every boot.
 *
 * Mechanism (validated 2026-08-09 with docs/memory_load + docs/swap_priming):
 *   cold — 6KB incompressible + 10KB pattern per 16KB page (compresses
 *          ~2.5:1, like real app data) → fed to the compressor.
 *   hot  — pure random (incompressible) → pins free low, locks physical.
 *   Interleaved fill with "breathing" (pause when free < min_free so the
 *   pageout daemon compresses cold and free recovers) → after each chunk
 *   check whether swap is active. If the base build completes without swap,
 *   keep pushing extra compressible cold chunks (only while free is low)
 *   until swap or timeout.
 *
 * Build:    ./build_swap_prime.sh            (→ SwapPrime.app; build only)
 * Install:  SwapPrime.app/Contents/MacOS/SwapPrime --install
 *           (self-installs: copy to ~/Applications, write + load LaunchAgent)
 * Uninstall:SwapPrime.app/Contents/MacOS/SwapPrime --uninstall
 * Usage:    SwapPrime [--timeout SEC] [--hot MB] [--cold MB] [--min-free-mb MB]
 *           defaults: --timeout 60 --min-free-mb 512; --hot/--cold auto-scale
 *           from total physical RAM (3500 / 7000 on an 8 GB guest).
 */
#import <Cocoa/Cocoa.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/sysctl.h>

#define PAGESIZE (16 * 1024)
#define CHUNK    (64 * 1024 * 1024)

/* ---- config ---- */
/* --hot/--cold default to 0 = auto: the sizes were tuned for an 8 GB guest
 * and are scaled linearly with total physical RAM (see resolve_sizes). */
static size_t   g_hot_mb      = 0;
static size_t   g_cold_mb     = 0;
static long long g_min_free_mb = 512;
static double   g_timeout_s   = 60.0;

/* Reference guest the 3500/7000 MB split was tuned on (8 GB = 8192 MB). */
#define REF_TOTAL_MB 8192
#define REF_HOT_MB   3500
#define REF_COLD_MB  7000

/* ---- shared state between the priming queue and the main run loop ---- */
static _Atomic int      g_done = 0;          /* 0 running, 1 success, -1 timeout */
static _Atomic long long g_elapsed_ms = 0;
static _Atomic long long g_hot_mb_done = 0;
static _Atomic long long g_cold_mb_done = 0;

static NSStatusItem  *g_status;
static NSMenuItem    *g_statusItem;

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

static long long
vm_free_pages(void)
{
	FILE *fp = popen("vm_stat", "r");
	char line[256];
	long long v = -1;

	if (fp == NULL) {
		return -1;
	}
	while (fgets(line, sizeof(line), fp) != NULL) {
		long long t = parse_pages(line, "Pages free:");
		if (t >= 0) {
			v = t;
			break;
		}
	}
	pclose(fp);
	return v;
}

/* swap is "active" once vm.swapusage reports total > 0 (kernel created and
 * registered a swapfile this boot). A stale swapfile0 file on disk does NOT
 * count — only sysctl does. */
static int
swap_active(void)
{
	FILE *fp = popen("sysctl vm.swapusage 2>/dev/null", "r");
	char line[256];
	int active = 0;

	if (fp == NULL) {
		return 0;
	}
	while (fgets(line, sizeof(line), fp) != NULL) {
		const char *p = strstr(line, "total = ");
		if (p) {
			double total = strtod(p + 8, NULL);
			if (total > 0) {
				active = 1;
			}
			break;
		}
	}
	pclose(fp);
	return active;
}

/* Total physical RAM in MB (hw.memsize returns bytes). 0 on failure. */
static uint64_t
total_phys_mb(void)
{
	uint64_t mem = 0;
	size_t len = sizeof(mem);
	if (sysctlbyname("hw.memsize", &mem, &len, NULL, 0) == 0) {
		return mem >> 20;
	}
	return 0;
}

/* Auto-size --hot/--cold from physical RAM: keep the same fraction of RAM as
 * the 8 GB guest the values were tuned on (hot = 3500/8192, cold = 7000/8192).
 * An explicit --hot/--cold always wins over the auto value. */
static void
resolve_sizes(void)
{
	uint64_t total_mb = total_phys_mb();
	if (total_mb == 0) { /* hw.memsize read failed — use the 8GB-tuned values */
		total_mb = REF_TOTAL_MB;
	}
	if (g_hot_mb == 0) {
		g_hot_mb = (size_t)((double)total_mb * REF_HOT_MB / REF_TOTAL_MB);
	}
	if (g_cold_mb == 0) {
		g_cold_mb = (size_t)((double)total_mb * REF_COLD_MB / REF_TOTAL_MB);
	}
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

static long long
now_ms(struct timespec t0)
{
	struct timespec t1;
	clock_gettime(CLOCK_MONOTONIC, &t1);
	return (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_nsec - t0.tv_nsec) / 1000000;
}

/* ---- priming work, runs on a background queue (never touches AppKit) ---- */
static void
run_prime(void)
{
	struct timespec t0;
	clock_gettime(CLOCK_MONOTONIC, &t0);

	printf("swap_prime: priming hot=%zuMB cold=%zuMB min_free=%lldMB "
	    "timeout=%.0fs pid=%d total_phys=%lluMB\n",
	    g_hot_mb, g_cold_mb, g_min_free_mb, g_timeout_s, (int)getpid(),
	    (unsigned long long)total_phys_mb());
	fflush(stdout);

	size_t hot_bytes = g_hot_mb << 20;
	size_t cold_bytes = g_cold_mb << 20;
	long long min_free = g_min_free_mb << 20;

	uint8_t *hot = mmap(NULL, hot_bytes, PROT_READ | PROT_WRITE,
	    MAP_ANON | MAP_PRIVATE, -1, 0);
	uint8_t *cold = mmap(NULL, cold_bytes, PROT_READ | PROT_WRITE,
	    MAP_ANON | MAP_PRIVATE, -1, 0);
	if (hot == MAP_FAILED || cold == MAP_FAILED) {
		perror("mmap");
		atomic_store(&g_done, -1);
		return;
	}
	if (swap_active()) { /* something already activated swap — nothing to do */
		goto success;
	}

	size_t hot_off = 0, cold_off = 0;

	/* Phase 1: interleave the base hot+cold regions, breathing when free
	 * gets low so the pageout daemon can compress cold in the background. */
	while (hot_off < hot_bytes || cold_off < cold_bytes) {
		if (cold_off < cold_bytes) {
			fill_region(cold + cold_off, CHUNK, fill_cold_page);
			cold_off += CHUNK;
			atomic_store(&g_cold_mb_done, cold_off >> 20);
		}
		if (hot_off < hot_bytes) {
			fill_region(hot + hot_off, CHUNK, fill_hot_page);
			hot_off += CHUNK;
			atomic_store(&g_hot_mb_done, hot_off >> 20);
		}
		if (swap_active()) {
			goto success;
		}
		long long fp = vm_free_pages();
		if (fp >= 0 && fp * PAGESIZE < min_free) {
			usleep(150 * 1000); /* let pageout compress cold */
		}
		atomic_store(&g_elapsed_ms, now_ms(t0));
		if (now_ms(t0) > g_timeout_s * 1000) {
			goto timeout;
		}
		usleep(3000);
	}

	/* Phase 2 (fallback): base build finished without swap. Keep pushing
	 * extra compressible cold — but only while free is actually low, so the
	 * kernel compresses it into CC (growing CC/(ANC+CC) toward 60%) instead
	 * of the chunks just sitting resident. Bounds physical usage. */
	while (now_ms(t0) <= g_timeout_s * 1000) {
		if (swap_active()) {
			goto success;
		}
		long long fp = vm_free_pages();
		if (fp < 0 || fp * PAGESIZE >= min_free) {
			usleep(200 * 1000); /* no pressure yet — wait, don't push */
			atomic_store(&g_elapsed_ms, now_ms(t0));
			continue;
		}
		uint8_t *extra = mmap(NULL, CHUNK, PROT_READ | PROT_WRITE,
		    MAP_ANON | MAP_PRIVATE, -1, 0);
		if (extra == MAP_FAILED) {
			usleep(200 * 1000);
			atomic_store(&g_elapsed_ms, now_ms(t0));
			continue;
		}
		fill_region(extra, CHUNK, fill_cold_page);
		atomic_fetch_add(&g_cold_mb_done, CHUNK >> 20);
		atomic_store(&g_elapsed_ms, now_ms(t0));
		usleep(5000);
	}

	goto timeout;

success:
	printf("swap_prime: SUCCESS — swap active after %lldms\n",
	    now_ms(t0));
	fflush(stdout);
	atomic_store(&g_done, 1);
	return;

timeout:
	printf("swap_prime: TIMEOUT after %.0fs — swap never engaged\n",
	    g_timeout_s);
	(void)system("sysctl vm.swapusage; "
	    "vm_stat | grep -E 'Pages free|Pages active|Pages inactive|"
	    "Pages occupied by compressor|Pages stored in compressor|Swapouts'");
	fflush(stdout);
	atomic_store(&g_done, -1);
}

/* ---- AppKit ---- */
static int install_app(void);   /* defined below main's helpers */
static int uninstall_app(void);
static BOOL is_installed(void);

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
	if (!is_installed()) {
		[[NSRunningApplication currentApplication]
		    activateWithOptions:NSApplicationActivateIgnoringOtherApps];
		NSAlert *alert = [[NSAlert alloc] init];
		alert.messageText = @"SwapPrime isn't installed";
		alert.informativeText =
		    @"SwapPrime is missing from /Applications or ~/Applications and its "
		    @"LaunchAgent isn't installed. Install it to prime swap at every login?";
		[alert addButtonWithTitle:@"Install"];
		[alert addButtonWithTitle:@"Quit"];
		if ([alert runModal] == NSAlertFirstButtonReturn) {
			(void)install_app();
		}
		[NSApp terminate:nil];
		return;
	}

	g_status = [[NSStatusBar systemStatusBar]
	    statusItemWithLength:NSSquareStatusItemLength];
	g_status.button.image =
	    [NSImage imageWithSystemSymbolName:@"memorychip"
	        accessibilityDescription:@"Swap prime"];
	g_status.button.image.template = YES;
	g_status.button.toolTip = @"Swap prime";

	NSMenu *menu = [[NSMenu alloc] init];
	g_statusItem = [menu addItemWithTitle:@"Swap priming…"
	    action:nil keyEquivalent:@""];
	g_statusItem.enabled = NO;
	[menu addItem:[NSMenuItem separatorItem]];
	NSMenuItem *quit = [menu addItemWithTitle:@"Quit"
	    action:@selector(quitApp:) keyEquivalent:@"q"];
	[quit setTarget:self];
	g_status.menu = menu;

	NSTimer *timer = [NSTimer timerWithTimeInterval:1.0 target:self
	    selector:@selector(refresh:) userInfo:nil repeats:YES];
	[[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];

	/* Give the status icon a moment to appear, then start priming. */
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
	    (int64_t)(2.0 * NSEC_PER_SEC)),
	    dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		run_prime();
		dispatch_async(dispatch_get_main_queue(), ^{
			[self finishPrime];
		});
	});
}

- (void)refresh:(NSTimer *)timer
{
	if (atomic_load(&g_done) != 0) {
		return;
	}
	long long ms = atomic_load(&g_elapsed_ms);
	long long h = atomic_load(&g_hot_mb_done);
	long long c = atomic_load(&g_cold_mb_done);
	g_statusItem.title = [NSString stringWithFormat:
	    @"swap priming… %llds (hot %lldMB / cold %lldMB)",
	    ms / 1000, h, c];
}

- (void)notifyTitle:(NSString *)title msg:(NSString *)msg
{
	NSString *et = [title stringByReplacingOccurrencesOfString:@"\""
	    withString:@"\\\""];
	NSString *em = [msg stringByReplacingOccurrencesOfString:@"\""
	    withString:@"\\\""];
	NSString *cmd = [NSString stringWithFormat:
	    @"osascript -e 'display notification \"%@\" with title \"%@\"'",
	    em, et];
	(void)system([cmd UTF8String]);
}

- (void)finishPrime
{
	if (atomic_load(&g_done) == 1) {
		g_status.button.image =
		    [NSImage imageWithSystemSymbolName:@"checkmark.circle.fill"
		        accessibilityDescription:@"Swap active"];
		g_status.button.image.template = YES;
		g_statusItem.title = @"Swap active — escape valve engaged";
		g_status.button.toolTip = @"swap active";
		[self notifyTitle:@"Swap active"
		    msg:@"Escape valve engaged. WIRED display allocations can no longer be starved."];
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
		    (int64_t)(2.0 * NSEC_PER_SEC)),
		    dispatch_get_main_queue(), ^{
			[NSApp terminate:nil];
		});
	} else {
		g_status.button.image =
		    [NSImage imageWithSystemSymbolName:@"exclamationmark.triangle.fill"
		        accessibilityDescription:@"Swap prime timed out"];
		g_status.button.image.template = YES;
		g_statusItem.title = @"Swap prime timed out — no swap";
		g_status.button.toolTip = @"swap not activated";
		[self notifyTitle:@"Swap prime timed out"
		    msg:@"Memory load ran but swap did not engage in time. See /tmp/swapprime.log for the final state."];
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
		    (int64_t)(6.0 * NSEC_PER_SEC)),
		    dispatch_get_main_queue(), ^{
			[NSApp terminate:nil];
		});
	}
}

- (void)quitApp:(id)sender
{
	[NSApp terminate:nil];
}

@end

/* ---- self-install / self-uninstall (CLI modes; no build script involved) ---- */

static int
install_app(void)
{
	@autoreleasepool {
		NSString *src = [[NSBundle mainBundle] bundlePath];
		if (![src hasSuffix:@".app"]) {
			fprintf(stderr,
			    "install: must be run from inside a .app bundle "
			    "(e.g. SwapPrime.app/Contents/MacOS/SwapPrime --install)\n");
			return 2;
		}
		NSString *home = NSHomeDirectory();
		NSString *dest = [home stringByAppendingPathComponent:
		    @"Applications/SwapPrime.app"];
		NSString *label = @"tech.imvictor.swapprime";
		NSString *agentDir = [home stringByAppendingPathComponent:
		    @"Library/LaunchAgents"];
		NSString *agent = [agentDir stringByAppendingPathComponent:
		    [label stringByAppendingString:@".plist"]];
		NSString *installedBin = [dest stringByAppendingPathComponent:
		    @"Contents/MacOS/SwapPrime"];
		NSFileManager *fm = [NSFileManager defaultManager];
		int uid = (int)getuid();

		if (![src isEqualToString:dest]) {
			[fm removeItemAtPath:dest error:nil];
			NSError *err = nil;
			if (![fm copyItemAtPath:src toPath:dest error:&err]) {
				fprintf(stderr, "install: copy %s -> %s failed: %s\n",
				    src.UTF8String, dest.UTF8String,
				    err.localizedDescription.UTF8String);
				return 1;
			}
		}

		[fm createDirectoryAtPath:agentDir withIntermediateDirectories:YES
		    attributes:nil error:nil];
		NSString *plist = [NSString stringWithFormat:
		    @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
		    @"<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
		    @"\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
		    @"<plist version=\"1.0\">\n"
		    @"<dict>\n"
		    @"    <key>Label</key><string>%@</string>\n"
		    @"    <key>ProgramArguments</key>\n"
		    @"    <array>\n"
		    @"        <string>%@</string>\n"
		    @"        <string>--timeout</string>\n"
		    @"        <string>60</string>\n"
		    @"    </array>\n"
		    @"    <key>RunAtLoad</key><true/>\n"
		    @"    <key>StandardOutPath</key><string>/tmp/swapprime.log</string>\n"
		    @"    <key>StandardErrorPath</key><string>/tmp/swapprime.err.log</string>\n"
		    @"</dict>\n"
		    @"</plist>\n", label, installedBin];
		if (![plist writeToFile:agent atomically:YES
		    encoding:NSUTF8StringEncoding error:nil]) {
			fprintf(stderr, "install: cannot write %s\n", agent.UTF8String);
			return 1;
		}

		char cmd[2048];
		snprintf(cmd, sizeof(cmd),
		    "launchctl bootout gui/%d \"%s\" 2>/dev/null || "
		    "launchctl unload \"%s\" 2>/dev/null || true; "
		    "launchctl bootstrap gui/%d \"%s\" 2>/dev/null || "
		    "launchctl load \"%s\"",
		    uid, agent.UTF8String, agent.UTF8String,
		    uid, agent.UTF8String, agent.UTF8String);
		if (system(cmd) != 0) {
			fprintf(stderr,
			    "install: launchctl failed to load %s\n", agent.UTF8String);
			return 1;
		}

		printf("installed: %s\n", dest.UTF8String);
		printf("agent:     %s (loads every login)\n", agent.UTF8String);
		printf("logs:      /tmp/swapprime.log\n");
		return 0;
	}
}

static int
uninstall_app(void)
{
	@autoreleasepool {
		NSString *home = NSHomeDirectory();
		NSString *label = @"tech.imvictor.swapprime";
		NSString *agent = [[home stringByAppendingPathComponent:
		    @"Library/LaunchAgents"] stringByAppendingPathComponent:
		    [label stringByAppendingString:@".plist"]];
		NSString *dest = [home stringByAppendingPathComponent:
		    @"Applications/SwapPrime.app"];
		int uid = (int)getuid();

		char cmd[1024];
		snprintf(cmd, sizeof(cmd),
		    "launchctl bootout gui/%d \"%s\" 2>/dev/null || "
		    "launchctl unload \"%s\" 2>/dev/null || true",
		    uid, agent.UTF8String, agent.UTF8String);
		(void)system(cmd);

		NSFileManager *fm = [NSFileManager defaultManager];
		[fm removeItemAtPath:agent error:nil];
		[fm removeItemAtPath:dest error:nil];
		printf("uninstalled.\n");
		return 0;
	}
}

/* Installed = app present in /Applications or ~/Applications AND its
 * LaunchAgent plist exists. Startup prompts for a self-install when not. */
static BOOL
is_installed(void)
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *home = NSHomeDirectory();
	BOOL inSystem = [fm fileExistsAtPath:@"/Applications/SwapPrime.app"];
	BOOL inUser = [fm fileExistsAtPath:
	    [home stringByAppendingPathComponent:@"Applications/SwapPrime.app"]];
	BOOL agent = [fm fileExistsAtPath:
	    [[home stringByAppendingPathComponent:@"Library/LaunchAgents"]
	        stringByAppendingPathComponent:@"tech.imvictor.swapprime.plist"]];
	return (inSystem || inUser) && agent;
}

int
main(int argc, char **argv)
{
	int mode = 0; /* 0 = prime, 1 = install, 2 = uninstall */

	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--timeout") == 0 && i + 1 < argc) {
			g_timeout_s = atof(argv[++i]);
		} else if (strcmp(argv[i], "--hot") == 0 && i + 1 < argc) {
			g_hot_mb = (size_t)atoll(argv[++i]);
		} else if (strcmp(argv[i], "--cold") == 0 && i + 1 < argc) {
			g_cold_mb = (size_t)atoll(argv[++i]);
		} else if (strcmp(argv[i], "--min-free-mb") == 0 && i + 1 < argc) {
			g_min_free_mb = atoll(argv[++i]);
		} else if (strcmp(argv[i], "--install") == 0) {
			mode = 1;
		} else if (strcmp(argv[i], "--uninstall") == 0) {
			mode = 2;
		} else {
			fprintf(stderr,
			    "usage: %s [--timeout SEC] [--hot MB] [--cold MB] "
			    "[--min-free-mb MB]\n"
			    "       %s --install    copy to ~/Applications, install "
			    "login LaunchAgent\n"
			    "       %s --uninstall  remove LaunchAgent + ~/Applications "
			    "copy\n"
			    "       --hot/--cold default to auto (scaled to physical "
			    "RAM)\n",
			    argv[0], argv[0], argv[0]);
			return 2;
		}
	}

	if (mode == 1) {
		return install_app();
	}
	if (mode == 2) {
		return uninstall_app();
	}
	resolve_sizes();

	@autoreleasepool {
		NSApplication *app = [NSApplication sharedApplication];
		[app setActivationPolicy:NSApplicationActivationPolicyAccessory];
		AppDelegate *delegate = [[AppDelegate alloc] init];
		app.delegate = delegate;
		[app run];
	}
	return 0;
}
