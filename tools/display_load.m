/*
 * display_load.m — synthetic display activity for issue #24 validation.
 *
 * Continuously animates a Core Animation layer, so WindowServer must
 * allocate IOSurface frames every frame — exactly the WIRED allocation that
 * stalls under guest memory pressure. If this window keeps animating while
 * free is pinned near zero (with swap active), the swap escape-valve
 * hypothesis holds; if it freezes, the stall reproduced.
 *
 * Compile: clang -fobjc-arc display_load.m -framework Cocoa \
 *              -framework QuartzCore -Wno-deprecated-declarations -o display_load
 */
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include <math.h>
#include <unistd.h>

int
main(void)
{
	@autoreleasepool {
		NSApplication *app = [NSApplication sharedApplication];
		[app setActivationPolicy:NSApplicationActivationPolicyRegular];
		[app activateIgnoringOtherApps:YES];

		NSWindow *win = [[NSWindow alloc]
		    initWithContentRect:NSMakeRect(0, 0, 480, 360)
		    styleMask:NSWindowStyleMaskTitled
		    backing:NSBackingStoreBuffered
		    defer:NO];
		NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, 360)];
		view.wantsLayer = YES;
		[win setContentView:view];
		[win makeKeyAndOrderFront:nil];

		CALayer *layer = [CALayer layer];
		layer.frame = CGRectMake(0, 0, 160, 160);
		layer.backgroundColor = [[NSColor systemRedColor] CGColor];
		[view.layer addSublayer:layer];

		CABasicAnimation *move = [CABasicAnimation animationWithKeyPath:@"position"];
		move.fromValue = [NSValue valueWithPoint:NSMakePoint(80, 80)];
		move.toValue = [NSValue valueWithPoint:NSMakePoint(400, 280)];
		move.duration = 1.0;
		move.autoreverses = YES;
		move.repeatCount = INFINITY;
		[layer addAnimation:move forKey:@"move"];

		CABasicAnimation *rot =
		    [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
		rot.fromValue = @0.0;
		rot.toValue = @(2.0 * M_PI);
		rot.duration = 2.0;
		rot.repeatCount = INFINITY;
		[layer addAnimation:rot forKey:@"rot"];

		printf("display_load: animating red square window, pid=%d "
		    "(kill %d)\n", (int)getpid(), (int)getpid());
		fflush(stdout);

		[app run];
	}
	return 0;
}
