// Encore's Now Playing helper.
//
// macOS only hands the system's Now Playing info to Apple's own programs, so
// this library is loaded into /usr/bin/perl (see bridge.pl), which is allowed
// to read it. It prints one line of JSON to stdout whenever the song, the
// artwork or the play state changes, and reads simple commands from stdin:
//
//   toggle | play | pause | next | prev | seek <seconds>
//
// It exits when stdin closes, so it never outlives the app.

#import <Foundation/Foundation.h>
#import <dlfcn.h>

typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRGetPlayingFn)(dispatch_queue_t, void (^)(BOOL));
typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef BOOL (*MRSendCommandFn)(uint32_t, NSDictionary *);
typedef void (*MRSetElapsedFn)(double);

static MRGetInfoFn getInfo;
static MRGetPlayingFn getPlaying;
static MRSendCommandFn sendCommand;
static MRSetElapsedFn setElapsed;

static NSString *lastArtworkKey = @"";
static NSString *lastLine = @"";
static BOOL emitPending = NO;

enum { kPlay = 0, kPause = 1, kToggle = 2, kNext = 4, kPrevious = 5 };

static NSString *sourceBundleID(void) {
    @try {
        Class request = NSClassFromString(@"MRNowPlayingRequest");
        id client = [[request valueForKey:@"localNowPlayingPlayerPath"] valueForKey:@"client"];
        id parent = [client valueForKey:@"parentApplicationBundleIdentifier"];
        if ([parent isKindOfClass:NSString.class] && [parent length] > 0) return parent;
        id own = [client valueForKey:@"bundleIdentifier"];
        if ([own isKindOfClass:NSString.class]) return own;
    } @catch (__unused NSException *e) {}
    return @"";
}

static NSString *text(NSDictionary *info, NSString *key) {
    id value = info[key];
    return [value isKindOfClass:NSString.class] ? value : @"";
}

static double number(NSDictionary *info, NSString *key) {
    id value = info[key];
    return [value isKindOfClass:NSNumber.class] ? [value doubleValue] : 0;
}

static void emit(void) {
    getInfo(dispatch_get_main_queue(), ^(NSDictionary *info) {
        getPlaying(dispatch_get_main_queue(), ^(BOOL playing) {
            NSMutableDictionary *out = [NSMutableDictionary dictionary];
            out[@"title"] = text(info, @"kMRMediaRemoteNowPlayingInfoTitle");
            out[@"artist"] = text(info, @"kMRMediaRemoteNowPlayingInfoArtist");
            out[@"album"] = text(info, @"kMRMediaRemoteNowPlayingInfoAlbum");
            out[@"duration"] = @(number(info, @"kMRMediaRemoteNowPlayingInfoDuration"));
            out[@"elapsed"] = @(number(info, @"kMRMediaRemoteNowPlayingInfoElapsedTime"));
            out[@"playing"] = @(playing);
            out[@"bundleID"] = sourceBundleID();

            double rate = number(info, @"kMRMediaRemoteNowPlayingInfoPlaybackRate");
            out[@"rate"] = @(playing ? (rate > 0 ? rate : 1) : 0);

            NSDate *stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
            if ([stamp isKindOfClass:NSDate.class]) out[@"timestamp"] = @(stamp.timeIntervalSince1970);

            NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
            NSString *artKey = @"";
            if ([art isKindOfClass:NSData.class] && art.length > 0) {
                artKey = [NSString stringWithFormat:@"%@-%lu",
                          info[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"] ?: @"",
                          (unsigned long)art.length];
                // The picture is big, so only send it when it changes.
                if (![artKey isEqualToString:lastArtworkKey]) {
                    out[@"artwork"] = [art base64EncodedStringWithOptions:0];
                }
            }
            out[@"artworkKey"] = artKey;
            lastArtworkKey = artKey;

            NSData *json = [NSJSONSerialization dataWithJSONObject:out
                                                           options:NSJSONWritingSortedKeys
                                                             error:nil];
            if (!json) return;
            NSString *line = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
            if ([line isEqualToString:lastLine]) return;
            lastLine = line;
            fputs(line.UTF8String, stdout);
            fputc('\n', stdout);
            fflush(stdout);
        });
    });
}

// Changes arrive in bursts (title, then artwork, then play state), so wait a
// moment and report once.
static void scheduleEmit(void) {
    if (emitPending) return;
    emitPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        emitPending = NO;
        emit();
    });
}

static void handleCommand(NSString *line) {
    if ([line isEqualToString:@"toggle"]) sendCommand(kToggle, nil);
    else if ([line isEqualToString:@"play"]) sendCommand(kPlay, nil);
    else if ([line isEqualToString:@"pause"]) sendCommand(kPause, nil);
    else if ([line isEqualToString:@"next"]) sendCommand(kNext, nil);
    else if ([line isEqualToString:@"prev"]) sendCommand(kPrevious, nil);
    else if ([line hasPrefix:@"seek "]) setElapsed(MAX(0, [[line substringFromIndex:5] doubleValue]));
    scheduleEmit();
}

void bridge_run(void) {
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!mr) { fprintf(stderr, "encore: MediaRemote is missing\n"); exit(2); }

    getInfo = dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    getPlaying = dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    sendCommand = dlsym(mr, "MRMediaRemoteSendCommand");
    setElapsed = dlsym(mr, "MRMediaRemoteSetElapsedTime");
    MRRegisterFn registerForNotifications = dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!getInfo || !getPlaying || !sendCommand || !setElapsed || !registerForNotifications) {
        fprintf(stderr, "encore: this macOS version changed MediaRemote\n");
        exit(2);
    }

    registerForNotifications(dispatch_get_main_queue());
    for (NSString *name in @[
        @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
    ]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(__unused NSNotification *note) { scheduleEmit(); }];
    }

    // A slow safety net in case a change notification is ever missed.
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), 5 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{ scheduleEmit(); });
    dispatch_resume(timer);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        char buffer[256];
        while (fgets(buffer, sizeof buffer, stdin)) {
            NSString *line = [[NSString stringWithUTF8String:buffer]
                              stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (line.length == 0) continue;
            dispatch_async(dispatch_get_main_queue(), ^{ handleCommand(line); });
        }
        exit(0); // The app went away.
    });

    CFRunLoopRun();
}
