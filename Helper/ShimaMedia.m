// Now Playing bridge.
//
// Since macOS 15.4, MediaRemote only answers processes Apple has entitled.
// /usr/bin/perl is one of them, so the app runs this dylib inside perl
// (see MediaController.swift) and talks to it over stdin/stdout:
//   stdout: one JSON object per line whenever playback state changes
//   stdin:  "play" | "pause" | "toggle" | "next" | "prev" | "seek <seconds>"

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*GetPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*GetClientFn)(dispatch_queue_t, void (^)(id));
typedef NSString *(*ClientStringFn)(id);
typedef void (*RegisterFn)(dispatch_queue_t);
typedef Boolean (*SendCommandFn)(int, NSDictionary *);
typedef void (*SetElapsedFn)(double);

enum { MRPlay = 0, MRPause = 1, MRTogglePlayPause = 2, MRNextTrack = 4, MRPreviousTrack = 5 };

static GetInfoFn MRGetInfo;
static GetPlayingFn MRGetPlaying;
static GetClientFn MRGetClient;
static ClientStringFn MRClientBundle;
static ClientStringFn MRClientParentBundle;
static SendCommandFn MRSendCommand;
static SetElapsedFn MRSetElapsed;

static NSString *lastState;
static NSString *lastArtKey;
static dispatch_source_t pollTimer;

static NSString *artKeyFor(NSData *data) {
    if (data.length == 0) return @"";
    const uint8_t *bytes = data.bytes;
    uint64_t hash = 1469598103934665603ULL;
    for (NSUInteger i = 0; i < data.length; i++) {
        hash ^= bytes[i];
        hash *= 1099511628211ULL;
    }
    return [NSString stringWithFormat:@"%llx-%lu", hash, (unsigned long)data.length];
}

static void writeLine(NSDictionary *payload) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

// Perl's run loop never drains an autorelease pool, so every callback below wraps its work in one;
// without them each refresh leaked its dictionaries and strings.
static void refresh(void) {
    dispatch_queue_t q = dispatch_get_main_queue();
    MRGetInfo(q, ^(NSDictionary *info) {
        MRGetPlaying(q, ^(Boolean playing) {
            MRGetClient(q, ^(id client) { @autoreleasepool {
                NSMutableDictionary *state = [NSMutableDictionary dictionary];
                state[@"title"] = info[@"kMRMediaRemoteNowPlayingInfoTitle"] ?: @"";
                state[@"artist"] = info[@"kMRMediaRemoteNowPlayingInfoArtist"] ?: @"";
                state[@"album"] = info[@"kMRMediaRemoteNowPlayingInfoAlbum"] ?: @"";
                state[@"duration"] = info[@"kMRMediaRemoteNowPlayingInfoDuration"] ?: @0;
                state[@"elapsed"] = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] ?: @0;
                state[@"rate"] = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] ?: @(playing ? 1 : 0);
                NSDate *timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                state[@"timestamp"] = @(timestamp ? timestamp.timeIntervalSince1970 : 0);
                state[@"playing"] = @(playing ? YES : NO);

                NSString *bundle = nil;
                if (client && MRClientParentBundle) bundle = MRClientParentBundle(client);
                if (client && !bundle && MRClientBundle) bundle = MRClientBundle(client);
                state[@"bundle"] = bundle ?: @"";

                NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                NSString *artKey = artKeyFor(art);
                state[@"artworkKey"] = artKey;

                NSData *stateJSON = [NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingSortedKeys error:nil];
                NSString *stateString = [[NSString alloc] initWithData:stateJSON encoding:NSUTF8StringEncoding];
                BOOL artChanged = lastArtKey == nil || ![artKey isEqualToString:lastArtKey];
                if (!artChanged && [stateString isEqualToString:lastState]) return;

                lastState = stateString;
                if (artChanged) {
                    state[@"artwork"] = art.length ? [art base64EncodedStringWithOptions:0] : @"";
                    lastArtKey = artKey;
                }
                writeLine(state);
            }});
        });
    });
}

static void handleCommand(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    NSString *command = parts.firstObject;
    @autoreleasepool {
    if ([command isEqualToString:@"play"]) MRSendCommand(MRPlay, nil);
    else if ([command isEqualToString:@"pause"]) MRSendCommand(MRPause, nil);
    else if ([command isEqualToString:@"toggle"]) MRSendCommand(MRTogglePlayPause, nil);
    else if ([command isEqualToString:@"next"]) MRSendCommand(MRNextTrack, nil);
    else if ([command isEqualToString:@"prev"]) MRSendCommand(MRPreviousTrack, nil);
    else if ([command isEqualToString:@"seek"] && parts.count > 1 && MRSetElapsed) MRSetElapsed(parts[1].doubleValue);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ refresh(); });
}

// Called from perl as an XSUB; the (interpreter, cv) arguments perl passes are ignored.
void shima_media_run(void) {
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!mr) {
        fprintf(stderr, "MediaRemote unavailable\n");
        return;
    }
    MRGetInfo = (GetInfoFn)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    MRGetPlaying = (GetPlayingFn)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    MRGetClient = (GetClientFn)dlsym(mr, "MRMediaRemoteGetNowPlayingClient");
    MRClientBundle = (ClientStringFn)dlsym(mr, "MRNowPlayingClientGetBundleIdentifier");
    MRClientParentBundle = (ClientStringFn)dlsym(mr, "MRNowPlayingClientGetParentAppBundleIdentifier");
    MRSendCommand = (SendCommandFn)dlsym(mr, "MRMediaRemoteSendCommand");
    MRSetElapsed = (SetElapsedFn)dlsym(mr, "MRMediaRemoteSetElapsedTime");
    if (!MRGetInfo || !MRGetPlaying || !MRGetClient || !MRSendCommand) {
        fprintf(stderr, "MediaRemote symbols missing\n");
        return;
    }

    RegisterFn registerForNotifications = (RegisterFn)dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (registerForNotifications) registerForNotifications(dispatch_get_main_queue());
    for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) { @autoreleasepool { refresh(); } }];
    }

    // Changes arrive as notifications; a slow, coalescable safety check catches any that go missing.
    pollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(pollTimer, DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC, 3 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(pollTimer, ^{ @autoreleasepool { refresh(); } });
    dispatch_resume(pollTimer);

    [NSThread detachNewThreadWithBlock:^{
        char buffer[512];
        while (fgets(buffer, sizeof buffer, stdin)) {
            @autoreleasepool {
                NSString *line = [[NSString stringWithUTF8String:buffer]
                    stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                dispatch_async(dispatch_get_main_queue(), ^{ handleCommand(line); });
            }
        }
        exit(0); // the app closed our stdin: it quit or restarted us
    }];

    CFRunLoopRun();
}
