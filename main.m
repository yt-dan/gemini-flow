// GeminiFlow: Google-compliant Wispr Flow alternative for macOS
// Hotkeyed to the Fn key (hold to talk, or double-tap for hands-free).
// Runs on Gemini Live Transcribe (gemini-3.5-transcribe-live) over WebSocket, with automatic REST and Apple On-Device fallback.

#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Security/Security.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <mach/mach_time.h>

static NSString * const kPrefApiKey = @"GeminiFlow_ApiKey";
static NSString * const kPrefSelectedModel = @"GeminiFlow_SelectedModel"; // legacy model choice; cleared on launch
static NSString * const kPrefEngineMode = @"GeminiFlow_EngineMode"; // @"gemini" or @"ondevice"
static NSString * const kDefaultModel = @"gemini-3.5-flash-lite";          // REST safety net only (Live failure)
static NSString * const kDefaultLiveModel = @"gemini-3.5-transcribe-live"; // THE engine: streaming, text ~0.4 s after release

static void GFLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2); // file logger, defined below

// How the Live socket authenticates (backlog 15; see GFLiveWebSocketRequest)
typedef NS_ENUM(NSInteger, GFLiveAuthMode) {
    GFLiveAuthUntested = 0,   // header auth not yet confirmed this run
    GFLiveAuthHeaderOK = 1,   // a header-auth session reached setupComplete: never fall back
    GFLiveAuthKeyInURL = 2,   // header auth was rejected and the key-in-URL retry worked: keep using it this run
};

#pragma mark - Structured Changelog Data (Foundation-only; synced one-way to iOS via changelog.json)

static BOOL GFStringHasForbiddenDash(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return NO;
    return [s rangeOfString:@"\u2014"].location != NSNotFound || [s rangeOfString:@"\u2013"].location != NSNotFound;
}

static NSArray<NSDictionary *> *GFBuiltInChangelogEntries(void) {
    static NSArray<NSDictionary *> *entries = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        entries = @[
            @{@"cycle": @(36), @"scope": @"engine", @"timestamp": @"13 Nov \u00B7 11:00", @"title": @"Repeated phrases and mid-thought restarts cleaned up", @"highlights": @[@"Keeps one copy when a phrase is said twice in a row while you gather a thought ('with my with my new app', 'I would I would', 'will do will do'), and when you restart after one dropped word ('I also want you to give some I also want you to give updates').", @"Leaves deliberate repeats alone: emphasis after a comma ('I know, I know'), courtesy phrases, names, number runs and idioms such as 'again and again'. Runs on your Mac in well under a millisecond."]},
            @{@"cycle": @(35), @"scope": @"mac", @"timestamp": @"13 Nov \u00B7 10:30", @"title": @"Brand refresh shared with GeminiFlow for iOS & cleaner windows", @"highlights": @[@"Adopted the iOS brand mark (three slanted bars) for the menu bar icon and the in-app icon, and the GeminiFlow wordmark typography in window headers.", @"Moved the Changelog and Setup titles below the window buttons and removed the trailing dots from menu items and buttons."]},
            @{@"cycle": @(34), @"scope": @"mac", @"timestamp": @"13 Nov \u00B7 09:40", @"title": @"Mac-native Changelog (Cmd+L), closable Setup window (Cmd+P) & iOS sync", @"highlights": @[@"Added a clean, flat Mac-native Changelog window (Cmd+L, Cmd+W, Esc) with inline titlebar search, Engine filter, collapsible timeline, and canonical changelog.json for iOS sync.", @"Replaced the modal Permissions alert with a closable Setup & Permissions window (Cmd+P) featuring live API key, Microphone, Accessibility, Speech, and Fn-key status indicators plus API key paste sanitization."]},
            @{@"cycle": @(33), @"scope": @"engine", @"timestamp": @"13 Nov \u00B7 09:09", @"title": @"Silent-press prompt-echo guard & low-evidence silence net", @"highlights": @[@"Stopped silent presses with 1 to 4 stray on-device noise characters from pasting echoed REST instructions ('Transcribe and clean up this audio dictation.').", @"Instructed the REST fallback model to return an empty result on silence or background noise and routed empty low-evidence responses cleanly to No speech."]},
            @{@"cycle": @(32), @"scope": @"engine", @"timestamp": @"12 Nov \u00B7 16:46", @"title": @"Noise-relative silence detection & REST plausibility safety net", @"highlights": @[@"Measured speech evidence relative to each press's 20th-percentile room noise floor so quiet-room taps and holds end immediately as No speech instead of calling REST.", @"Added a numbers-only REST plausibility net rejecting hallucinated zero-timestamps ('00:00') and runaway text lengths on silent audio."]},
            @{@"cycle": @(31), @"scope": @"engine", @"timestamp": @"12 Nov \u00B7 15:16", @"title": @"Zero word loss across slow split turns", @"highlights": @[@"Held voiced audio (with 0.3s pre-roll) behind any in-flight split turn until generationComplete arrives instead of reopening early after 1.5s, eliminating dropped seam words.", @"Raised the T26 multi-close hands-free recall gate from 0.95 to 0.99."]},
            @{@"cycle": @(30), @"scope": @"mac", @"timestamp": @"12 Nov \u00B7 13:16", @"title": @"Hands-free HUD indicator redesign", @"highlights": @[@"Replaced the outer mint rim and glow in locked hands-free mode with a crisp 7px green indicator dot on a soft inner halo and solid green waveform bars inside the pill.", @"Kept hold-to-talk, Thinking, and notice pill renders pixel-identical."]},
            @{@"cycle": @(29), @"scope": @"engine", @"timestamp": @"12 Nov \u00B7 12:01", @"title": @"Planned Live session rotation before the 10-minute server cap", @"highlights": @[@"Proactively rotates the Gemini Live WebSocket at the first quiet split point after 8.5 minutes with zero resent audio and zero seam duplicates.", @"Treats server closes after 9.5 minutes (or after goAway) as planned rotations that do not consume the 2-reconnect drop budget."]},
            @{@"cycle": @(28), @"scope": @"mac", @"timestamp": @"12 Nov \u00B7 09:10", @"title": @"Accurate 4-gram duplicate-phrase test gate", @"highlights": @[@"Updated duplicated_phrases() in the test runner to flag 4-grams only when they appear at least twice in the output and more often than in expected text, eliminating false positives on minor recognizer phrasing variants."]},
            @{@"cycle": @(27), @"scope": @"engine", @"timestamp": @"11 Nov \u00B7 19:57", @"title": @"5- and 10-minute marathon dictation suite & privacy-safe press stats", @"highlights": @[@"Added opt-in 5-minute and 10-minute continuous Live dictation gates (T23) and scaled the e2e watchdog for multi-minute sessions.", @"Logged one numbers-only Press stats line per dictation (audio duration, Live session age, reconnects, and activity count)."]},
            @{@"cycle": @(26), @"scope": @"mac", @"timestamp": @"11 Nov \u00B7 17:35", @"title": @"Visual distinction for locked hands-free HUD & offscreen PNG renderer", @"highlights": @[@"Added visual differentiation between hold-to-talk and double-tap locked hands-free mode on the floating HUD pill.", @"Added --render-hud-png for deterministic 2x offscreen HUD verification."]},
            @{@"cycle": @(25), @"scope": @"engine", @"timestamp": @"11 Nov \u00B7 15:37", @"title": @"Release-cushion telemetry & atomic test audio cache", @"highlights": @[@"Logged numbers-only Fn-up release cushion coverage (hostTime reach past key release and post-release RMS) to measure real hardware buffer lag.", @"Made test runner TTS and WAV cache writes atomic so interrupted runs never leave truncated audio fixtures."]},
            @{@"cycle": @(24), @"scope": @"engine", @"timestamp": @"11 Nov \u00B7 13:47", @"title": @"Instant completion when releasing Fn between Live turns", @"highlights": @[@"Finished Live dictations immediately on key release (~135ms instead of ~570ms) when all prior speech was already finalized at a pause split and no uncovered speech remains."]},
            @{@"cycle": @(23), @"scope": @"engine", @"timestamp": @"11 Nov \u00B7 11:55", @"title": @"Last-sentence question punctuation & filler-like cleanup", @"highlights": @[@"Judged trailing '?' vs '.' from the final sentence rather than earlier clauses in multi-sentence dictations.", @"Removed stray filler 'like' immediately preceding a stripped 'kind of' or 'sort of' hedge."]},
            @{@"cycle": @(22), @"scope": @"engine", @"timestamp": @"11 Nov \u00B7 09:56", @"title": @"Context-aware 'kind of' and 'sort of' filler removal", @"highlights": @[@"Stripped 'kind of' and 'sort of' only when set off as spoken pauses or adjacent to vocal fillers, preserving meaningful uses like 'what kind of car' and 'sort of works'."]},
            @{@"cycle": @(21), @"scope": @"engine", @"timestamp": @"10 Nov \u00B7 19:36", @"title": @"Pronoun capitalization, mixed-case brands & grammatical doubles", @"highlights": @[@"Protected 'i.e.', dotfiles ('.env'), URLs, and mixed-case names ('iPhone', 'macOS') during capitalization and punctuation cleanup.", @"Collapsed single-word stutters ('the the', 'I I') while keeping grammatical doubles ('had had', 'that that', 'very very')."]},
            @{@"cycle": @(20), @"scope": @"engine", @"timestamp": @"10 Nov \u00B7 17:59", @"title": @"Header-only API key auth & automatic log redaction", @"highlights": @[@"Moved Gemini API key authentication from query URLs into the x-goog-api-key request header across Live WebSocket and REST calls.", @"Added defensive secret scrubbing in GFLog and static binary/request verification (T19)."]}
        ];
    });
    return entries;
}

static BOOL GFChangelogValidateEntries(NSArray<NSDictionary *> *entries, NSString **outReason) {
    if (![entries isKindOfClass:[NSArray class]] || entries.count == 0) {
        if (outReason) *outReason = @"entries must be a non-empty array";
        return NO;
    }
    NSInteger prevCycle = -1;
    for (NSUInteger i = 0; i < entries.count; i++) {
        NSDictionary *e = entries[i];
        if (![e isKindOfClass:[NSDictionary class]]) {
            if (outReason) *outReason = @"entry is not a dictionary";
            return NO;
        }
        NSNumber *cycNum = e[@"cycle"];
        NSString *scope = e[@"scope"];
        NSString *ts = e[@"timestamp"];
        NSString *title = e[@"title"];
        NSArray *highlights = e[@"highlights"];
        if (![cycNum isKindOfClass:[NSNumber class]] || cycNum.integerValue <= 0) {
            if (outReason) *outReason = @"invalid cycle number";
            return NO;
        }
        NSInteger cyc = cycNum.integerValue;
        if (i > 0 && cyc != prevCycle - 1) {
            if (outReason) *outReason = [NSString stringWithFormat:@"non-contiguous cycle %ld after %ld", (long)cyc, (long)prevCycle];
            return NO;
        }
        prevCycle = cyc;
        if (![scope isKindOfClass:[NSString class]] || (![scope isEqualToString:@"engine"] && ![scope isEqualToString:@"mac"])) {
            if (outReason) *outReason = @"scope must be engine or mac";
            return NO;
        }
        if (![ts isKindOfClass:[NSString class]] || [ts stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length == 0 || GFStringHasForbiddenDash(ts)) {
            if (outReason) *outReason = @"invalid or dashed timestamp";
            return NO;
        }
        if (![title isKindOfClass:[NSString class]] || [title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length == 0 || GFStringHasForbiddenDash(title)) {
            if (outReason) *outReason = @"invalid or dashed title";
            return NO;
        }
        if (![highlights isKindOfClass:[NSArray class]] || highlights.count == 0) {
            if (outReason) *outReason = @"highlights must be non-empty";
            return NO;
        }
        for (id h in highlights) {
            if (![h isKindOfClass:[NSString class]] || [(NSString *)h stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length == 0 || GFStringHasForbiddenDash((NSString *)h)) {
                if (outReason) *outReason = @"invalid or dashed highlight";
                return NO;
            }
        }
    }
    return YES;
}

static NSArray<NSDictionary *> *GFChangelogParseJSONData(NSData *data) {
    if (!data || data.length == 0) return nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSArray *raw = nil;
    if ([root isKindOfClass:[NSDictionary class]]) {
        raw = ((NSDictionary *)root)[@"entries"];
    } else if ([root isKindOfClass:[NSArray class]]) {
        raw = (NSArray *)root;
    }
    if (!GFChangelogValidateEntries(raw, NULL)) return nil;
    return raw;
}

static NSArray<NSDictionary *> *GFChangelogLoadEntriesFromPaths(NSArray<NSString *> *paths) {
    NSArray<NSDictionary *> *builtIn = GFBuiltInChangelogEntries();
    NSInteger builtInLatest = [builtIn.firstObject[@"cycle"] integerValue];
    for (NSString *p in paths) {
        if (![p isKindOfClass:[NSString class]] || p.length == 0) continue;
        NSData *d = [NSData dataWithContentsOfFile:p];
        NSArray<NSDictionary *> *parsed = GFChangelogParseJSONData(d);
        if (parsed && [parsed.firstObject[@"cycle"] integerValue] >= builtInLatest) {
            return parsed;
        }
    }
    return builtIn;
}

static NSArray<NSDictionary *> *GFChangelogFilterEntries(NSArray<NSDictionary *> *entries, NSString *query, NSString *scopeFilter) {
    if (!entries) return @[];
    NSString *scopeTrim = [scopeFilter ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;
    NSString *trimmed = [query ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    BOOL hasScope = scopeTrim.length > 0 && ![scopeTrim isEqualToString:@"all"];
    if (!hasScope && trimmed.length == 0) return entries;

    NSInteger exactHashCycle = -1;
    if ([trimmed hasPrefix:@"#"] && trimmed.length > 1) {
        NSString *digits = [trimmed substringFromIndex:1];
        NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
        if ([digits rangeOfCharacterFromSet:nonDigits].location == NSNotFound) {
            exactHashCycle = digits.integerValue;
        }
    }

    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (NSDictionary *e in entries) {
        NSString *eScope = [e[@"scope"] lowercaseString];
        if (hasScope && ![eScope isEqualToString:scopeTrim]) continue;
        if (trimmed.length == 0) {
            [out addObject:e];
            continue;
        }
        NSInteger cyc = [e[@"cycle"] integerValue];
        if (exactHashCycle > 0) {
            if (cyc == exactHashCycle) [out addObject:e];
            continue;
        }
        NSString *cycStr = [NSString stringWithFormat:@"%ld", (long)cyc];
        if ([cycStr isEqualToString:trimmed] ||
            [e[@"title"] localizedCaseInsensitiveContainsString:trimmed] ||
            [eScope localizedCaseInsensitiveContainsString:trimmed]) {
            [out addObject:e];
            continue;
        }
        for (NSString *h in e[@"highlights"]) {
            if ([h localizedCaseInsensitiveContainsString:trimmed]) {
                [out addObject:e];
                break;
            }
        }
    }
    return out;
}

// Sanitizes pasted API keys (.env assignments, export lines, quotes, curl snippets, query URLs, stray whitespace/newlines).
// Returns @"" if input is empty or a keyless http(s) URL (e.g. https://aistudio.google.com/apikey) so an existing key is never clobbered.
static NSString *GFSanitizeApiKeyInput(NSString *raw) {
    if (![raw isKindOfClass:[NSString class]] || raw.length == 0) return @"";
    NSString *s = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length == 0) return @"";

    // Extract ?key=AIza... or x-goog-api-key: ... if user pasted a curl command or URL snippet
    static NSRegularExpression *urlKeyRe, *hdrKeyRe, *envRe;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        urlKeyRe = [NSRegularExpression regularExpressionWithPattern:@"[?&](?:api_?)?key=([A-Za-z0-9_\\-]{16,})" options:NSRegularExpressionCaseInsensitive error:nil];
        hdrKeyRe = [NSRegularExpression regularExpressionWithPattern:@"x-goog-api-key[\"']?\\s*[:=]\\s*[\"']?([A-Za-z0-9_\\-]{16,})" options:NSRegularExpressionCaseInsensitive error:nil];
        envRe    = [NSRegularExpression regularExpressionWithPattern:@"^(?:export\\s+)?[A-Za-z0-9_]*KEY[A-Za-z0-9_]*\\s*=\\s*(.*)$" options:NSRegularExpressionCaseInsensitive error:nil];
    });
    NSTextCheckingResult *um = [urlKeyRe firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    if (um && [um rangeAtIndex:1].location != NSNotFound) {
        return [s substringWithRange:[um rangeAtIndex:1]];
    }
    NSTextCheckingResult *hm = [hdrKeyRe firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    if (hm && [hm rangeAtIndex:1].location != NSNotFound) {
        return [s substringWithRange:[hm rangeAtIndex:1]];
    }
    NSTextCheckingResult *em = [envRe firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    if (em && [em rangeAtIndex:1].location != NSNotFound) {
        s = [[s substringWithRange:[em rangeAtIndex:1]] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    NSCharacterSet *quotes = [NSCharacterSet characterSetWithCharactersInString:@"\"'`"];
    while (s.length >= 2 && [quotes characterIsMember:[s characterAtIndex:0]] && [quotes characterIsMember:[s characterAtIndex:s.length - 1]]) {
        s = [[s substringWithRange:NSMakeRange(1, s.length - 2)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    // Strip any internal whitespace or newlines introduced by terminal wrapping
    NSArray<NSString *> *parts = [s componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    s = [parts componentsJoinedByString:@""];
    NSString *lower = s.lowercaseString;
    if ([lower hasPrefix:@"http://"] || [lower hasPrefix:@"https://"]) return @"";
    return s;
}

// Custom NSTextField that supports Cmd+V, Cmd+C, Cmd+X, Cmd+A inside accessory app dialogs
@interface PasteableTextField : NSTextField
@end

@implementation PasteableTextField
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if (([event modifierFlags] & NSEventModifierFlagDeviceIndependentFlagsMask) == NSEventModifierFlagCommand) {
        NSString *chars = [event charactersIgnoringModifiers];
        if ([chars isEqualToString:@"v"]) {
            return [NSApp sendAction:@selector(paste:) to:nil from:self];
        } else if ([chars isEqualToString:@"c"]) {
            return [NSApp sendAction:@selector(copy:) to:nil from:self];
        } else if ([chars isEqualToString:@"x"]) {
            return [NSApp sendAction:@selector(cut:) to:nil from:self];
        } else if ([chars isEqualToString:@"a"]) {
            return [NSApp sendAction:@selector(selectAll:) to:nil from:self];
        }
    }
    return [super performKeyEquivalent:event];
}
@end

// Shared closable window for accessory-app utilities: supports traffic-light X, Cmd+W, Cmd+F, and Esc.
@interface GFClosableWindow : NSWindow
@property (nonatomic, copy) void (^onFindShortcut)(void);
@property (nonatomic, copy) BOOL (^onEscapeShortcut)(void); // return YES if consumed (e.g. cleared search), NO to close window
@end

@implementation GFClosableWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    NSString *ch = event.charactersIgnoringModifiers.lowercaseString;
    if (mods == NSEventModifierFlagCommand) {
        if ([ch isEqualToString:@"w"]) {
            [self performClose:nil];
            return YES;
        }
        if ([ch isEqualToString:@"f"] && self.onFindShortcut) {
            self.onFindShortcut();
            return YES;
        }
    }
    return [super performKeyEquivalent:event];
}
- (void)cancelOperation:(id)sender {
    if (self.onEscapeShortcut && self.onEscapeShortcut()) return;
    [self performClose:sender];
}
@end

// Clean, flat Mac-native Changelog UI (unified surface, no nested folder boxes; stripped by transplant.py on iOS)
typedef struct {
    NSRect rect;
    NSInteger cycle; // > 0 = earlier cycle toggle, -1 = Collapse all
} GFChangelogHitTarget;

@interface GFChangelogDocumentView : NSView
@property (nonatomic, copy) NSArray<NSDictionary *> *allEntries;
@property (nonatomic, copy) NSString *searchQuery;
@property (nonatomic, copy) NSString *scopeFilter;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *expandedCycles;
@property (nonatomic, assign) NSInteger hoveredTargetCycle;
@property (nonatomic, copy) void (^onStateChanged)(void);
- (CGFloat)preferredHeightForWidth:(CGFloat)width;
- (void)relayoutForWidth:(CGFloat)width;
@end

@implementation GFChangelogDocumentView {
    NSMutableArray<NSValue *> *_hitTargets;
    NSTrackingArea *_trackingArea;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _allEntries = GFBuiltInChangelogEntries();
        _searchQuery = @"";
        _scopeFilter = @"all";
        _expandedCycles = [NSMutableSet set];
        _hoveredTargetCycle = 0;
        _hitTargets = [NSMutableArray array];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }

- (BOOL)isDarkAppearance {
    NSAppearance *app = self.effectiveAppearance ?: [NSApp effectiveAppearance];
    NSAppearanceName match = [app bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
    return [match isEqualToString:NSAppearanceNameDarkAqua];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_trackingArea) [self removeTrackingArea:_trackingArea];
    _trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                 options:(NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect)
                                                   owner:self
                                                userInfo:nil];
    [self addTrackingArea:_trackingArea];
}

- (BOOL)isFilteringActive {
    NSString *q = [self.searchQuery ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *s = [self.scopeFilter ?: @"all" lowercaseString];
    return q.length > 0 || (s.length > 0 && ![s isEqualToString:@"all"]);
}

- (CGFloat)wrappedHeightForText:(NSString *)text font:(NSFont *)font width:(CGFloat)width {
    if (text.length == 0 || width <= 4.0) return 16.0;
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.lineBreakMode = NSLineBreakByWordWrapping;
    ps.lineSpacing = 2.5;
    NSRect r = [text boundingRectWithSize:NSMakeSize(width, 10000.0)
                                  options:(NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading)
                               attributes:@{NSFontAttributeName: font, NSParagraphStyleAttributeName: ps}];
    return ceil(MAX(font.ascender - font.descender + 2.0, r.size.height));
}

static NSString *GFShortDateFromTimestamp(NSString *ts) {
    if (![ts isKindOfClass:[NSString class]]) return @"";
    NSRange mid = [ts rangeOfString:@"\u00B7"];
    if (mid.location != NSNotFound) {
        return [[ts substringToIndex:mid.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }
    return ts;
}

- (CGFloat)renderOrMeasureWithWidth:(CGFloat)width draw:(BOOL)doDraw {
    BOOL dark = [self isDarkAppearance];
    NSColor *bgColor      = dark ? [NSColor colorWithSRGBRed:0.082 green:0.086 blue:0.102 alpha:1.0]
                                 : [NSColor colorWithSRGBRed:1.000 green:1.000 blue:1.000 alpha:1.0];
    NSColor *hoverColor   = dark ? [NSColor colorWithWhite:1.0 alpha:0.055]
                                 : [NSColor colorWithWhite:0.0 alpha:0.040];
    NSColor *dividerColor = dark ? [NSColor colorWithWhite:1.0 alpha:0.075]
                                 : [NSColor colorWithWhite:0.0 alpha:0.075];
    NSColor *inkColor     = dark ? [NSColor colorWithWhite:0.97 alpha:1.0]
                                 : [NSColor colorWithSRGBRed:0.090 green:0.090 blue:0.105 alpha:1.0];
    NSColor *bodyColor    = dark ? [NSColor colorWithSRGBRed:0.730 green:0.735 blue:0.775 alpha:1.0]
                                 : [NSColor colorWithSRGBRed:0.310 green:0.315 blue:0.355 alpha:1.0];
    NSColor *mutedColor   = dark ? [NSColor colorWithSRGBRed:0.530 green:0.535 blue:0.580 alpha:1.0]
                                 : [NSColor colorWithSRGBRed:0.510 green:0.515 blue:0.560 alpha:1.0];

    if (doDraw) {
        [bgColor setFill];
        NSRectFill(self.bounds);
        [_hitTargets removeAllObjects];
    }

    NSFont *overlineFont = [NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightSemibold];
    NSFont *timeFont     = [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightRegular];
    NSFont *heroTitleFont= [NSFont systemFontOfSize:15.5 weight:NSFontWeightSemibold];
    NSFont *rowTitleFont = [NSFont systemFontOfSize:13.0 weight:NSFontWeightMedium];
    NSFont *cycleColFont = [NSFont monospacedDigitSystemFontOfSize:12.0 weight:NSFontWeightMedium];
    NSFont *bulletFont   = [NSFont systemFontOfSize:12.5 weight:NSFontWeightRegular];
    NSFont *secHdrFont   = [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightMedium];

    NSMutableParagraphStyle *wrapPS = [[NSMutableParagraphStyle alloc] init];
    wrapPS.lineBreakMode = NSLineBreakByWordWrapping;
    wrapPS.lineSpacing = 2.5;

    NSMutableParagraphStyle *truncPS = [[NSMutableParagraphStyle alloc] init];
    truncPS.lineBreakMode = NSLineBreakByTruncatingTail;

    CGFloat padX = 24.0;
    CGFloat contentW = MAX(260.0, width - padX * 2.0);
    CGFloat y = 18.0;

    BOOL filtering = [self isFilteringActive];
    NSArray<NSDictionary *> *filtered = GFChangelogFilterEntries(self.allEntries, self.searchQuery, self.scopeFilter);

    CGFloat (^measureOrDrawBullets)(NSArray<NSString *> *, CGFloat, CGFloat, CGFloat, BOOL) = ^CGFloat(NSArray<NSString *> *items, CGFloat bx, CGFloat by, CGFloat bw, BOOL drawNow) {
        CGFloat curY = by;
        NSDictionary *bAttrs = @{NSFontAttributeName: bulletFont, NSForegroundColorAttributeName: bodyColor, NSParagraphStyleAttributeName: wrapPS};
        NSDictionary *dotAttrs = @{NSFontAttributeName: bulletFont, NSForegroundColorAttributeName: mutedColor};
        for (NSUInteger i = 0; i < items.count; i++) {
            NSString *item = items[i];
            CGFloat textW = MAX(80.0, bw - 14.0);
            CGFloat h = [self wrappedHeightForText:item font:bulletFont width:textW];
            if (drawNow) {
                [@"\u2022" drawAtPoint:NSMakePoint(bx, curY) withAttributes:dotAttrs];
                [item drawWithRect:NSMakeRect(bx + 14.0, curY, textW, h + 4.0)
                           options:(NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading)
                        attributes:bAttrs];
            }
            curY += h + (i + 1 < items.count ? 6.0 : 0.0);
        }
        return curY - by;
    };

    if (filtering) {
        if (filtered.count == 0) {
            if (doDraw) {
                NSString *empty = @"No matching updates.";
                NSDictionary *ea = @{NSFontAttributeName: rowTitleFont, NSForegroundColorAttributeName: mutedColor};
                NSSize esz = [empty sizeWithAttributes:ea];
                [empty drawAtPoint:NSMakePoint((width - esz.width) / 2.0, y + 36.0) withAttributes:ea];
            }
            return y + 96.0;
        }
        for (NSUInteger i = 0; i < filtered.count; i++) {
            NSDictionary *entry = filtered[i];
            if (i > 0) {
                if (doDraw) {
                    [dividerColor setFill];
                    NSRectFillUsingOperation(NSMakeRect(padX, y, contentW, 1.0), NSCompositingOperationSourceOver);
                }
                y += 15.0;
            }
            NSInteger cyc = [entry[@"cycle"] integerValue];
            NSString *meta = [NSString stringWithFormat:@"#%ld", (long)cyc];
            CGFloat titleX = padX + 42.0;
            CGFloat dateReserve = 96.0;
            CGFloat titleW = contentW - 42.0 - dateReserve;
            CGFloat th = [self wrappedHeightForText:entry[@"title"] font:rowTitleFont width:titleW];
            if (doDraw) {
                [meta drawAtPoint:NSMakePoint(padX, y + 1.0)
                   withAttributes:@{NSFontAttributeName: cycleColFont, NSForegroundColorAttributeName: mutedColor}];
                [entry[@"title"] drawWithRect:NSMakeRect(titleX, y, titleW, th + 4.0)
                                      options:(NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading)
                                   attributes:@{NSFontAttributeName: rowTitleFont, NSForegroundColorAttributeName: inkColor, NSParagraphStyleAttributeName: wrapPS}];
                NSDictionary *ta = @{NSFontAttributeName: timeFont, NSForegroundColorAttributeName: mutedColor};
                NSSize tsz = [entry[@"timestamp"] sizeWithAttributes:ta];
                [entry[@"timestamp"] drawAtPoint:NSMakePoint(padX + contentW - tsz.width, y + 1.0) withAttributes:ta];
            }
            CGFloat bh = measureOrDrawBullets(entry[@"highlights"], titleX, y + th + 7.0, contentW - 42.0, doDraw);
            y += th + 7.0 + bh + 15.0;
        }
        return y + 12.0;
    }

    if (self.allEntries.count == 0) return 60.0;

    // 1. Flat Latest Release Section (clean macOS typography, no nested card box)
    NSDictionary *latest = self.allEntries[0];
    if (doDraw) {
        NSString *overText = [NSString stringWithFormat:@"LATEST \u00B7 CYCLE %ld", (long)[latest[@"cycle"] integerValue]];
        [overText drawAtPoint:NSMakePoint(padX, y)
               withAttributes:@{NSFontAttributeName: overlineFont, NSForegroundColorAttributeName: mutedColor, NSKernAttributeName: @(0.6)}];
        NSDictionary *ta = @{NSFontAttributeName: timeFont, NSForegroundColorAttributeName: mutedColor};
        NSSize tsz = [latest[@"timestamp"] sizeWithAttributes:ta];
        [latest[@"timestamp"] drawAtPoint:NSMakePoint(padX + contentW - tsz.width, y - 0.5) withAttributes:ta];
    }
    y += 20.0;

    CGFloat heroTitleH = [self wrappedHeightForText:latest[@"title"] font:heroTitleFont width:contentW];
    if (doDraw) {
        [latest[@"title"] drawWithRect:NSMakeRect(padX, y, contentW, heroTitleH + 4.0)
                               options:(NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading)
                            attributes:@{NSFontAttributeName: heroTitleFont, NSForegroundColorAttributeName: inkColor, NSParagraphStyleAttributeName: wrapPS}];
    }
    y += heroTitleH + 10.0;

    CGFloat heroBulletsH = measureOrDrawBullets(latest[@"highlights"], padX, y, contentW, doDraw);
    y += heroBulletsH + 20.0;

    if (doDraw) {
        [dividerColor setFill];
        NSRectFillUsingOperation(NSMakeRect(padX, y, contentW, 1.0), NSCompositingOperationSourceOver);
    }
    y += 18.0;

    // 2. Flat Earlier Updates Timeline (borderless rows, subtle hover, click to expand)
    if (self.allEntries.count > 1) {
        NSUInteger earlierCount = self.allEntries.count - 1;
        if (doDraw) {
            NSString *hdr = [NSString stringWithFormat:@"Earlier updates (%lu)", (unsigned long)earlierCount];
            [hdr drawAtPoint:NSMakePoint(padX, y)
              withAttributes:@{NSFontAttributeName: secHdrFont, NSForegroundColorAttributeName: mutedColor}];
            if (self.expandedCycles.count > 0) {
                NSString *colStr = @"Collapse all";
                NSDictionary *ca = @{NSFontAttributeName: [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium],
                                     NSForegroundColorAttributeName: (self.hoveredTargetCycle == -1 ? inkColor : mutedColor)};
                NSSize csz = [colStr sizeWithAttributes:ca];
                [colStr drawAtPoint:NSMakePoint(padX + contentW - csz.width, y) withAttributes:ca];
                GFChangelogHitTarget ht = {NSMakeRect(padX + contentW - csz.width - 6.0, y - 3.0, csz.width + 12.0, 22.0), -1};
                [_hitTargets addObject:[NSValue valueWithBytes:&ht objCType:@encode(GFChangelogHitTarget)]];
            }
        }
        y += 24.0;

        for (NSUInteger idx = 0; idx < earlierCount; idx++) {
            NSDictionary *entry = self.allEntries[idx + 1];
            NSInteger cyc = [entry[@"cycle"] integerValue];
            BOOL open = [self.expandedCycles containsObject:@(cyc)];
            NSString *shortDate = GFShortDateFromTimestamp(entry[@"timestamp"]);

            CGFloat leftLead = 54.0; // chevron + #cycle
            CGFloat rightDateW = 54.0;
            CGFloat titleW = contentW - leftLead - rightDateW;
            CGFloat rh = 36.0;
            CGFloat th = 18.0;
            CGFloat bh = 0.0;
            if (open) {
                th = [self wrappedHeightForText:entry[@"title"] font:rowTitleFont width:titleW];
                bh = measureOrDrawBullets(entry[@"highlights"], 0, 0, contentW - leftLead, NO);
                rh = 10.0 + th + 8.0 + bh + 14.0;
            }

            if (doDraw) {
                if (idx > 0) {
                    [dividerColor setFill];
                    NSRectFillUsingOperation(NSMakeRect(padX, y, contentW, 1.0), NSCompositingOperationSourceOver);
                }
                NSRect rowHit = NSMakeRect(padX - 8.0, y + 1.0, contentW + 16.0, rh - 2.0);
                if (self.hoveredTargetCycle == cyc) {
                    NSBezierPath *hbp = [NSBezierPath bezierPathWithRoundedRect:rowHit xRadius:6.0 yRadius:6.0];
                    [hoverColor setFill];
                    [hbp fill];
                }
                GFChangelogHitTarget ht = {rowHit, cyc};
                [_hitTargets addObject:[NSValue valueWithBytes:&ht objCType:@encode(GFChangelogHitTarget)]];

                // Left subtle chevron
                NSBezierPath *chev = [NSBezierPath bezierPath];
                chev.lineWidth = 1.5;
                chev.lineCapStyle = NSLineCapStyleRound;
                chev.lineJoinStyle = NSLineJoinStyleRound;
                CGFloat cx = padX + 4.0, cy = y + 18.0;
                if (open) {
                    [chev moveToPoint:NSMakePoint(cx - 3.5, cy - 1.5)];
                    [chev lineToPoint:NSMakePoint(cx, cy + 2.0)];
                    [chev lineToPoint:NSMakePoint(cx + 3.5, cy - 1.5)];
                } else {
                    [chev moveToPoint:NSMakePoint(cx - 1.5, cy - 3.5)];
                    [chev lineToPoint:NSMakePoint(cx + 2.0, cy)];
                    [chev lineToPoint:NSMakePoint(cx - 1.5, cy + 3.5)];
                }
                [mutedColor setStroke];
                [chev stroke];

                NSString *cycLabel = [NSString stringWithFormat:@"#%ld", (long)cyc];
                [cycLabel drawAtPoint:NSMakePoint(padX + 16.0, y + 9.5)
                       withAttributes:@{NSFontAttributeName: cycleColFont, NSForegroundColorAttributeName: mutedColor}];

                NSDictionary *da = @{NSFontAttributeName: timeFont, NSForegroundColorAttributeName: mutedColor};
                NSString *dateToShow = open ? entry[@"timestamp"] : shortDate;
                NSSize dsz = [dateToShow sizeWithAttributes:da];

                if (open) {
                    CGFloat openTitleW = contentW - leftLead - (dsz.width + 12.0);
                    CGFloat openTH = [self wrappedHeightForText:entry[@"title"] font:rowTitleFont width:MAX(120.0, openTitleW)];
                    [entry[@"title"] drawWithRect:NSMakeRect(padX + leftLead, y + 9.0, MAX(120.0, openTitleW), openTH + 4.0)
                                          options:(NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading)
                                       attributes:@{NSFontAttributeName: rowTitleFont, NSForegroundColorAttributeName: inkColor, NSParagraphStyleAttributeName: wrapPS}];
                    [dateToShow drawAtPoint:NSMakePoint(padX + contentW - dsz.width, y + 10.0) withAttributes:da];
                    measureOrDrawBullets(entry[@"highlights"], padX + leftLead, y + 9.0 + openTH + 8.0, contentW - leftLead, YES);
                } else {
                    [entry[@"title"] drawWithRect:NSMakeRect(padX + leftLead, y + 9.0, titleW, 20.0)
                                          options:NSStringDrawingUsesLineFragmentOrigin
                                       attributes:@{NSFontAttributeName: rowTitleFont, NSForegroundColorAttributeName: inkColor, NSParagraphStyleAttributeName: truncPS}];
                    [dateToShow drawAtPoint:NSMakePoint(padX + contentW - dsz.width, y + 10.0) withAttributes:da];
                }
            }
            y += rh;
        }
        y += 20.0;
    }

    return y;
}

- (CGFloat)preferredHeightForWidth:(CGFloat)width {
    return MAX(360.0, [self renderOrMeasureWithWidth:width draw:NO]);
}

- (void)relayoutForWidth:(CGFloat)width {
    CGFloat w = MAX(320.0, width);
    CGFloat h = [self preferredHeightForWidth:w];
    [self setFrameSize:NSMakeSize(w, h)];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [self renderOrMeasureWithWidth:self.bounds.size.width draw:YES];
}

- (NSInteger)targetCycleAtPoint:(NSPoint)pt {
    for (NSValue *v in _hitTargets) {
        GFChangelogHitTarget ht;
        [v getValue:&ht];
        if (NSPointInRect(pt, ht.rect)) return ht.cycle;
    }
    return 0;
}

- (void)mouseMoved:(NSEvent *)event {
    NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger hit = [self targetCycleAtPoint:pt];
    if (hit != self.hoveredTargetCycle) {
        self.hoveredTargetCycle = hit;
        [self setNeedsDisplay:YES];
    }
}

- (void)mouseExited:(NSEvent *)event {
    if (self.hoveredTargetCycle != 0) {
        self.hoveredTargetCycle = 0;
        [self setNeedsDisplay:YES];
    }
}

- (void)mouseUp:(NSEvent *)event {
    NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger hit = [self targetCycleAtPoint:pt];
    if (hit == -1) {
        [self.expandedCycles removeAllObjects];
        [self relayoutForWidth:self.bounds.size.width];
        if (self.onStateChanged) self.onStateChanged();
    } else if (hit > 0) {
        if ([self.expandedCycles containsObject:@(hit)]) [self.expandedCycles removeObject:@(hit)];
        else [self.expandedCycles addObject:@(hit)];
        [self relayoutForWidth:self.bounds.size.width];
        if (self.onStateChanged) self.onStateChanged();
    }
}
@end

static NSArray<NSString *> *GFChangelogDefaultMacPaths(void) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSString *bundlePath = [[NSBundle mainBundle] pathForResource:@"changelog" ofType:@"json"];
    if (bundlePath) [paths addObject:bundlePath];
    NSString *home = NSHomeDirectory();
    if (home.length > 0) {
        [paths addObject:[home stringByAppendingPathComponent:@"GeminiFlow/changelog.json"]];
        [paths addObject:[home stringByAppendingPathComponent:@"Library/Application Support/GeminiFlow/changelog.json"]];
    }
    return paths;
}

// Height of the strip that holds the window buttons (close / minimize / zoom). Nothing of ours is drawn or placed in it: titles and
// controls sit in the row below (user report 2026-11-13: a title next to the window buttons looked awkward).
static const CGFloat kGFTitlebarStripHeight = 28.0;
static const CGFloat kGFChangelogHeaderHeight = 84.0;

// Brand mark and wordmark shared with GeminiFlow for iOS (Core/BrandMotion.swift BrandMarkPose, App/UI/BrandHeaderView.swift):
// three capsule bars, each 0.156 of the mark size wide with 0.102 gaps, rest heights 0.44 / 0.84 / 0.58, the group slanted 14
// degrees clockwise; "Gemini" bold (kerning -0.032 em) + "Flow" semibold italic (kerning -0.020 em), 0.035 em apart.
static const CGFloat kGFBrandBarWidth = 0.156, kGFBrandBarGap = 0.102, kGFBrandSlantDegrees = 14.0;
static const CGFloat kGFBrandRestHeights[3] = {0.44, 0.84, 0.58};
static void GFDrawBrandMark(NSRect box, const CGFloat heights[3], NSColor *color) {
    CGFloat size = MIN(box.size.width, box.size.height);
    CGFloat bw = size * kGFBrandBarWidth, step = bw + size * kGFBrandBarGap;
    BOOL flipped = [NSGraphicsContext currentContext].flipped; // a positive rotation is clockwise only in a flipped context
    NSAffineTransform *t = [NSAffineTransform transform];
    [t translateXBy:NSMidX(box) yBy:NSMidY(box)];
    [t rotateByDegrees:flipped ? kGFBrandSlantDegrees : -kGFBrandSlantDegrees];
    [NSGraphicsContext saveGraphicsState];
    [t concat];
    [color setFill];
    for (int i = 0; i < 3; i++) {
        CGFloat h = MAX(bw, size * heights[i]);
        NSRect r = NSMakeRect((i - 1) * step - bw / 2.0, -h / 2.0, bw, h);
        [[NSBezierPath bezierPathWithRoundedRect:r xRadius:bw / 2.0 yRadius:bw / 2.0] fill];
    }
    [NSGraphicsContext restoreGraphicsState];
}
static NSAttributedString *GFBrandTitle(NSString *text, CGFloat size, NSColor *ink) {
    return [[NSAttributedString alloc] initWithString:text ?: @""
                                           attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:size weight:NSFontWeightBold],
                                                        NSForegroundColorAttributeName: ink, NSKernAttributeName: @(-size * 0.032)}];
}
static NSAttributedString *GFBrandWordmark(CGFloat size, NSColor *ink) {
    NSFont *bold = [NSFont systemFontOfSize:size weight:NSFontWeightBold];
    NSFont *semi = [NSFont systemFontOfSize:size weight:NSFontWeightSemibold];
    NSFontDescriptor *itd = [semi.fontDescriptor fontDescriptorWithSymbolicTraits:(semi.fontDescriptor.symbolicTraits | NSFontDescriptorTraitItalic)];
    NSFont *flow = (itd ? [NSFont fontWithDescriptor:itd size:size] : nil) ?: semi;
    NSMutableDictionary *fa = [@{NSFontAttributeName: flow, NSForegroundColorAttributeName: ink, NSKernAttributeName: @(-size * 0.020)} mutableCopy];
    if (!(flow.fontDescriptor.symbolicTraits & NSFontDescriptorTraitItalic)) fa[NSObliquenessAttributeName] = @(0.18);
    NSMutableAttributedString *w = [[NSMutableAttributedString alloc] init];
    [w appendAttributedString:[[NSAttributedString alloc] initWithString:@"Gemin" attributes:@{NSFontAttributeName: bold,
        NSForegroundColorAttributeName: ink, NSKernAttributeName: @(-size * 0.032)}]];
    [w appendAttributedString:[[NSAttributedString alloc] initWithString:@"i" attributes:@{NSFontAttributeName: bold,
        NSForegroundColorAttributeName: ink, NSKernAttributeName: @(size * 0.035)}]];
    [w appendAttributedString:[[NSAttributedString alloc] initWithString:@"Flow" attributes:fa]];
    return w;
}
// Mark + text on one line; returns the width used from origin.x.
static CGFloat GFDrawBrandLockup(NSPoint origin, NSAttributedString *text, CGFloat size, NSColor *ink) {
    CGFloat lineH = text.size.height, mark = size * 1.05;
    GFDrawBrandMark(NSMakeRect(origin.x - mark * 0.12, origin.y + (lineH - mark) / 2.0, mark, mark), kGFBrandRestHeights, ink);
    CGFloat textX = origin.x + mark * 0.76 + size * 0.22;
    [text drawAtPoint:NSMakePoint(textX, origin.y)];
    return (textX - origin.x) + text.size.width;
}
// The iOS app icon ("Obsidian Ink": dark tile, white mark at 0.6 of the tile) as a Mac-shaped rounded tile, used at runtime
// (dialogs); the bundle's Finder icon is unchanged.
static NSImage *GFBrandAppIconImage(CGFloat side) {
    return [NSImage imageWithSize:NSMakeSize(side, side) flipped:NO drawingHandler:^BOOL(NSRect r) {
        NSRect tile = NSInsetRect(r, r.size.width * 0.09, r.size.width * 0.09);
        CGFloat rad = tile.size.width * 0.225;
        NSGradient *g = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithSRGBRed:0.180 green:0.184 blue:0.220 alpha:1.0]
                                                      endingColor:[NSColor colorWithSRGBRed:0.055 green:0.059 blue:0.078 alpha:1.0]];
        [g drawInBezierPath:[NSBezierPath bezierPathWithRoundedRect:tile xRadius:rad yRadius:rad] angle:-90.0];
        GFDrawBrandMark(NSInsetRect(tile, tile.size.width * 0.2, tile.size.width * 0.2), kGFBrandRestHeights, [NSColor whiteColor]);
        return YES;
    }];
}
static NSBitmapImageRep *GFRenderBrandPreview(NSArray<NSImage *> *menuIcons) {
    CGFloat W = 640.0, H = 220.0;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)(W * 2) pixelsHigh:(NSInteger)(H * 2)
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace
        bytesPerRow:(NSInteger)(W * 2) * 4 bitsPerPixel:32];
    rep.size = NSMakeSize(W, H);
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
    [[NSColor colorWithWhite:0.94 alpha:1.0] setFill];
    NSRectFill(NSMakeRect(0, 0, W, H));
    [GFBrandAppIconImage(180.0) drawInRect:NSMakeRect(20, 20, 180, 180) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
    NSArray<NSString *> *labels = @[@"Idle", @"Listening", @"Thinking"];
    NSColor *ink = [NSColor colorWithSRGBRed:0.090 green:0.090 blue:0.105 alpha:1.0];
    for (NSUInteger i = 0; i < menuIcons.count && i < 3; i++) {
        NSRect box = NSMakeRect(250 + i * 125, 96, 72, 72);
        [menuIcons[i] drawInRect:box fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
        [labels[i] drawAtPoint:NSMakePoint(box.origin.x + 4, 68) withAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12.0], NSForegroundColorAttributeName: ink}];
    }
    GFDrawBrandLockup(NSMakePoint(254, 22), GFBrandWordmark(22.0, ink), 22.0, ink);
    [NSGraphicsContext restoreGraphicsState];
    return rep;
}

// Header that draws the unified flat background, the title below the window-button strip, and a bottom 1px separator hairline
@interface GFFlatHeaderView : NSView
@property (nonatomic, copy) NSString *headerTitle;
@end

@implementation GFFlatHeaderView
- (void)drawRect:(NSRect)dirtyRect {
    NSAppearance *app = self.effectiveAppearance ?: [NSApp effectiveAppearance];
    BOOL dark = [[app bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
    NSColor *bg = dark ? [NSColor colorWithSRGBRed:0.082 green:0.086 blue:0.102 alpha:1.0]
                       : [NSColor colorWithSRGBRed:1.000 green:1.000 blue:1.000 alpha:1.0];
    NSColor *sep = dark ? [NSColor colorWithWhite:1.0 alpha:0.08]
                        : [NSColor colorWithWhite:0.0 alpha:0.08];
    NSColor *ink = dark ? [NSColor colorWithWhite:0.97 alpha:1.0]
                        : [NSColor colorWithSRGBRed:0.090 green:0.090 blue:0.105 alpha:1.0];
    [bg setFill];
    NSRectFill(self.bounds);
    [sep setFill];
    NSRectFillUsingOperation(NSMakeRect(0, 0, self.bounds.size.width, 1.0), NSCompositingOperationSourceOver);
    if (self.headerTitle.length > 0) {
        NSAttributedString *title = GFBrandTitle(self.headerTitle, 20.0, ink);
        CGFloat rowH = MAX(0.0, self.bounds.size.height - kGFTitlebarStripHeight); // the row under the window buttons
        [title drawAtPoint:NSMakePoint(24.0, (rowH - title.size.height) / 2.0 + 1.0)];
    }
}
@end

// The Changelog header: title on the left, filter field + All/Engine switch on the right, all below the window-button strip.
static GFFlatHeaderView *GFMakeChangelogHeader(NSRect frame, id target, NSSearchField * __autoreleasing *outSearch,
                                               NSSegmentedControl * __autoreleasing *outScope) {
    GFFlatHeaderView *bar = [[GFFlatHeaderView alloc] initWithFrame:frame];
    bar.headerTitle = @"Changelog";
    CGFloat w = frame.size.width, rowH = frame.size.height - kGFTitlebarStripHeight;
    NSSegmentedControl *scope = [NSSegmentedControl segmentedControlWithLabels:@[@"All", @"Engine"]
                                                                  trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                        target:target
                                                                        action:NSSelectorFromString(@"scopeSegmentChanged:")];
    scope.selectedSegment = 0;
    scope.controlSize = NSControlSizeSmall;
    scope.frame = NSMakeRect(w - 24.0 - 104.0, (rowH - 24.0) / 2.0, 104.0, 24.0);
    scope.autoresizingMask = NSViewMinXMargin;
    [bar addSubview:scope];
    NSSearchField *search = [[NSSearchField alloc] initWithFrame:NSMakeRect(w - 24.0 - 104.0 - 10.0 - 170.0, (rowH - 26.0) / 2.0, 170.0, 26.0)];
    search.placeholderString = @"Filter updates";
    search.controlSize = NSControlSizeSmall;
    search.font = [NSFont systemFontOfSize:12.0];
    search.autoresizingMask = NSViewMinXMargin;
    [bar addSubview:search];
    if (outSearch) *outSearch = search;
    if (outScope) *outScope = scope;
    return bar;
}

static NSBitmapImageRep *GFRenderChangelogSnapshot(BOOL dark, NSString *query, NSString *scopeFilter, NSSet<NSNumber *> *expanded) {
    CGFloat w = 520.0;
    GFChangelogDocumentView *doc = [[GFChangelogDocumentView alloc] initWithFrame:NSMakeRect(0, 0, w, 560.0)];
    doc.allEntries = GFChangelogLoadEntriesFromPaths(GFChangelogDefaultMacPaths());
    doc.searchQuery = query ?: @"";
    doc.scopeFilter = scopeFilter ?: @"all";
    if (expanded) [doc.expandedCycles setSet:expanded];
    NSAppearance *appearance = [NSAppearance appearanceNamed:(dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua)];
    CGFloat docH = [doc preferredHeightForWidth:w];
    CGFloat headerH = kGFChangelogHeaderHeight;
    CGFloat totalH = headerH + docH;

    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, w, totalH)];
    container.appearance = appearance;
    GFFlatHeaderView *hdr = GFMakeChangelogHeader(NSMakeRect(0, docH, w, headerH), nil, NULL, NULL);
    // Simulated macOS traffic lights for realistic window preview
    [doc setFrame:NSMakeRect(0, 0, w, docH)];
    [container addSubview:doc];
    [container addSubview:hdr];

    NSInteger pw = (NSInteger)(w * 2.0), ph = (NSInteger)(totalH * 2.0);
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:pw pixelsHigh:ph
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace
        bytesPerRow:pw * 4 bitsPerPixel:32];
    rep.size = NSMakeSize(w, totalH);
    [appearance performAsCurrentDrawingAppearance:^{
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
        [container displayRectIgnoringOpacity:container.bounds inContext:[NSGraphicsContext currentContext]];
        // Draw standard traffic-light circles in preview top-left
        CGFloat tlY = totalH - 20.0; // centred in the 28 pt window-button strip
        NSColor *tlColors[3] = {
            [NSColor colorWithSRGBRed:1.0 green:0.373 blue:0.341 alpha:1.0],
            [NSColor colorWithSRGBRed:0.996 green:0.737 blue:0.180 alpha:1.0],
            [NSColor colorWithSRGBRed:0.157 green:0.784 blue:0.251 alpha:1.0]
        };
        for (int i = 0; i < 3; i++) {
            NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(12.0 + i * 20.0, tlY, 12.0, 12.0)];
            [tlColors[i] setFill];
            [dot fill];
        }
        [NSGraphicsContext restoreGraphicsState];
    }];
    return rep;
}

@interface GFChangelogWindowController : NSObject <NSSearchFieldDelegate, NSWindowDelegate>
@property (nonatomic, strong) GFClosableWindow *window;
@property (nonatomic, strong) NSSearchField *searchField;
@property (nonatomic, strong) NSSegmentedControl *scopeControl;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) GFChangelogDocumentView *docView;
+ (instancetype)sharedController;
- (void)showWindow;
- (void)reloadEntries;
@end

@implementation GFChangelogWindowController

+ (instancetype)sharedController {
    static GFChangelogWindowController *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[GFChangelogWindowController alloc] init];
    });
    return shared;
}

- (void)ensureWindow {
    if (self.window) return;
    NSRect frame = NSMakeRect(0, 0, 520, 600);
    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView;
    self.window = [[GFClosableWindow alloc] initWithContentRect:frame styleMask:style backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"GeminiFlow Changelog";
    self.window.titleVisibility = NSWindowTitleHidden;
    self.window.titlebarAppearsTransparent = YES;
    self.window.minSize = NSMakeSize(480, 400);
    self.window.releasedWhenClosed = NO;
    self.window.delegate = self;
    [self.window center];

    __weak typeof(self) weakSelf = self;
    self.window.onFindShortcut = ^{
        [weakSelf.window makeFirstResponder:weakSelf.searchField];
    };
    self.window.onEscapeShortcut = ^BOOL{
        if (weakSelf.searchField.stringValue.length > 0) {
            weakSelf.searchField.stringValue = @"";
            weakSelf.docView.searchQuery = @"";
            CGFloat cw = weakSelf.scrollView.contentSize.width > 100 ? weakSelf.scrollView.contentSize.width : weakSelf.window.contentView.bounds.size.width;
            [weakSelf.docView relayoutForWidth:cw];
            return YES;
        }
        return NO;
    };

    NSView *root = self.window.contentView;
    root.autoresizesSubviews = YES;

    CGFloat headerH = kGFChangelogHeaderHeight;
    NSSearchField *search = nil;
    NSSegmentedControl *scope = nil;
    GFFlatHeaderView *topBar = GFMakeChangelogHeader(NSMakeRect(0, frame.size.height - headerH, frame.size.width, headerH), self,
                                                     &search, &scope);
    topBar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.searchField = search;
    self.searchField.delegate = self;
    self.scopeControl = scope;
    [root addSubview:topBar];

    self.scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height - headerH)];
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.hasHorizontalScroller = NO;
    self.scrollView.autohidesScrollers = YES;
    self.scrollView.drawsBackground = NO;
    self.scrollView.borderType = NSNoBorder;
    self.scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    self.docView = [[GFChangelogDocumentView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, 540.0)];
    self.scrollView.documentView = self.docView;
    [root addSubview:self.scrollView];

    [self reloadEntries];
}

- (void)reloadEntries {
    [self ensureWindow];
    self.docView.allEntries = GFChangelogLoadEntriesFromPaths(GFChangelogDefaultMacPaths());
    CGFloat contentW = self.scrollView.contentSize.width > 100 ? self.scrollView.contentSize.width : self.window.contentView.bounds.size.width;
    [self.docView relayoutForWidth:contentW];
}

- (void)scopeSegmentChanged:(NSSegmentedControl *)sender {
    self.docView.scopeFilter = sender.selectedSegment == 1 ? @"engine" : @"all";
    CGFloat contentW = self.scrollView.contentSize.width > 100 ? self.scrollView.contentSize.width : self.window.contentView.bounds.size.width;
    [self.docView relayoutForWidth:contentW];
}

- (void)controlTextDidChange:(NSNotification *)obj {
    self.docView.searchQuery = self.searchField.stringValue ?: @"";
    CGFloat contentW = self.scrollView.contentSize.width > 100 ? self.scrollView.contentSize.width : self.window.contentView.bounds.size.width;
    [self.docView relayoutForWidth:contentW];
}

- (void)windowDidResize:(NSNotification *)notification {
    CGFloat contentW = self.scrollView.contentSize.width > 100 ? self.scrollView.contentSize.width : self.window.contentView.bounds.size.width;
    [self.docView relayoutForWidth:contentW];
}

- (void)showWindow {
    [self reloadEntries];
    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeKeyAndOrderFront:nil];
}
@end

// Non-modal, closable Setup & Onboarding Window (replaces the trapping modal NSAlert)
typedef struct {
    BOOL hasApiKey;
    NSInteger micStatus;    // AVAuthorizationStatus: 0 notDetermined, 1 restricted, 2 denied, 3 authorized
    BOOL axTrusted;
    NSInteger speechStatus; // SFSpeechRecognizerAuthorizationStatus: 0 notDetermined, 1 denied, 2 restricted, 3 authorized
    BOOL fnDoNothing;
} GFSetupState;

typedef struct {
    NSRect rect;
    NSInteger actionId; // 1=API Key, 2=Mic, 3=Accessibility, 4=Speech, 5=Keyboard, 6=Done
} GFSetupHitTarget;

@interface GFSetupContentView : NSView
@property (nonatomic, assign) GFSetupState state;
@property (nonatomic, assign) NSInteger hoveredActionId;
@property (nonatomic, copy) void (^onAction)(NSInteger actionId);
@end

@implementation GFSetupContentView {
    NSMutableArray<NSValue *> *_hitTargets;
    NSTrackingArea *_trackingArea;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _hitTargets = [NSMutableArray array];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_trackingArea) [self removeTrackingArea:_trackingArea];
    _trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                 options:(NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect)
                                                   owner:self
                                                userInfo:nil];
    [self addTrackingArea:_trackingArea];
}

- (void)drawRect:(NSRect)dirtyRect {
    NSAppearance *app = self.effectiveAppearance ?: [NSApp effectiveAppearance];
    BOOL dark = [[app bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
    NSColor *bgColor    = dark ? [NSColor colorWithSRGBRed:0.082 green:0.086 blue:0.102 alpha:1.0]
                               : [NSColor colorWithSRGBRed:1.000 green:1.000 blue:1.000 alpha:1.0];
    NSColor *inkColor   = dark ? [NSColor colorWithWhite:0.97 alpha:1.0]
                               : [NSColor colorWithSRGBRed:0.090 green:0.090 blue:0.105 alpha:1.0];
    NSColor *mutedColor = dark ? [NSColor colorWithSRGBRed:0.560 green:0.565 blue:0.615 alpha:1.0]
                               : [NSColor colorWithSRGBRed:0.450 green:0.455 blue:0.500 alpha:1.0];
    NSColor *sepColor   = dark ? [NSColor colorWithWhite:1.0 alpha:0.075]
                               : [NSColor colorWithWhite:0.0 alpha:0.075];
    NSColor *btnBg      = dark ? [NSColor colorWithWhite:1.0 alpha:0.09]
                               : [NSColor colorWithWhite:0.0 alpha:0.055];
    NSColor *btnHoverBg = dark ? [NSColor colorWithWhite:1.0 alpha:0.15]
                               : [NSColor colorWithWhite:0.0 alpha:0.095];
    NSColor *doneBg     = inkColor;
    NSColor *doneFg     = bgColor;
    NSColor *greenDot   = [NSColor colorWithSRGBRed:0.176 green:0.784 blue:0.294 alpha:1.0];
    NSColor *amberDot   = [NSColor colorWithSRGBRed:0.960 green:0.650 blue:0.140 alpha:1.0];

    [bgColor setFill];
    NSRectFill(self.bounds);
    [_hitTargets removeAllObjects];

    CGFloat w = self.bounds.size.width;
    CGFloat padX = 24.0;
    CGFloat contentW = w - padX * 2.0;

    // Title below the window-button strip (the top kGFTitlebarStripHeight pt stay empty)
    CGFloat lockW = GFDrawBrandLockup(NSMakePoint(padX, 34.0), GFBrandWordmark(20.0, inkColor), 20.0, inkColor);
    [@"Setup" drawAtPoint:NSMakePoint(padX + lockW + 7.0, 34.0)
           withAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:20.0 weight:NSFontWeightRegular],
                            NSForegroundColorAttributeName: mutedColor, NSKernAttributeName: @(-20.0 * 0.020)}];

    CGFloat y = 66.0;
    [@"Hold Fn to speak and release to paste anywhere on your Mac." drawAtPoint:NSMakePoint(padX, y)
                                                                 withAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12.5],
                                                                                  NSForegroundColorAttributeName: mutedColor}];
    y += 28.0;

    struct {
        NSInteger actionId;
        BOOL ok;
        NSString *title;
        NSString *subtitle;
        NSString *btnTitle;
    } rows[5] = {
        {1, self.state.hasApiKey,
         @"Gemini API Key",
         self.state.hasApiKey ? @"Configured (Gemini Live Transcribe active)" : @"Optional: add a key for fast cloud transcription",
         self.state.hasApiKey ? @"Change" : @"Set Key"},
        {2, self.state.micStatus == 3,
         @"Microphone",
         self.state.micStatus == 3 ? @"Ready" : @"Required to hear your voice while holding Fn",
         self.state.micStatus == 0 ? @"Allow" : (self.state.micStatus == 3 ? @"Settings" : @"Open Settings")},
        {3, self.state.axTrusted,
         @"Accessibility",
         self.state.axTrusted ? @"Ready (auto-paste & Fn key listener active)" : @"Required to paste at your cursor and detect Fn",
         self.state.axTrusted ? @"Settings" : @"Open Settings"},
        {4, self.state.speechStatus == 3,
         @"Speech Recognition",
         self.state.speechStatus == 3 ? @"Ready (offline safety net)" : @"Recommended for offline fallback",
         self.state.speechStatus == 0 ? @"Allow" : (self.state.speechStatus == 3 ? @"Settings" : @"Open Settings")},
        {5, self.state.fnDoNothing,
         @"Fn / Globe Key",
         self.state.fnDoNothing ? @"Set to 'Do Nothing' in Keyboard Settings" : @"Tip: set 'Press fn key to: Do Nothing'",
         @"Keyboard"}
    };

    NSFont *rowTitleF = [NSFont systemFontOfSize:13.0 weight:NSFontWeightMedium];
    NSFont *rowSubF   = [NSFont systemFontOfSize:11.5 weight:NSFontWeightRegular];
    NSFont *btnFont   = [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];

    for (int i = 0; i < 5; i++) {
        [sepColor setFill];
        NSRectFillUsingOperation(NSMakeRect(padX, y, contentW, 1.0), NSCompositingOperationSourceOver);

        CGFloat rowH = 54.0;
        NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(padX + 2.0, y + 14.0, 8.0, 8.0)];
        [(rows[i].ok ? greenDot : amberDot) setFill];
        [dot fill];

        [rows[i].title drawAtPoint:NSMakePoint(padX + 18.0, y + 9.0)
                    withAttributes:@{NSFontAttributeName: rowTitleF, NSForegroundColorAttributeName: inkColor}];
        [rows[i].subtitle drawAtPoint:NSMakePoint(padX + 18.0, y + 28.0)
                       withAttributes:@{NSFontAttributeName: rowSubF, NSForegroundColorAttributeName: mutedColor}];

        NSDictionary *ba = @{NSFontAttributeName: btnFont, NSForegroundColorAttributeName: inkColor};
        NSSize bsz = [rows[i].btnTitle sizeWithAttributes:ba];
        CGFloat bw = MAX(74.0, ceil(bsz.width) + 22.0);
        NSRect bRect = NSMakeRect(padX + contentW - bw, y + 14.0, bw, 26.0);
        NSBezierPath *bbp = [NSBezierPath bezierPathWithRoundedRect:bRect xRadius:6.0 yRadius:6.0];
        [(self.hoveredActionId == rows[i].actionId ? btnHoverBg : btnBg) setFill];
        [bbp fill];
        [rows[i].btnTitle drawAtPoint:NSMakePoint(bRect.origin.x + (bw - bsz.width) / 2.0, bRect.origin.y + (26.0 - bsz.height) / 2.0 - 0.5)
                       withAttributes:ba];
        GFSetupHitTarget ht = {bRect, rows[i].actionId};
        [_hitTargets addObject:[NSValue valueWithBytes:&ht objCType:@encode(GFSetupHitTarget)]];

        y += rowH;
    }

    [sepColor setFill];
    NSRectFillUsingOperation(NSMakeRect(padX, y, contentW, 1.0), NSCompositingOperationSourceOver);
    y += 16.0;

    // Bottom-right Done button
    NSString *doneLabel = @"Done";
    NSDictionary *da = @{NSFontAttributeName: [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold], NSForegroundColorAttributeName: doneFg};
    NSSize dsz = [doneLabel sizeWithAttributes:da];
    NSRect doneRect = NSMakeRect(padX + contentW - 76.0, y, 76.0, 28.0);
    NSBezierPath *dbp = [NSBezierPath bezierPathWithRoundedRect:doneRect xRadius:7.0 yRadius:7.0];
    [doneBg setFill];
    [dbp fill];
    [doneLabel drawAtPoint:NSMakePoint(doneRect.origin.x + (76.0 - dsz.width) / 2.0, doneRect.origin.y + (28.0 - dsz.height) / 2.0 - 0.5)
            withAttributes:da];
    GFSetupHitTarget dht = {doneRect, 6};
    [_hitTargets addObject:[NSValue valueWithBytes:&dht objCType:@encode(GFSetupHitTarget)]];
}

- (NSInteger)actionAtPoint:(NSPoint)pt {
    for (NSValue *v in _hitTargets) {
        GFSetupHitTarget ht;
        [v getValue:&ht];
        if (NSPointInRect(pt, ht.rect)) return ht.actionId;
    }
    return 0;
}

- (void)mouseMoved:(NSEvent *)event {
    NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger hit = [self actionAtPoint:pt];
    if (hit != self.hoveredActionId) {
        self.hoveredActionId = hit;
        [self setNeedsDisplay:YES];
    }
}

- (void)mouseExited:(NSEvent *)event {
    if (self.hoveredActionId != 0) {
        self.hoveredActionId = 0;
        [self setNeedsDisplay:YES];
    }
}

- (void)mouseUp:(NSEvent *)event {
    NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger hit = [self actionAtPoint:pt];
    if (hit > 0 && self.onAction) self.onAction(hit);
}
@end

static NSBitmapImageRep *GFRenderSetupSnapshot(BOOL dark, GFSetupState state) {
    CGFloat w = 470.0, h = 424.0;
    GFSetupContentView *v = [[GFSetupContentView alloc] initWithFrame:NSMakeRect(0, 0, w, h)];
    v.state = state;
    NSAppearance *appearance = [NSAppearance appearanceNamed:(dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua)];
    v.appearance = appearance;
    NSInteger pw = (NSInteger)(w * 2.0), ph = (NSInteger)(h * 2.0);
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:pw pixelsHigh:ph
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace
        bytesPerRow:pw * 4 bitsPerPixel:32];
    rep.size = NSMakeSize(w, h);
    [appearance performAsCurrentDrawingAppearance:^{
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
        [v displayRectIgnoringOpacity:v.bounds inContext:[NSGraphicsContext currentContext]];
        // Simulated traffic lights (Close X and Minimize -)
        NSColor *tlColors[3] = {
            [NSColor colorWithSRGBRed:1.0 green:0.373 blue:0.341 alpha:1.0],
            [NSColor colorWithSRGBRed:0.996 green:0.737 blue:0.180 alpha:1.0],
            [NSColor colorWithWhite:0.5 alpha:0.25]
        };
        for (int i = 0; i < 3; i++) {
            NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(12.0 + i * 20.0, h - 20.0, 12.0, 12.0)];
            [tlColors[i] setFill];
            [dot fill];
        }
        [NSGraphicsContext restoreGraphicsState];
    }];
    return rep;
}

@interface GFSetupWindowController : NSObject <NSWindowDelegate>
@property (nonatomic, strong) GFClosableWindow *window;
@property (nonatomic, strong) GFSetupContentView *contentView;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, copy) void (^onPromptApiKey)(void);
@property (nonatomic, copy) void (^onAccessibilityTrusted)(void);
+ (instancetype)sharedController;
- (void)showWindow;
- (void)refreshState;
@end

@implementation GFSetupWindowController

+ (instancetype)sharedController {
    static GFSetupWindowController *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[GFSetupWindowController alloc] init];
    });
    return shared;
}

- (GFSetupState)queryLiveState {
    GFSetupState st = {0};
    NSString *key = [[NSUserDefaults standardUserDefaults] stringForKey:kPrefApiKey] ?: @"";
    st.hasApiKey = key.length > 0;
    st.micStatus = (NSInteger)[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    st.axTrusted = AXIsProcessTrusted();
    st.speechStatus = (NSInteger)[SFSpeechRecognizer authorizationStatus];
    NSDictionary *hi = [[NSUserDefaults standardUserDefaults] persistentDomainForName:@"com.apple.HIToolbox"];
    id fnVal = hi[@"AppleFnUsageType"];
    st.fnDoNothing = (fnVal != nil && [fnVal respondsToSelector:@selector(integerValue)] && [fnVal integerValue] == 0);
    return st;
}

- (void)refreshState {
    if (!self.contentView) return;
    GFSetupState st = [self queryLiveState];
    if (st.axTrusted && self.onAccessibilityTrusted) self.onAccessibilityTrusted();
    self.contentView.state = st;
    [self.contentView setNeedsDisplay:YES];
}

- (void)ensureWindow {
    if (self.window) return;
    NSRect frame = NSMakeRect(0, 0, 470, 424);
    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskFullSizeContentView;
    self.window = [[GFClosableWindow alloc] initWithContentRect:frame styleMask:style backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"GeminiFlow Setup";
    self.window.titleVisibility = NSWindowTitleHidden;
    self.window.titlebarAppearsTransparent = YES;
    self.window.releasedWhenClosed = NO;
    self.window.delegate = self;
    [self.window center];

    self.contentView = [[GFSetupContentView alloc] initWithFrame:frame];
    __weak typeof(self) weakSelf = self;
    self.contentView.onAction = ^(NSInteger actionId) {
        typeof(self) s = weakSelf;
        if (!s) return;
        if (actionId == 1) {
            if (s.onPromptApiKey) s.onPromptApiKey();
            [s refreshState];
        } else if (actionId == 2) {
            if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] == AVAuthorizationStatusNotDetermined) {
                [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
                    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf refreshState]; });
                }];
            } else {
                [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"]];
            }
        } else if (actionId == 3) {
            NSDictionary *opts = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
            AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
            [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
        } else if (actionId == 4) {
            if ([SFSpeechRecognizer authorizationStatus] == SFSpeechRecognizerAuthorizationStatusNotDetermined) {
                [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
                    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf refreshState]; });
                }];
            } else {
                [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"]];
            }
        } else if (actionId == 5) {
            [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.Keyboard-Settings.extension"]];
        } else if (actionId == 6) {
            [s.window performClose:nil];
        }
    };
    self.window.contentView = self.contentView;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidBecomeActive:)
                                                 name:NSApplicationDidBecomeActiveNotification object:nil];
}

- (void)appDidBecomeActive:(NSNotification *)note {
    if (self.window.isVisible) [self refreshState];
}

- (void)windowWillClose:(NSNotification *)notification {
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

- (void)showWindow {
    [self ensureWindow];
    [self refreshState];
    [self.refreshTimer invalidate];
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(refreshState) userInfo:nil repeats:YES];
    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeKeyAndOrderFront:nil];
}
@end

typedef NS_ENUM(NSInteger, HUDMode) {
    HUDModeListeningHold = 0,
    HUDModeListeningHandsFree = 1,
    HUDModeThinking = 2,
    HUDModeSuccess = 3,
    HUDModeNotice = 4
};

// HUD geometry (backlog 0n). The pill itself is kHUDPillWidth x kHUDPillHeight at the same on-screen spot as before; the window is
// kHUDGlowPad larger on every side (once room for a hands-free glow, removed in backlog 0s; the margin stays so the window frame and
// the pill position do not change). Nothing is ever drawn outside the pill, in any mode.
static const CGFloat kHUDPillWidth = 144.0;
static const CGFloat kHUDPillHeight = 36.0;
static const CGFloat kHUDGlowPad = 8.0;
static const CGFloat kHUDPillBottomOffset = 68.0; // pill bottom edge above the screen's visibleFrame bottom
// The hands-free (locked) green (#38DC82, saturated so it reads on the dark frosted pill), used ONLY inside the pill by the
// indicator dot, its soft halo and the waveform bars (backlog 0s: no green rim or glow around the pill).
#define GF_HUD_GREEN(a) [NSColor colorWithCalibratedRed:0.22 green:0.86 blue:0.51 alpha:(a)]

// Window origin that keeps the pill centred kHUDPillBottomOffset above the bottom of visibleFrame (the pill sits kHUDGlowPad
// inside the window), i.e. exactly where the old pill-sized window put it.
static NSPoint GFHUDWindowOriginForVisibleFrame(NSRect visibleFrame, NSSize windowSize) {
    CGFloat pad = (windowSize.width - kHUDPillWidth) / 2.0;
    return NSMakePoint(visibleFrame.origin.x + (visibleFrame.size.width - windowSize.width) / 2.0,
                       visibleFrame.origin.y + kHUDPillBottomOffset - pad);
}

// Floating HUD View displaying 60fps acoustic waveform and dynamic micro-badges
@interface FloatingHUDView : NSView
@property (nonatomic, assign) HUDMode mode;
// Space between the view's edge and the pill (the panel uses kHUDGlowPad; 0 = the pill fills the view).
@property (nonatomic, assign) CGFloat pillInset;
@property (nonatomic, assign) float targetAudioLevel;
@property (nonatomic, assign) float smoothedLevel;
@property (nonatomic, assign) float animPhase;
@property (nonatomic, copy) NSString *noticeText;
@end

@implementation FloatingHUDView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _mode = HUDModeListeningHold;
        _targetAudioLevel = 0.0f;
        _smoothedLevel = 0.0f;
        _animPhase = 0.0f;
        _noticeText = @"";
    }
    return self;
}

- (void)advanceAnimation {
    self.animPhase += 0.14f;
    if (self.animPhase > 10000.0f) self.animPhase = 0.0f;

    // Fast attack, smooth decay envelope follower
    if (self.targetAudioLevel > self.smoothedLevel) {
        self.smoothedLevel += (self.targetAudioLevel - self.smoothedLevel) * 0.45f;
    } else {
        self.smoothedLevel += (self.targetAudioLevel - self.smoothedLevel) * 0.14f;
    }
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    // The pill: everything below uses `bounds` = the pill's rect (inset pillInset inside the view; nothing is drawn outside it).
    NSRect bounds = NSInsetRect(self.bounds, self.pillInset, self.pillInset);
    if (bounds.size.width <= 0 || bounds.size.height <= 0) return;
    CGFloat pillRadius = bounds.size.height / 2.0;
    BOOL handsFree = (self.mode == HUDModeListeningHandsFree);
    // Gentle slow pulse for the hands-free dot's halo (~2.4 s period at the 60 fps animPhase rate of 8.4/s).
    float glowPulse = 0.5f + 0.5f * sinf(self.animPhase * 0.31f);

    NSBezierPath *pill = [NSBezierPath bezierPathWithRoundedRect:bounds xRadius:pillRadius yRadius:pillRadius];

    // 1. Liquid Glass specular sheen gradient (translucent, lets live frosted backdrop blur shine through)
    NSGradient *glassSheen = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedWhite:1.0 alpha:0.15]
                                                           endingColor:[NSColor colorWithCalibratedWhite:1.0 alpha:0.02]];
    [glassSheen drawInBezierPath:pill angle:-90.0];

    // 2. Specular glass hairline rim
    NSRect insetRect = NSInsetRect(bounds, 0.5, 0.5);
    NSBezierPath *rim = [NSBezierPath bezierPathWithRoundedRect:insetRect xRadius:pillRadius - 0.5 yRadius:pillRadius - 0.5];
    [[NSColor colorWithCalibratedWhite:1.0 alpha:0.26] setStroke];
    [rim setLineWidth:1.0];
    [rim stroke];

    // 3. Center Area: Waveform Bars OR Status Label
    if (self.mode == HUDModeListeningHold || self.mode == HUDModeListeningHandsFree || self.mode == HUDModeThinking) {
        // In hands-free (locked) mode: a bright 7 px green dot at left (centred where the old 5 px dot was) on a soft green halo
        // that stays well inside the pill (13 px across, gently pulsing).
        if (handsFree) {
            CGFloat dotCX = bounds.origin.x + 16.5, dotCY = NSMidY(bounds);
            CGFloat haloR = 6.5, dotR = 3.5;
            NSBezierPath *halo = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(dotCX - haloR, dotCY - haloR, 2.0 * haloR, 2.0 * haloR)];
            NSGradient *haloGrad = [[NSGradient alloc] initWithStartingColor:GF_HUD_GREEN(0.30 + 0.15 * glowPulse)
                                                                 endingColor:GF_HUD_GREEN(0.0)];
            [haloGrad drawInBezierPath:halo relativeCenterPosition:NSZeroPoint];
            [GF_HUD_GREEN(1.0) setFill];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(dotCX - dotR, dotCY - dotR, 2.0 * dotR, 2.0 * dotR)] fill];
        }

        // 13 ultra-sleek, symmetrical acoustic wave bars centered in the glass capsule
        int barCount = 13;
        CGFloat barWidth = 2.2;
        CGFloat barGap = 3.2;
        CGFloat totalWaveWidth = barCount * barWidth + (barCount - 1) * barGap;
        CGFloat waveStartX = bounds.origin.x + (bounds.size.width - totalWaveWidth) / 2.0;

        float profile[13] = {0.20f, 0.32f, 0.48f, 0.66f, 0.84f, 0.96f, 1.00f, 0.96f, 0.84f, 0.66f, 0.48f, 0.32f, 0.20f};

        for (int i = 0; i < barCount; i++) {
            CGFloat bx = waveStartX + i * (barWidth + barGap);
            CGFloat h = 3.5;
            NSColor *barColor = [NSColor whiteColor];

            if (self.mode == HUDModeThinking) {
                float shimmer = 0.5f + 0.5f * sinf(self.animPhase * 2.0f - i * 0.48f);
                h = 3.5 + (shimmer * profile[i]) * 13.5;
                barColor = [NSColor colorWithCalibratedRed:0.80 + 0.20 * shimmer green:0.88 + 0.12 * shimmer blue:1.0 alpha:0.92];
            } else if (self.mode == HUDModeListeningHandsFree) {
                float wave = 0.5f + 0.5f * sinf(self.animPhase * 1.4f - i * 0.50f);
                float idleBreath = 0.08f * wave * profile[i];
                float voiceHeight = self.smoothedLevel * (0.55f + 0.45f * sinf(self.animPhase * 2.2f + i * 0.65f)) * profile[i];
                float norm = fminf(1.0f, idleBreath + voiceHeight);
                h = 3.5 + norm * 16.5;
                // Same motion and heights as hold-to-talk, but in strong, high-alpha green (backlog 0s).
                barColor = GF_HUD_GREEN(0.86 + 0.14 * norm);
            } else {
                float wave = 0.5f + 0.5f * sinf(self.animPhase * 1.4f - i * 0.50f);
                float idleBreath = 0.08f * wave * profile[i];
                float voiceHeight = self.smoothedLevel * (0.55f + 0.45f * sinf(self.animPhase * 2.2f + i * 0.65f)) * profile[i];
                float norm = fminf(1.0f, idleBreath + voiceHeight);
                h = 3.5 + norm * 16.5;
                barColor = [NSColor colorWithCalibratedWhite:0.98 alpha:(0.58 + 0.42 * norm)];
            }

            CGFloat by = bounds.origin.y + (bounds.size.height - h) / 2.0;
            NSRect barRect = NSMakeRect(bx, by, barWidth, h);
            NSBezierPath *bp = [NSBezierPath bezierPathWithRoundedRect:barRect xRadius:1.1 yRadius:1.1];
            [barColor setFill];
            [bp fill];
        }
    } else {
        // Centered status text (e.g. "Done", "Cancelled", "No speech")
        NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
        style.alignment = NSTextAlignmentCenter;
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.96 alpha:1.0],
            NSParagraphStyleAttributeName: style
        };
        NSRect textRect = NSMakeRect(bounds.origin.x + 12.0, bounds.origin.y + (bounds.size.height - 16.0) / 2.0 + 1.0,
                                     bounds.size.width - 24.0, 16.0);
        [self.noticeText drawInRect:textRect withAttributes:attrs];
    }
}

@end

// Offscreen render of a HUD view into a fresh RGBA bitmap (premultiplied, 8 bits/channel, `scale` pixels per point), used by
// --test and --render-hud-png. With `backdrop`, a desktop-grey background and a dark pill (standing in for the frosted glass the
// window server draws) go underneath, so a PNG looks like the on-screen HUD.
static NSBitmapImageRep *GFRenderHUDView(FloatingHUDView *view, CGFloat scale, BOOL backdrop) {
    NSRect b = view.bounds;
    NSInteger w = (NSInteger)lround(b.size.width * scale), h = (NSInteger)lround(b.size.height * scale);
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h bitsPerSample:8
                                                               samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                                                                colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:w * 4 bitsPerPixel:32];
    if (!rep) return nil;
    rep.size = b.size;
    memset(rep.bitmapData, 0, (size_t)(w * h * 4));
    NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    if (!ctx) return nil;
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:ctx];
    if (backdrop) {
        [[NSColor colorWithCalibratedRed:0.86 green:0.87 blue:0.89 alpha:1.0] setFill];
        NSRectFill(b);
        NSRect pr = NSInsetRect(b, view.pillInset, view.pillInset);
        [[NSColor colorWithCalibratedWhite:0.16 alpha:0.92] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:pr xRadius:pr.size.height / 2.0 yRadius:pr.size.height / 2.0] fill];
    }
    [NSGraphicsContext restoreGraphicsState];
    [view displayRectIgnoringOpacity:b inContext:ctx];
    [ctx flushGraphics];
    return rep;
}

// Floating HUD Panel (compact frosted capsule)
@interface FloatingHUDPanel : NSPanel
@property (nonatomic, strong) FloatingHUDView *hudView;
@property (nonatomic, strong) NSTimer *animTimer;
- (void)setHUDMode:(HUDMode)mode noticeText:(NSString *)text;
- (void)updateAudioLevel:(float)level;
- (void)showCenteredNearBottom;
// Fades the HUD out, then hides it and stops the 60 fps timer, unless stillCurrent() says a newer presentation began
// during the fade (a new recording must never lose its HUD to an old dismissal).
- (void)fadeOutAndHideIf:(BOOL (^)(void))stillCurrent;
@end

@implementation FloatingHUDPanel

- (instancetype)init {
    // Window = pill + kHUDGlowPad on every side (an empty margin since backlog 0s); the pill keeps its old size and screen position.
    NSRect frame = NSMakeRect(0, 0, kHUDPillWidth + 2.0 * kHUDGlowPad, kHUDPillHeight + 2.0 * kHUDGlowPad);
    NSRect pillFrame = NSMakeRect(kHUDGlowPad, kHUDGlowPad, kHUDPillWidth, kHUDPillHeight);
    self = [super initWithContentRect:frame
                            styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                              backing:NSBackingStoreBuffered
                                defer:NO];
    if (self) {
        [self setOpaque:NO];
        [self setBackgroundColor:[NSColor clearColor]];
        [self setLevel:NSFloatingWindowLevel];
        [self setHidesOnDeactivate:NO];
        [self setIgnoresMouseEvents:YES];
        [self setHasShadow:YES];

        // Authentic macOS frosted glass using NSVisualEffectView with pill maskImage
        NSView *container = [[NSView alloc] initWithFrame:frame];
        NSVisualEffectView *vfx = [[NSVisualEffectView alloc] initWithFrame:pillFrame];
        vfx.material = NSVisualEffectMaterialHUDWindow;
        vfx.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        vfx.state = NSVisualEffectStateActive;
        vfx.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];

        // Mask image ensures pixel-perfect rounded pill blur and native shadow
        NSImage *maskImg = [NSImage imageWithSize:pillFrame.size flipped:NO drawingHandler:^BOOL(NSRect dstRect) {
            [[NSColor blackColor] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:dstRect xRadius:18.0 yRadius:18.0] fill];
            return YES;
        }];
        vfx.maskImage = maskImg;

        // The HUD view covers the whole window (pill + empty margin), drawn above the frosted pill.
        _hudView = [[FloatingHUDView alloc] initWithFrame:frame];
        _hudView.pillInset = kHUDGlowPad;
        _hudView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [container addSubview:vfx];
        [container addSubview:_hudView];

        [self setContentView:container];
    }
    return self;
}

- (BOOL)canBecomeKeyWindow {
    return NO;
}

- (BOOL)canBecomeMainWindow {
    return NO;
}

- (void)startTimerIfNeeded {
    if (!self.animTimer) {
        __weak typeof(self) weakSelf = self;
        self.animTimer = [NSTimer timerWithTimeInterval:(1.0 / 60.0) repeats:YES block:^(NSTimer * _Nonnull t) {
            [weakSelf.hudView advanceAnimation];
        }];
        [[NSRunLoop mainRunLoop] addTimer:self.animTimer forMode:NSRunLoopCommonModes];
    }
}

- (void)stopTimer {
    if (self.animTimer) {
        [self.animTimer invalidate];
        self.animTimer = nil;
    }
}

- (void)setHUDMode:(HUDMode)mode noticeText:(NSString *)text {
    self.hudView.mode = mode;
    if (text) self.hudView.noticeText = text;
    [self.hudView setNeedsDisplay:YES];
}

- (void)updateAudioLevel:(float)level {
    self.hudView.targetAudioLevel = level;
}

- (void)showCenteredNearBottom {
    NSScreen *screen = [NSScreen mainScreen];
    if (!screen && [NSScreen screens].count > 0) {
        screen = [NSScreen screens][0];
    }
    if (screen) {
        [self setFrameOrigin:GFHUDWindowOriginForVisibleFrame([screen visibleFrame], self.frame.size)];
    }

    [self startTimerIfNeeded];
    self.alphaValue = 0.0;
    [self orderFrontRegardless];
    [self invalidateShadow];

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext * _Nonnull context) {
        context.duration = 0.15;
        self.animator.alphaValue = 1.0;
    }];
}

- (void)fadeOutAndHideIf:(BOOL (^)(void))stillCurrent {
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext * _Nonnull context) {
        context.duration = 0.18;
        self.animator.alphaValue = 0.0;
    } completionHandler:^{
        if (stillCurrent && !stillCurrent()) return; // re-shown during the fade: keep it
        [self orderOut:nil];
        [self stopTimer];
    }];
}

@end

// App Delegate
// One press of the hotkey (backlog 6). When a new press starts before the previous dictation has finished (its Live final turn,
// REST safety net or on-device fallback still running), the previous one keeps its own snapshot here: its recording and its
// on-device transcript as of the new press. Its late fallbacks work from this snapshot, never from the new press's buffers, and
// its result is still delivered (clipboard, Recent Dictations, auto-paste) without touching the new press's HUD or menu icon.
@interface GFDictation : NSObject
@property (nonatomic, assign) NSUInteger serial;
@property (nonatomic, strong) NSData *pcm;           // frozen 16 kHz PCM, set when superseded (until then: self.recordedPCMData)
@property (nonatomic, copy) NSString *onDeviceText;  // on-device transcript frozen at the new press
@property (nonatomic, assign) BOOL superseded;       // a newer press started before this dictation finished
@property (nonatomic, assign) BOOL liveHadTextAtSupersede;      // backlog 0u: Live had text for it when the newer press started
@property (nonatomic, assign) BOOL onDeviceNoSpeechAtSupersede; // backlog 0u: on-device had said "No speech detected" by then
@property (nonatomic, assign) BOOL finished;         // delivered, or ended as no speech
@property (nonatomic, assign) NSTimeInterval releaseTime;
// Bounded wait (user-approved 2026-11-10): on-device text delivered early while a slow REST call runs, maybe swapped later
@property (nonatomic, strong) NSString *earlyText;           // the early on-device delivery (nil = none)
@property (nonatomic, assign) NSTimeInterval earlyPasteTime; // when its Cmd+V was posted (0 = not pasted)
@property (nonatomic, assign) pid_t earlyPid;                // frontmost app at that Cmd+V
@property (nonatomic, strong) id earlyElement;               // focused AXUIElement at that Cmd+V
@property (nonatomic, assign) BOOL earlyUserInput;           // a real keyDown/mouseDown since the early delivery
@property (nonatomic, assign) BOOL earlyResolved;            // the late REST outcome was handled
@end
@implementation GFDictation
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, SFSpeechRecognizerDelegate, NSURLSessionWebSocketDelegate>

@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenu *menu;
@property (nonatomic, strong) FloatingHUDPanel *hudPanel;
// HUD/menu state. Every HUD presentation (presentHUD) bumps hudGeneration; a delayed dismissal only acts if the generation
// it was scheduled under is still current, so a stale "Cancelled"/"No speech"/post-paste fade can't hide a new recording.
@property (nonatomic, assign) NSUInteger hudGeneration;
@property (nonatomic, assign) NSInteger menuIconState;          // 0 = idle, 1 = listening, 2 = thinking (set via setMenuIconState:)
@property (nonatomic, assign) NSUInteger hudDismissalsHonored;  // counters for the --test suite / diagnostics
@property (nonatomic, assign) NSUInteger hudDismissalsDropped;
@property (nonatomic, assign) BOOL unitTestMode;                // --test: keep the user's log file quiet

// Audio capture
@property (nonatomic, strong) AVAudioEngine *audioEngine;
@property (nonatomic, strong) NSMutableData *recordedPCMData; // 16kHz 16-bit mono PCM

// Hotkey state machine
@property (nonatomic, assign) BOOL isRecording;
@property (nonatomic, assign) BOOL isHandsFree;
@property (nonatomic, assign) BOOL fnKeyIsCurrentlyDown;
@property (nonatomic, assign) NSTimeInterval lastFnPressTime;
@property (nonatomic, assign) NSTimeInterval fnDownTimestamp;
@property (nonatomic, strong) id globalFlagsMonitor;
@property (nonatomic, strong) id localFlagsMonitor;
@property (nonatomic, strong) id globalKeyMonitor;
@property (nonatomic, strong) id localKeyMonitor;
@property (nonatomic, strong) NSTimer *permissionWatchTimer;
@property (nonatomic, assign) BOOL lastAXTrusted;
@property (nonatomic, assign) BOOL lastListenAccess;
@property (nonatomic, assign) NSInteger modifierEventLogCount;

// On-Device speech recognizer
@property (nonatomic, strong) SFSpeechRecognizer *speechRecognizer;
@property (atomic, strong) SFSpeechAudioBufferRecognitionRequest *recognitionRequest; // read from the audio thread
@property (nonatomic, strong) SFSpeechRecognitionTask *recognitionTask;
@property (nonatomic, copy) NSString *latestOnDeviceTranscript;   // full accumulated transcript (committed + current)
@property (nonatomic, assign) BOOL latestOnDeviceIsFinal;
@property (nonatomic, assign) BOOL onDeviceReportedNoSpeech; // recognizer ended with "No speech detected" (1110) after release
// Apple's recognizer (macOS 14+) restarts bestTranscription after every pause.
// Finished utterances are committed here so earlier speech is never lost.
@property (nonatomic, strong) NSMutableString *committedOnDeviceTranscript;
@property (nonatomic, copy) NSString *currentOnDeviceSegment;
@property (nonatomic, copy) NSString *lastCommittedOnDeviceSegment;
@property (nonatomic, assign) NSUInteger committedLengthBeforeLastSegment;
@property (nonatomic, assign) NSTimeInterval lastOnDeviceResultTime;
@property (nonatomic, assign) NSUInteger recognitionSessionId;
@property (nonatomic, assign) BOOL isFinalizingOnDevice;
@property (nonatomic, copy) void (^e2eCompletion)(NSString *finalText); // test hook
@property (nonatomic, copy) NSString *e2eAudioFile;                     // test hook: feed WAV instead of mic
@property (atomic, assign) BOOL e2eFeedRunning;
@property (atomic, assign) NSTimeInterval e2eFirstBufferTime;
@property (atomic, assign) BOOL micBuffersSeen;              // this press got at least one audio buffer (set on the audio thread)
@property (nonatomic, assign) NSTimeInterval micStartTime;   // when this press started the microphone
@property (nonatomic, assign) NSTimeInterval lastCapturedAudioEndTime; // backlog 27: wall time of the newest sample in recordedPCMData (main)
@property (nonatomic, assign) NSTimeInterval releaseFnUpTime;  // backlog 27: this press's Fn up (or e2e release); 0 = none yet
@property (nonatomic, assign) NSUInteger releasePCMBytesAtFnUp; // backlog 27: recordedPCMData length at that Fn up
@property (nonatomic, assign) NSUInteger micWatchdogGeneration;
@property (nonatomic, assign) BOOL micRebuildTried;          // this press already used its one automatic engine rebuild
@property (nonatomic, copy) NSString *lastMicNotice;         // notice of the last mic failure (diagnostics / --test)
@property (nonatomic, copy) NSString *e2eMicFail;            // test hook (e2e only): start | start-once | nobuffers | denied
@property (nonatomic, assign) NSUInteger e2eMicStartAttempts;
@property (nonatomic, copy) NSString *e2eMode;        // @"file" or @"mic"
@property (nonatomic, assign) double e2eMicSeconds;
@property (nonatomic, copy) NSString *e2eGeminiModel;  // test hook: run the Gemini path with this model
@property (nonatomic, assign) BOOL e2eRestFaultOnce;   // test hook (e2e only): first REST attempt fails with a fast HTTP 503
@property (nonatomic, assign) double e2eRestFaultDelay; // test hook (e2e only): seconds before that injected 503 arrives (0 = 0.15 s)
@property (nonatomic, assign) double e2eRestFakeOkDelay; // test hook (e2e only): first REST call answers a canned HTTP 200 after s (no network)
@property (nonatomic, copy) NSString *e2eRestFakeText;    // test hook (e2e only): overrides canned REST text for --e2e-rest-fake-ok
@property (nonatomic, assign) double e2eRestDelay;       // test hook (e2e only): first real REST call is held s before it is sent
@property (nonatomic, assign) BOOL e2eLiveDropOutput;  // test hook (e2e only): ignore Live serverContent (final turn closes empty)
@property (nonatomic, assign) NSTimeInterval e2ePressTime;
@property (nonatomic, assign) NSTimeInterval e2eReleaseTime;
@property (nonatomic, copy) NSString *e2eSecondPressFile;   // test hook (e2e only): a second press starts while the first finishes
@property (nonatomic, copy) NSString *e2eSecondPressPhase;  // @"release" | @"rest" | @"restfail" (see e2eStartSecondPress)
@property (nonatomic, assign) BOOL e2eSecondPressStarted;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *e2eDeliveredSerials;
@property (nonatomic, assign) BOOL e2eWavFallback;     // test hook (e2e only): ignore streaming on-device results -> WAV fallback
@property (nonatomic, copy) NSString *e2eWavHang;       // test hook (e2e only): the WAV recognizer never ends (final | all)
@property (nonatomic, assign) double e2eServerTurnEndAt;      // test hook (e2e only): simulate a server-initiated turn end at this many s sent
@property (nonatomic, assign) BOOL e2eServerTurnEndFired;
@property (nonatomic, assign) NSUInteger e2eHiddenEchoes;     // ACTIVITY_END echoes of the simulated end still to hide
@property (nonatomic, assign) double e2eLiveDropAt;           // test hook (e2e only): force-close the Live socket at this many s sent
@property (nonatomic, assign) BOOL e2eLiveDropFired;
@property (nonatomic, assign) double e2eLiveRotateAge;        // test hook (e2e only): planned rotation at this session age (s) instead of kLiveRotateAge
@property (nonatomic, assign) double e2eLiveLifetime;         // test hook (e2e only): every Live session is closed (1008) at this session age (s)
@property (nonatomic, assign) NSUInteger e2eLifetimeClosedSid; // liveSessionId of the socket the lifetime hook last closed
@property (nonatomic, assign) NSUInteger e2eLifetimeCloses;
@property (nonatomic, copy) NSDictionary *e2eLiveSetupExtra;      // test hook (e2e only, backlog 0y-probe): deep-merged into the Live `setup` object
@property (nonatomic, assign) NSTimeInterval e2eLiveSetupSentTime; // setup probe: when the current socket's setup message was sent
@property (nonatomic, strong) NSMutableSet<NSString *> *e2eLiveSeenFields; // setup probe: field NAMES of this session's server messages

// Gemini Live WebSocket session
@property (nonatomic, strong) NSURLSession *liveSession;
@property (nonatomic, strong) NSURLSessionWebSocketTask *liveWebSocketTask;
@property (nonatomic, strong) NSMutableString *liveReceivedTranscript;
@property (nonatomic, assign) BOOL liveWebSocketConnected;
@property (nonatomic, strong) NSDate *lastChunkSentDate;
@property (nonatomic, strong) NSMutableData *pendingLivePCMBuffer;
@property (nonatomic, assign) BOOL hasCompletedGeminiTurn;
@property (nonatomic, assign) NSUInteger liveSessionId;      // guards callbacks from an older socket
@property (nonatomic, assign) NSUInteger liveSentBytes;      // offset into recordedPCMData already streamed
@property (nonatomic, strong) NSMutableArray<NSString *> *liveSegments; // finalized utterance transcripts
@property (nonatomic, assign) BOOL liveSpeechActive;         // server VAD saw speech that isn't finalized yet
@property (nonatomic, assign) BOOL liveFinalizing;           // Fn released, waiting for the last transcript
@property (nonatomic, assign) BOOL liveActivityEnded;        // activityEnd already sent for this session
@property (nonatomic, assign) NSUInteger liveCoveredBytes;    // PCM bytes the server has confirmed as finished utterances
// Long hands-free sessions are split into several manual activities at local silences, because the server's
// release->text time grows with the length of the open activity (16 s: 0.5 s, 32 s: 0.7 s, 124 s: 1.55 s).
@property (nonatomic, assign) BOOL liveActivityOpen;          // activityStart sent, activityEnd not yet
@property (nonatomic, assign) NSUInteger liveActivityStartByte; // liveSentBytes when the open activity started
@property (nonatomic, assign) NSUInteger liveActivityCount;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *livePendingActivityEnds; // liveSentBytes at each activityEnd awaiting turnComplete
@property (nonatomic, assign) NSUInteger liveVoiceScannedBytes; // local voice scan progress (bytes)
@property (nonatomic, assign) NSUInteger liveLastVoicedByte;    // end of the last frame above the split threshold
@property (nonatomic, assign) NSUInteger liveLastActivityEndByte; // liveSentBytes at the last activityEnd (0 = none yet)
@property (nonatomic, assign) NSTimeInterval liveSplitTime;      // when the last split activityEnd was sent
@property (nonatomic, assign) BOOL liveTurnEndCounted;         // generationComplete already ended this turn
@property (nonatomic, assign) BOOL liveSplitDisabled;          // server ended a turn on its own: keep one activity (safety-net semantics)
@property (nonatomic, assign) BOOL liveFailed;
@property (nonatomic, assign) NSTimeInterval liveReleaseTime;
@property (nonatomic, assign) NSUInteger liveActivityEndsSent;   // activityEnd messages sent this session
@property (nonatomic, assign) NSUInteger liveActivityEndEchoes;  // server ACTIVITY_END echoes received this session
@property (nonatomic, assign) NSUInteger liveFinalEndIndex;      // liveActivityEndsSent value of the release's activityEnd (0 = none)
@property (nonatomic, assign) BOOL liveFinalReopenDeferred;       // released with speech held behind a pending split turn (backlog 0r)
@property (nonatomic, assign) BOOL liveTestSocketless;            // --test only: run the pump without a socket (sends are no-ops)
// Mid-press reconnect (backlog 0h): per press, not per socket
@property (nonatomic, assign) NSUInteger liveReconnects;         // reconnects used by this press (max kLiveMaxReconnects)
@property (nonatomic, assign) BOOL liveEverConnected;            // this press reached setupComplete at least once
@property (nonatomic, assign) NSTimeInterval liveSocketReadyTime; // setupComplete time of the CURRENT socket (0 = none; backlog 0m)
@property (nonatomic, assign) NSUInteger liveCoveredSegments;    // liveSegments.count when liveCoveredBytes last advanced
// Planned session rotation (backlog 0p): per press / per socket
@property (nonatomic, assign) NSUInteger liveRotations;          // planned rotations this press (never counted as reconnects)
@property (nonatomic, assign) BOOL liveSocketIsRotation;         // the current socket replaced a session by a planned rotation
@property (nonatomic, assign) BOOL liveQuietResume;              // at setupComplete: stay between activities (no activityStart)
@property (nonatomic, assign) BOOL liveGoAway;                   // the current socket received a goAway server message
// API key out of URLs (backlog 15)
@property (nonatomic, assign) GFLiveAuthMode liveAuthMode;       // per run: header auth confirmed / key-in-URL fallback in use
@property (nonatomic, assign) BOOL liveAuthViaHeader;            // the current Live session sent the key in x-goog-api-key
@property (nonatomic, assign) BOOL liveNextConnectKeyInURL;      // one-shot: the next connect is the key-in-URL retry
@property (nonatomic, assign) BOOL liveAuthRetrySession;         // the current session is that retry

// Recent dictations
@property (nonatomic, strong) NSMutableArray<NSString *> *recentDictations;

// Dictation sessions (backlog 6): one GFDictation per press; a superseded one finishes from its own snapshot.
@property (nonatomic, strong) GFDictation *activeDictation;  // the latest press (recording or finishing)
@property (nonatomic, assign) NSUInteger dictationSerial;
// Tests only (--test, two-press e2e): receives each result instead of clipboard/paste/HUD. nil text = no speech.
@property (nonatomic, copy) void (^resultSink)(NSString *text, GFDictation *d);
// Auto-paste is strictly ordered (backlog 6). deferredPastes: superseded dictations that finished while the newer press was still
// recording (pasted at its release or Esc). pasteQueue: texts waiting to be put on the clipboard and pasted, one at a time.
@property (nonatomic, strong) NSMutableArray<NSString *> *deferredPastes;
@property (nonatomic, strong) NSMutableArray<NSString *> *pasteQueue;
@property (nonatomic, assign) BOOL pasteInFlight;
@property (nonatomic, strong) NSMutableArray<NSString *> *pasteLog;  // --test only: pastes in order (no clipboard / Cmd+V)
@property (nonatomic, copy) NSString *testClipboard;                // --test only: what would be on the clipboard
@property (nonatomic, strong) GFDictation *earlyWatchDictation; // bounded wait: early-pasted dictation whose swap window is open
@property (nonatomic, strong) id earlyMouseMonitor;
@property (nonatomic, strong) id earlyLocalMouseMonitor;

// Menu items references
@property (nonatomic, strong) NSMenuItem *statusMenuItem;
@property (nonatomic, strong) NSMenuItem *geminiModeMenuItem;
@property (nonatomic, strong) NSMenuItem *onDeviceModeMenuItem;
@property (nonatomic, strong) NSMenu *recentSubmenu;

@end

// REST safety-net request budget. Short dictations keep the measured 8 s timeout (p50 ~2.5 s, p90 ~3.4 s; 3.2 s used to time
// out ~1 in 10 requests). Long recordings need more: upload + transcription of 124 s of audio timed out at 8 s (cycle 4), which
// lost the dictation to on-device partials. NSURLRequest's timeout is an idle timeout, so allow 0.25 s per audio second on top.
static NSTimeInterval GFRestTimeoutForAudioSeconds(double audioSeconds) {
    return 8.0 + 0.25 * MAX(0.0, audioSeconds);
}
// Output cap for REST. 512 tokens cut a ~2 min dictation at ~380 words; dictated speech is ~3-4 tokens/s, so 8192 covers
// well over 30 minutes. A cap only bounds the worst case, so it costs short dictations nothing.
static const NSInteger kRestMaxOutputTokens = 8192;
// REST safety-net retry (cycle 6). gemini-3.5-flash-lite sometimes answers HTTP 503 "high demand" (or 429) within ~2 s; without a
// retry the user got Apple's on-device text. Allow ONE retry after a short backoff, only for a transient status (429/5xx) that came
// back fast (within a quarter of the audio-scaled budget: 2 s for short dictations, ~10 s for 2 min of audio), never after a
// timeout or a slow failure. The retry's idle timeout is the budget left (at least 5 s), so a short dictation's worst case stays
// about one request budget (~8 s) instead of doubling it.
// Slow 429/503 (cycle 12, backlog 0f): on 2026-11-06 a real HTTP 503 "high demand" came back after 5.97 s on a 2.6 s clip, past
// the fast window, so the user got on-device text. An explicit 429/503 means the server never started the work (no partial
// result to wait for), so it is still worth ONE retry whenever the retry fits a bounded deadline: the audio-scaled budget plus
// kRestSlowRetryGrace (4 s). The retry gets the usual idle timeout (>= 5 s, a realistic REST call: healthy short calls take
// p50 ~2.5 s, p90 ~3.4 s), so a slow 429/503 is retried only if elapsed + backoff + 5 s <= budget + 4 s (short clip: by ~6.5-7 s).
// Worst case for a short dictation: budget + 4 s (~12-13 s) instead of on-device text. Never after a timeout, never twice, and
// never for other slow 5xx or any other 4xx (the request itself is wrong; retrying cannot help).
static const NSTimeInterval kRestRetryBackoff = 0.5;
static const NSTimeInterval kRestRetryMinTimeout = 5.0;
static const NSTimeInterval kRestSlowRetryGrace = 4.0;
static NSTimeInterval GFRestRetryTimeout(double audioSeconds, double spentSoFar) {
    return MAX(kRestRetryMinTimeout, GFRestTimeoutForAudioSeconds(audioSeconds) - MAX(0.0, spentSoFar));
}
static BOOL GFRestShouldRetry(NSInteger status, BOOL timedOut, NSUInteger retryIndex, double elapsed, double audioSeconds) {
    if (timedOut || retryIndex > 0) return NO;
    if (status != 429 && (status < 500 || status > 599)) return NO;
    double budget = GFRestTimeoutForAudioSeconds(audioSeconds);
    if (elapsed <= 0.25 * budget) return YES;          // fast transient failure (cycle 6)
    if (status != 429 && status != 503) return NO;     // slow: only an explicit "overloaded / try again" answer
    double spent = MAX(0.0, elapsed) + kRestRetryBackoff;
    return spent + GFRestRetryTimeout(audioSeconds, spent) <= budget + kRestSlowRetryGrace;
}

// Live empty final turn (cycle 8). With manual activity the server answers every activityEnd with one voiceActivity
// ACTIVITY_END echo, sent right AFTER that turn's generationComplete when there is text. When the release's activityEnd is
// echoed while its turn is still pending, the server closed the turn with no output: seen on every real no-transcript press
// (0.4-1.7 s, on-device "No speech detected"; no generationComplete ever came) and never on a press with speech. Without this,
// those presses waited out the 2.5 s cap before the REST safety net (~4.1 s total). echoIndex is the 1-based echo count;
// echoes of split activityEnds (index < finalEndIndex) never trigger it.
static BOOL GFLiveEchoMeansEmptyFinalTurn(NSUInteger echoIndex, NSUInteger finalEndIndex, NSUInteger pendingTurns) {
    return finalEndIndex > 0 && echoIndex == finalEndIndex && pendingTurns > 0;
}
// Grace after such an echo for a late generationComplete/transcript before falling back (in-order delivery makes it ~0).
static const NSTimeInterval kLiveEmptyTurnGrace = 0.15;
// Unsolicited Live turn end (backlog 0c). With manual activity the server ends a turn only when we send activityEnd (0 of 429 turn
// ends in GeminiFlow.log 2026-11-05..09 were unsolicited). If it ever ends one while the press is still recording, its activity is
// over and audio sent outside an activity is ignored: measured with --e2e-live-server-turn-end, the speech after it never reached
// Live and the dictation went through REST. Then mark our activity closed too, so the next voiced audio re-opens one (activityStart
// with 0.3 s pre-roll, the same path as after a split) and stays on Live. Never after release or once the final activityEnd is out.
static BOOL GFLiveReopenAfterUnsolicitedTurnEnd(NSUInteger pendingTurns, BOOL activityOpen, BOOL finalizing, BOOL activityEnded) {
    return pendingTurns == 0 && activityOpen && !finalizing && !activityEnded;
}
// Seam after a slow split turn (backlog 0r). T26 on 2026-11-12 11:25: after a 25.8 s resend a 27.07 s activity was split; its turn
// took 5.4 s. The old rule reopened ("merged") after 1.5 s and dropped the pending split end, so (a) the late generationComplete looked
// like a server-initiated turn end of the new activity: coverage jumped to everything sent (32.45 s, past the answered activity's end
// at 27.07 s), the app marked the new activity closed WITHOUT an activityEnd and sent a second activityStart into it; and (b) the
// server, still generating the split turn, lost the first ~2.2 s of audio sent in the new activity ("Finally, remember that the";
// the 2026-11-11 19:41 long run hit the same merge). The server handles one turn at a time: never open an activity while a turn is
// pending. Voiced audio after a split end is held (with its pre-roll) until the split turn ends, then sent inside the reopened
// activity; on release the final activity waits the same way (liveFinalReopenDeferred). 0 of 725 logged splits closed empty, and
// an empty split turn is still released by its ACTIVITY_END echo (GFLiveEchoPendingIndex), so the hold always ends.
typedef NS_ENUM(NSInteger, GFLiveBetweenAction) {
    GFLiveBetweenDropSilence = 0, // nothing voiced since the held position: keep only the pre-roll
    GFLiveBetweenHold,            // voiced audio waits for the pending split turn (before or after release)
    GFLiveBetweenReopen,          // nothing pending: activityStart, then the held audio from its pre-roll
};
static GFLiveBetweenAction GFLiveBetweenActivitiesDecision(BOOL voicedSinceHeld, NSUInteger pendingTurns) {
    if (!voicedSinceHeld) return GFLiveBetweenDropSilence;
    return pendingTurns > 0 ? GFLiveBetweenHold : GFLiveBetweenReopen;
}
// ACTIVITY_END echoes come one per activityEnd, in order, right after that turn's generationComplete. Index into
// livePendingActivityEnds of the activityEnd that echo #echoIndex belongs to when its turn has not ended yet, else -1 (its turn
// already ended, or the echo is not of an activityEnd we sent). Coverage on an echo advances only to that end, never to a later one.
static NSInteger GFLiveEchoPendingIndex(NSUInteger echoIndex, NSUInteger endsSent, NSUInteger pendingCount) {
    NSUInteger resolved = endsSent - MIN(endsSent, pendingCount);
    if (echoIndex == 0 || echoIndex > endsSent || echoIndex <= resolved) return -1;
    return (NSInteger)(echoIndex - 1 - resolved);
}

// Mid-press reconnect (backlog 0h). On 2026-11-10 13:31 the Live server closed the socket (close code 1011) 19 s into a 124 s
// hands-free press; the whole dictation then waited for REST at release (5.4 s). If the socket of an established session dies
// while the press is still recording (not finalizing, not closed by us: cancel/Esc/finish close it first), open a new session,
// send activityStart and resend the audio from liveCoveredBytes (the end of the last turn the server finished, so nothing is lost
// and nothing is sent twice: no pre-roll, no seam to dedupe). Text of finished turns is kept. At most kLiveMaxReconnects per press,
// after a short backoff, and only if the same press is still recording; otherwise (or after release) everything falls back as before.
static const NSUInteger kLiveMaxReconnects = 2;
static NSTimeInterval GFLiveReconnectBackoff(NSUInteger attempt) { return attempt == 0 ? 0.25 : 0.75; }
static BOOL GFLiveShouldReconnect(BOOL recording, BOOL finalizing, BOOL ourSocket, BOOL everConnected, NSUInteger reconnectsSoFar) {
    return recording && !finalizing && ourSocket && everConnected && reconnectsSoFar < kLiveMaxReconnects;
}
// Planned Live session rotation (backlog 0p). The Live server ends every session after ~10 min: on 2026-11-11 it closed a hands-free
// session at 590 s sent (close code 1008, "Socket is not connected"). The mid-press reconnect resumed from the covered byte with no
// loss, but it used one of the kLiveMaxReconnects per press, so a 30+ min dictation (or a real drop after 10 min) could exhaust the
// budget and fall back. Two layers, neither counted against the drop budget (real drops still count, max 2):
//  (a) proactive: once the session is kLiveRotateAge old and the press sits at a split point (no activity open, no turn pending:
//      every sent byte is in a finished turn), open a fresh session at once and continue from there. No new seam: the split
//      already ended the turn. Audio captured while it connects is buffered and sent on setupComplete (pre-roll as after a split).
//  (b) fallback: a close of a session at least kLivePlannedCloseAge old (or after a goAway message, at least kLiveGoAwayMinAge old)
//      while recording is the planned end of the session, not a drop: resume like a reconnect (from the covered byte), uncounted.
// Each needs a session of that age, so they can't loop. A rotation socket that fails to connect is a real drop (no age yet).
static const double kLiveRotateAge = 510.0;        // 8.5 min
static const double kLivePlannedCloseAge = 570.0;  // 9.5 min (observed close: ~589 s of session age)
static const double kLiveGoAwayMinAge = 30.0;
static const double kLiveE2EMinRotateAge = 5.0;    // floor for the e2e-only overrides
static BOOL GFLiveShouldRotate(BOOL recording, BOOL finalizing, BOOL activityEnded, BOOL connected, BOOL activityOpen,
                               NSUInteger pendingTurns, double sessionAge, BOOL goAway, double rotateAge) {
    if (!recording || finalizing || activityEnded || !connected || activityOpen || pendingTurns > 0 || isnan(sessionAge)) return NO;
    return sessionAge >= rotateAge || (goAway && sessionAge >= kLiveGoAwayMinAge);
}
static BOOL GFLiveCloseIsPlannedRotation(BOOL recording, BOOL finalizing, BOOL ourSocket, double sessionAge, BOOL goAway,
                                         double plannedCloseAge) {
    if (!recording || finalizing || !ourSocket || isnan(sessionAge)) return NO;
    return sessionAge >= plannedCloseAge || (goAway && sessionAge >= kLiveGoAwayMinAge);
}

// API key out of URLs (backlog 15). A `?key=` URL leaks into NSError userInfo (NSURLErrorFailingURLStringErrorKey) and any logged
// URL. REST and every other HTTP request send the key in the x-goog-api-key header instead. Live sends the same header on the
// WebSocket upgrade; if that session dies with an auth-type error before setupComplete, the connect is retried ONCE with the key
// in the URL (the old method), and the URL method is then kept for the rest of the run. GFLog redacts secrets defensively.
static NSString * const kGeminiRESTBase = @"https://generativelanguage.googleapis.com/v1beta";
static NSString * const kGeminiLiveWSURL = @"wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent";
static NSString * const kGeminiKeyHeader = @"x-goog-api-key";

// Scrub anything key-like from a log line: the configured key itself, `key=` / `key%3D` query values, x-goog-api-key header
// values and anything shaped like a Google API key (AIza...). Over-redaction is harmless in a log.
static NSString *GFRedactSecrets(NSString *s, NSString *knownKey) {
    if (s.length == 0) return s;
    NSString *out = s;
    if (knownKey.length >= 8) out = [out stringByReplacingOccurrencesOfString:knownKey withString:@"<redacted>"];
    static NSArray<NSRegularExpression *> *res; static dispatch_once_t once;
    dispatch_once(&once, ^{
        res = @[[NSRegularExpression regularExpressionWithPattern:@"((?:(?<![A-Za-z0-9])|(?<=%3F)|(?<=%26))(?:api)?key(?:=|%3D))[^&\\s\"'<>#)]+" options:NSRegularExpressionCaseInsensitive error:nil],
                [NSRegularExpression regularExpressionWithPattern:@"(x-goog-api-key[\"']?\\s*[:=]\\s*[\"']?)[^\\s\"',;)}]+"
                                                          options:NSRegularExpressionCaseInsensitive error:nil],
                [NSRegularExpression regularExpressionWithPattern:@"()AIza[0-9A-Za-z_\\-]{20,}" options:0 error:nil]];
    });
    for (NSRegularExpression *re in res) {
        if ([out rangeOfString:@"key" options:NSCaseInsensitiveSearch].location == NSNotFound && ![out containsString:@"AIza"]) break;
        out = [re stringByReplacingMatchesInString:out options:0 range:NSMakeRange(0, out.length) withTemplate:@"$1<redacted>"];
    }
    return out;
}

// Every Gemini HTTP request: key in the header, never in the URL.
static NSMutableURLRequest *GFGeminiRequest(NSURL *url, NSString *apiKey) {
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url];
    if (apiKey.length > 0) [r setValue:apiKey forHTTPHeaderField:kGeminiKeyHeader];
    return r;
}
static NSURL *GFGenerateContentURL(NSString *model) {
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@/models/%@:generateContent", kGeminiRESTBase, model]];
}
static NSURL *GFRestWarmupURL(void) { return [NSURL URLWithString:[kGeminiRESTBase stringByAppendingString:@"/models?pageSize=1"]]; }
static NSURL *GFModelInfoURL(NSString *model) { return [NSURL URLWithString:[NSString stringWithFormat:@"%@/models/%@", kGeminiRESTBase, model]]; }
// Live upgrade request: header auth, or (keyInURL: the one-shot fallback) the key as a query item and no header.
static NSMutableURLRequest *GFLiveWebSocketRequest(NSString *apiKey, BOOL keyInURL) {
    NSURL *url = [NSURL URLWithString:kGeminiLiveWSURL];
    if (!keyInURL) return GFGeminiRequest(url, apiKey);
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    c.queryItems = @[[NSURLQueryItem queryItemWithName:@"key" value:apiKey ?: @""]];
    return [NSMutableURLRequest requestWithURL:c.URL ?: url];
}
// Live setup message: the first frame on the socket (startGeminiLiveWebSocketResuming: explains why it looks like this).
// `extra` is a TEST HOOK (e2e only: --e2e-live-setup-extra <json>, backlog 0y-probe): a JSON object deep-merged into the `setup`
// object, so one online probe run can try setup fields the real server may or may not accept (inputAudioTranscription with
// languageCodes / customVocabulary / mode, at any nesting) without a rebuild. Dictionaries merge key by key; anything else (arrays,
// strings, numbers) replaces the old value; null removes the key. nil or {} gives exactly the message the app has always sent,
// and the normal app never passes anything else (liveSetupProbeExtra).
static id GFJSONDeepMerge(id base, id extra) {
    if (![extra isKindOfClass:[NSDictionary class]]) return extra;
    NSMutableDictionary *out = [base isKindOfClass:[NSDictionary class]] ? [(NSDictionary *)base mutableCopy] : [NSMutableDictionary dictionary];
    for (id key in (NSDictionary *)extra) {
        id v = ((NSDictionary *)extra)[key];
        if (v == [NSNull null]) [out removeObjectForKey:key];
        else out[key] = GFJSONDeepMerge(out[key], v);
    }
    return out;
}
static NSDictionary *GFLiveSetupMessage(NSString *model, NSDictionary *extra) {
    NSDictionary *setup = @{@"model": [NSString stringWithFormat:@"models/%@", model],
                            @"generationConfig": @{@"responseModalities": @[@"TEXT"]},
                            @"realtimeInputConfig": @{@"automaticActivityDetection": @{@"disabled": @YES}}};
    if ([extra isKindOfClass:[NSDictionary class]] && extra.count > 0) setup = GFJSONDeepMerge(setup, extra);
    return @{@"setup": setup};
}
// The --e2e-live-setup-extra argument as a dictionary; nil unless it is a JSON object.
static NSDictionary *GFParseLiveSetupExtra(NSString *json) {
    NSData *d = [json dataUsingEncoding:NSUTF8StringEncoding];
    id obj = d.length > 0 ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}
// Field NAMES of a JSON value as dotted paths (dictionaries are followed `depth` levels down). Values are never included.
static void GFJSONCollectKeyPaths(id obj, NSString *prefix, int depth, NSMutableSet<NSString *> *into) {
    if (depth > 0 && [obj isKindOfClass:[NSDictionary class]] && [(NSDictionary *)obj count] > 0) {
        for (id k in (NSDictionary *)obj)
            GFJSONCollectKeyPaths(((NSDictionary *)obj)[k], prefix.length > 0 ? [NSString stringWithFormat:@"%@.%@", prefix, k] : [k description],
                                  depth - 1, into);
    } else if (prefix.length > 0) {
        [into addObject:prefix];
    }
}
// Setup probe log lines (e2e only). They carry numbers, flags, field names and the server's own close / error text: never dictated
// text, never the key (GFLog redacts as always). One line each, in a fixed shape that .autoimprove/tests/run_tests.py parses
// (parse_probe; checked offline against --dump-live-probe-lines).
static NSString *GFLiveProbeClean(NSString *s, NSUInteger maxLen) {
    NSString *t = [[(s ?: @"") componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "];
    t = [t stringByReplacingOccurrencesOfString:@"\"" withString:@"'"];
    return t.length > maxLen ? [[t substringToIndex:maxLen] stringByAppendingString:@"..."] : t;
}
static NSString *GFLiveProbeJoinedNames(NSSet<NSString *> *names) {
    return [[names.allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@", "];
}
static NSString *GFLiveProbeSetupLine(NSUInteger sid, NSDictionary *extra, NSUInteger setupBytes, BOOL keyInURL) {
    NSMutableSet<NSString *> *paths = [NSMutableSet set];
    if (extra.count > 0) GFJSONCollectKeyPaths(extra, @"setup", 8, paths);
    return [NSString stringWithFormat:@"E2E: Live setup probe: session %lu sends the setup with %lu extra field(s) [%@] (%lu bytes, key via %@)",
            (unsigned long)sid, (unsigned long)paths.count, GFLiveProbeJoinedNames(paths), (unsigned long)setupBytes, keyInURL ? @"URL" : @"header"];
}
static NSString *GFLiveProbeSetupCompleteLine(NSUInteger sid, BOOL viaHeader, double msSinceSetupSent) {
    return [NSString stringWithFormat:@"E2E: Live setup probe: setupComplete=1 (session %lu, key via %@, %.0f ms after the setup was sent)",
            (unsigned long)sid, viaHeader ? @"header" : @"URL", msSinceSetupSent];
}
static NSString *GFLiveProbeCloseLine(BOOL setupDone, NSUInteger sid, BOOL viaHeader, NSInteger httpStatus, NSInteger closeCode,
                                      NSString *closeReason, NSString *errDomain, NSInteger errCode) {
    return [NSString stringWithFormat:@"E2E: Live setup probe: socket closed %@ setupComplete (setupComplete=%d, session %lu, key via %@, HTTP %ld, "
            @"close code %ld, error %@ %ld) close reason \"%@\"", setupDone ? @"after" : @"before", setupDone, (unsigned long)sid,
            viaHeader ? @"header" : @"URL", (long)httpStatus, (long)closeCode,
            errDomain.length > 0 ? [errDomain stringByReplacingOccurrencesOfString:@" " withString:@"_"] : @"none", (long)errCode,
            GFLiveProbeClean(closeReason, 400)];
}
// nil unless the server message is an error frame ({"error": {...}}).
static NSString *GFLiveProbeErrorFrameLine(NSDictionary *json, BOOL setupDone) {
    id e = [json isKindOfClass:[NSDictionary class]] ? json[@"error"] : nil;
    if (!e) return nil;
    NSDictionary *err = [e isKindOfClass:[NSDictionary class]] ? e : nil;
    id code = err[@"code"], status = err[@"status"], msg = err[@"message"];
    return [NSString stringWithFormat:@"E2E: Live setup probe: server error frame (setupComplete=%d, code %ld, status %@) message \"%@\"", setupDone,
            [code respondsToSelector:@selector(integerValue)] ? (long)[code integerValue] : 0L,
            [status isKindOfClass:[NSString class]] && [status length] > 0 ? [GFLiveProbeClean(status, 60) stringByReplacingOccurrencesOfString:@" " withString:@"_"] : @"none",
            GFLiveProbeClean([msg isKindOfClass:[NSString class]] ? msg : ([e isKindOfClass:[NSString class]] ? e : nil), 400)];
}
static NSString *GFLiveProbeFieldsLine(NSSet<NSString *> *names) {
    return [NSString stringWithFormat:@"E2E: Live setup probe: server message fields seen: [%@]", GFLiveProbeJoinedNames(names)];
}
// Did a Live session die because the server rejected its credentials? (handshake answered 4xx instead of 101, policy-violation /
// invalid-payload close, an auth-ish close reason, or NSURLSession's bad-response / authentication errors). Network-level
// failures (offline, DNS, timeouts, resets) are NOT auth: they fail exactly as before.
static BOOL GFLiveFailureLooksLikeAuth(NSInteger httpStatus, NSInteger closeCode, NSString *closeReason, NSString *errDomain, NSInteger errCode) {
    if (httpStatus >= 400 && httpStatus < 500) return YES;
    if (closeCode == 1007 || closeCode == 1008) return YES;
    NSString *r = closeReason.lowercaseString ?: @"";
    for (NSString *w in @[@"api key", @"api_key", @"apikey", @"unauthenticated", @"unauthorized", @"permission", @"credential", @"authenticat"])
        if ([r containsString:w]) return YES;
    if ([errDomain isEqualToString:NSURLErrorDomain]
        && (errCode == NSURLErrorBadServerResponse || errCode == NSURLErrorUserAuthenticationRequired || errCode == NSURLErrorUserCancelledAuthentication))
        return YES;
    return NO;
}
// Retry a failed connect once with the key in the URL? Only a header-auth session that never reached setupComplete, while header
// auth is unconfirmed this run, the press is still recording (not released: a release before setup takes REST as before), and the
// failure looks like auth.
static BOOL GFLiveShouldRetryWithKeyInURL(BOOL viaHeader, BOOL setupDone, GFLiveAuthMode mode, BOOL recording, BOOL finalizing, BOOL ourSocket,
                                          BOOL authLike) {
    return viaHeader && !setupDone && mode != GFLiveAuthHeaderOK && recording && !finalizing && ourSocket && authLike;
}

// No-speech presses (backlog 0e, approved by the user 2026-11-06 13:43). REST invents fluent text for noise-only audio
// ("The quick brown fox...", "00:00"), and the app pasted it on accidental taps. A press ends as "No speech" WITHOUT calling
// REST only when ALL THREE independent signals agree:
//   (a) Live closed the release's final turn with no output and no earlier turn had text (GFLiveEchoMeansEmptyFinalTurn),
//   (b) Apple on-device explicitly reported "No speech detected" (kAFAssistantErrorDomain 1110) after release, with no text,
//   (c) almost no audio above a low absolute level: <= 0.10 s of 20 ms frames above RMS 60 (about -55 dBFS).
// If ANY signal suggests speech, REST runs exactly as before. (c) is deliberately absolute, not noise-relative: the adaptive
// estimate (voicedSecondsInRecordingFromByte, floor 150) reads a 0.43 s all-speech word as 0.02 s voiced, while this check
// reads it as 0.42 s, and speech at -36 dB still reads 0.56 s. A noisy room just keeps today's REST path.
static const double kNoSpeechFrameRMS = 60.0;
static const double kNoSpeechMaxLoudSeconds = 0.10;
static const NSTimeInterval kNoSpeechOnDeviceWait = 0.6; // max wait for on-device's verdict after Live's empty turn
// Seconds of 20 ms frames (16 kHz mono int16) whose RMS exceeds `threshold`; *maxRMS gets the loudest frame's RMS.
static double GFSecondsAboveRMS(const int16_t *samples, NSUInteger count, double threshold, double *maxRMS) {
    const NSUInteger frame = 320;
    NSUInteger loud = 0;
    double peak = 0;
    for (NSUInteger f = 0; samples && (f + 1) * frame <= count; f++) {
        double acc = 0;
        for (NSUInteger i = 0; i < frame; i++) { double v = samples[f * frame + i]; acc += v * v; }
        double r = sqrt(acc / frame);
        if (r > peak) peak = r;
        if (r > threshold) loud++;
    }
    if (maxRMS) *maxRMS = peak;
    return loud * 0.02;
}
// Backlog 0u (user-reported + user-approved 2026-11-12: silence must end as "No speech"). Signal (c) above counts frames above an
// ABSOLUTE RMS 60, which an ordinary quiet room exceeds (real 2026-11-12 16:01: a silent 2.3 s hold read 1.82 s, max RMS 156;
// 0.39 s taps read 0.20 s, max RMS 133-239), so silent presses went to REST, which invented text. Speech evidence a quiet room
// cannot pass: the loudest 20 ms frame must reach RMS 350 (about -40 dBFS) AND >= 0.10 s of frames must exceed the press's own
// noise floor by 3x (floor = 20th-percentile frame RMS; threshold at least RMS 250, at most RMS 1000 (about -30 dBFS) so a press
// that is ALL speech, e.g. a 0.4 s "Hello.", whose 20th percentile is speech, still counts). Test clips: room noise and clicks
// 0.00-0.06 s; the quietest test speech (T6/T11 quiet, -18 dB) peaks at RMS 837 with 1.42 s; a 0.6 s "Thanks." 0.22 s.
static const double kSpeechPeakRMS = 350.0;
static const double kSpeechEvidenceFloorRMS = 250.0;
static const double kSpeechEvidenceCapRMS = 1000.0;
static const double kSpeechEvidenceNoiseMult = 3.0;
static const double kSpeechEvidenceMinSeconds = 0.10;
typedef struct { double peakRMS, noiseRMS, thresholdRMS, evidenceSeconds, loudSeconds; } GFSpeechEvidence;
static double GFSpeechEvidenceThreshold(double noiseRMS) {
    return MIN(MAX(kSpeechEvidenceFloorRMS, kSpeechEvidenceNoiseMult * noiseRMS), kSpeechEvidenceCapRMS);
}
static GFSpeechEvidence GFMeasureSpeechEvidence(const int16_t *samples, NSUInteger count) {
    GFSpeechEvidence e = {0, 0, kSpeechEvidenceFloorRMS, 0, 0};
    const NSUInteger frame = 320;
    NSUInteger total = samples ? count / frame : 0;
    if (total == 0) return e;
    double *rms = malloc(sizeof(double) * total), *sorted = malloc(sizeof(double) * total);
    if (!rms || !sorted) { free(rms); free(sorted); e.peakRMS = 1e9; e.evidenceSeconds = 1e9; e.loudSeconds = 1e9; return e; } // fail-safe: speech
    NSUInteger loud = 0;
    for (NSUInteger f = 0; f < total; f++) {
        double acc = 0;
        for (NSUInteger i = 0; i < frame; i++) { double v = samples[f * frame + i]; acc += v * v; }
        rms[f] = sqrt(acc / frame);
        if (rms[f] > e.peakRMS) e.peakRMS = rms[f];
        if (rms[f] > kNoSpeechFrameRMS) loud++;
    }
    memcpy(sorted, rms, sizeof(double) * total);
    qsort_b(sorted, total, sizeof(double), ^int(const void *a, const void *b) {
        double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : (x > y ? 1 : 0);
    });
    e.noiseRMS = sorted[total / 5];
    e.thresholdRMS = GFSpeechEvidenceThreshold(e.noiseRMS);
    NSUInteger ev = 0;
    for (NSUInteger f = 0; f < total; f++) if (rms[f] > e.thresholdRMS) ev++;
    free(rms); free(sorted);
    e.evidenceSeconds = ev * 0.02;
    e.loudSeconds = loud * 0.02;
    return e;
}
// YES = nothing in the audio a quiet room couldn't produce on its own.
static BOOL GFNoLoudSpeech(double peakRMS, double evidenceSeconds) {
    return peakRMS < kSpeechPeakRMS || evidenceSeconds < kSpeechEvidenceMinSeconds;
}
// Backlog 0u (4): last net on REST's output for a press where Live produced no text AND on-device explicitly heard nothing
// ("No speech detected", no text). REST invents fluent text for noise ("00:00 ...", "0:00 --", whole sentences). Reject output
// that starts with a zero timestamp, or is longer than 10 chars + 40 chars per second of speech audio (0 s when the press has no
// loud speech; else the larger of the evidence and the RMS-60 seconds). Real test speech reads <= 32 chars per such second
// (quiet_long, -26 dB). Decided on numbers only; nothing about the text is logged.
static const double kRestCharsBase = 10.0;
static const double kRestCharsPerSpeechSecond = 40.0;
static const NSUInteger kRestPlausibilityMaxNoiseOnDeviceChars = 4; // room noise can coax 1-3 stray chars out of SFSpeechRecognizer
typedef NS_ENUM(NSInteger, GFRestPlausibility) {
    GFRestPlausible = 0, GFRestImplausibleTimestamp, GFRestImplausibleLength, GFRestImplausiblePromptEcho
};
static BOOL GFRestPlausibilityNetApplies(NSUInteger liveSegments, BOOL onDeviceSaidNoSpeech, NSUInteger onDeviceChars) {
    return liveSegments == 0 && onDeviceSaidNoSpeech && onDeviceChars == 0;
}
// Also check plausibility when the audio has no loud speech and on-device heard at most a tiny noise blip (<= 4 chars), even if
// on-device didn't report 1110 (seen 2026-11-12 21:39: max RMS 118, evidence 0.00 s, ondevice_chars 2 -> REST echoed the prompt).
static BOOL GFRestShouldCheckPlausibility(NSUInteger liveSegments, BOOL onDeviceSaidNoSpeech, NSUInteger onDeviceChars, BOOL noLoudSpeech) {
    if (liveSegments > 0) return NO;
    if (GFRestPlausibilityNetApplies(liveSegments, onDeviceSaidNoSpeech, onDeviceChars)) return YES;
    return noLoudSpeech && onDeviceChars <= kRestPlausibilityMaxNoiseOnDeviceChars;
}
// Rejects REST echoing our own prompt ("Transcribe and clean up this audio dictation." / "...this text." / system prompt text)
// when neither Live nor on-device corroborated the word "transcribe".
static BOOL GFRestIsPromptEcho(NSString *text) {
    if (text.length == 0) return NO;
    NSString *norm = [[text lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    norm = [norm stringByTrimmingCharactersInSet:[NSCharacterSet punctuationCharacterSet]];
    while ([norm containsString:@"  "]) norm = [norm stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    if ([norm hasPrefix:@"transcribe and clean up this"]) return YES;
    if ([norm isEqualToString:@"transcribe this audio dictation"] || [norm isEqualToString:@"transcribe audio dictation"]) return YES;
    if ([norm hasPrefix:@"you are a voice dictation and transcription engine"]) return YES;
    if ([norm containsString:@"output only the clean, punctuated transcript"]
        || [norm containsString:@"output only the final text with no commentary"]) return YES;
    return NO;
}
static BOOL GFRestEchoRejected(NSString *restText, NSUInteger liveSegments, NSString *onDeviceText) {
    if (liveSegments > 0 || !GFRestIsPromptEcho(restText)) return NO;
    if (onDeviceText.length > 0 && [[onDeviceText lowercaseString] containsString:@"transcribe"]) return NO;
    return YES;
}
static NSUInteger GFRestCharBudget(BOOL noLoudSpeech, double evidenceSeconds, double loudSeconds) {
    double speech = noLoudSpeech ? 0.0 : MAX(0.0, MAX(evidenceSeconds, loudSeconds));
    return (NSUInteger)floor(kRestCharsBase + kRestCharsPerSpeechSecond * MIN(speech, 36000.0));
}
static BOOL GFHasZeroTimestampPrefix(NSString *text) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ re = [NSRegularExpression regularExpressionWithPattern:@"^\\s*[\\[(]?0{1,2}:0[0-9]" options:0 error:nil]; });
    return text.length > 0 && [re firstMatchInString:text options:0 range:NSMakeRange(0, text.length)] != nil;
}
static GFRestPlausibility GFRestOutputPlausibility(NSString *text, NSUInteger charBudget) {
    if (GFHasZeroTimestampPrefix(text)) return GFRestImplausibleTimestamp;
    if (text.length > charBudget) return GFRestImplausibleLength;
    return GFRestPlausible;
}
static const char *GFRestPlausibilityName(GFRestPlausibility p) {
    if (p == GFRestPlausible) return "kept";
    if (p == GFRestImplausibleTimestamp) return "rejected (zero-timestamp prefix), no speech";
    if (p == GFRestImplausiblePromptEcho) return "rejected (prompt echo), no speech";
    return "rejected (too long for the audio), no speech";
}
// Backlog 27 (MEASUREMENT ONLY, since cycle 25): the release waits a fixed 120 ms cushion after Fn up before it stops the press.
// To size it from real data, each release logs (numbers only, never text) how far past Fn up the captured audio reaches at the
// stop and how long the cushion really waited. No timing is changed.
// Wall-clock (NSDate reference) time of a captured buffer's LAST sample: from its AVAudioTime host time when valid (mic tap),
// else the moment the buffer entered the pipeline (e2e file feed: paced in real time, so that moment is its audio end).
static NSTimeInterval GFCapturedBufferEndTime(NSTimeInterval nowWall, double nowHostSeconds, BOOL hostTimeValid,
                                              double bufferStartHostSeconds, double frames, double sampleRate) {
    if (!hostTimeValid || sampleRate <= 0 || frames < 0) return nowWall;
    return nowWall - (nowHostSeconds - (bufferStartHostSeconds + frames / sampleRate));
}
// ms of captured audio past Fn up (negative: the captured audio ends before Fn up); NAN when either time is unknown.
static double GFAudioReachPastReleaseMs(NSTimeInterval audioEndTime, NSTimeInterval fnUpTime) {
    if (audioEndTime <= 0 || fnUpTime <= 0) return NAN;
    return (audioEndTime - fnUpTime) * 1000.0;
}
static NSString *GFReleaseCushionLogLine(double reachMs, double waitedMs, double tailMs, double tailMaxRMS) {
    NSString *reach = isnan(reachMs) ? @"n/a" : [NSString stringWithFormat:@"%+.0f ms", reachMs];
    return [NSString stringWithFormat:@"Release cushion: captured audio reaches %@ past Fn up; stopped %.0f ms after Fn up; "
                                      @"%.0f ms of audio arrived after Fn up (max RMS %.0f)", reach, waitedMs, tailMs, tailMaxRMS];
}
// Backlog 0m: one numbers-only line per press at release (never text): the press's total audio and the age of the Live socket in
// use, so long hands-free presses (and the daily 5/10 min online run) show how close they come to the Live session lifetime
// (~15 min per Google's docs) and to the REST inline-audio limit (~8 min of WAV). Age = since the CURRENT socket's setupComplete
// (a mid-press reconnect starts a new session); NAN when no socket is up.
static double GFLiveSessionAgeSeconds(NSTimeInterval now, NSTimeInterval socketReadyTime) {
    if (socketReadyTime <= 0 || now < socketReadyTime) return NAN;
    return now - socketReadyTime;
}
static NSString *GFPressStatsLogLine(double audioSeconds, BOOL liveUsed, double liveAgeSeconds, NSUInteger reconnects,
                                     NSUInteger activities) {
    NSString *audio = [NSString stringWithFormat:@"Press stats: %.1f s of audio", MAX(0.0, audioSeconds)];
    if (!liveUsed) return [audio stringByAppendingString:@"; Live not used"];
    NSString *age = isnan(liveAgeSeconds) ? @"n/a" : [NSString stringWithFormat:@"%.1f s", liveAgeSeconds];
    return [NSString stringWithFormat:@"%@; Live session age at release %@; reconnects %lu; Live activities %lu", audio, age,
                                      (unsigned long)reconnects, (unsigned long)activities];
}
// Backlog 0p: the same line plus "; planned rotations N" when a press rotated its Live session (unchanged otherwise).
static NSString *GFPressStatsLogLineWithRotations(double audioSeconds, BOOL liveUsed, double liveAgeSeconds, NSUInteger reconnects,
                                                  NSUInteger activities, NSUInteger rotations) {
    NSString *line = GFPressStatsLogLine(audioSeconds, liveUsed, liveAgeSeconds, reconnects, activities);
    if (!liveUsed || rotations == 0) return line;
    return [line stringByAppendingFormat:@"; planned rotations %lu", (unsigned long)rotations];
}
// Backlog 0u: besides the original three-signal rule, Live empty + no on-device text + no loud speech (GFNoLoudSpeech) is no speech.
static BOOL GFNoSpeechVerdict(BOOL liveFinalTurnEmpty, NSUInteger liveSegments, BOOL onDeviceSaidNoSpeech,
                              NSUInteger onDeviceChars, double loudSeconds, BOOL noLoudSpeech) {
    if (!liveFinalTurnEmpty || liveSegments > 0 || onDeviceChars > 0) return NO;
    return (onDeviceSaidNoSpeech && loudSeconds <= kNoSpeechMaxLoudSeconds) || noLoudSpeech;
}

// Live text counts as complete when at most this much voiced audio (adaptive estimate) is not covered by a finished turn.
static const double kLiveUncoveredSpeechLimit = 0.35;
// A new press started while the previous press's Live final turn was still pending (backlog 6). The new press needs the
// microphone and the Live session, so the old turn can't be awaited. Deliver the old press's Live text only if it already covers
// its speech; otherwise re-run the old press's own recording through REST. With no Live text, no on-device text and almost no
// audio above the no-speech level (an accidental tap), end it as no speech instead (REST invents text for noise). Before this fix
// every such press was silently dropped (REST read the NEW press's empty buffer).
typedef NS_ENUM(NSInteger, GFSupersededLiveAction) { GFSupersededUseLiveText, GFSupersededUseRest, GFSupersededNoSpeech };
// Backlog 0u: no Live text + no on-device text + no loud speech (GFNoLoudSpeech) is no speech too (real 2026-11-12: a silent 2.1 s
// hold read loud 1.58 s above RMS 60 and REST invented text for it).
static GFSupersededLiveAction GFSupersededLiveDecision(NSUInteger liveSegments, double uncoveredVoicedSeconds,
                                                       NSUInteger onDeviceChars, double loudSeconds, BOOL noLoudSpeech) {
    if (liveSegments > 0) return uncoveredVoicedSeconds > kLiveUncoveredSpeechLimit ? GFSupersededUseRest : GFSupersededUseLiveText;
    if (onDeviceChars == 0 && (loudSeconds <= kNoSpeechMaxLoudSeconds || noLoudSpeech)) return GFSupersededNoSpeech;
    return GFSupersededUseRest;
}
// Backlog 26: the release found no activity open and no turn pending (the user paused >= 0.6 s after >= 8 s of activity, that split
// turn was answered while Fn was still held, and nothing voiced came after it). Nothing is left to wait for, but only the 0.45 s
// grace timer used to finish such a press (real 2026-11-10 09:22: "done in 0.47s"). Decide at once with that timer's own rules:
// voiced audio no finished turn covers -> REST (never finish with less than was said); text -> finish now; no text at all -> wait
// (the grace timer / 2.5 s cap decide, as before).
typedef NS_ENUM(NSInteger, GFLiveIdleReleaseAction) { GFLiveIdleReleaseWait = 0, GFLiveIdleReleaseFinish, GFLiveIdleReleaseRest };
static GFLiveIdleReleaseAction GFLiveIdleReleaseDecision(BOOL activityOpen, NSUInteger pendingTurns, NSUInteger liveSegments,
                                                         double uncoveredVoicedSeconds) {
    if (activityOpen || pendingTurns > 0) return GFLiveIdleReleaseWait; // a turn is still coming: its turn end finishes the press
    if (uncoveredVoicedSeconds > kLiveUncoveredSpeechLimit) return GFLiveIdleReleaseRest;
    return liveSegments > 0 ? GFLiveIdleReleaseFinish : GFLiveIdleReleaseWait;
}
// Backlog 7: a press whose microphone never starts (startAndReturnError fails, the input format is 0 Hz / 0 channels, or no buffer
// arrives) used to show "listening" and later "No speech". Now it ends right away with a clear HUD notice, after ONE automatic
// engine rebuild (device busy / format glitch). Mic permission denied/restricted can't be fixed by a rebuild: macOS feeds such
// an app silence, so the press would only ever end as "No speech"; tell the user what to fix instead.
// Watchdog timing: on 32 real presses in ~/Library/Logs/GeminiFlow.log (2026-11-05..10) audio started 0.08-0.58 s after the press
// (median 0.16 s). A Bluetooth headset's switch to its mic profile can take ~1-1.5 s and posts a configuration change (the
// engine rebuild then re-arms the watchdog). 2.0 s is > 3x the slowest press seen; after a rebuild the route is already up, so
// 1.5 s. A release with no buffer at all after >= 1.0 s also ends as "mic unavailable": zero audio can't hold a dictation.
typedef NS_ENUM(NSInteger, GFMicProblem) { GFMicProblemNone = 0, GFMicProblemStartError, GFMicProblemBadFormat, GFMicProblemNoBuffers };
typedef NS_ENUM(NSInteger, GFMicAction) { GFMicActionProceed = 0, GFMicActionRebuild, GFMicActionGiveUp };
static const NSTimeInterval kMicFirstBufferTimeout = 2.0;
static const NSTimeInterval kMicRebuildBufferTimeout = 1.5;
static const NSTimeInterval kMicNoBufferReleaseMinPress = 1.0;
static BOOL GFMicPermissionBlocked(long micAuth) {
    return micAuth == AVAuthorizationStatusDenied || micAuth == AVAuthorizationStatusRestricted;
}
static GFMicAction GFMicProblemDecision(GFMicProblem problem, long micAuth, BOOL rebuildTried) {
    if (GFMicPermissionBlocked(micAuth)) return GFMicActionGiveUp;
    if (problem == GFMicProblemNone) return GFMicActionProceed;
    return rebuildTried ? GFMicActionGiveUp : GFMicActionRebuild;
}
// HUD notice (the capsule fits ~20 characters); the menu status line carries the longer hint.
static NSString *GFMicProblemNotice(long micAuth) {
    return GFMicPermissionBlocked(micAuth) ? @"Mic access needed" : @"Mic unavailable";
}
static BOOL GFMicNoBuffersAtRelease(BOOL buffersSeen, NSUInteger pcmBytes, NSTimeInterval heldSeconds) {
    return !buffersSeen && pcmBytes == 0 && heldSeconds >= kMicNoBufferReleaseMinPress;
}
static const char *GFMicProblemName(GFMicProblem p) {
    switch (p) {
        case GFMicProblemStartError: return "audio engine failed to start";
        case GFMicProblemBadFormat: return "input format invalid (0 Hz / 0 channels)";
        case GFMicProblemNoBuffers: return "no audio buffers";
        default: return "none";
    }
}
static const char *GFSupersededActionName(GFSupersededLiveAction a) {
    return a == GFSupersededUseLiveText ? "Live text" : (a == GFSupersededUseRest ? "REST on its own recording" : "no speech");
}

// Bounded wait on the Live-failure path (user-approved 2026-11-10). If the REST safety net hasn't answered ~3 s after release, the
// on-device text (only if there is some, never for a no-speech press) is delivered right away. If Gemini text arrives later it
// replaces exactly that paste, but only when provably safe; otherwise it goes to the clipboard and Recent Dictations.
static const NSTimeInterval kEarlyPasteAfterRelease = 3.0;
static const NSTimeInterval kEarlyPasteMinRestTime = 1.0;  // REST always gets at least this long before the early paste
static const NSTimeInterval kLateSwapWindow = 10.0;        // max seconds from the early Cmd+V to a swap
static const int64_t kGFSyntheticEventTag = 0x4746504153544531; // kCGEventSourceUserData on our own key events
static NSTimeInterval GFEarlyPasteDelay(NSTimeInterval sinceRelease) {
    return MAX(kEarlyPasteAfterRelease - sinceRelease, kEarlyPasteMinRestTime);
}
static BOOL GFEarlyPasteAllowed(NSUInteger onDeviceChars, BOOL onDeviceSaidNoSpeech, double loudSeconds, BOOL newerPress, BOOL done) {
    return onDeviceChars > 0 && !onDeviceSaidNoSpeech && loudSeconds > kNoSpeechMaxLoudSeconds && !newerPress && !done;
}
typedef NS_ENUM(NSInteger, GFLateSwap) { GFLateSwapReplace, GFLateKeepIdentical, GFLateKeepNotPasted, GFLateKeepNewerPress,
    GFLateKeepTimeout, GFLateKeepUserInput, GFLateKeepFocusChanged, GFLateKeepPasteBusy, GFLateKeepUnverified };
// sincePaste < 0: the early text was never pasted (clipboard-only or still queued)
static GFLateSwap GFLateSwapDecision(NSString *pasted, NSString *gemini, NSTimeInterval sincePaste, BOOL userInput,
                                     BOOL sameApp, BOOL sameField, BOOL newerPress, BOOL pasteBusy) {
    if ([pasted isEqualToString:gemini]) return GFLateKeepIdentical;
    if (sincePaste < 0) return GFLateKeepNotPasted;
    if (newerPress) return GFLateKeepNewerPress;
    if (sincePaste > kLateSwapWindow) return GFLateKeepTimeout;
    if (userInput) return GFLateKeepUserInput;
    if (!sameApp || !sameField) return GFLateKeepFocusChanged;
    if (pasteBusy) return GFLateKeepPasteBusy;
    return GFLateSwapReplace;
}
static const char *GFLateSwapName(GFLateSwap s) {
    static const char *names[] = {"swap", "keep (identical)", "keep (not pasted)", "keep (newer press)", "keep (window over)",
                                  "keep (user typed or clicked)", "keep (focus changed)", "keep (paste queue busy)",
                                  "keep (pasted text not verified)"};
    return (s >= GFLateSwapReplace && s <= GFLateKeepUnverified) ? names[s] : "?";
}
static id GFCopyFocusedElement(void) {
    AXUIElementRef sys = AXUIElementCreateSystemWide();
    if (!sys) return nil;
    AXUIElementSetMessagingTimeout(sys, 0.3);
    CFTypeRef el = NULL;
    AXError e = AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute, &el);
    CFRelease(sys);
    if (e != kAXErrorSuccess || !el) { if (el) CFRelease(el); return nil; }
    return CFBridgingRelease(el);
}
static NSString *GFAXString(AXUIElementRef el, CFStringRef attr) {
    CFTypeRef v = NULL;
    if (AXUIElementCopyAttributeValue(el, attr, &v) != kAXErrorSuccess || !v) { if (v) CFRelease(v); return nil; }
    if (CFGetTypeID(v) != CFStringGetTypeID()) { CFRelease(v); return nil; }
    return CFBridgingRelease(v);
}
static BOOL GFAXSetSelection(AXUIElementRef el, CFRange r) {
    AXValueRef v = AXValueCreate(kAXValueCFRangeType, &r);
    if (!v) return NO;
    AXError e = AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute, v);
    CFRelease(v);
    return e == kAXErrorSuccess;
}
// Text of range r (UTF-16 units) in a text element
static NSString *GFAXStringForRange(AXUIElementRef el, CFRange r) {
    AXValueRef rv = AXValueCreate(kAXValueCFRangeType, &r);
    CFTypeRef out = NULL;
    AXError e = rv ? AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute, rv, &out) : kAXErrorFailure;
    if (rv) CFRelease(rv);
    if (e == kAXErrorSuccess && out && CFGetTypeID(out) == CFStringGetTypeID()) return CFBridgingRelease(out);
    if (out) CFRelease(out);
    NSString *all = GFAXString(el, kAXValueAttribute);
    if (!all || r.location < 0 || (NSUInteger)(r.location + r.length) > all.length) return nil;
    return [all substringWithRange:NSMakeRange((NSUInteger)r.location, (NSUInteger)r.length)];
}
// Select exactly the text we pasted: it must sit right before the caret with nothing selected; then read the selection back.
// AX ranges count UTF-16 units, the same unit as NSString.length, so composed characters and emoji stay whole (no arrow-key
// counting). Only AX calls here: no keystroke reaches the app unless this returns YES; on any mismatch the caret is put back.
static BOOL GFAXSelectPastedText(id element, NSString *pasted) {
    AXUIElementRef el = (__bridge AXUIElementRef)element;
    if (!el || pasted.length == 0) return NO;
    AXUIElementSetMessagingTimeout(el, 0.3);
    CFTypeRef rv = NULL;
    CFRange sel = CFRangeMake(0, 0);
    BOOL got = AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute, &rv) == kAXErrorSuccess && rv
               && CFGetTypeID(rv) == AXValueGetTypeID() && AXValueGetValue((AXValueRef)rv, kAXValueCFRangeType, &sel);
    if (rv) CFRelease(rv);
    CFIndex len = (CFIndex)pasted.length;
    if (!got || sel.length != 0 || sel.location < len) return NO;
    CFRange ours = CFRangeMake(sel.location - len, len);
    if (![GFAXStringForRange(el, ours) isEqualToString:pasted]) return NO;
    if (GFAXSetSelection(el, ours) && [GFAXString(el, kAXSelectedTextAttribute) isEqualToString:pasted]) return YES;
    GFAXSetSelection(el, CFRangeMake(sel.location, 0));
    return NO;
}
static NSString *const kGFE2ECannedRestText = @"This is the canned Gemini transcript for the bounded wait test.";

// Lowercase, alphanumerics only, single-spaced: for comparing recognizer re-sends ("Hello world" vs "hello world.")
static NSString *GFNormalize(NSString *s) {
    if (!s) return @"";
    NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
    BOOL pendingSpace = NO;
    NSCharacterSet *alnum = [NSCharacterSet alphanumericCharacterSet];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar ch = [s characterAtIndex:i];
        if ([alnum characterIsMember:ch]) {
            if (pendingSpace && out.length) [out appendString:@" "];
            pendingSpace = NO;
            [out appendString:[[NSString stringWithCharacters:&ch length:1] lowercaseString]];
        } else if (ch == ' ') {
            pendingSpace = YES;
        }
    }
    return out;
}

// Dictated audio for the on-device WAV fallback goes to a private per-user temp file that is deleted as soon as its
// recognition ends (backlog 8). It used to be the fixed, world-readable /tmp/geminiflow_last.wav, kept until overwritten.
static NSString *const kGFLegacyTempAudioPath = @"/tmp/geminiflow_last.wav";
static NSString *const kGFTempAudioPrefix = @"geminiflow-";
static const NSTimeInterval kGFStaleTempAudioAge = 120.0; // launch cleanup keeps younger files (another instance may be using them)

static NSString *GFNewTempAudioPath(void) {
    NSString *name = [NSString stringWithFormat:@"%@%@.wav", kGFTempAudioPrefix, [NSUUID UUID].UUIDString];
    return [NSTemporaryDirectory() stringByAppendingPathComponent:name];
}

// Writes data to a NEW file readable only by the user (0600; O_EXCL|O_NOFOLLOW: never reuses or follows an existing path).
static BOOL GFWritePrivateFile(NSData *data, NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR);
    if (fd < 0) return NO;
    BOOL ok = fchmod(fd, S_IRUSR | S_IWUSR) == 0; // exactly 0600 whatever the umask
    const uint8_t *p = data.bytes;
    size_t left = data.length;
    while (ok && left > 0) {
        ssize_t n = write(fd, p, left);
        if (n < 0) { if (errno == EINTR) continue; ok = NO; break; }
        p += n; left -= (size_t)n;
    }
    if (close(fd) != 0) ok = NO;
    if (!ok) unlink(path.fileSystemRepresentation);
    return ok;
}

// Writes wav to a private temp file and calls start(path, done). done() deletes the file: call it once the recognition that
// reads the file has ended, on success AND failure (extra calls are no-ops; any thread). Returns NO, without calling start,
// if the file can't be written.
static BOOL GFWithTempAudioFile(NSData *wav, void (^start)(NSString *path, dispatch_block_t done)) {
    NSString *path = GFNewTempAudioPath();
    if (!GFWritePrivateFile(wav, path)) return NO;
    NSObject *lock = [[NSObject alloc] init];
    __block BOOL deleted = NO;
    dispatch_block_t done = ^{
        @synchronized (lock) {
            if (deleted) return;
            deleted = YES;
        }
        unlink(path.fileSystemRepresentation);
    };
    start(path, done);
    return YES;
}

// Watchdog for the on-device WAV URL recognition fallback (backlog 9). If SFSpeechURLRecognitionRequest never calls back, the
// dictation used to sit in "Thinking" forever. Real logs (50 fallbacks, 2026-11-06..09): 5.07-6.0 s of speech finished in
// 0.14-0.18 s and 2.0 s of no speech errored in 0.06-0.10 s, i.e. <= 0.036 s per audio second including startup. The limit
// 5 s + 0.5 s per audio second is >= 13x that (40x for a 5 s clip). It never cuts off a recognition that is still progressing:
// past the limit, any callback in the last 3 s (a partial result) extends the wait. The hard cap is the temp-file backstop.
static const NSTimeInterval kGFWavWatchdogBaseSeconds = 5.0;
static const NSTimeInterval kGFWavWatchdogPerAudioSecond = 0.5;
static const NSTimeInterval kGFWavWatchdogQuietSeconds = 3.0;

static NSTimeInterval GFWavWatchdogLimit(double audioSeconds) {
    return kGFWavWatchdogBaseSeconds + kGFWavWatchdogPerAudioSecond * MAX(0.0, audioSeconds);
}

// The cycle-11 temp-file backstop: the audio file is deleted by then even if nothing else ran (also the watchdog's hard cap).
static NSTimeInterval GFTempAudioBackstopSeconds(double audioSeconds) {
    return MAX(300.0, 4.0 * audioSeconds);
}

// e2e harness watchdog (test-only; backlog 0m). The file feed is paced in real time, so a 10 min test file needs 10 min before its
// release, plus the whole worst-case chain after it: the REST budget + the slow-retry grace, then the WAV fallback's watchdog
// limit, + a margin. Never shorter than the old rule (120 s, or file + 60 s + the REST per-audio-second budget).
static double GFE2EWatchdogSeconds(double fileSeconds) {
    if (!(fileSeconds > 0)) return 120.0;
    double old = fileSeconds + 60.0 + (GFRestTimeoutForAudioSeconds(fileSeconds) - 8.0);
    double chain = fileSeconds + GFRestTimeoutForAudioSeconds(fileSeconds) + kRestSlowRetryGrace + GFWavWatchdogLimit(fileSeconds) + 30.0;
    return MAX(120.0, MAX(old, chain));
}

// Seconds until the watchdog should look again; 0 = give up now. sinceProgress < 0 means no callback yet.
static NSTimeInterval GFWavWatchdogWait(NSTimeInterval elapsed, NSTimeInterval limit, NSTimeInterval quiet, NSTimeInterval cap,
                                        NSTimeInterval sinceProgress) {
    if (elapsed >= cap) return 0;
    NSTimeInterval wait = limit - elapsed;
    if (sinceProgress >= 0) wait = MAX(wait, quiet - sinceProgress);
    wait = MIN(wait, cap - elapsed);
    return wait > 0 ? wait : 0;
}

// One WAV recognition's end-once state + watchdog. Main thread only. end returns YES only for the first caller (the final
// result, an error, or the expiry), so a dictation is ended exactly once.
@interface GFWavWatchdog : NSObject
@property (nonatomic, readonly) BOOL ended;
@property (nonatomic, readonly, copy) NSString *partialText;   // latest partial transcription ("" = none)
@property (nonatomic, readonly) NSUInteger progressCount;      // callbacks seen (partial results)
@property (nonatomic, readonly) NSTimeInterval limit;
@property (nonatomic, strong) id task;                         // the recognition task (released at end)
- (instancetype)initWithLimit:(NSTimeInterval)limit quiet:(NSTimeInterval)quiet cap:(NSTimeInterval)cap;
- (void)startWithExpiry:(void (^)(GFWavWatchdog *w, NSTimeInterval elapsed))expiry;
- (void)noteProgress:(NSString *)partialText;
- (BOOL)end;
@end

@implementation GFWavWatchdog {
    NSTimeInterval _quiet, _cap, _start, _lastProgress;
    void (^_expiry)(GFWavWatchdog *, NSTimeInterval);
    dispatch_source_t _timer;
}
- (instancetype)initWithLimit:(NSTimeInterval)limit quiet:(NSTimeInterval)quiet cap:(NSTimeInterval)cap {
    if ((self = [super init])) { _limit = limit; _quiet = quiet; _cap = MAX(cap, limit); _partialText = @""; _lastProgress = -1; }
    return self;
}
- (void)startWithExpiry:(void (^)(GFWavWatchdog *, NSTimeInterval))expiry {
    _expiry = [expiry copy];
    _start = [NSDate timeIntervalSinceReferenceDate];
    [self checkAfter:_limit];
}
// A one-shot timer with 10 ms leeway (dispatch_after's default leeway made an 8 s limit fire ~0.4 s late). The source keeps
// this object alive until it fires or end cancels it.
- (void)checkAfter:(NSTimeInterval)delay {
    if (_timer) dispatch_source_cancel(_timer);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    _timer = timer;
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), DISPATCH_TIME_FOREVER,
                              (uint64_t)(0.01 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{
        dispatch_source_cancel(timer);
        if (self->_timer == timer) self->_timer = nil;
        if (self.ended) return;
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        NSTimeInterval wait = GFWavWatchdogWait(now - self->_start, self->_limit, self->_quiet, self->_cap,
                                                self->_lastProgress < 0 ? -1 : now - self->_lastProgress);
        if (wait > 0.001) { [self checkAfter:wait]; return; }
        void (^expiry)(GFWavWatchdog *, NSTimeInterval) = self->_expiry;
        if ([self end] && expiry) expiry(self, now - self->_start);
    });
    dispatch_resume(timer);
}
- (void)noteProgress:(NSString *)partialText {
    if (_ended) return;
    _progressCount++;
    _lastProgress = [NSDate timeIntervalSinceReferenceDate];
    if (partialText.length > 0) _partialText = [partialText copy];
}
- (BOOL)end {
    if (_ended) return NO;
    _ended = YES;
    _expiry = nil;
    _task = nil;
    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
    return YES;
}
@end

// Removes dictation audio left behind by older builds (legacyPath) or by a run that ended before its cleanup (e.g. a crash)
// from dir. Only regular files older than minAge are removed. Returns the number removed.
static NSUInteger GFRemoveStaleTempAudio(NSString *dir, NSString *legacyPath, NSTimeInterval minAge) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    if (legacyPath) [paths addObject:legacyPath];
    for (NSString *name in [fm contentsOfDirectoryAtPath:dir error:nil]) {
        if ([name hasPrefix:kGFTempAudioPrefix] && [name.pathExtension isEqualToString:@"wav"])
            [paths addObject:[dir stringByAppendingPathComponent:name]];
    }
    NSUInteger removed = 0;
    for (NSString *p in paths) {
        NSDictionary *attrs = [fm attributesOfItemAtPath:p error:nil]; // a symlink's own attributes (never followed)
        if (![attrs.fileType isEqualToString:NSFileTypeRegular]) continue;
        if (-[attrs.fileModificationDate timeIntervalSinceNow] < minAge) continue;
        if ([fm removeItemAtPath:p error:nil]) removed++;
    }
    return removed;
}

// ~/Library/Logs/GeminiFlow.log is rotated at launch once it is larger than kGFLogMaxBytes (backlog 13); exactly one old
// log is kept, as GeminiFlow.log.1 (an older .1 is replaced).
static const unsigned long long kGFLogMaxBytes = 5ull * 1024 * 1024;

static NSString *GFLogPath(void) {
    static NSString *path; static dispatch_once_t once;
    dispatch_once(&once, ^{ path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/GeminiFlow.log"]; });
    return path;
}

// Moves path to path.1 (replacing any existing path.1) when path is a regular file larger than maxBytes.
// Returns the size of the rotated file, or 0 if nothing was rotated (missing, small enough, not a regular file, rename failed).
static unsigned long long GFRotateLogIfNeeded(NSString *path, unsigned long long maxBytes) {
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode)) return 0;
    if ((unsigned long long)st.st_size <= maxBytes) return 0;
    NSString *old = [path stringByAppendingString:@".1"];
    if (rename(path.fileSystemRepresentation, old.fileSystemRepresentation) != 0) return 0; // atomic; replaces old .1
    return (unsigned long long)st.st_size;
}

// Appends line to the log at path through one cached descriptor (O_APPEND: whole lines, even with another instance writing)
// instead of opening and closing the file for every line. Reopens when path changes or the file at path is no longer the open
// one (rotated, renamed or deleted, e.g. by another instance's launch rotation), so lines never go to GeminiFlow.log.1.
// Synchronous on purpose: e2e runs exit right after their last line. Errors are ignored (logging must never break the app).
static void GFLogAppendLine(NSString *path, NSString *line) {
    static int fd = -1;
    static NSString *openPath = nil;
    static dev_t openDev; static ino_t openIno;
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!path || data.length == 0) return;
    @synchronized ([NSFileManager class]) {
        const char *cpath = path.fileSystemRepresentation;
        struct stat st;
        if (fd >= 0 && (![openPath isEqualToString:path] || stat(cpath, &st) != 0 || st.st_dev != openDev || st.st_ino != openIno)) {
            close(fd);
            fd = -1;
        }
        if (fd < 0) {
            fd = open(cpath, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0644);
            if (fd < 0) return;
            if (fstat(fd, &st) != 0) { close(fd); fd = -1; return; }
            openPath = [path copy]; openDev = st.st_dev; openIno = st.st_ino;
        }
        const uint8_t *p = data.bytes;
        size_t left = data.length;
        while (left > 0) {
            ssize_t n = write(fd, p, left);
            if (n < 0) { if (errno == EINTR) continue; break; }
            p += n; left -= (size_t)n;
        }
    }
}

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    // Keep the diagnostic log bounded: rotate before this launch writes its first line (normal app only, not e2e runs)
    unsigned long long rotatedLogBytes = self.e2eMode.length == 0 ? GFRotateLogIfNeeded(GFLogPath(), kGFLogMaxBytes) : 0;
    if (rotatedLogBytes > 0) GFLog(@"Log rotated: previous GeminiFlow.log (%llu bytes) is now GeminiFlow.log.1", rotatedLogBytes);

    _recordedPCMData = [NSMutableData data];
    _recentDictations = [NSMutableArray array];
    _pendingLivePCMBuffer = [NSMutableData data];

    // Default preferences and automatic migration from slow/unavailable models
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    // GeminiFlow runs on a single engine (Gemini Live Transcribe); the old per-user model choice is retired.
    [defaults removeObjectForKey:kPrefSelectedModel];
    if (![defaults stringForKey:kPrefEngineMode]) {
        [defaults setObject:@"ondevice" forKey:kPrefEngineMode]; // Default to ondevice until key set
    }

    // Dictated audio must not outlive its recognition: remove the legacy world-readable /tmp file and any orphaned temp WAVs
    NSUInteger staleAudio = GFRemoveStaleTempAudio(NSTemporaryDirectory(), kGFLegacyTempAudioPath, kGFStaleTempAudioAge);
    if (staleAudio > 0) GFLog(@"Removed %lu stale dictation audio file(s)", (unsigned long)staleAudio);

    [self setupMenu];
    [self setupHUD];
    [self setupSpeechRecognizer];

    if (self.e2eMode.length == 0) {
        // Hotkeys first, so nothing later in launch can prevent Fn from working
        [self setupHotkeyMonitors];
    }

    // Pre-warm CoreAudio input engine so recording starts with zero lag on Fn press
    self.audioEngine = [[AVAudioEngine alloc] init];
    [self prewarmAudioEngine];
    // If the mic changes (AirPods / external mic plugged in), rebuild the engine so the tap format is valid
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(audioEngineConfigurationChanged:)
                                                 name:AVAudioEngineConfigurationChangeNotification object:nil];

    if (self.e2eMode.length > 0) {
        [self runE2E];
        return;
    }

    // Automatically trigger macOS permission registration on launch
    [self requestAllPermissions];

    GFLog(@"GeminiFlow launched successfully. Hotkey: Fn (hold or double-tap).");
}

// -[AVAudioEngine prepare] on a fresh engine with no nodes throws on macOS 26
// ("inputNode != nullptr || outputNode != nullptr"), which used to abort the rest of launch.
- (void)prewarmAudioEngine {
    @try {
        (void)self.audioEngine.inputNode; // instantiate the input node so the graph is valid
        [self.audioEngine prepare];
    } @catch (NSException *e) {
        GFLog(@"Audio engine pre-warm skipped: %@", e.reason);
    }
}

- (void)audioEngineConfigurationChanged:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (note.object != self.audioEngine) return;
        // Starting input on Bluetooth headsets (HFP switch) can post a change while the engine keeps running.
        // Only rebuild when the engine has actually stopped, to avoid rebuild loops that drop audio.
        if (self.audioEngine.isRunning) return;
        NSLog(@"Audio device configuration changed; rebuilding audio engine.");
        BOOL wasRecording = self.isRecording;
        [self.audioEngine.inputNode removeTapOnBus:0];
        self.audioEngine = [[AVAudioEngine alloc] init];
        if (wasRecording && !self.e2eAudioFile) {
            // Re-install the tap on the new device without discarding what was already transcribed
            if (![self restartMicTapAfterDeviceChange]) {
                if (!self.micBuffersSeen) { // nothing was captured: there is nothing to finish
                    GFLog(@"Mic: could not restart the microphone after a device change (no audio yet)");
                    [self abortPressForMicProblem:GFMicProblemStartError micAuth:[self micAuthorizationStatus] closeLive:YES];
                    return;
                }
                NSLog(@"Could not restart microphone after device change; finishing with what was captured.");
                [self stopRecordingAndProcess];
            } else if (!self.micBuffersSeen) {
                // A device switch while waiting for the first buffer (e.g. a Bluetooth headset): that was this press's rebuild;
                // give the new device a full first-buffer window.
                self.micRebuildTried = YES;
                [self armMicWatchdogAfter:kMicFirstBufferTimeout];
            }
        } else {
            [self prewarmAudioEngine];
        }
    });
}

- (BOOL)restartMicTapAfterDeviceChange {
    AVAudioInputNode *inputNode = self.audioEngine.inputNode;
    AVAudioFormat *inputFormat = [inputNode outputFormatForBus:0];
    if (inputFormat.sampleRate == 0) return NO;
    AVAudioFormat *targetFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16 sampleRate:16000.0 channels:1 interleaved:YES];
    AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:inputFormat toFormat:targetFormat];
    __weak typeof(self) weakSelf = self;
    [inputNode removeTapOnBus:0];
    [inputNode installTapOnBus:0 bufferSize:1024 format:inputFormat block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        [weakSelf processCapturedBuffer:buffer converter:converter targetFormat:targetFormat when:when];
    }];
    NSError *err = nil;
    if (![self.audioEngine startAndReturnError:&err]) {
        NSLog(@"Audio engine restart failed: %@", err.localizedDescription);
        [inputNode removeTapOnBus:0];
        return NO;
    }
    return YES;
}

#pragma mark - End-to-End Test Mode (GeminiFlow --e2e-file <wav> | --e2e-mic <seconds>)

- (void)runE2E {
    __weak typeof(self) weakSelf = self;
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf runE2EAuthorized:status]; });
    }];
}

- (void)runE2EAuthorized:(SFSpeechRecognizerAuthorizationStatus)status {
    printf("E2E speechAuth=%ld micAuth=%ld onDevice=%d\n", (long)status,
           (long)[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio], self.speechRecognizer.supportsOnDeviceRecognition);
    fflush(stdout);
    __weak typeof(self) weakSelf = self;
    self.e2eCompletion = ^(NSString *finalText) {
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        printf("E2E RESULT: \"%s\"\n", finalText.UTF8String);
        printf("E2E release->result latency: %.0f ms\n", (now - weakSelf.e2eReleaseTime) * 1000.0);
        fflush(stdout);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
    };
    if (self.e2eSecondPressFile.length > 0) {
        // Two-press mode (--e2e-second-press): report each dictation's result by press number; exit once both have reported.
        self.e2eDeliveredSerials = [NSMutableArray array];
        self.resultSink = ^(NSString *text, GFDictation *d) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
            printf("E2E RESULT #%lu: \"%s\"\n", (unsigned long)d.serial, (text ?: @"<NO SPEECH>").UTF8String);
            printf("E2E #%lu release->result latency: %.0f ms (superseded=%d)\n", (unsigned long)d.serial,
                   (now - d.releaseTime) * 1000.0, d.superseded);
            [strongSelf.e2eDeliveredSerials addObject:@(d.serial)];
            fflush(stdout);
            if (strongSelf.e2eDeliveredSerials.count >= 2) {
                printf("E2E BOTH DELIVERED (order %s)\n",
                       [[strongSelf.e2eDeliveredSerials valueForKey:@"stringValue"] componentsJoinedByString:@","].UTF8String);
                fflush(stdout);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
            }
        };
    }
    // Simulate Fn press: start recording
    self.e2eFirstBufferTime = 0;
    self.e2ePressTime = [NSDate timeIntervalSinceReferenceDate];
    [self startRecording];
    printf("E2E startRecording returned in %.0f ms\n", ([NSDate timeIntervalSinceReferenceDate] - self.e2ePressTime) * 1000.0);
    fflush(stdout);

    if ([self.e2eMode isEqualToString:@"file"]) {
        [self e2ePollFeed]; // release Fn as soon as the file has been fully "spoken"
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.e2eMicSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf e2eRelease];
        });
    }
    // Watchdog: 120 s, or, for long (multi-minute hands-free) test files, the real-time feed + the whole fallback chain after the
    // release (REST budget + slow-retry grace + WAV fallback watchdog), so a long fallback is never cut short by the harness.
    double watchdog = 120.0;
    if (self.e2eAudioFile) {
        AVAudioFile *wf = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:self.e2eAudioFile] error:nil];
        if (wf && wf.processingFormat.sampleRate > 0) {
            double fileSeconds = wf.length / wf.processingFormat.sampleRate;
            watchdog = MAX(watchdog, GFE2EWatchdogSeconds(fileSeconds));
        }
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(watchdog * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        printf("E2E TIMEOUT\n"); exit(3);
    });
}

- (void)e2ePollFeed {
    if (self.e2eFeedRunning || self.e2eFirstBufferTime == 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self e2ePollFeed]; });
        return;
    }
    [self e2eRelease];
}

- (void)e2eRelease {
    printf("E2E first audio buffer arrived %.0f ms after press\n",
           self.e2eFirstBufferTime > 0 ? (self.e2eFirstBufferTime - self.e2ePressTime) * 1000.0 : -1.0);
    self.e2eReleaseTime = [NSDate timeIntervalSinceReferenceDate];
    self.activeDictation.releaseTime = self.e2eReleaseTime;
    self.releaseFnUpTime = self.e2eReleaseTime; // backlog 27: the e2e "Fn up"
    self.releasePCMBytesAtFnUp = self.recordedPCMData.length;
    fflush(stdout);
    // Same 120 ms tail cushion as the real Fn release path
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf stopRecordingAndProcess];
    });
}

// Test hook (e2e only, --e2e-second-press <wav> <phase>): the second press, started while the first dictation is still finishing.
// "release": 0.05 s after the first release (its Live final turn is pending). "rest"/"restfail": when the first press's REST call
// starts (the call is held 1 s; "restfail" then fails it as if offline). --e2e-live-drop-output applies to the first press only.
- (void)e2eStartSecondPress {
    if (self.e2eSecondPressStarted || self.e2eMode.length == 0 || self.e2eSecondPressFile.length == 0) return;
    self.e2eSecondPressStarted = YES;
    self.e2eLiveDropOutput = NO;
    self.e2eServerTurnEndAt = 0;
    self.e2eLiveDropAt = 0;
    self.e2eLiveRotateAge = 0;
    self.e2eLiveLifetime = 0;
    self.e2eAudioFile = self.e2eSecondPressFile;
    self.e2eFirstBufferTime = 0;
    self.e2ePressTime = [NSDate timeIntervalSinceReferenceDate];
    printf("E2E second press starts (phase %s)\n", self.e2eSecondPressPhase.UTF8String);
    fflush(stdout);
    GFLog(@"E2E: second press starts (phase %@)", self.e2eSecondPressPhase);
    [self startRecording];
    [self e2ePollFeed];
}

- (void)requestAllPermissions {
    BOOL micReady = ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] == AVAuthorizationStatusAuthorized);
    BOOL axReady = AXIsProcessTrusted();
    if (!micReady || !axReady) {
        [self openSetupWindow];
    } else if ([SFSpeechRecognizer authorizationStatus] == SFSpeechRecognizerAuthorizationStatusNotDetermined) {
        [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
            NSLog(@"Speech recognition authorization status: %ld", (long)status);
        }];
    }
}

#pragma mark - HUD / menu state

- (void)setMenuIconState:(NSInteger)state {
    _menuIconState = state;
    if (self.statusItem) self.statusItem.button.image = [self menuBarIconForState:state];
}

// Show the HUD as a new presentation: older pending dismissals become stale.
- (void)presentHUD {
    self.hudGeneration += 1;
    [self.hudPanel showCenteredNearBottom];
}

- (void)dismissHUDAfterDelay:(NSTimeInterval)delay {
    NSUInteger gen = self.hudGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0.0, delay) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.hudGeneration != gen) {
            strongSelf.hudDismissalsDropped += 1;
            if (!strongSelf.unitTestMode) {
                GFLog(@"HUD: dropped a stale dismissal (generation %lu, now %lu)", (unsigned long)gen, (unsigned long)strongSelf.hudGeneration);
            }
            return;
        }
        strongSelf.hudDismissalsHonored += 1;
        [strongSelf.hudPanel fadeOutAndHideIf:^BOOL{ return weakSelf.hudGeneration == gen; }];
    });
}

// The single "return to idle" step for every terminal path of a dictation (delivered, no speech, cancelled, clipboard-only):
// menu icon + status title back to Ready, optional short HUD notice, then the HUD (and its 60 fps timer) dismissed.
// If a NEW recording is already running (late delivery of the previous dictation), its icon and HUD are left alone.
- (void)returnToIdleWithStatusTitle:(NSString *)title notice:(NSString *)notice mode:(HUDMode)mode dismissAfter:(NSTimeInterval)delay {
    if (self.isRecording) {
        if (!self.unitTestMode) GFLog(@"HUD: idle reset skipped (a new recording is active)");
        return;
    }
    [self setMenuIconState:0];
    self.statusMenuItem.title = title ?: @"Ready: Hold or Double-Tap Fn";
    if (notice) [self.hudPanel setHUDMode:mode noticeText:notice];
    [self dismissHUDAfterDelay:delay];
}

// HUD/menu feedback after a transcript was put on the clipboard (no clipboard/paste side effects here, so it is unit-testable).
- (void)showDeliveredUIAccessibilityTrusted:(BOOL)trusted {
    [self showDeliveredUIAccessibilityTrusted:trusted dictation:nil];
}

- (void)showDeliveredUIAccessibilityTrusted:(BOOL)trusted dictation:(GFDictation *)d {
    if (d.superseded) {
        // A previous dictation finished while a newer press owns the HUD and icon (recording OR already Thinking, when
        // isRecording is NO and returnToIdle's guard would not help): leave them alone (backlog 6).
        if (!self.unitTestMode) GFLog(@"HUD: dictation #%lu delivered late; the newer press keeps the HUD", (unsigned long)d.serial);
        return;
    }
    if (!trusted) {
        [self returnToIdleWithStatusTitle:@"Copied! (Enable Accessibility to Auto-Paste)" notice:@"Enable Accessibility"
                                     mode:HUDModeNotice dismissAfter:2.2];
    } else {
        // HUD micro-feedback, then fade out right away
        [self returnToIdleWithStatusTitle:nil notice:nil mode:HUDModeNotice dismissAfter:0.05];
    }
}

- (NSImage *)menuBarIconForState:(NSInteger)state {
    // state: 0 = idle, 1 = listening, 2 = thinking. The GeminiFlow brand mark shared with the iOS app (three slanted bars):
    // rest heights when idle, taller bars while listening, three dots while thinking. A template image (tinted by the menu bar).
    NSImage *image = [NSImage imageWithSize:NSMakeSize(18, 18) flipped:NO drawingHandler:^BOOL(NSRect dstRect) {
        static const CGFloat listening[3] = {0.66, 0.98, 0.80}, thinking[3] = {0.0, 0.0, 0.0};
        const CGFloat *h = state == 1 ? listening : (state == 2 ? thinking : kGFBrandRestHeights);
        GFDrawBrandMark(NSInsetRect(dstRect, 0.5, 0.5), h, [NSColor blackColor]);
        return YES;
    }];
    [image setTemplate:YES];
    return image;
}

- (void)setupMenu {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    self.statusItem.button.title = @"";
    [self setMenuIconState:0];

    self.menu = [[NSMenu alloc] init];
    [NSApp setApplicationIconImage:GFBrandAppIconImage(256.0)]; // the icon shown in this app's dialogs (same mark as the iOS app)

    self.statusMenuItem = [[NSMenuItem alloc] initWithTitle:@"Ready: Hold or Double-Tap Fn" action:nil keyEquivalent:@""];
    [self.statusMenuItem setEnabled:NO];
    [self.menu addItem:self.statusMenuItem];

    [self.menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *toggleItem = [[NSMenuItem alloc] initWithTitle:@"Start / Stop Dictation (Fn)" action:@selector(toggleRecordingFromMenu) keyEquivalent:@"d"];
    [self.menu addItem:toggleItem];

    [self.menu addItem:[NSMenuItem separatorItem]];

    // Engine mode items
    // Single engine: Gemini Live Transcribe (streaming). REST and Apple on-device are automatic safety nets.
    self.geminiModeMenuItem = [[NSMenuItem alloc] initWithTitle:@"Engine: Gemini Live Transcribe (recommended)" action:@selector(selectGeminiMode) keyEquivalent:@""];
    self.geminiModeMenuItem.toolTip = @"Streams audio to gemini-3.5-transcribe-live; text ~0.4 s after release. Falls back automatically if the network fails.";
    [self.menu addItem:self.geminiModeMenuItem];

    self.onDeviceModeMenuItem = [[NSMenuItem alloc] initWithTitle:@"Engine: Apple On-Device (offline, private)" action:@selector(selectOnDeviceMode) keyEquivalent:@""];
    [self.menu addItem:self.onDeviceModeMenuItem];

    [self updateEngineCheckmarks];

    // API Key setup
    NSMenuItem *apiKeyItem = [[NSMenuItem alloc] initWithTitle:@"Set Gemini API Key" action:@selector(promptForApiKey) keyEquivalent:@"k"];
    [self.menu addItem:apiKeyItem];

    [self.menu addItem:[NSMenuItem separatorItem]];

    // Recent dictations submenu
    NSMenuItem *recentItem = [[NSMenuItem alloc] initWithTitle:@"Recent Dictations" action:nil keyEquivalent:@""];
    self.recentSubmenu = [[NSMenu alloc] init];
    [self updateRecentSubmenu];
    [recentItem setSubmenu:self.recentSubmenu];
    [self.menu addItem:recentItem];

    // Keyboard & permissions setup
    NSMenuItem *setupItem = [[NSMenuItem alloc] initWithTitle:@"Permissions & Keyboard Setup" action:@selector(openSetupWindow) keyEquivalent:@"p"];
    [self.menu addItem:setupItem];

    // In-app Changelog (Cycle history & iOS engine sync)
    NSMenuItem *changelogItem = [[NSMenuItem alloc] initWithTitle:@"Changelog" action:@selector(showChangelogWindow) keyEquivalent:@"l"];
    NSArray<NSDictionary *> *clEntries = GFChangelogLoadEntriesFromPaths(GFChangelogDefaultMacPaths());
    if (clEntries.count > 0) {
        changelogItem.toolTip = [NSString stringWithFormat:@"Latest: Cycle %ld - %@",
                                 (long)[clEntries.firstObject[@"cycle"] integerValue], clEntries.firstObject[@"title"]];
    }
    [self.menu addItem:changelogItem];

    [self.menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit GeminiFlow" action:@selector(quitApp) keyEquivalent:@"q"];
    [self.menu addItem:quitItem];

    self.statusItem.menu = self.menu;
}

- (void)setupHUD {
    self.hudPanel = [[FloatingHUDPanel alloc] init];
}

- (void)showChangelogWindow {
    [[GFChangelogWindowController sharedController] showWindow];
}

- (void)openSetupWindow {
    GFSetupWindowController *ctrl = [GFSetupWindowController sharedController];
    __weak typeof(self) weakSelf = self;
    ctrl.onPromptApiKey = ^{ [weakSelf promptForApiKey]; };
    ctrl.onAccessibilityTrusted = ^{ [weakSelf installFnEventTapIfPossible]; };
    [ctrl showWindow];
}

- (void)setupSpeechRecognizer {
    self.speechRecognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:@"en-US"]];
    self.speechRecognizer.delegate = self;
}

- (void)updateEngineCheckmarks {
    NSString *mode = [[NSUserDefaults standardUserDefaults] stringForKey:kPrefEngineMode];
    if ([mode isEqualToString:@"gemini"]) {
        [self.geminiModeMenuItem setState:NSControlStateValueOn];
        [self.onDeviceModeMenuItem setState:NSControlStateValueOff];
    } else {
        [self.geminiModeMenuItem setState:NSControlStateValueOff];
        [self.onDeviceModeMenuItem setState:NSControlStateValueOn];
    }
}

- (void)selectGeminiMode {
    NSString *existingKey = [[NSUserDefaults standardUserDefaults] stringForKey:kPrefApiKey] ?: @"";
    if (existingKey.length == 0) {
        [self promptForApiKey];
        return;
    }
    [[NSUserDefaults standardUserDefaults] setObject:@"gemini" forKey:kPrefEngineMode];
    [self updateEngineCheckmarks];
}

- (void)selectOnDeviceMode {
    [[NSUserDefaults standardUserDefaults] setObject:@"ondevice" forKey:kPrefEngineMode];
    [self updateEngineCheckmarks];
}

- (void)promptForApiKey {
    NSString *existingKey = [[NSUserDefaults standardUserDefaults] stringForKey:kPrefApiKey] ?: @"";
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Gemini API Key";
    alert.informativeText = @"Paste your Google Gemini API key below (stored locally on your Mac). You can paste a raw key or a GEMINI_API_KEY=... line:";
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert addButtonWithTitle:@"Get API Key"];
    if (existingKey.length > 0) {
        [alert addButtonWithTitle:@"Remove Key"];
    }

    PasteableTextField *input = [[PasteableTextField alloc] initWithFrame:NSMakeRect(0, 0, 340, 24)];
    input.placeholderString = @"AIzaSy...";
    input.stringValue = existingKey;
    alert.accessoryView = input;

    [NSApp activateIgnoringOtherApps:YES];
    NSModalResponse resp = [alert runModal];
    if (resp == NSAlertThirdButtonReturn) {
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://aistudio.google.com/apikey"]];
        return;
    }
    if (existingKey.length > 0 && resp == NSAlertThirdButtonReturn + 1) {
        [[NSUserDefaults standardUserDefaults] setObject:@"" forKey:kPrefApiKey];
        [[NSUserDefaults standardUserDefaults] setObject:@"ondevice" forKey:kPrefEngineMode];
        [self updateEngineCheckmarks];
        return;
    }
    if (resp == NSAlertFirstButtonReturn) {
        NSString *cleanKey = GFSanitizeApiKeyInput(input.stringValue);
        if (cleanKey.length == 0) {
            // Never silently wipe an existing saved key when pasting an empty string or bare AI Studio URL
            if (existingKey.length == 0) {
                [[NSUserDefaults standardUserDefaults] setObject:@"ondevice" forKey:kPrefEngineMode];
                [self updateEngineCheckmarks];
            }
            return;
        }
        [[NSUserDefaults standardUserDefaults] setObject:cleanKey forKey:kPrefApiKey];
        NSLog(@"Gemini API key saved.");
        [[NSUserDefaults standardUserDefaults] setObject:@"gemini" forKey:kPrefEngineMode];
        [self updateEngineCheckmarks];
        [self verifyApiKeyForLive];
    }
}

// After a key is saved, confirm it can reach the Live Transcribe model (key sent as a header, never in the URL).
- (void)verifyApiKeyForLive {
    NSString *apiKey = [[NSUserDefaults standardUserDefaults] stringForKey:kPrefApiKey];
    if (!apiKey || apiKey.length == 0) {
        [self promptForApiKey];
        return;
    }

    NSMutableURLRequest *req = GFGeminiRequest(GFModelInfoURL(kDefaultLiveModel), apiKey);
    req.timeoutInterval = 10.0;

    if (!self.isRecording) { // don't cover a recording's HUD
        [self.hudPanel setHUDMode:HUDModeNotice noticeText:@"Checking API key..."];
        [self presentHUD];
    }

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *notice;
            if (error || status == 0) notice = @"Key check failed (offline?)";
            else if (status == 200) notice = @"Gemini Live ready";
            else if (status == 400 || status == 401 || status == 403) notice = @"API key invalid";
            else if (status == 404) notice = @"Live model unavailable for this key";
            else notice = [NSString stringWithFormat:@"Key check failed (HTTP %ld)", (long)status];
            GFLog(@"API key check: HTTP %ld -> %@", (long)status, notice);
            if (self.isRecording) return; // a dictation started meanwhile: keep its HUD
            [self.hudPanel setHUDMode:HUDModeNotice noticeText:notice];
            [self dismissHUDAfterDelay:1.8];
        });
    }] resume];
}

#pragma mark - Hotkey Setup (Fn Key)

// Diagnostic log at ~/Library/Logs/GeminiFlow.log (unified-log NSLog output is redacted as <private>)
static void GFLog(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    msg = GFRedactSecrets(msg, [[NSUserDefaults standardUserDefaults] stringForKey:kPrefApiKey]); // never log the key (backlog 15)
    NSLog(@"%@", msg);
    static NSDateFormatter *df; static dispatch_once_t once;
    dispatch_once(&once, ^{ df = [[NSDateFormatter alloc] init]; df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS"; });
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [df stringFromDate:[NSDate date]], msg];
    GFLogAppendLine(GFLogPath(), line);
}

static CFMachPortRef gFnEventTap = NULL;

// Low-level listen-only tap: more reliable than NSEvent global monitors for the Fn modifier, and
// works with either Accessibility or Input Monitoring permission.
static CGEventRef GFEventTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    AppDelegate *delegate = (__bridge AppDelegate *)refcon;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        GFLog(@"Fn event tap was disabled by the system (type %d); re-enabling.", (int)type);
        if (gFnEventTap) CGEventTapEnable(gFnEventTap, true);
        return event;
    }
    if (type == kCGEventFlagsChanged) {
        int64_t keyCode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        BOOL fnDown = (CGEventGetFlags(event) & kCGEventFlagMaskSecondaryFn) != 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            [delegate handleModifierKeyCode:(unsigned short)keyCode fnDown:fnDown source:@"tap"];
        });
    }
    return event;
}

- (void)setupHotkeyMonitors {
    [self installFnEventTapIfPossible];
    [self installNSEventMonitorsIfNeeded];
    [self logPermissionState:@"launch"];

    // Re-attach listeners automatically when permissions are granted later (no relaunch needed)
    __weak typeof(self) weakSelf = self;
    self.permissionWatchTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) {
        [weakSelf refreshHotkeyListenersIfPermissionsChanged];
    }];
}

- (void)logPermissionState:(NSString *)context {
    BOOL ax = AXIsProcessTrusted();
    BOOL listen = NO;
    if (@available(macOS 10.15, *)) listen = CGPreflightListenEventAccess();
    long mic = (long)[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    long speech = (long)[SFSpeechRecognizer authorizationStatus];
    GFLog(@"[perm:%@] accessibility=%d inputMonitoring=%d mic=%ld(3=ok) speech=%ld(3=ok) fnTap=%@ fnUsageType=%@",
          context, ax, listen, mic, speech, gFnEventTap ? @"active" : @"none",
          [[NSUserDefaults standardUserDefaults] persistentDomainForName:@"com.apple.HIToolbox"][@"AppleFnUsageType"] ?: @"(default)");
    self.lastAXTrusted = ax;
    self.lastListenAccess = listen;
}

- (void)refreshHotkeyListenersIfPermissionsChanged {
    BOOL ax = AXIsProcessTrusted();
    BOOL listen = NO;
    if (@available(macOS 10.15, *)) listen = CGPreflightListenEventAccess();
    if (ax == self.lastAXTrusted && listen == self.lastListenAccess && (gFnEventTap || !(ax || listen))) return;
    GFLog(@"Permission change detected; re-attaching Fn listeners.");
    [self removeHotkeyListeners];
    [self installFnEventTapIfPossible];
    [self installNSEventMonitorsIfNeeded];
    [self logPermissionState:@"changed"];
}

- (void)installFnEventTapIfPossible {
    if (gFnEventTap) return;
    CGEventMask mask = CGEventMaskBit(kCGEventFlagsChanged);
    gFnEventTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionListenOnly,
                                   mask, GFEventTapCallback, (__bridge void *)self);
    if (!gFnEventTap) {
        GFLog(@"Could not create Fn event tap (needs Accessibility or Input Monitoring).");
        if (@available(macOS 10.15, *)) CGRequestListenEventAccess(); // surfaces the Input Monitoring prompt
        return;
    }
    CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, gFnEventTap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
    CFRelease(src);
    CGEventTapEnable(gFnEventTap, true);
    GFLog(@"Fn event tap installed.");
}

- (void)removeHotkeyListeners {
    if (gFnEventTap) {
        CGEventTapEnable(gFnEventTap, false);
        CFMachPortInvalidate(gFnEventTap);
        CFRelease(gFnEventTap);
        gFnEventTap = NULL;
    }
    if (self.globalFlagsMonitor) { [NSEvent removeMonitor:self.globalFlagsMonitor]; self.globalFlagsMonitor = nil; }
    if (self.localFlagsMonitor) { [NSEvent removeMonitor:self.localFlagsMonitor]; self.localFlagsMonitor = nil; }
    if (self.globalKeyMonitor) { [NSEvent removeMonitor:self.globalKeyMonitor]; self.globalKeyMonitor = nil; }
    if (self.localKeyMonitor) { [NSEvent removeMonitor:self.localKeyMonitor]; self.localKeyMonitor = nil; }
}

- (void)installNSEventMonitorsIfNeeded {
    __weak typeof(self) weakSelf = self;

    // Backup path for modifier key flag changes (keyCode 63 / Fn key); deduped against the tap
    if (!self.globalFlagsMonitor) {
        self.globalFlagsMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskFlagsChanged handler:^(NSEvent *event) {
            [weakSelf handleFlagsChanged:event];
        }];
    }
    if (!self.localFlagsMonitor) {
        self.localFlagsMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskFlagsChanged handler:^NSEvent *(NSEvent *event) {
            [weakSelf handleFlagsChanged:event];
            return event;
        }];
    }

    // Monitor Esc key to cancel recording
    if (!self.globalKeyMonitor) {
        self.globalKeyMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^(NSEvent *event) {
            [weakSelf handleKeyDown:event];
        }];
    }
    if (!self.localKeyMonitor) {
        self.localKeyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
            [weakSelf handleKeyDown:event];
            return event;
        }];
    }
}

// Bounded wait: any real key or click after the early on-device paste rules out the swap. Our own synthetic key events carry
// kGFSyntheticEventTag (and our pid), so they don't count.
- (void)noteUserInputForEarlyPaste:(NSEvent *)event {
    GFDictation *d = self.earlyWatchDictation;
    if (!d || d.earlyUserInput) return;
    CGEventRef cg = event.CGEvent;
    if (cg && (CGEventGetIntegerValueField(cg, kCGEventSourceUserData) == kGFSyntheticEventTag
               || CGEventGetIntegerValueField(cg, kCGEventSourceUnixProcessID) == getpid())) return;
    d.earlyUserInput = YES;
    GFLog(@"Early paste: user input (event type %lu) after the on-device paste of dictation #%lu; no swap",
          (unsigned long)event.type, (unsigned long)d.serial);
}

- (void)startEarlyPasteWatch:(GFDictation *)d {
    [self stopEarlyPasteWatch];
    self.earlyWatchDictation = d;
    __weak typeof(self) weakSelf = self;
    NSEventMask m = NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown;
    self.earlyMouseMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:m handler:^(NSEvent *e) { [weakSelf noteUserInputForEarlyPaste:e]; }];
    self.earlyLocalMouseMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:m handler:^NSEvent *(NSEvent *e) {
        [weakSelf noteUserInputForEarlyPaste:e];
        return e;
    }];
}

- (void)stopEarlyPasteWatch {
    if (self.earlyMouseMonitor) { [NSEvent removeMonitor:self.earlyMouseMonitor]; self.earlyMouseMonitor = nil; }
    if (self.earlyLocalMouseMonitor) { [NSEvent removeMonitor:self.earlyLocalMouseMonitor]; self.earlyLocalMouseMonitor = nil; }
    self.earlyWatchDictation = nil;
}

- (void)handleKeyDown:(NSEvent *)event {
    [self noteUserInputForEarlyPaste:event];
    if (self.isRecording && event.keyCode == 53) { // 53 is Esc key
        NSLog(@"Dictation cancelled via Esc key.");
        [self cancelRecording];
    }
}

- (void)handleFlagsChanged:(NSEvent *)event {
    [self handleModifierKeyCode:event.keyCode fnDown:(([event modifierFlags] & NSEventModifierFlagFunction) != 0) source:@"nsevent"];
}

- (void)handleModifierKeyCode:(unsigned short)keyCode fnDown:(BOOL)fnIsDown source:(NSString *)source {
    if (self.modifierEventLogCount < 40) { // modifier keys only (no typed characters); capped to keep the log small
        self.modifierEventLogCount++;
        GFLog(@"modifier event via %@: keyCode=%u fnFlag=%d", source, keyCode, fnIsDown);
    }
    // Check if the event involves the Fn key (keyCode 63)
    if (keyCode != 63) {
        return;
    }
    // The tap and the NSEvent monitor both deliver the same press; only act on real state changes
    if (fnIsDown == self.fnKeyIsCurrentlyDown) {
        return;
    }
    GFLog(@"Fn %@ (via %@)", fnIsDown ? @"DOWN" : @"UP", source);

    self.fnKeyIsCurrentlyDown = fnIsDown;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    if (fnIsDown) {
        // Fn Key Pressed Down
        NSTimeInterval timeSinceLastPress = now - self.lastFnPressTime;
        self.fnDownTimestamp = now;

        if (self.isHandsFree) {
            // In hands-free mode, pressing Fn again finishes dictation
            NSLog(@"Fn tapped to stop hands-free dictation.");
            [self stopRecordingAndProcess];
            return;
        }

        // Check for double-tap (two presses within 380 ms)
        if (timeSinceLastPress > 0.05 && timeSinceLastPress < 0.38) {
            NSLog(@"Double-tap Fn detected: Entering hands-free mode.");
            self.isHandsFree = YES;
            if (!self.isRecording) {
                [self startRecording];
            }
            // (a press whose mic failed has ended with a notice: keep it, and leave hands-free off)
            if (self.isRecording) [self.hudPanel setHUDMode:HUDModeListeningHandsFree noticeText:nil];
        } else {
            // First press or hold
            if (!self.isRecording) {
                [self startRecording];
            }
        }
        self.lastFnPressTime = now;
    } else {
        // Fn Key Released
        if (self.isHandsFree) {
            // In hands-free mode, releasing the key does NOT stop recording
            return;
        }
        if (self.isRecording) { // backlog 27 (measurement only): where the release cushion starts
            self.releaseFnUpTime = now;
            self.releasePCMBytesAtFnUp = self.recordedPCMData.length;
        }

        NSTimeInterval holdDuration = now - self.fnDownTimestamp;
        NSTimeInterval capturedDownTime = self.fnDownTimestamp;

        if (self.isRecording && holdDuration >= 0.22) {
            // Hold-to-talk completed: add 120ms tail cushion so final syllable is never clipped
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (weakSelf.isRecording && !weakSelf.isHandsFree && !weakSelf.fnKeyIsCurrentlyDown && weakSelf.fnDownTimestamp == capturedDownTime) {
                    NSLog(@"Hold-to-talk completed with tail cushion (duration: %.2fs). Stopping...", holdDuration);
                    [weakSelf stopRecordingAndProcess];
                }
            });
        } else if (self.isRecording && holdDuration < 0.22) {
            // Quick tap: wait briefly to see if second tap arrives for double-tap
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.38 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (weakSelf.isRecording && !weakSelf.isHandsFree && !weakSelf.fnKeyIsCurrentlyDown && weakSelf.fnDownTimestamp == capturedDownTime) {
                    // No second tap arrived; finish dictation
                    [weakSelf stopRecordingAndProcess];
                }
            });
        }
    }
}

- (void)toggleRecordingFromMenu {
    if (self.isRecording) {
        [self stopRecordingAndProcess];
    } else {
        self.isHandsFree = YES;
        [self startRecording];
        if (self.isRecording) [self.hudPanel setHUDMode:HUDModeListeningHandsFree noticeText:nil];
    }
}

#pragma mark - Audio Recording Engine

- (BOOL)isLiveWebSocketModel:(NSString *)model {
    if (!model) return NO;
    return [model containsString:@"live"];
}

// A new press while the previous dictation may still be finishing (backlog 6): freeze the previous dictation's recording and
// on-device transcript into its GFDictation, so its late fallbacks (REST, on-device, WAV) never read the new press's buffers, and
// finish now the steps that need the shared microphone / recognizer / Live session. Its result is still delivered.
- (void)supersedePreviousDictation {
    GFDictation *prev = self.activeDictation;
    if (!prev) { prev = [[GFDictation alloc] init]; self.activeDictation = prev; }
    BOOL liveFinalizing = self.liveFinalizing && !self.hasCompletedGeminiTurn;
    BOOL onDeviceFinalizing = self.isFinalizingOnDevice;
    // On-device text as of now (the new press stops this recognizer) and Live coverage, both before the buffers are swapped
    [self commitCurrentOnDeviceSegment];
    [self refreshAccumulatedOnDeviceTranscript];
    NSString *onDeviceText = [self.latestOnDeviceTranscript ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    double uncovered = liveFinalizing ? [self voicedSecondsInRecordingFromByte:self.liveCoveredBytes] : 0;
    if (!prev.superseded) {
        prev.onDeviceText = onDeviceText;
        prev.pcm = self.recordedPCMData ?: [NSData data];
        prev.liveHadTextAtSupersede = self.liveSegments.count > 0;
        prev.onDeviceNoSpeechAtSupersede = self.onDeviceReportedNoSpeech;
        prev.superseded = YES;
    }
    self.recordedPCMData = [NSMutableData data]; // the new press records into a fresh buffer; the old one now belongs to prev
    if (liveFinalizing) {
        GFSpeechEvidence ev = GFMeasureSpeechEvidence((const int16_t *)prev.pcm.bytes, prev.pcm.length / 2);
        BOOL noLoud = GFNoLoudSpeech(ev.peakRMS, ev.evidenceSeconds);
        GFSupersededLiveAction action = GFSupersededLiveDecision(self.liveSegments.count, uncovered, onDeviceText.length,
                                                                 ev.loudSeconds, noLoud);
        GFLog(@"Dictation #%lu: new press during its Live finalization (%lu segments, uncovered %.2fs, on-device %lu chars, "
              @"loud %.2fs, max RMS %.0f, speech evidence %.2fs above RMS %.0f, %.2fs audio) -> %s", (unsigned long)prev.serial,
              (unsigned long)self.liveSegments.count, uncovered, (unsigned long)onDeviceText.length, ev.loudSeconds, ev.peakRMS,
              ev.evidenceSeconds, ev.thresholdRMS, prev.pcm.length / 32000.0, GFSupersededActionName(action));
        if (action == GFSupersededUseLiveText) {
            [self finishLiveTranscriptWithReason:@"new press during finalization"];
        } else {
            self.hasCompletedGeminiTurn = YES;
            [self closeLiveWebSocket];
            if (self.recognitionTask) { [self.recognitionTask cancel]; self.recognitionTask = nil; }
            if (action == GFSupersededUseRest) [self performGenerateContentFallbackForDictation:prev];
            else [self showNoSpeechDetectedForDictation:prev];
        }
        self.liveFinalizing = NO;
    } else if (onDeviceFinalizing) {
        // The previous dictation was waiting for its on-device final result: finish it from the snapshot now.
        self.recognitionSessionId += 1; // stop the old poll / callbacks
        self.isFinalizingOnDevice = NO;
        if (self.recognitionTask) { [self.recognitionTask cancel]; self.recognitionTask = nil; }
        GFLog(@"Dictation #%lu: new press during its on-device finalization", (unsigned long)prev.serial);
        [self finishSupersededDictationOnDevice:prev];
    }
}

// The PCM a dictation's fallbacks must use: its frozen snapshot once a newer press started, else the live buffer.
- (NSData *)pcmForDictation:(GFDictation *)d {
    if (d.superseded && d.pcm) return d.pcm;
    return self.recordedPCMData ?: [NSData data];
}

- (void)startRecording {
    if (self.isRecording) return;

    // A previous dictation still finishing keeps its own snapshot and is finished/delivered from it (backlog 6)
    [self supersedePreviousDictation];

    self.isRecording = YES;
    self.dictationSerial += 1;
    self.activeDictation = [[GFDictation alloc] init];
    self.activeDictation.serial = self.dictationSerial;
    GFLog(@"startRecording (handsFree=%d, speechAuth=%ld, recognizerAvailable=%d)", self.isHandsFree,
          (long)[SFSpeechRecognizer authorizationStatus], self.speechRecognizer.isAvailable);
    self.hasCompletedGeminiTurn = NO;
    [self.recordedPCMData setLength:0];
    [self.pendingLivePCMBuffer setLength:0];
    self.latestOnDeviceTranscript = @"";
    self.committedOnDeviceTranscript = [NSMutableString string];
    self.currentOnDeviceSegment = @"";
    self.lastCommittedOnDeviceSegment = nil;
    self.isFinalizingOnDevice = NO;
    self.liveReceivedTranscript = [NSMutableString string];
    self.liveWebSocketConnected = NO;
    self.lastChunkSentDate = [NSDate date];

    // Start the microphone FIRST so the opening words are captured while UI/network work happens
    self.micBuffersSeen = NO;
    self.micRebuildTried = NO;
    self.lastCapturedAudioEndTime = 0;
    self.releaseFnUpTime = 0;
    self.releasePCMBytesAtFnUp = 0;
    self.micWatchdogGeneration += 1;
    self.micStartTime = [NSDate timeIntervalSinceReferenceDate];
    GFMicProblem micProblem = [self startAudioEngine];
    long micAuth = [self micAuthorizationStatus]; // after the start: the hot path stays unchanged
    GFMicAction micAction = GFMicProblemDecision(micProblem, micAuth, NO);
    if (micAction == GFMicActionRebuild) {
        GFLog(@"Mic: %s at press; rebuilding the audio engine once", GFMicProblemName(micProblem));
        self.micRebuildTried = YES;
        [self rebuildAudioEngineForMicRetry];
        micProblem = [self startAudioEngine];
        micAction = GFMicProblemDecision(micProblem, micAuth, YES);
        if (micAction == GFMicActionProceed) GFLog(@"Mic: started after the rebuild");
    }
    if (micAction == GFMicActionGiveUp) {
        // Before any Live session / HUD "listening": nothing to close, nothing to send
        [self abortPressForMicProblem:(micProblem == GFMicProblemNone ? GFMicProblemStartError : micProblem) micAuth:micAuth closeLive:NO];
        return;
    }
    if (!self.e2eAudioFile || [self.e2eMicFail isEqualToString:@"nobuffers"]) { // the e2e file feed never needs the watchdog
        [self armMicWatchdogAfter:(self.micRebuildTried ? kMicRebuildBufferTimeout : kMicFirstBufferTimeout)];
    }

    // Status icon
    [self setMenuIconState:1];
    self.statusMenuItem.title = @"Recording in progress...";

    // Show HUD (a new presentation: any dismissal still pending from the previous dictation becomes stale)
    [self.hudPanel setHUDMode:(self.isHandsFree ? HUDModeListeningHandsFree : HUDModeListeningHold) noticeText:nil];
    [self presentHUD];

    NSString *engineMode = [self effectiveEngineMode];
    NSString *apiKey = [[NSUserDefaults standardUserDefaults] stringForKey:kPrefApiKey];
    NSString *selectedModel = [self currentGeminiModel];

    // If Gemini mode is selected and API key is present:
    if ([engineMode isEqualToString:@"gemini"] && apiKey.length > 0) {
        if ([self isLiveWebSocketModel:selectedModel]) {
            [self startGeminiLiveWebSocket];
        } else {
            // Pre-warm HTTPS connection pool in background while speaking so TLS handshake is ready
            NSMutableURLRequest *wReq = GFGeminiRequest(GFRestWarmupURL(), apiKey); // key in the header, not the URL
            wReq.HTTPMethod = @"HEAD";
            wReq.timeoutInterval = 3.0;
            [[[NSURLSession sharedSession] dataTaskWithRequest:wReq] resume];
        }
    }
}

#pragma mark - On-Device Segment Accumulation

// Join a finished utterance onto the committed transcript. Apple capitalises the first word of
// every new utterance but drops the period at pauses, so add one when the next segment is capitalised.
- (void)commitCurrentOnDeviceSegment {
    NSString *seg = [self.currentOnDeviceSegment stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    self.currentOnDeviceSegment = @"";
    if (seg.length == 0) return;
    self.lastCommittedOnDeviceSegment = seg;
    if (!self.committedOnDeviceTranscript) self.committedOnDeviceTranscript = [NSMutableString string];
    NSMutableString *c = self.committedOnDeviceTranscript;
    self.committedLengthBeforeLastSegment = c.length;
    if (c.length > 0) {
        unichar last = [c characterAtIndex:c.length - 1];
        unichar first = [seg characterAtIndex:0];
        BOOL lastIsPunct = [[NSCharacterSet characterSetWithCharactersInString:@".?!,;:"] characterIsMember:last];
        BOOL nextIsCap = [[NSCharacterSet uppercaseLetterCharacterSet] characterIsMember:first];
        BOOL nextIsI = [seg isEqualToString:@"I"] || [seg hasPrefix:@"I "] || [seg hasPrefix:@"I'"] ||
                       [seg hasPrefix:@"I\u2019"] || [seg hasPrefix:@"I,"];
        // Don't end a sentence on a function word: a thinking pause after "the"/"with"/"to" is mid-sentence
        NSString *prevWord = [[[c componentsSeparatedByString:@" "] lastObject] lowercaseString];
        static NSSet *functionWords;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            functionWords = [NSSet setWithArray:@[@"the", @"a", @"an", @"to", @"of", @"and", @"or", @"but", @"with", @"for",
                                                  @"in", @"on", @"at", @"by", @"from", @"about", @"my", @"our", @"your",
                                                  @"their", @"his", @"her", @"its", @"is", @"are", @"was", @"were", @"that",
                                                  @"so", @"because", @"if", @"then", @"than", @"like", @"um", @"uh"]];
        });
        BOOL prevIsFunction = [functionWords containsObject:prevWord];
        if (!lastIsPunct && nextIsCap && !nextIsI && !prevIsFunction) [c appendString:@"."];
        [c appendString:@" "];
    }
    [c appendString:seg];
}

- (void)refreshAccumulatedOnDeviceTranscript {
    NSMutableString *full = [NSMutableString stringWithString:self.committedOnDeviceTranscript ?: @""];
    NSString *cur = [self.currentOnDeviceSegment stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (cur.length > 0) {
        if (full.length > 0) [full appendString:@" "];
        [full appendString:cur];
    }
    self.latestOnDeviceTranscript = full;
}

// Called on the main queue for every recognizer result of the active session.
- (void)handleOnDeviceResult:(SFSpeechRecognitionResult *)result {
    BOOL utteranceEnded = result.isFinal;
    if (@available(macOS 11.3, *)) {
        // Non-nil metadata marks the end of an utterance; the next partial starts from scratch.
        if (result.speechRecognitionMetadata != nil) utteranceEnded = YES;
    }
    [self handleOnDeviceText:result.bestTranscription.formattedString utteranceEnded:utteranceEnded isFinal:result.isFinal];
}

- (void)handleOnDeviceText:(NSString *)text utteranceEnded:(BOOL)utteranceEnded isFinal:(BOOL)isFinal {
    NSString *str = text ?: @"";
    if (isFinal) utteranceEnded = YES;
    self.lastOnDeviceResultTime = [NSDate timeIntervalSinceReferenceDate];

    // After an utterance is committed the recognizer may re-send it (e.g. as the isFinal result when the
    // user pauses before releasing Fn), sometimes refined ("Hello world" -> "Hello world."). Replace instead
    // of appending. Only end-of-utterance/final results qualify: a genuinely new utterance starts as partials.
    if (str.length > 0 && utteranceEnded && self.currentOnDeviceSegment.length == 0 && self.lastCommittedOnDeviceSegment.length > 0) {
        NSString *nNew = GFNormalize(str);
        NSString *nAll = GFNormalize(self.committedOnDeviceTranscript);
        NSString *nLast = GFNormalize(self.lastCommittedOnDeviceSegment);
        BOOL replaceAll = nAll.length > 0 && [nNew hasPrefix:nAll];
        BOOL replaceLast = !replaceAll && nLast.length > 0 && [nNew hasPrefix:nLast];
        if (replaceAll || replaceLast) {
            NSUInteger keep = replaceAll ? 0 : MIN(self.committedLengthBeforeLastSegment, self.committedOnDeviceTranscript.length);
            [self.committedOnDeviceTranscript deleteCharactersInRange:NSMakeRange(keep, self.committedOnDeviceTranscript.length - keep)];
            NSString *trimmed = [self.committedOnDeviceTranscript stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            [self.committedOnDeviceTranscript setString:trimmed];
            self.currentOnDeviceSegment = str;
            [self commitCurrentOnDeviceSegment];
            if (isFinal) self.latestOnDeviceIsFinal = YES;
            [self refreshAccumulatedOnDeviceTranscript];
            return;
        }
    }

    if (str.length > 0) {
        // Safety net: if the recognizer silently restarted without an end marker
        // (new text is not an extension of the current segment and is much shorter), commit the old one.
        // Skip when the new text contains digits: "three hundred and forty five" -> "345" is a revision.
        NSString *cur = self.currentOnDeviceSegment ?: @"";
        NSUInteger curWords = [[cur componentsSeparatedByString:@" "] count];
        BOOL hasDigits = [str rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]].location != NSNotFound;
        if (cur.length > 12 && curWords >= 4 && !hasDigits && str.length < cur.length / 2) {
            NSString *curHead = [[cur substringToIndex:MIN((NSUInteger)6, cur.length)] lowercaseString];
            if (![[str lowercaseString] hasPrefix:curHead]) {
                [self commitCurrentOnDeviceSegment];
            }
        }
        self.currentOnDeviceSegment = str;
    }
    if (utteranceEnded) {
        [self commitCurrentOnDeviceSegment];
    }
    if (isFinal) {
        self.latestOnDeviceIsFinal = YES;
    }
    [self refreshAccumulatedOnDeviceTranscript];
}

- (GFMicProblem)startAudioEngine {
    if (!self.audioEngine) {
        self.audioEngine = [[AVAudioEngine alloc] init];
    }

    // Invalidate the previous session first so its late callbacks can't write into this one,
    // even if we bail out below.
    self.recognitionSessionId += 1;
    if (self.recognitionTask) {
        [self.recognitionTask cancel];
        self.recognitionTask = nil;
    }
    self.latestOnDeviceIsFinal = NO;
    self.onDeviceReportedNoSpeech = NO;

    AVAudioInputNode *inputNode = self.e2eAudioFile ? nil : self.audioEngine.inputNode;
    AVAudioFormat *inputFormat = self.e2eAudioFile
        ? [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:1]
        : [inputNode outputFormatForBus:0];

    if (inputFormat.sampleRate == 0 || inputFormat.channelCount == 0) {
        GFLog(@"Error: audio input node format invalid (%.0f Hz, %u channels).", inputFormat.sampleRate, (unsigned)inputFormat.channelCount);
        return GFMicProblemBadFormat;
    }

    // Target format: 16,000 Hz, 1 channel (mono), 16-bit signed integer PCM
    AVAudioFormat *targetFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                                   sampleRate:16000.0
                                                                     channels:1
                                                                  interleaved:YES];

    AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:inputFormat toFormat:targetFormat];

    // On-device recognition request setup with Dictation taskHint & Auto-Punctuation
    self.recognitionRequest = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
    self.recognitionRequest.shouldReportPartialResults = YES;
    self.recognitionRequest.taskHint = SFSpeechRecognitionTaskHintDictation;
    if (@available(macOS 13.0, *)) {
        self.recognitionRequest.addsPunctuation = YES;
    }
    if (self.speechRecognizer.supportsOnDeviceRecognition) {
        self.recognitionRequest.requiresOnDeviceRecognition = YES;
    }

    __weak typeof(self) weakSelf = self;
    NSUInteger sessionId = self.recognitionSessionId;
    if (self.recognitionRequest && self.speechRecognizer.isAvailable) {
        self.recognitionTask = [self.speechRecognizer recognitionTaskWithRequest:self.recognitionRequest resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                // Ignore late callbacks from a previous press
                if (weakSelf.recognitionSessionId != sessionId) return;
                if (result && !(weakSelf.e2eWavFallback && weakSelf.e2eMode.length > 0)) { // test hook: on-device "hears nothing"
                    [weakSelf handleOnDeviceResult:result];
                }
                if (error && !result) {
                    GFLog(@"On-device recognition ended: %@ (domain=%@ code=%ld)", error.localizedDescription, error.domain, (long)error.code);
                    // Only the explicit no-speech verdict for the finished press counts (not "Dictation disabled" etc.)
                    if ([error.domain isEqualToString:@"kAFAssistantErrorDomain"] && error.code == 1110 && !weakSelf.isRecording)
                        weakSelf.onDeviceReportedNoSpeech = YES;
                    // Treat an error as the end of the stream so finalization doesn't wait for nothing
                    [weakSelf commitCurrentOnDeviceSegment];
                    [weakSelf refreshAccumulatedOnDeviceTranscript];
                    weakSelf.latestOnDeviceIsFinal = YES;
                }
            });
        }];
    } else {
        GFLog(@"Speech recognizer unavailable (available=%d)", self.speechRecognizer.isAvailable);
    }

    // Remove any previous tap before installing new one
    if (self.e2eAudioFile) {
        self.e2eMicStartAttempts += 1;
        // Test hook (--e2e-mic-fail): the "mic" fails to start (every attempt, or only the first), or starts but sends nothing
        if ([self.e2eMicFail isEqualToString:@"start"] || ([self.e2eMicFail isEqualToString:@"start-once"] && self.e2eMicStartAttempts == 1)) {
            GFLog(@"E2E: simulating a mic start failure (attempt %lu)", (unsigned long)self.e2eMicStartAttempts);
            return GFMicProblemStartError;
        }
        if ([self.e2eMicFail isEqualToString:@"nobuffers"]) {
            GFLog(@"E2E: simulating a mic that starts but delivers no audio");
            return GFMicProblemNone;
        }
        // Test mode: stream the WAV through the exact same per-buffer pipeline as the mic, in real time
        [self startE2EFileFeedWithConverter:converter targetFormat:targetFormat];
        return GFMicProblemNone;
    }
    [inputNode removeTapOnBus:0];
    [inputNode installTapOnBus:0 bufferSize:1024 format:inputFormat block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        if (weakSelf.e2eFirstBufferTime == 0) weakSelf.e2eFirstBufferTime = [NSDate timeIntervalSinceReferenceDate];
        [weakSelf processCapturedBuffer:buffer converter:converter targetFormat:targetFormat when:when];
    }];

    NSError *startError = nil;
    BOOL started = [self.audioEngine startAndReturnError:&startError];
    if (!started || startError) {
        GFLog(@"Error starting audio engine: %@ (domain=%@ code=%ld, running=%d)", startError.localizedDescription ?: @"(no error)",
              startError.domain, (long)startError.code, self.audioEngine.isRunning);
        if (!self.audioEngine.isRunning) {
            [inputNode removeTapOnBus:0];
            return GFMicProblemStartError;
        }
    }
    return GFMicProblemNone;
}

// Mic authorization for the mic-failure decision. The e2e file feed never uses the mic (the test runner's own mic permission
// must not change the result): authorized, unless the test hook simulates a denied permission.
- (long)micAuthorizationStatus {
    if (self.e2eMode.length > 0 && self.e2eAudioFile) {
        return [self.e2eMicFail isEqualToString:@"denied"] ? (long)AVAuthorizationStatusDenied : (long)AVAuthorizationStatusAuthorized;
    }
    return (long)[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
}

// A fresh AVAudioEngine for the one automatic retry (device busy / stale format). e2e: the next start attempt is the "rebuild".
- (void)rebuildAudioEngineForMicRetry {
    if (self.e2eAudioFile) return;
    @try {
        [self.audioEngine.inputNode removeTapOnBus:0];
        [self.audioEngine stop];
    } @catch (NSException *e) {
        GFLog(@"Mic: old engine teardown threw: %@", e.reason);
    }
    self.audioEngine = [[AVAudioEngine alloc] init];
}

// No-buffer watchdog for the current press (cancelled by a newer press, by any end of this press, or by the first buffer).
- (void)armMicWatchdogAfter:(NSTimeInterval)seconds {
    self.micWatchdogGeneration += 1;
    NSUInteger gen = self.micWatchdogGeneration;
    NSUInteger serial = self.dictationSerial;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) s = weakSelf;
        if (!s || s.micWatchdogGeneration != gen || !s.isRecording || s.dictationSerial != serial || s.micBuffersSeen) return;
        [s micWatchdogFired];
    });
}

- (void)micWatchdogFired {
    long micAuth = [self micAuthorizationStatus];
    NSTimeInterval since = [NSDate timeIntervalSinceReferenceDate] - self.micStartTime;
    if (GFMicProblemDecision(GFMicProblemNoBuffers, micAuth, self.micRebuildTried) == GFMicActionRebuild) {
        self.micRebuildTried = YES;
        if (!self.unitTestMode) GFLog(@"Mic: no audio buffers %.2fs after press; rebuilding the audio engine once", since);
        BOOL restarted = YES;
        if (!self.e2eAudioFile) {
            [self rebuildAudioEngineForMicRetry];
            restarted = [self restartMicTapAfterDeviceChange]; // same recognizer request; buffers go through the shared pipeline
        } else {
            GFLog(@"E2E: simulated mic rebuilt (it still delivers no audio)");
        }
        if (restarted) {
            [self armMicWatchdogAfter:kMicRebuildBufferTimeout];
            return;
        }
        GFLog(@"Mic: engine rebuild failed");
    }
    [self abortPressForMicProblem:GFMicProblemNoBuffers micAuth:micAuth closeLive:YES];
}

// The microphone could not be used for this press: end it at once with a clear notice. Same cleanup as Esc (cancelRecording):
// no Live session left open, no REST call, nothing pasted for this press (a previous dictation's deferred paste still goes out).
- (void)abortPressForMicProblem:(GFMicProblem)problem micAuth:(long)micAuth closeLive:(BOOL)closeLive {
    BOOL permission = GFMicPermissionBlocked(micAuth);
    NSString *notice = GFMicProblemNotice(micAuth);
    NSTimeInterval since = self.micStartTime > 0 ? [NSDate timeIntervalSinceReferenceDate] - self.micStartTime : 0;
    if (!self.unitTestMode) {
        GFLog(@"Mic unavailable: dictation #%lu ended %.2fs after press (%s, micAuth=%ld, rebuild %@); no Live, no REST, nothing pasted",
              (unsigned long)self.activeDictation.serial, since, permission ? "microphone permission denied" : GFMicProblemName(problem),
              micAuth, self.micRebuildTried ? @"tried" : @"not tried");
    }
    self.micWatchdogGeneration += 1;
    self.isRecording = NO;
    self.isHandsFree = NO;
    self.activeDictation.finished = YES;
    self.recognitionSessionId += 1; // drop any late recognizer callbacks
    self.isFinalizingOnDevice = NO;
    [self stopAudioEngine];
    if (self.recognitionTask) {
        [self.recognitionTask cancel];
        self.recognitionTask = nil;
    }
    if (closeLive) { // this press opened a Live session: close it so nothing (not even the REST safety net) runs for it
        self.hasCompletedGeminiTurn = YES;
        self.liveSessionId += 1;
        [self closeLiveWebSocket];
    }
    [self flushDeferredPastes]; // a previous dictation that finished during this press still gets pasted (backlog 6)
    self.lastMicNotice = notice;
    [self.hudPanel setHUDMode:HUDModeNotice noticeText:notice];
    [self presentHUD];
    [self returnToIdleWithStatusTitle:(permission ? @"Microphone permission needed (System Settings > Privacy & Security > Microphone)"
                                                  : @"Mic unavailable: check the input device")
                               notice:notice mode:HUDModeNotice dismissAfter:2.0];
    if (self.e2eCompletion) {
        printf("E2E MIC UNAVAILABLE after %.0f ms (%s, notice \"%s\")\n", since * 1000.0,
               permission ? "permission" : GFMicProblemName(problem), notice.UTF8String);
        self.e2eReleaseTime = self.micStartTime; // its latency line reads from the press
        void (^done)(NSString *) = self.e2eCompletion;
        self.e2eCompletion = nil;
        done(@"<MIC UNAVAILABLE>");
    }
}

// Shared per-buffer pipeline (called from the mic tap thread, or the e2e file feeder thread; `when` is nil for the file feed)
- (void)processCapturedBuffer:(AVAudioPCMBuffer *)buffer converter:(AVAudioConverter *)converter targetFormat:(AVAudioFormat *)targetFormat
                         when:(AVAudioTime *)when {
    __weak typeof(self) weakSelf = self;
    AVAudioFormat *inputFormat = buffer.format;
    BOOL hostValid = when != nil && when.hostTimeValid; // backlog 27: when this buffer's last sample was captured (measurement only)
    NSTimeInterval captureEnd = GFCapturedBufferEndTime([NSDate timeIntervalSinceReferenceDate],
                                                        hostValid ? [AVAudioTime secondsForHostTime:mach_absolute_time()] : 0, hostValid,
                                                        hostValid ? [AVAudioTime secondsForHostTime:when.hostTime] : 0,
                                                        buffer.frameLength, inputFormat.sampleRate);
    if (!self.micBuffersSeen) { // first buffer of this press (any tap: initial, device-change restart or watchdog rebuild)
        self.micBuffersSeen = YES;
        NSTimeInterval firstAfter = [NSDate timeIntervalSinceReferenceDate] - self.micStartTime;
        if (!self.e2eAudioFile && !self.unitTestMode) {
            dispatch_async(dispatch_get_main_queue(), ^{ GFLog(@"Mic: first audio buffer %.0f ms after press", firstAfter * 1000.0); });
        }
    }
    {
        // Feed on-device recognizer buffer
        SFSpeechAudioBufferRecognitionRequest *req = weakSelf.recognitionRequest;
        if (req) {
            [req appendAudioPCMBuffer:buffer];
        }

        // Calculate input volume level directly for smooth waveform animation
        float peak = 0.0f;
        if (buffer.floatChannelData != NULL) {
            float *chan = buffer.floatChannelData[0];
            for (AVAudioFrameCount f = 0; f < buffer.frameLength; f++) {
                float val = fabsf(chan[f]);
                if (val > peak) peak = val;
            }
        }
        float animLevel = peak * 4.0f;
        if (animLevel > 1.0f) animLevel = 1.0f;

        // Convert to 16kHz 1-ch 16-bit PCM for Gemini and offline WAV
        AVAudioPCMBuffer *convertedBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:targetFormat
                                                                          frameCapacity:(AVAudioFrameCount)(buffer.frameLength * 16000.0 / inputFormat.sampleRate + 512)];

        __block BOOL didProvideInput = NO;
        NSError *convError = nil;
        AVAudioConverterOutputStatus status = [converter convertToBuffer:convertedBuffer error:&convError withInputFromBlock:^AVAudioBuffer *(AVAudioFrameCount inNumberOfFrames, AVAudioConverterInputStatus *outStatus) {
            if (didProvideInput) {
                *outStatus = AVAudioConverterInputStatus_NoDataNow;
                return nil;
            }
            didProvideInput = YES;
            *outStatus = AVAudioConverterInputStatus_HaveData;
            return buffer;
        }];

        // Streaming conversion of one buffer returns InputRanDry (not HaveData) while still producing
        // frames; accepting only HaveData silently discarded 100% of the recorded PCM.
        if (status != AVAudioConverterOutputStatus_Error && status != AVAudioConverterOutputStatus_EndOfStream) {
            int16_t *channelData = convertedBuffer.int16ChannelData[0];
            NSUInteger byteCount = convertedBuffer.frameLength * sizeof(int16_t);

            if (byteCount > 0 && channelData != NULL) {
                NSData *chunkData = [NSData dataWithBytes:channelData length:byteCount];

                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf.recordedPCMData appendData:chunkData];
                    weakSelf.lastCapturedAudioEndTime = captureEnd;
                    [weakSelf.hudPanel updateAudioLevel:animLevel];

                    [weakSelf pumpLiveAudioForce:NO];
                });
            }
        }
    }
}

- (void)startE2EFileFeedWithConverter:(AVAudioConverter *)converter targetFormat:(AVAudioFormat *)targetFormat {
    NSError *err = nil;
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:self.e2eAudioFile] error:&err];
    if (!file) { NSLog(@"e2e: cannot open %@: %@", self.e2eAudioFile, err); return; }
    AVAudioFormat *fmt = file.processingFormat;
    AVAudioConverter *fileConverter = [[AVAudioConverter alloc] initFromFormat:fmt toFormat:targetFormat];
    self.e2eFeedRunning = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        AVAudioFrameCount chunk = 1024;
        double chunkDur = chunk / fmt.sampleRate;
        NSDate *start = [NSDate date];
        long long n = 0;
        while (weakSelf.e2eFeedRunning && file.framePosition < file.length) {
            AVAudioPCMBuffer *b = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt frameCapacity:chunk];
            if (![file readIntoBuffer:b frameCount:chunk error:nil] || b.frameLength == 0) break;
            if (weakSelf.e2eFirstBufferTime == 0) weakSelf.e2eFirstBufferTime = [NSDate timeIntervalSinceReferenceDate];
            [weakSelf processCapturedBuffer:b converter:fileConverter targetFormat:targetFormat when:nil];
            n++;
            double wait = [[start dateByAddingTimeInterval:n * chunkDur] timeIntervalSinceNow];
            if (wait > 0) [NSThread sleepForTimeInterval:wait];
        }
        weakSelf.e2eFeedRunning = NO;
    });
}

- (void)stopAudioEngine {
    self.e2eFeedRunning = NO;
    if (self.audioEngine && !self.e2eAudioFile) {
        [self.audioEngine.inputNode removeTapOnBus:0];
        [self.audioEngine stop];
        [self prewarmAudioEngine]; // Keep CoreAudio engine pre-warmed for next press
    }
    if (self.recognitionRequest) {
        [self.recognitionRequest endAudio];
        self.recognitionRequest = nil;
    }
    // Do not cancel recognitionTask immediately; let it finish emitting final transcript
}

- (void)cancelRecording {
    self.isRecording = NO;
    self.isHandsFree = NO;
    [self flushDeferredPastes]; // a previous dictation that finished during this press still gets pasted (backlog 6)
    self.recognitionSessionId += 1; // drop any late recognizer callbacks / pending finalization
    self.isFinalizingOnDevice = NO;
    [self stopAudioEngine];
    if (self.recognitionTask) {
        [self.recognitionTask cancel];
        self.recognitionTask = nil;
    }
    [self closeLiveWebSocket];

    [self returnToIdleWithStatusTitle:nil notice:@"Cancelled" mode:HUDModeNotice dismissAfter:0.8];
}

// Backlog 27 (measurement only): numbers about the release cushion of a Fn-hold (or e2e) release, logged at the stop.
- (void)logReleaseCushionAtStop {
    NSTimeInterval stopAt = [NSDate timeIntervalSinceReferenceDate];
    NSUInteger len = self.recordedPCMData.length;
    NSUInteger from = MIN(self.releasePCMBytesAtFnUp, len) & ~(NSUInteger)1;
    double tailMax = 0;
    if (len > from) {
        GFSecondsAboveRMS((const int16_t *)((const uint8_t *)self.recordedPCMData.bytes + from), (len - from) / 2, kNoSpeechFrameRMS, &tailMax);
    }
    GFLog(@"%@", GFReleaseCushionLogLine(GFAudioReachPastReleaseMs(self.lastCapturedAudioEndTime, self.releaseFnUpTime),
                                         (stopAt - self.releaseFnUpTime) * 1000.0, (len - from) / 32.0, tailMax));
}

- (void)stopRecordingAndProcess {
    if (!self.isRecording) return;
    if (self.micStartTime > 0 && GFMicNoBuffersAtRelease(self.micBuffersSeen, self.recordedPCMData.length,
                                                         [NSDate timeIntervalSinceReferenceDate] - self.micStartTime)) {
        // Not a single buffer in a press of >= 1 s: the mic never worked, so there is nothing to transcribe (not "No speech")
        [self abortPressForMicProblem:GFMicProblemNoBuffers micAuth:[self micAuthorizationStatus] closeLive:YES];
        return;
    }
    GFLog(@"stopRecordingAndProcess: pcm=%.2fs liveText=%lu chars final=%d", self.recordedPCMData.length / 32000.0,
          (unsigned long)self.latestOnDeviceTranscript.length, self.latestOnDeviceIsFinal);
    if (self.releaseFnUpTime > 0 && !self.isHandsFree) [self logReleaseCushionAtStop];
    self.isRecording = NO;
    self.isHandsFree = NO;
    GFDictation *dictation = self.activeDictation;
    if (dictation.releaseTime == 0) dictation.releaseTime = [NSDate timeIntervalSinceReferenceDate];
    [self flushDeferredPastes]; // previous dictations that finished during this press paste first, before this one's text

    [self stopAudioEngine];

    [self setMenuIconState:2];
    NSString *engineMode = [self effectiveEngineMode];
    NSString *apiKey = [[NSUserDefaults standardUserDefaults] stringForKey:kPrefApiKey];
    BOOL liveUsed = [engineMode isEqualToString:@"gemini"] && apiKey.length > 0 && [self isLiveWebSocketModel:[self currentGeminiModel]];
    GFLog(@"%@", GFPressStatsLogLineWithRotations(self.recordedPCMData.length / 32000.0, liveUsed,
                                                  GFLiveSessionAgeSeconds([NSDate timeIntervalSinceReferenceDate], self.liveSocketReadyTime),
                                                  self.liveReconnects, self.liveActivityCount, self.liveRotations));

    [self.hudPanel setHUDMode:HUDModeThinking noticeText:nil];
    if ([engineMode isEqualToString:@"gemini"] && apiKey.length > 0) {
        [self finishWithGeminiProcessing];
    } else {
        [self finishWithOnDeviceTranscriptForDictation:dictation];
    }
    if (self.e2eMode.length > 0 && self.e2eSecondPressFile.length > 0 && !self.e2eSecondPressStarted
        && [self.e2eSecondPressPhase isEqualToString:@"release"]) {
        __weak typeof(self) weakSelf = self; // test hook: the second press starts while this one's Live final turn is pending
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf e2eStartSecondPress];
        });
    }
}

#pragma mark - Gemini Live WebSocket Engine (streaming transcription)

// Streams audio while Fn is held so transcription happens *during* speech; on release only the last
// utterance is pending (measured ~0.3 s vs 2-5 s for one-shot REST). Any failure falls back to REST
// (gemini-3.5-flash-lite) on the full recording, then to Apple's on-device transcript.

- (void)startGeminiLiveWebSocket { [self startGeminiLiveWebSocketResuming:NO]; }

// Per-socket protocol state. A fresh press resets everything; a mid-press reconnect (resume) keeps the press's coverage, voice
// scan and the text of finished turns, drops text of a turn the server never finished (its audio is resent), and resends from
// the covered byte. All byte offsets stay offsets into recordedPCMData, so coverage accounting spans sessions.
- (void)liveResetSessionStateResuming:(BOOL)resume {
    if (!resume) {
        self.liveCoveredBytes = 0;
        self.liveSegments = [NSMutableArray array];
        self.liveCoveredSegments = 0;
        self.liveActivityCount = 0;
        self.liveVoiceScannedBytes = 0;
        self.liveLastVoicedByte = 0;
        self.liveReconnects = 0;
        self.liveEverConnected = NO;
        self.liveRotations = 0;
    } else if (self.liveSegments.count > self.liveCoveredSegments) {
        [self.liveSegments removeObjectsInRange:NSMakeRange(self.liveCoveredSegments, self.liveSegments.count - self.liveCoveredSegments)];
    }
    self.liveSentBytes = resume ? self.liveCoveredBytes : 0;
    self.liveSpeechActive = NO;
    self.liveFinalizing = NO;
    self.liveActivityEnded = NO;
    self.liveActivityOpen = NO;
    self.liveActivityStartByte = self.liveSentBytes;
    self.livePendingActivityEnds = [NSMutableArray array];
    self.liveSplitDisabled = NO;
    self.liveTurnEndCounted = NO;
    self.liveLastActivityEndByte = resume ? self.liveCoveredBytes : 0;
    self.liveSplitTime = 0;
    self.liveActivityEndsSent = 0;
    self.liveActivityEndEchoes = 0;
    self.liveFinalEndIndex = 0;
    self.liveFinalReopenDeferred = NO;
    self.liveFailed = NO;
    self.liveWebSocketConnected = NO;
    self.liveSocketIsRotation = NO; // a planned rotation sets these right after the new socket starts (liveApplyRotationResume...)
    self.liveQuietResume = NO;
    self.liveGoAway = NO;
}

// Test hook (e2e only, --e2e-live-setup-extra <json>, backlog 0y-probe): the extra `setup` object. nil in the normal app and outside
// e2e mode, so the setup message is the usual one and none of the "Live setup probe" log lines exist. {} = the usual message plus
// the probe's log lines (the probe's control case).
- (NSDictionary *)liveSetupProbeExtra { return self.e2eMode.length > 0 ? self.e2eLiveSetupExtra : nil; }

// Setup probe (e2e only): remember which fields the server's messages carry (names only, never values) and log an error frame.
- (void)e2eNoteLiveProbeMessage:(NSDictionary *)json {
    GFJSONCollectKeyPaths(json, @"", 3, self.e2eLiveSeenFields);
    NSString *errLine = GFLiveProbeErrorFrameLine(json, self.liveWebSocketConnected);
    if (errLine) GFLog(@"%@", errLine);
}

- (void)startGeminiLiveWebSocketResuming:(BOOL)resume {
    NSString *apiKey = [[NSUserDefaults standardUserDefaults] stringForKey:kPrefApiKey];
    NSString *model = [self currentGeminiModel];

    [self closeLiveWebSocket];
    self.liveSessionId += 1;
    NSUInteger sid = self.liveSessionId;
    [self liveResetSessionStateResuming:resume];

    // Key in the x-goog-api-key header of the upgrade request; the key-in-URL method only as the one-shot auth fallback (backlog 15)
    BOOL keyInURL = self.liveNextConnectKeyInURL || self.liveAuthMode == GFLiveAuthKeyInURL;
    self.liveAuthRetrySession = self.liveNextConnectKeyInURL;
    self.liveNextConnectKeyInURL = NO;
    self.liveAuthViaHeader = !keyInURL;
    self.liveSession = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration] delegate:nil delegateQueue:nil];
    self.liveWebSocketTask = [self.liveSession webSocketTaskWithRequest:GFLiveWebSocketRequest(apiKey, keyInURL)];
    self.liveWebSocketTask.maximumMessageSize = 4 * 1024 * 1024;
    [self.liveWebSocketTask resume];

    // Transcription models reject system instructions; they return inputTranscription per utterance.
    // Manual activity: the server's VAD misses some voices / fast speech entirely (no ACTIVITY_START, even at
    // START_SENSITIVITY_HIGH), forcing the slow REST safety net. The user already tells us exactly when they speak
    // (Fn held), so we mark the whole press as one activity: activityStart at setupComplete, activityEnd on release.
    NSDictionary *setupExtra = [self liveSetupProbeExtra]; // test hook (e2e only); nil = the normal setup message
    NSDictionary *setupMsg = GFLiveSetupMessage(model, setupExtra);
    NSString *setupStr = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:setupMsg options:0 error:nil] encoding:NSUTF8StringEncoding];
    __weak typeof(self) weakSelf = self;
    GFLog(@"Live: connecting (%@, key via %@)", model, keyInURL ? @"URL" : @"header");
    if (setupExtra) { // setup probe (e2e only): which fields were added (names only), and start collecting the server's field names
        self.e2eLiveSetupSentTime = [NSDate timeIntervalSinceReferenceDate];
        self.e2eLiveSeenFields = [NSMutableSet set];
        GFLog(@"%@", GFLiveProbeSetupLine(sid, setupExtra, setupStr.length, keyInURL));
    }
    NSURLSessionWebSocketTask *task = self.liveWebSocketTask;
    [self.liveWebSocketTask sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:setupStr] completionHandler:^(NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *why = [NSString stringWithFormat:@"setup send: %@", error.localizedDescription];
                // Header-auth session before setupComplete: the receive error carries the handshake details (HTTP status / close
                // code) that tell an auth rejection from a network failure, so let it report first; this report only matters if it
                // never comes. Every other case reports at once, as before.
                if (weakSelf.liveSessionId == sid && weakSelf.liveAuthViaHeader && !weakSelf.liveWebSocketConnected) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [weakSelf liveConnectionLost:why session:sid task:task error:error];
                    });
                } else {
                    [weakSelf liveConnectionLost:why session:sid task:task error:error];
                }
            });
        }
    }];
    [self listenForWebSocketMessagesSession:sid task:self.liveWebSocketTask];
}

- (void)listenForWebSocketMessagesSession:(NSUInteger)sid task:(NSURLSessionWebSocketTask *)task {
    __weak typeof(self) weakSelf = self;
    [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        NSDictionary *json = nil;
        if (!error) {
            NSData *d = message.type == NSURLSessionWebSocketMessageTypeString ? [message.string dataUsingEncoding:NSUTF8StringEncoding] : message.data;
            if (d) json = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf.liveSessionId != sid) return; // stale socket
            if (error) {
                [weakSelf liveConnectionLost:[NSString stringWithFormat:@"receive: %@ (close code %ld)", error.localizedDescription, (long)task.closeCode]
                                     session:sid task:task error:error];
                return;
            }
            [weakSelf handleLiveMessage:json session:sid];
            if (weakSelf.liveWebSocketTask == task && !weakSelf.liveFailed) {
                [weakSelf listenForWebSocketMessagesSession:sid task:task];
            }
        });
    }];
}

- (void)handleLiveMessage:(NSDictionary *)json session:(NSUInteger)sid {
    if (![json isKindOfClass:[NSDictionary class]]) return;
    if (self.e2eLiveSeenFields) [self e2eNoteLiveProbeMessage:json]; // setup probe (e2e only)
    if (json[@"setupComplete"]) {
        self.liveWebSocketConnected = YES;
        self.liveEverConnected = YES;
        self.liveSocketReadyTime = [NSDate timeIntervalSinceReferenceDate];
        GFLog(@"Live: setupComplete");
        if ([self liveSetupProbeExtra]) // setup probe (e2e only): the server accepted this setup message
            GFLog(@"%@", GFLiveProbeSetupCompleteLine(sid, self.liveAuthViaHeader, (self.liveSocketReadyTime - self.e2eLiveSetupSentTime) * 1000.0));
        if (self.liveAuthViaHeader) {
            if (self.liveAuthMode != GFLiveAuthHeaderOK) GFLog(@"Live: auth via the x-goog-api-key header works (key kept out of the URL)");
            self.liveAuthMode = GFLiveAuthHeaderOK;
        } else if (self.liveAuthRetrySession) {
            GFLog(@"Live: header auth was rejected but the key-in-URL retry worked; using the URL method for the rest of this run");
            self.liveAuthMode = GFLiveAuthKeyInURL;
        }
        if (self.liveSocketIsRotation)
            GFLog(@"Live: rotated session ready (rotation #%lu, %@); %.2fs of audio waiting from %.2fs (%lu segments kept)",
                  (unsigned long)self.liveRotations, self.liveQuietResume ? @"between activities" : @"resending from the covered byte",
                  (self.recordedPCMData.length - MIN(self.recordedPCMData.length, self.liveSentBytes)) / 32000.0,
                  self.liveSentBytes / 32000.0, (unsigned long)self.liveSegments.count);
        else if (self.liveReconnects > 0)
            GFLog(@"Live: reconnected (#%lu); resending %.2fs of audio from %.2fs (%lu segments kept)", (unsigned long)self.liveReconnects,
                  (self.recordedPCMData.length - MIN(self.recordedPCMData.length, self.liveSentBytes)) / 32000.0,
                  self.liveSentBytes / 32000.0, (unsigned long)self.liveSegments.count);
        if (self.liveQuietResume) {
            // Planned rotation at a split point (backlog 0p): nothing was pending, so stay between activities. The pump reopens an
            // activity (with pre-roll) on the next voiced audio; a release now finishes at once (released between turns).
            self.liveQuietResume = NO;
            [self pumpLiveAudioForce:YES];
            if (self.liveFinalizing) [self sendLiveAudioStreamEnd];
            return;
        }
        // Open the (manual) activity before any audio so the server transcribes everything the user says.
        [self sendLiveActivityStart]; // pending until the server's turnComplete for this activity
        [self pumpLiveAudioForce:YES]; // flush audio captured while connecting
        if (self.liveFinalizing) [self sendLiveAudioStreamEnd]; // released before setup finished
        return;
    }
    if (json[@"goAway"]) {
        // Backlog 0p: the server announces the end of this session. Not seen so far; log it (numbers only) and rotate at the next
        // split point (GFLiveShouldRotate); a close after it counts as planned (GFLiveCloseIsPlannedRotation).
        NSDictionary *ga = [json[@"goAway"] isKindOfClass:[NSDictionary class]] ? json[@"goAway"] : nil;
        id tl = ga[@"timeLeft"];
        double left = [tl respondsToSelector:@selector(doubleValue)] ? [tl doubleValue] : -1.0;
        self.liveGoAway = YES;
        GFLog(@"Live: goAway received at session age %.1fs (time left %.1fs; %.2fs sent, covered %.2fs)",
              GFLiveSessionAgeSeconds([NSDate timeIntervalSinceReferenceDate], self.liveSocketReadyTime), left,
              self.liveSentBytes / 32000.0, self.liveCoveredBytes / 32000.0);
        return;
    }
    NSDictionary *va = json[@"voiceActivity"];
    if ([va isKindOfClass:[NSDictionary class]]) {
        if ([va[@"type"] isEqualToString:@"ACTIVITY_START"]) self.liveSpeechActive = YES;
        if ([va[@"type"] isEqualToString:@"ACTIVITY_END"] && self.e2eHiddenEchoes > 0 && self.e2eMode.length > 0) {
            // Test hook: the simulated server-initiated turn end must look like the server's own (no echo of an activityEnd).
            self.e2eHiddenEchoes -= 1;
            GFLog(@"E2E: hid the ACTIVITY_END echo of the simulated server turn end at %.2fs sent", self.liveSentBytes / 32000.0);
            return;
        }
        if ([va[@"type"] isEqualToString:@"ACTIVITY_END"]) {
            self.liveActivityEndEchoes += 1;
            // An echo beyond our own activityEnds is a server-initiated end: don't let it shift the echo <-> activityEnd pairing.
            if (self.liveActivityEndEchoes > self.liveActivityEndsSent) self.liveActivityEndEchoes = self.liveActivityEndsSent;
            if (self.liveFinalizing && GFLiveEchoMeansEmptyFinalTurn(self.liveActivityEndEchoes, self.liveFinalEndIndex,
                                                                     self.livePendingActivityEnds.count))
                [self liveScheduleEmptyFinalTurnCheckSession:sid];
            // Cover only up to the activityEnd this echo belongs to (backlog 0r: never a later activity's end). Its turn still
            // pending = the server closed it with no transcript; a split one is released after a short grace so held audio flows.
            NSInteger echoIdx = GFLiveEchoPendingIndex(self.liveActivityEndEchoes, self.liveActivityEndsSent,
                                                       self.livePendingActivityEnds.count);
            if (echoIdx >= 0 && (NSUInteger)echoIdx < self.livePendingActivityEnds.count) {
                self.liveCoveredBytes = MAX(self.liveCoveredBytes, self.livePendingActivityEnds[echoIdx].unsignedIntegerValue);
                if (self.liveActivityEndEchoes != self.liveFinalEndIndex)
                    [self liveScheduleEmptySplitTurnCheck:self.liveActivityEndEchoes session:sid];
            } else if (self.livePendingActivityEnds.count == 0) {
                if (self.liveLastActivityEndByte > 0)
                    self.liveCoveredBytes = MAX(self.liveCoveredBytes, self.liveLastActivityEndByte);
                else
                    self.liveCoveredBytes = self.liveSentBytes;
            }
            self.liveCoveredSegments = self.liveSegments.count;
        }
        GFLog(@"Live: %@ at %.2fs sent", va[@"type"], self.liveSentBytes / 32000.0);
    }
    NSDictionary *sc = json[@"serverContent"];
    if (![sc isKindOfClass:[NSDictionary class]]) return;
    if (self.e2eLiveDropOutput && self.e2eMode.length > 0) return; // test hook: Live "hears nothing" (e2e only)
    NSString *finalText = sc[@"inputTranscription"][@"text"];
    if ([finalText isKindOfClass:[NSString class]]) {
        NSString *t = [finalText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length > 0) {
            [self.liveSegments addObject:t];
            GFLog(@"Live: transcript segment %lu (%lu chars) at %.2fs sent", (unsigned long)self.liveSegments.count,
                  (unsigned long)t.length, self.liveSentBytes / 32000.0);
        }
    }
    // The transcribe model ends each turn with generationComplete (turnComplete may follow later or not at all).
    // Count one turn end per turn: whichever arrives first; a turnComplete right after a generationComplete is the same turn.
    if ([sc[@"interrupted"] boolValue]) GFLog(@"Live: interrupted at %.2fs sent", self.liveSentBytes / 32000.0);
    BOOL genDone = [sc[@"generationComplete"] boolValue], turnFlag = [sc[@"turnComplete"] boolValue];
    BOOL turnDone = genDone || (turnFlag && !self.liveTurnEndCounted);
    if (turnFlag && !genDone && self.liveTurnEndCounted) {
        self.liveTurnEndCounted = NO;
        GFLog(@"Live: turnComplete (same turn) at %.2fs sent", self.liveSentBytes / 32000.0);
    } else if (turnDone) {
        self.liveTurnEndCounted = genDone && !turnFlag;
    }
    if (turnDone) {
        self.liveCoveredSegments = self.liveSegments.count; // this turn's text has arrived (it precedes its turn end)
        if (self.livePendingActivityEnds.count > 0) {
            // Turns complete in activity order: this one covers the audio up to its activityEnd.
            NSUInteger endIndex = self.liveActivityEndsSent - MIN(self.liveActivityEndsSent, self.livePendingActivityEnds.count) + 1;
            self.liveCoveredBytes = MAX(self.liveCoveredBytes, self.livePendingActivityEnds.firstObject.unsignedIntegerValue);
            [self.livePendingActivityEnds removeObjectAtIndex:0];
            self.liveSpeechActive = self.livePendingActivityEnds.count > 0 || self.liveActivityOpen;
            NSTimeInterval since = [NSDate timeIntervalSinceReferenceDate] - self.liveSplitTime;
            if (self.liveSplitTime > 0 && since > 1.5 && endIndex != self.liveFinalEndIndex && !self.liveActivityOpen
                && self.livePendingActivityEnds.count == 0) // numbers only (backlog 0r: look for this line online)
                GFLog(@"Live: slow split turn answered %.2fs after its activityEnd (%.2fs of audio held for the next activity)", since,
                      (self.recordedPCMData.length - MIN(self.recordedPCMData.length, self.liveSentBytes)) / 32000.0);
        } else {
            // The server ended a turn we didn't end. Later audio may be ignored, so it must count as uncovered
            // (cycle-2 safety net -> REST); stop splitting for the rest of this session.
            self.liveSpeechActive = NO;
            self.liveCoveredBytes = self.liveSentBytes;
            self.liveSplitDisabled = YES;
            if (GFLiveReopenAfterUnsolicitedTurnEnd(self.livePendingActivityEnds.count, self.liveActivityOpen,
                                                    self.liveFinalizing, self.liveActivityEnded)) {
                // Still recording: the server's activity is over. Re-open on the next speech so it stays on Live (backlog 0c);
                // the re-opened activity's own turn covers it, and the coverage check above still guards anything it misses.
                self.liveActivityOpen = NO;
                GFLog(@"Live: server ended the turn mid-press at %.2fs sent; re-opening the activity on the next speech",
                      self.liveSentBytes / 32000.0);
            }
        }
        GFLog(@"Live: %@ at %.2fs sent (covered %.2fs, %lu activities pending, open=%d)", genDone ? @"generationComplete" : @"turnComplete",
              self.liveSentBytes / 32000.0, self.liveCoveredBytes / 32000.0, (unsigned long)self.livePendingActivityEnds.count, self.liveActivityOpen);
        if (self.liveFinalReopenDeferred && self.livePendingActivityEnds.count == 0)
            [self liveSendDeferredFinalActivity]; // released behind a pending split turn: now send the held speech as the final turn
        else if (self.liveFinalizing && self.livePendingActivityEnds.count == 0 && !self.liveActivityOpen)
            [self finishLiveTranscriptWithReason:@"final utterance complete"];
        else if (!self.liveActivityOpen && !self.liveActivityEnded)
            [self pumpLiveAudioForce:YES]; // split turn answered: reopen now if speech was buffered meanwhile
    }
}

// Backlog 0r: a split activityEnd was echoed while its turn was still pending: the server closed that turn with no transcript (it
// never sends generationComplete for it). After the usual grace, release it so audio held behind it reaches the next activity.
// The release's own empty turn keeps its existing handling (liveScheduleEmptyFinalTurnCheckSession).
- (void)liveScheduleEmptySplitTurnCheck:(NSUInteger)echoIndex session:(NSUInteger)sid {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLiveEmptyTurnGrace * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) s = weakSelf;
        if (!s || s.liveSessionId != sid || s.hasCompletedGeminiTurn || s.liveFailed) return;
        if (s.liveFinalEndIndex > 0 && s.liveActivityEndEchoes >= s.liveFinalEndIndex) return; // the final turn's check decides
        if (GFLiveEchoPendingIndex(echoIndex, s.liveActivityEndsSent, s.livePendingActivityEnds.count) != 0) return; // answered
        [s liveSplitTurnClosedEmpty];
    });
}

- (void)liveSplitTurnClosedEmpty {
    if (self.livePendingActivityEnds.count == 0) return;
    self.liveCoveredBytes = MAX(self.liveCoveredBytes, self.livePendingActivityEnds.firstObject.unsignedIntegerValue);
    [self.livePendingActivityEnds removeObjectAtIndex:0];
    self.liveSpeechActive = self.livePendingActivityEnds.count > 0 || self.liveActivityOpen;
    GFLog(@"Live: split turn closed with no transcript (ACTIVITY_END echo, no generationComplete); covered %.2fs, %lu pending",
          self.liveCoveredBytes / 32000.0, (unsigned long)self.livePendingActivityEnds.count);
    if (self.liveFinalReopenDeferred && self.livePendingActivityEnds.count == 0)
        [self liveSendDeferredFinalActivity];
    else if (self.liveFinalizing && self.livePendingActivityEnds.count == 0 && !self.liveActivityOpen)
        [self liveFinishIfReleasedBetweenTurns]; // finishes, or goes to REST if speech is uncovered
    else if (!self.liveActivityOpen && !self.liveActivityEnded)
        [self pumpLiveAudioForce:YES];
}

// Backlog 0r: released while speech was held behind a pending split turn. That turn has ended now: open the final activity, send
// the held audio (from its pre-roll) and end it, exactly as a release with an open activity does.
- (void)liveSendDeferredFinalActivity {
    self.liveFinalReopenDeferred = NO;
    GFLog(@"Live: pending split turn ended after release; sending the held %.2fs as the final activity",
          (self.recordedPCMData.length - MIN(self.recordedPCMData.length, self.liveSentBytes)) / 32000.0);
    [self sendLiveActivityStart];
    [self pumpLiveAudioForce:YES];
    [self sendLiveActivityEnd];
    self.liveFinalEndIndex = self.liveActivityEndsSent;
}

- (void)pumpLiveAudioForce:(BOOL)force {
    if (!self.liveWebSocketConnected || (!self.liveWebSocketTask && !self.liveTestSocketless)) return;
    if ([self e2eMaybeSimulateLifetimeClose]) return;
    NSUInteger total = self.recordedPCMData.length;
    if (total <= self.liveSentBytes) return;
    if (!force && total - self.liveSentBytes < 3200) return; // send ~100 ms chunks
    if (!self.liveActivityOpen) {
        if (self.liveActivityEnded) return;
        // Planned session rotation at a split point (backlog 0p (a)): no activity open and no turn pending
        if (GFLiveShouldRotate(self.isRecording, self.liveFinalizing, self.liveActivityEnded, self.liveWebSocketConnected,
                               self.liveActivityOpen, self.livePendingActivityEnds.count,
                               GFLiveSessionAgeSeconds([NSDate timeIntervalSinceReferenceDate], self.liveSocketReadyTime),
                               self.liveGoAway, [self liveRotateAgeSeconds])) {
            [self liveRotateSessionAtSplitPoint];
            return; // the new session sends the buffered audio at its setupComplete
        }
        // Between activities (after a split): hold back silence (the server ignores audio outside an activity) and
        // reopen as soon as anything above the split threshold arrives, sending ~0.3 s of pre-roll before it.
        [self liveScanVoiceUpTo:total];
        switch (GFLiveBetweenActivitiesDecision(self.liveLastVoicedByte > self.liveSentBytes, self.livePendingActivityEnds.count)) {
            case GFLiveBetweenDropSilence: {
                const NSUInteger preroll = 9600;
                if (total > self.liveSentBytes + preroll) self.liveSentBytes = total - preroll;
                return;
            }
            case GFLiveBetweenHold:
                // An activityStart while a split turn is pending makes the server drop that turn (right after the split end) or
                // lose the start of the new activity (while it is still generating; backlog 0r). Hold the voiced audio, from its
                // pre-roll, until the split turn ends (its generationComplete, or its ACTIVITY_END echo if it closed empty): the
                // turn end pumps again and this audio goes into the reopened activity. On release, sendLiveAudioStreamEnd defers
                // the final activity the same way.
                return;
            case GFLiveBetweenReopen:
                break;
        }
        [self sendLiveActivityStart];
    }
    // A resend from the covered byte (reconnect/rotation) or audio held behind a slow split turn can be many seconds: send it as
    // 1 s messages (normal ~100 ms pumps are one message).
    NSUInteger maxChunk = 32000;
    while (self.liveSentBytes < total) {
        NSUInteger pending = MIN(maxChunk, total - self.liveSentBytes);
        NSData *chunk = [self.recordedPCMData subdataWithRange:NSMakeRange(self.liveSentBytes, pending)];
        self.liveSentBytes += pending;
        NSDictionary *msg = @{@"realtimeInput": @{@"audio": @{@"mimeType": @"audio/pcm;rate=16000",
                                                             @"data": [chunk base64EncodedStringWithOptions:0]}}};
        NSString *str = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:msg options:0 error:nil] encoding:NSUTF8StringEncoding];
        [self.liveWebSocketTask sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:str] completionHandler:^(NSError *error) {
            if (error) GFLog(@"Live: audio send failed: %@", error.localizedDescription);
        }];
    }
    [self e2eMaybeDropLiveSocket];
    [self e2eMaybeSimulateServerTurnEnd];
    [self liveMaybeSplitActivity];
}

// Test hook (e2e only, --e2e-live-drop-at <s>): the Live socket dies mid-press, as on 2026-11-10 13:31 (server close 1011). The
// task is cancelled with close code 1011 and left in place, so the app sees exactly what a server close produces: a receive error
// on its current socket while the press is still recording. Fires once per run (first press), never after release.
- (void)e2eMaybeDropLiveSocket {
    if (self.e2eMode.length == 0 || self.e2eLiveDropAt <= 0 || self.e2eLiveDropFired || self.liveFinalizing || !self.isRecording) return;
    if (self.liveSentBytes < (NSUInteger)(self.e2eLiveDropAt * 32000.0)) return;
    self.e2eLiveDropFired = YES;
    GFLog(@"E2E: force-closing the Live socket at %.2fs sent (covered %.2fs)", self.liveSentBytes / 32000.0, self.liveCoveredBytes / 32000.0);
    [self.liveWebSocketTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeInternalServerError reason:nil];
}

// Test hook (e2e only, --e2e-live-server-turn-end <s>): make the server end the open activity's turn on its own while the press
// is still recording, as if it had decided the turn was over. A raw activityEnd is sent WITHOUT any client bookkeeping (the app
// still thinks its activity is open, nothing is pending), and its ACTIVITY_END echo is hidden, so the app only sees the real
// server's generationComplete for a turn it never ended, and later audio reaches a server with no open activity.
- (void)e2eMaybeSimulateServerTurnEnd {
    if (self.e2eMode.length == 0 || self.e2eServerTurnEndAt <= 0 || self.e2eServerTurnEndFired) return;
    if (!self.liveActivityOpen || self.liveFinalizing || self.liveActivityEnded || self.livePendingActivityEnds.count > 0) return;
    if (self.liveSentBytes < (NSUInteger)(self.e2eServerTurnEndAt * 32000.0)) return;
    self.e2eServerTurnEndFired = YES;
    self.e2eHiddenEchoes += 1;
    GFLog(@"E2E: simulating a server-initiated turn end at %.2fs sent", self.liveSentBytes / 32000.0);
    [self.liveWebSocketTask sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:@"{\"realtimeInput\":{\"activityEnd\":{}}}"]
                      completionHandler:^(NSError *error) {}];
}

// Test hook (e2e only, --e2e-live-lifetime <s>): the server's session lifetime, shrunk. Every Live session is closed with close code
// 1008 (as on 2026-11-11 at ~590 s) once it is <s> old (since its setupComplete) while the press is recording; the task is left in
// place so the app sees a real receive error on its current socket. Nothing more is sent to a closed socket. The planned-close age
// becomes <s> - 1 (livePlannedCloseAgeSeconds), so these closes must be handled as planned rotations, not drops.
- (BOOL)e2eMaybeSimulateLifetimeClose {
    if (self.e2eMode.length == 0 || self.e2eLiveLifetime <= 0 || self.liveFinalizing || !self.isRecording) return NO;
    if (self.e2eLifetimeClosedSid == self.liveSessionId) return YES;
    double age = GFLiveSessionAgeSeconds([NSDate timeIntervalSinceReferenceDate], self.liveSocketReadyTime);
    if (isnan(age) || age < MAX(kLiveE2EMinRotateAge, self.e2eLiveLifetime)) return NO;
    self.e2eLifetimeClosedSid = self.liveSessionId;
    self.e2eLifetimeCloses += 1;
    GFLog(@"E2E: simulating the Live session-lifetime close #%lu at session age %.1fs (%.2fs sent, covered %.2fs, activity open=%d)",
          (unsigned long)self.e2eLifetimeCloses, age, self.liveSentBytes / 32000.0, self.liveCoveredBytes / 32000.0, self.liveActivityOpen);
    [self.liveWebSocketTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodePolicyViolation reason:nil];
    return YES;
}

// Backlog 0p: rotation thresholds (the e2e-only hooks shrink them; never below kLiveE2EMinRotateAge).
- (double)liveRotateAgeSeconds {
    if (self.e2eMode.length > 0 && self.e2eLiveRotateAge > 0) return MAX(kLiveE2EMinRotateAge, self.e2eLiveRotateAge);
    return kLiveRotateAge;
}
- (double)livePlannedCloseAgeSeconds {
    if (self.e2eMode.length > 0 && self.e2eLiveLifetime > 0) return MAX(kLiveE2EMinRotateAge, self.e2eLiveLifetime - 1.0);
    return kLivePlannedCloseAge;
}

// Resume state of a planned rotation (backlog 0p), applied right after the new socket started (liveResetSessionStateResuming:YES
// already set liveSentBytes to the covered byte and dropped text of unfinished turns). quiet = the old session had no activity open
// and no turn pending: every sent byte is in a finished turn and all audio held back since that split is below the split threshold
// (silence), so keep the held-back position and open NO activity at setupComplete; the next voiced audio reopens one with the usual
// pre-roll (an activity of pure silence would end as an empty final turn on release -> REST). Not quiet: resend from the covered
// byte with activityStart at setupComplete, exactly like a mid-press reconnect. Nothing covered is ever sent twice.
- (void)liveApplyRotationResumeHeldBack:(NSUInteger)heldBack quiet:(BOOL)quiet {
    self.liveSocketIsRotation = YES;
    self.liveQuietResume = quiet;
    if (quiet) {
        NSUInteger pos = MAX(self.liveCoveredBytes, MIN(heldBack, self.recordedPCMData.length));
        self.liveSentBytes = pos;
        self.liveActivityStartByte = pos;
    }
}

// Backlog 0p (a): the session is old enough and nothing is pending: replace it now (not counted against the reconnect budget).
- (void)liveRotateSessionAtSplitPoint {
    NSUInteger heldBack = self.liveSentBytes;
    self.liveRotations += 1;
    GFLog(@"Live: planned session rotation #%lu at session age %.1fs (split point, nothing pending; %.2fs sent, covered %.2fs; "
          @"reconnects used %lu/%lu)", (unsigned long)self.liveRotations,
          GFLiveSessionAgeSeconds([NSDate timeIntervalSinceReferenceDate], self.liveSocketReadyTime), self.liveSentBytes / 32000.0,
          self.liveCoveredBytes / 32000.0, (unsigned long)self.liveReconnects, (unsigned long)kLiveMaxReconnects);
    [self startGeminiLiveWebSocketResuming:YES];
    [self liveApplyRotationResumeHeldBack:heldBack quiet:YES];
}

- (void)sendLiveActivityStart {
    self.liveActivityOpen = YES;
    self.liveActivityStartByte = self.liveSentBytes;
    self.liveActivityCount += 1;
    self.liveSpeechActive = YES;
    if (self.liveActivityCount > 1) GFLog(@"Live: activityStart #%lu at %.2fs", (unsigned long)self.liveActivityCount, self.liveSentBytes / 32000.0);
    [self.liveWebSocketTask sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:@"{\"realtimeInput\":{\"activityStart\":{}}}"]
                      completionHandler:^(NSError *error) { if (error) GFLog(@"Live: activityStart send failed: %@", error.localizedDescription); }];
}

// Closes the open activity; its turnComplete will cover the audio sent so far.
- (void)sendLiveActivityEnd {
    self.liveActivityOpen = NO;
    self.liveActivityEndsSent += 1;
    self.liveLastActivityEndByte = self.liveSentBytes;
    [self.livePendingActivityEnds addObject:@(self.liveSentBytes)];
    [self.liveWebSocketTask sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:@"{\"realtimeInput\":{\"activityEnd\":{}}}"]
                      completionHandler:^(NSError *error) {}];
}

// Local voice scan for activity splitting. Fixed threshold (150 RMS) is never above the adaptive threshold of
// voicedSecondsInRecordingFromByte (>= 150), so audio that the coverage check counts as speech is never treated as
// silence here (never held back, never a split point).
- (void)liveScanVoiceUpTo:(NSUInteger)total {
    const NSUInteger frameBytes = 640; // 20 ms
    NSData *pcm = self.recordedPCMData;
    if (total > pcm.length) total = pcm.length;
    const int16_t *samples = (const int16_t *)pcm.bytes;
    while (self.liveVoiceScannedBytes + frameBytes <= total) {
        NSUInteger off = self.liveVoiceScannedBytes;
        double acc = 0;
        for (NSUInteger i = 0; i < frameBytes / 2; i++) { double v = samples[off / 2 + i]; acc += v * v; }
        if (sqrt(acc / (frameBytes / 2)) > 150.0) self.liveLastVoicedByte = off + frameBytes;
        self.liveVoiceScannedBytes = off + frameBytes;
    }
}

// Split a long activity at a local pause (>= 0.6 s after >= 8 s of activity) so the final turn after release stays short.
- (void)liveMaybeSplitActivity {
    if (!self.liveActivityOpen || self.liveFinalizing || self.liveActivityEnded || self.liveSplitDisabled) return;
    if (self.liveSentBytes < self.liveActivityStartByte + 8 * 32000) return;
    [self liveScanVoiceUpTo:self.liveSentBytes];
    if (self.liveLastVoicedByte <= self.liveActivityStartByte) return; // nothing said in this activity yet
    if (self.liveVoiceScannedBytes < self.liveLastVoicedByte + 19200) return; // < 0.6 s of silence
    GFLog(@"Live: split activity #%lu at %.2fs (%.2fs long)", (unsigned long)self.liveActivityCount,
          self.liveSentBytes / 32000.0, (self.liveSentBytes - self.liveActivityStartByte) / 32000.0);
    self.liveSplitTime = [NSDate timeIntervalSinceReferenceDate];
    [self sendLiveActivityEnd];
}

// Kept for compatibility with older call sites
- (void)sendAudioChunkToLiveWebSocket:(NSData *)pcmChunk { [self pumpLiveAudioForce:YES]; }

- (void)sendLiveAudioStreamEnd {
    if (self.liveActivityEnded) return; // release raced setupComplete: both paths try to end the activity
    [self pumpLiveAudioForce:YES]; // before marking ended: voice since the last split must still reopen an activity
    self.liveActivityEnded = YES;
    if (!self.liveActivityOpen && self.livePendingActivityEnds.count > 0 && self.liveLastVoicedByte > self.liveSentBytes) {
        // Backlog 0r: speech is held behind a split turn that is still pending. Its turn end opens, fills and ends the final
        // activity (liveSendDeferredFinalActivity); the 2.5 s cap still guards a turn that never ends.
        self.liveFinalReopenDeferred = YES;
        GFLog(@"Live: released with %.2fs of audio held behind a pending split turn; the final activity opens when it ends",
              (self.recordedPCMData.length - MIN(self.recordedPCMData.length, self.liveSentBytes)) / 32000.0);
        return;
    }
    // Released between activities (silence since the last split): nothing left to end; the pending turns finish it, or (none
    // pending: every turn was already answered) it finishes right now (backlog 26).
    if (!self.liveActivityOpen) { [self liveFinishIfReleasedBetweenTurns]; return; }
    // Manual activity mode: activityEnd closes the last activity; the server then completes the turn.
    [self sendLiveActivityEnd];
    self.liveFinalEndIndex = self.liveActivityEndsSent;
}

// Backlog 26: released with no activity open. If no turn is pending either, every voiced byte so far went into an answered turn,
// so finish now (or go to REST if speech is uncovered) instead of at the 0.45 s grace timer; otherwise the pending turns finish it.
- (void)liveFinishIfReleasedBetweenTurns {
    if (!self.liveFinalizing || self.hasCompletedGeminiTurn || self.liveFailed) return;
    if (self.liveActivityOpen || self.livePendingActivityEnds.count > 0) return; // a turn end will finish it
    double uncovered = [self voicedSecondsInRecordingFromByte:self.liveCoveredBytes];
    GFLiveIdleReleaseAction action = GFLiveIdleReleaseDecision(self.liveActivityOpen, self.livePendingActivityEnds.count,
                                                               self.liveSegments.count, uncovered);
    if (action == GFLiveIdleReleaseFinish) {
        [self finishLiveTranscriptWithReason:[NSString stringWithFormat:@"released between turns, nothing pending (covered %.2fs)",
                                              self.liveCoveredBytes / 32000.0]];
    } else if (action == GFLiveIdleReleaseRest) {
        [self liveFailedWithReason:[NSString stringWithFormat:@"%.2fs of speech after %.2fs not transcribed by Live (released between turns)",
                                    uncovered, self.liveCoveredBytes / 32000.0] session:self.liveSessionId];
    }
}

// The server echoed the release's activityEnd before that turn produced anything (see GFLiveEchoMeansEmptyFinalTurn).
// Give in-flight messages a moment, then re-run the full recording through the REST safety net now instead of at the 2.5 s cap.
// Never finishes with less than was said: an empty final turn always goes to REST, even when earlier turns had text.
- (void)liveScheduleEmptyFinalTurnCheckSession:(NSUInteger)sid {
    NSUInteger pendingAtEcho = self.livePendingActivityEnds.count;
    NSTimeInterval echoTime = [NSDate timeIntervalSinceReferenceDate];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLiveEmptyTurnGrace * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.liveSessionId != sid || strongSelf.hasCompletedGeminiTurn || strongSelf.liveFailed) return;
        if (strongSelf.livePendingActivityEnds.count < pendingAtEcho || strongSelf.livePendingActivityEnds.count == 0) return;
        [strongSelf liveEmptyFinalTurnSession:sid reason:[NSString stringWithFormat:
            @"server closed the final turn with no transcript, %.2fs after release (%lu earlier segments)",
            echoTime - strongSelf.liveReleaseTime, (unsigned long)strongSelf.liveSegments.count]];
    });
}

// Live's final turn closed empty (signal a). End as "No speech" only if on-device and the local level checks agree (see
// GFNoSpeechVerdict); otherwise re-run the full recording through REST exactly as before. Logs signals only, never text.
// Backlog 0u: ALWAYS wait (<= kNoSpeechOnDeviceWait) for on-device's verdict, even when audio is above the RMS-60 level (a quiet
// room's noise is), so the speech-evidence rule can decide with it.
- (void)liveEmptyFinalTurnSession:(NSUInteger)sid reason:(NSString *)reason {
    if (self.liveSegments.count > 0) { [self liveFailedWithReason:reason session:sid]; return; } // earlier turns heard speech
    GFSpeechEvidence ev = GFMeasureSpeechEvidence((const int16_t *)self.recordedPCMData.bytes, self.recordedPCMData.length / 2);
    [self liveNoSpeechAwaitOnDeviceSession:sid reason:reason evidence:ev
                                  deadline:[NSDate timeIntervalSinceReferenceDate] + kNoSpeechOnDeviceWait];
}

- (void)liveNoSpeechAwaitOnDeviceSession:(NSUInteger)sid reason:(NSString *)reason evidence:(GFSpeechEvidence)ev
                                deadline:(NSTimeInterval)deadline {
    if (self.liveSessionId != sid || self.hasCompletedGeminiTurn || self.liveFailed) return; // late text / new press won
    NSUInteger chars = [self.latestOnDeviceTranscript stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length;
    BOOL onDeviceDone = self.onDeviceReportedNoSpeech || chars > 0 || self.latestOnDeviceIsFinal || !self.recognitionTask;
    if (!onDeviceDone && [NSDate timeIntervalSinceReferenceDate] < deadline) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf liveNoSpeechAwaitOnDeviceSession:sid reason:reason evidence:ev deadline:deadline];
        });
        return;
    }
    BOOL noLoud = GFNoLoudSpeech(ev.peakRMS, ev.evidenceSeconds);
    BOOL noSpeech = GFNoSpeechVerdict(YES, self.liveSegments.count, self.onDeviceReportedNoSpeech, chars, ev.loudSeconds, noLoud);
    GFLog(@"No-speech check: live_empty=1 ondevice_no_speech=%d ondevice_chars=%lu ondevice_done=%d loud=%.2fs (max RMS %.0f) "
          @"evidence=%.2fs above RMS %.0f (noise RMS %.0f) no_loud_speech=%d -> %@", self.onDeviceReportedNoSpeech,
          (unsigned long)chars, onDeviceDone, ev.loudSeconds, ev.peakRMS, ev.evidenceSeconds, ev.thresholdRMS, ev.noiseRMS, noLoud,
          noSpeech ? @"no speech, skipping REST" : @"speech possible, using REST");
    if (!noSpeech) { [self liveFailedWithReason:reason session:sid]; return; }
    self.hasCompletedGeminiTurn = YES;
    GFLog(@"Live: no speech in %.2fs after release (%@)", [NSDate timeIntervalSinceReferenceDate] - self.liveReleaseTime, reason);
    [self closeLiveWebSocket];
    if (self.recognitionTask && !self.isRecording) {
        [self.recognitionTask cancel];
        self.recognitionTask = nil;
    }
    [self showNoSpeechDetectedForDictation:self.activeDictation];
}

- (void)closeLiveWebSocket {
    if (self.e2eLiveSeenFields) { // setup probe (e2e only): the field names this session's server messages carried
        if (self.e2eLiveSeenFields.count > 0) GFLog(@"%@", GFLiveProbeFieldsLine(self.e2eLiveSeenFields));
        self.e2eLiveSeenFields = nil;
    }
    self.liveWebSocketConnected = NO;
    self.liveSocketReadyTime = 0;
    if (self.liveWebSocketTask) {
        [self.liveWebSocketTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
        self.liveWebSocketTask = nil;
    }
    if (self.liveSession) {
        [self.liveSession invalidateAndCancel];
        self.liveSession = nil;
    }
}

// The socket of session `sid` failed (receive or setup-send error). Reconnect mid-press when GFLiveShouldReconnect allows it
// (backlog 0h); otherwise fail exactly as before (REST at release / now if finalizing).
- (void)liveConnectionLost:(NSString *)reason session:(NSUInteger)sid task:(NSURLSessionWebSocketTask *)task {
    [self liveConnectionLost:reason session:sid task:task error:nil];
}

- (void)liveConnectionLost:(NSString *)reason session:(NSUInteger)sid task:(NSURLSessionWebSocketTask *)task error:(NSError *)error {
    if (self.liveSessionId != sid || self.liveFailed || self.hasCompletedGeminiTurn) return;
    BOOL ours = task != nil && task == self.liveWebSocketTask;
    if ([self liveSetupProbeExtra]) { // setup probe (e2e only): how the socket ended (a rejected setup closes it before setupComplete)
        NSInteger probeHTTP = [task.response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)task.response).statusCode : 0;
        NSString *probeReason = task.closeReason.length > 0 ? [[NSString alloc] initWithData:task.closeReason encoding:NSUTF8StringEncoding] : nil;
        GFLog(@"%@", GFLiveProbeCloseLine(self.liveWebSocketConnected, sid, self.liveAuthViaHeader, probeHTTP, task.closeCode, probeReason,
                                          error.domain, error.code));
    }
    if (self.liveAuthViaHeader && !self.liveWebSocketConnected) { // backlog 15: header auth rejected? retry once with the key in the URL
        NSInteger http = [task.response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)task.response).statusCode : 0;
        NSString *closeReason = task.closeReason.length > 0 ? [[NSString alloc] initWithData:task.closeReason encoding:NSUTF8StringEncoding] : nil;
        BOOL authLike = GFLiveFailureLooksLikeAuth(http, task.closeCode, closeReason, error.domain, error.code);
        if (GFLiveShouldRetryWithKeyInURL(YES, NO, self.liveAuthMode, self.isRecording, self.liveFinalizing, ours, authLike)) {
            GFLog(@"Live: header auth rejected before setupComplete (%@; HTTP %ld, close %ld %@); retrying once with the key in the URL",
                  reason, (long)http, (long)task.closeCode, closeReason ?: @"");
            self.liveNextConnectKeyInURL = YES;
            [self startGeminiLiveWebSocketResuming:self.liveEverConnected];
            return;
        }
    }
    double sessionAge = GFLiveSessionAgeSeconds([NSDate timeIntervalSinceReferenceDate], self.liveSocketReadyTime);
    if (GFLiveCloseIsPlannedRotation(self.isRecording, self.liveFinalizing, ours, sessionAge, self.liveGoAway,
                                     [self livePlannedCloseAgeSeconds])) {
        // Backlog 0p (b): the server ended an old session (its ~10-min lifetime): a planned rotation, not a drop. Same resume as a
        // reconnect (or the quiet one at a split point), at once and without using the reconnect budget.
        BOOL quiet = !self.liveActivityOpen && self.livePendingActivityEnds.count == 0;
        NSUInteger heldBack = self.liveSentBytes;
        self.liveRotations += 1;
        if (!self.unitTestMode) GFLog(@"Live: session closed at session age %.1fs while recording (%@); planned rotation #%lu, not counted "
              @"as a reconnect (%lu/%lu used); resuming from %.2fs covered (%@)", sessionAge, reason, (unsigned long)self.liveRotations,
              (unsigned long)self.liveReconnects, (unsigned long)kLiveMaxReconnects, self.liveCoveredBytes / 32000.0,
              quiet ? @"between activities" : @"activity open or turn pending");
        self.liveSessionId += 1; // late callbacks of the closed socket are now stale
        NSUInteger rotSid = self.liveSessionId;
        [self closeLiveWebSocket];
        GFDictation *rd = self.activeDictation;
        __weak typeof(self) weakRot = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakRot;
            if (!strongSelf || strongSelf.liveSessionId != rotSid || strongSelf.activeDictation != rd || !strongSelf.isRecording
                || strongSelf.liveFinalizing || strongSelf.hasCompletedGeminiTurn || strongSelf.liveWebSocketTask) return;
            [strongSelf startGeminiLiveWebSocketResuming:YES];
            [strongSelf liveApplyRotationResumeHeldBack:heldBack quiet:quiet];
        });
        return;
    }
    if (!GFLiveShouldReconnect(self.isRecording, self.liveFinalizing, ours, self.liveEverConnected, self.liveReconnects)) {
        if (ours && self.isRecording && !self.liveFinalizing && self.liveEverConnected && !self.unitTestMode)
            GFLog(@"Live: connection lost again; %lu reconnects already used this press", (unsigned long)self.liveReconnects);
        [self liveFailedWithReason:reason session:sid];
        return;
    }
    NSTimeInterval backoff = GFLiveReconnectBackoff(self.liveReconnects);
    self.liveReconnects += 1;
    if (!self.unitTestMode) GFLog(@"Live: connection lost at %.2fs sent while recording (%@); reconnect %lu/%lu in %.2fs, resuming from %.2fs covered",
          self.liveSentBytes / 32000.0, reason, (unsigned long)self.liveReconnects, (unsigned long)kLiveMaxReconnects, backoff,
          self.liveCoveredBytes / 32000.0);
    self.liveSessionId += 1; // late callbacks of the dead socket are now stale
    NSUInteger waitSid = self.liveSessionId;
    [self closeLiveWebSocket]; // until the new session is up, audio just accumulates; a release now takes REST (no session)
    GFDictation *d = self.activeDictation;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(backoff * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.liveSessionId != waitSid || strongSelf.activeDictation != d || !strongSelf.isRecording
            || strongSelf.liveFinalizing || strongSelf.hasCompletedGeminiTurn || strongSelf.liveWebSocketTask) return;
        [strongSelf startGeminiLiveWebSocketResuming:YES];
    });
}

- (void)liveFailedWithReason:(NSString *)reason session:(NSUInteger)sid {
    if (self.liveSessionId != sid || self.liveFailed || self.hasCompletedGeminiTurn) return;
    self.liveFailed = YES;
    if (!self.unitTestMode) GFLog(@"Live: failed (%@)", reason);
    [self closeLiveWebSocket];
    if (self.liveFinalizing) {
        self.hasCompletedGeminiTurn = YES;
        GFLog(@"Live: falling back to REST (%@) on the full recording", kDefaultModel);
        [self performGenerateContentFallbackForDictation:self.activeDictation];
    }
    // If still recording, finishWithGeminiProcessing will see liveFailed and use REST.
}

// Seconds of voiced audio in recordedPCMData from byte offset `from` (20 ms frames, adaptive energy threshold).
// Used to detect speech the Live server never transcribed (its VAD can miss some voices / fast speech).
- (double)voicedSecondsInRecordingFromByte:(NSUInteger)from {
    NSData *pcm = self.recordedPCMData;
    const NSUInteger frameBytes = 640; // 20 ms of 16 kHz 16-bit mono
    NSUInteger total = pcm.length / frameBytes;
    if (total == 0) return 0;
    const int16_t *samples = (const int16_t *)pcm.bytes;
    double *rms = malloc(sizeof(double) * total);
    if (!rms) return 0;
    for (NSUInteger f = 0; f < total; f++) {
        double acc = 0;
        for (NSUInteger i = 0; i < frameBytes / 2; i++) { double v = samples[f * (frameBytes / 2) + i]; acc += v * v; }
        rms[f] = sqrt(acc / (frameBytes / 2));
    }
    // Noise floor = 20th percentile frame energy over the whole recording
    double *sorted = malloc(sizeof(double) * total);
    if (!sorted) { free(rms); return 0; }
    memcpy(sorted, rms, sizeof(double) * total);
    qsort_b(sorted, total, sizeof(double), ^int(const void *a, const void *b) {
        double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : (x > y ? 1 : 0);
    });
    double threshold = MAX(150.0, 3.0 * sorted[total / 5]);
    free(sorted);
    NSUInteger voiced = 0;
    for (NSUInteger f = from / frameBytes; f < total; f++) if (rms[f] > threshold) voiced++;
    free(rms);
    return voiced * 0.02;
}

- (void)finishLiveTranscriptWithReason:(NSString *)reason {
    if (self.hasCompletedGeminiTurn) return;
    self.hasCompletedGeminiTurn = YES;
    NSString *joined = [[self.liveSegments componentsJoinedByString:@" "] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    GFLog(@"Live: done in %.2fs after release (%@, %lu segments, %lu chars)",
          [NSDate timeIntervalSinceReferenceDate] - self.liveReleaseTime, reason, (unsigned long)self.liveSegments.count, (unsigned long)joined.length);
    if ([self liveSetupProbeExtra]) { // setup probe (e2e only): the server's text before the app's polish. Synthetic test clips;
        printf("E2E LIVE RAW: \"%s\"\n", GFLiveProbeClean(joined, 100000).UTF8String); // one line, stdout only (like E2E RESULT): never the log file
        fflush(stdout);
    }
    [self closeLiveWebSocket];
    if (joined.length > 0) {
        if (self.recognitionTask && !self.isRecording) {
            [self.recognitionTask cancel];
            self.recognitionTask = nil;
        }
        [self applyFinalTranscript:[self polishOnDeviceTranscript:joined] dictation:self.activeDictation];
    } else {
        GFLog(@"Live: no text; falling back to REST.");
        [self performGenerateContentFallbackForDictation:self.activeDictation];
    }
}

- (void)finishWithGeminiProcessing {
    NSString *selectedModel = [self currentGeminiModel];
    if (![self isLiveWebSocketModel:selectedModel] || !self.liveWebSocketTask || self.liveFailed) {
        if (self.liveFailed) GFLog(@"Live had failed during recording; using REST.");
        else if ((self.liveReconnects > 0 || self.liveRotations > 0) && [self isLiveWebSocketModel:selectedModel]) GFLog(@"Live: released while reconnecting (no session); using REST.");
        [self closeLiveWebSocket];
        [self performGenerateContentFallbackForDictation:self.activeDictation];
        return;
    }

    self.liveFinalizing = YES;
    self.liveReleaseTime = [NSDate timeIntervalSinceReferenceDate];
    NSUInteger sid = self.liveSessionId;
    __weak typeof(self) weakSelf = self;

    // Let PCM chunks already queued on the main queue land before sending the tail + end-of-stream
    dispatch_async(dispatch_get_main_queue(), ^{
        if (weakSelf.liveSessionId != sid || weakSelf.hasCompletedGeminiTurn) return;
        if (weakSelf.liveWebSocketConnected) [weakSelf sendLiveAudioStreamEnd];
        // (if not connected yet, setupComplete will flush everything and send end-of-stream)
    });

    // If no speech is pending, the last utterance is already transcribed: finish after a short grace
    // period so a word spoken right before release can still be flagged (server VAD lag measured ~0.1 s).
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakSelf.liveSessionId != sid || weakSelf.hasCompletedGeminiTurn) return;
        if (weakSelf.liveSpeechActive || !weakSelf.liveWebSocketConnected) return;
        // Never finish with less than was said: if there is voiced audio the server never covered with an
        // utterance (its VAD missed it), Live's text is incomplete. Re-run the full recording through REST now
        // instead of dropping words (or waiting for the 2.5 s cap when Live heard nothing at all).
        double uncovered = [weakSelf voicedSecondsInRecordingFromByte:weakSelf.liveCoveredBytes];
        if (uncovered > kLiveUncoveredSpeechLimit) {
            [weakSelf liveFailedWithReason:[NSString stringWithFormat:@"%.2fs of speech after %.2fs not transcribed by Live",
                                            uncovered, weakSelf.liveCoveredBytes / 32000.0] session:sid];
        } else if (weakSelf.liveSegments.count > 0) {
            [weakSelf finishLiveTranscriptWithReason:@"no pending speech"];
        }
    });
    // Hard cap: if the stream hasn't delivered by now, re-run the full recording through REST
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakSelf.liveSessionId != sid || weakSelf.hasCompletedGeminiTurn) return;
        [weakSelf liveFailedWithReason:@"no final transcript within 2.5 s of release" session:sid];
    });
}

#pragma mark - GenerateContent Fallback Engine (Zero Lost Audio)

- (NSData *)createWavDataFromPCM:(NSData *)pcmData {
    uint32_t sampleRate = 16000;
    uint16_t numChannels = 1;
    uint16_t bitsPerSample = 16;
    uint32_t byteRate = sampleRate * numChannels * (bitsPerSample / 8);
    uint16_t blockAlign = numChannels * (bitsPerSample / 8);
    uint32_t dataSize = (uint32_t)pcmData.length;
    uint32_t chunkSize = 36 + dataSize;

    NSMutableData *wav = [NSMutableData dataWithCapacity:44 + dataSize];
    [wav appendBytes:"RIFF" length:4];
    [wav appendBytes:&chunkSize length:4];
    [wav appendBytes:"WAVE" length:4];
    [wav appendBytes:"fmt " length:4];

    uint32_t subchunk1Size = 16;
    uint16_t audioFormat = 1; // PCM
    [wav appendBytes:&subchunk1Size length:4];
    [wav appendBytes:&audioFormat length:2];
    [wav appendBytes:&numChannels length:2];
    [wav appendBytes:&sampleRate length:4];
    [wav appendBytes:&byteRate length:4];
    [wav appendBytes:&blockAlign length:2];
    [wav appendBytes:&bitsPerSample length:2];

    [wav appendBytes:"data" length:4];
    [wav appendBytes:&dataSize length:4];
    [wav appendData:pcmData];

    return wav;
}

- (NSString *)currentGeminiModel {
    if (self.e2eGeminiModel.length > 0) return self.e2eGeminiModel; // test hook (--e2e-file <wav> <model>)
    return kDefaultLiveModel;
}

// e2e test runs choose their engine explicitly and never touch the saved preference
- (NSString *)effectiveEngineMode {
    if (self.e2eMode.length > 0) return self.e2eGeminiModel.length > 0 ? @"gemini" : @"ondevice";
    return [[NSUserDefaults standardUserDefaults] stringForKey:kPrefEngineMode];
}

// Bounded wait (user-approved 2026-11-10): once REST starts for the current press, deliver its on-device text if REST hasn't
// answered ~3 s after release (at least kEarlyPasteMinRestTime into the call). Not for superseded presses (cycle-10 rules apply).
- (void)armEarlyPasteForDictation:(GFDictation *)d {
    if (!d || d.superseded || d.earlyText || self.resultSink || self.unitTestMode || d.releaseTime <= 0) return;
    NSTimeInterval delay = GFEarlyPasteDelay([NSDate timeIntervalSinceReferenceDate] - d.releaseTime);
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf earlyPasteIfStillWaitingForDictation:d];
    });
}

- (void)earlyPasteIfStillWaitingForDictation:(GFDictation *)d {
    if (d.finished || d.earlyText) return; // REST (or a fallback) already delivered
    NSString *od = [self.latestOnDeviceTranscript ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSData *pcm = [self pcmForDictation:d];
    double loud = GFSecondsAboveRMS((const int16_t *)pcm.bytes, pcm.length / 2, kNoSpeechFrameRMS, NULL);
    BOOL newer = d.superseded || self.isRecording || self.activeDictation != d;
    NSString *polished = GFEarlyPasteAllowed(od.length, self.onDeviceReportedNoSpeech, loud, newer, self.isFinalizingOnDevice)
                         ? [self polishOnDeviceTranscript:od] : @"";
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if ([polished stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].length == 0) {
        GFLog(@"Early paste: not used for dictation #%lu (on-device %lu chars, no-speech %d, loud %.2fs, newer press %d)",
              (unsigned long)d.serial, (unsigned long)od.length, self.onDeviceReportedNoSpeech, loud, newer);
        return;
    }
    GFLog(@"Early paste: REST has not answered %.2fs after release; delivering the on-device text now (dictation #%lu, %lu chars)",
          now - d.releaseTime, (unsigned long)d.serial, (unsigned long)polished.length);
    if (self.e2eCompletion) { // e2e: nothing is pasted; report this delivery, the final result follows
        d.earlyText = polished;
        printf("E2E EARLY DELIVERY: \"%s\"\n", polished.UTF8String);
        printf("E2E early delivery latency: %.0f ms\n", (now - self.e2eReleaseTime) * 1000.0);
        fflush(stdout);
        return;
    }
    [self startEarlyPasteWatch:d];
    [self applyFinalTranscript:polished dictation:d];
    d.earlyText = polished; // after delivery: later results for d go to resolveEarlyPastedDictation
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kLateSwapWindow + 1.0) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakSelf.earlyWatchDictation == d) [weakSelf stopEarlyPasteWatch];
    });
}

// The REST outcome for a dictation whose on-device text was already delivered early. text = Gemini's polished text, or nil when
// REST failed / returned nothing (the delivered text then stays). Swaps only when every safety condition holds and the pasted
// text is verified in place; otherwise the Gemini text goes to the clipboard and Recent Dictations without pasting.
- (void)resolveEarlyPastedDictation:(GFDictation *)d geminiText:(NSString *)text {
    if (d.earlyResolved) return;
    d.earlyResolved = YES;
    BOOL watched = self.earlyWatchDictation == d && self.globalKeyMonitor && self.earlyMouseMonitor;
    if (self.earlyWatchDictation == d) [self stopEarlyPasteWatch];
    BOOL hasText = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length > 0;
    if (self.e2eCompletion) {
        GFLog(@"Early paste: e2e final result = %@", hasText ? @"the Gemini text" : @"the on-device text already delivered");
        void (^done)(NSString *) = self.e2eCompletion;
        self.e2eCompletion = nil;
        done(hasText ? text : d.earlyText);
        return;
    }
    if (!hasText) {
        if (!self.unitTestMode) GFLog(@"Early paste: no Gemini text for dictation #%lu; the delivered on-device text stays", (unsigned long)d.serial);
        return;
    }
    NSTimeInterval since = d.earlyPasteTime > 0 ? [NSDate timeIntervalSinceReferenceDate] - d.earlyPasteTime : -1;
    id elem = self.unitTestMode ? nil : GFCopyFocusedElement();
    pid_t pid = self.unitTestMode ? 0 : [NSWorkspace sharedWorkspace].frontmostApplication.processIdentifier;
    BOOL sameApp = d.earlyPid > 0 && pid == d.earlyPid;
    BOOL sameField = d.earlyElement && elem && CFEqual((__bridge CFTypeRef)d.earlyElement, (__bridge CFTypeRef)elem);
    BOOL newer = d.superseded || self.isRecording || self.activeDictation != d;
    BOOL busy = self.pasteInFlight || self.pasteQueue.count > 0 || _deferredPastes.count > 0;
    GFLateSwap s = GFLateSwapDecision(d.earlyText, text, since, d.earlyUserInput || !watched, sameApp, sameField, newer, busy);
    if (s == GFLateSwapReplace && !GFAXSelectPastedText(elem, d.earlyText)) s = GFLateKeepUnverified;
    if (!self.unitTestMode) {
        GFLog(@"Early paste: Gemini text for dictation #%lu, %.2fs after the on-device paste (%lu -> %lu chars; same app %d, "
              @"same field %d, input %d, newer press %d, busy %d) -> %s", (unsigned long)d.serial, since,
              (unsigned long)d.earlyText.length, (unsigned long)text.length, sameApp, sameField, d.earlyUserInput || !watched,
              newer, busy, GFLateSwapName(s));
    }
    if (s == GFLateKeepIdentical) return;
    if (s == GFLateSwapReplace) {
        NSUInteger i = [self.recentDictations indexOfObjectIdenticalTo:d.earlyText];
        if (i != NSNotFound) [self.recentDictations replaceObjectAtIndex:i withObject:text];
        else [self.recentDictations insertObject:text atIndex:0];
        [self updateRecentSubmenu];
        [self enqueuePaste:text]; // the early paste is selected: Cmd+V replaces exactly it
        return;
    }
    [self.recentDictations insertObject:text atIndex:0];
    if (self.recentDictations.count > 5) [self.recentDictations removeLastObject];
    [self updateRecentSubmenu];
    if (!self.pasteInFlight) [self setClipboardText:text];
}

// Backlog 0u (4) + prompt-echo fix (2026-11-12): reject REST prompt echoes when Live was empty and on-device didn't hear
// "transcribe", and check timestamp/char-budget plausibility whenever on-device heard nothing OR the audio had no loud speech
// with at most a tiny on-device noise blip (<= 4 chars). Main thread. Logs numbers only, never text.
- (BOOL)restOutputPlausible:(NSString *)text dictation:(GFDictation *)d {
    NSUInteger segs, odChars;
    BOOL odNoSpeech;
    NSString *odText;
    if (d.superseded) {
        segs = d.liveHadTextAtSupersede ? 1 : 0;
        odNoSpeech = d.onDeviceNoSpeechAtSupersede;
        odText = [d.onDeviceText ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    } else {
        segs = self.liveSegments.count;
        odNoSpeech = self.onDeviceReportedNoSpeech;
        odText = [self.latestOnDeviceTranscript ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    odChars = odText.length;
    if (GFRestEchoRejected(text, segs, odText)) {
        if (!self.unitTestMode) {
            GFLog(@"REST plausibility (dictation #%lu): Live no text, ondevice_chars=%lu; %lu chars -> %s",
                  (unsigned long)d.serial, (unsigned long)odChars, (unsigned long)text.length,
                  GFRestPlausibilityName(GFRestImplausiblePromptEcho));
        }
        return NO;
    }
    if (segs > 0) return YES;
    NSData *pcm = [self pcmForDictation:d];
    GFSpeechEvidence ev = GFMeasureSpeechEvidence((const int16_t *)pcm.bytes, pcm.length / 2);
    BOOL noLoud = GFNoLoudSpeech(ev.peakRMS, ev.evidenceSeconds);
    if (!GFRestShouldCheckPlausibility(segs, odNoSpeech, odChars, noLoud)) return YES;
    NSUInteger budget = GFRestCharBudget(noLoud, ev.evidenceSeconds, ev.loudSeconds);
    GFRestPlausibility verdict = GFRestOutputPlausibility(text, budget);
    if (!self.unitTestMode) {
        GFLog(@"REST plausibility (dictation #%lu): Live no text, ondevice_no_speech=%d, ondevice_chars=%lu; %lu chars vs limit %lu "
              @"(max RMS %.0f, evidence %.2fs, loud %.2fs, no_loud_speech=%d, %.2fs audio) -> %s", (unsigned long)d.serial,
              odNoSpeech, (unsigned long)odChars, (unsigned long)text.length, (unsigned long)budget, ev.peakRMS, ev.evidenceSeconds,
              ev.loudSeconds, noLoud, pcm.length / 32000.0, GFRestPlausibilityName(verdict));
    }
    return verdict == GFRestPlausible;
}

- (void)performGenerateContentFallbackForDictation:(GFDictation *)dictation {
    NSString *apiKey = [[NSUserDefaults standardUserDefaults] stringForKey:kPrefApiKey];
    NSString *selectedModel = [self currentGeminiModel];
    if ([self isLiveWebSocketModel:selectedModel]) selectedModel = kDefaultModel; // live models are streaming-only

    // Hop through the main queue once so PCM chunks the tap already queued are appended before we build the WAV.
    // Apple's recognizer keeps running in the background as the fallback if Gemini fails or is slow.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf executeGenerateContentWithModel:selectedModel apiKey:apiKey dictation:dictation];
    });
}

- (void)executeGenerateContentWithModel:(NSString *)model apiKey:(NSString *)apiKey dictation:(GFDictation *)dictation {
    // Always send the audio: Gemini transcribes far better than Apple (accents, background noise),
    // and cleaning up Apple's text can't fix words Apple misheard. Very short clips stay on-device.
    // The dictation's own recording: if a new press started meanwhile, that is its snapshot, not the new press's buffer.
    NSData *pcm = [self pcmForDictation:dictation];
    if (pcm.length < 9600) { // < 0.3 s of 16 kHz 16-bit audio
        GFLog(@"Gemini: clip too short (%.2fs); using on-device transcript.", pcm.length / 32000.0);
        [self finishWithOnDeviceTranscriptForDictation:dictation];
        return;
    }
    if (dictation.superseded) GFLog(@"Dictation #%lu: REST on its own recording (%.2fs; a newer press is active)", (unsigned long)dictation.serial, pcm.length / 32000.0);
    [self armEarlyPasteForDictation:dictation];
    NSData *wavData = [self createWavDataFromPCM:pcm];
    NSString *b64Audio = [wavData base64EncodedStringWithOptions:0];
    [self callGeminiWithModel:model b64Audio:b64Audio apiKey:apiKey retryIndex:0 startTime:[NSDate timeIntervalSinceReferenceDate]
                    dictation:dictation];
}

- (void)callGeminiWithModel:(NSString *)model
                   b64Audio:(NSString *)b64Audio
                     apiKey:(NSString *)apiKey
                 retryIndex:(NSUInteger)retryIndex
                  startTime:(NSTimeInterval)startTime
                  dictation:(GFDictation *)dictation {
    NSMutableURLRequest *request = GFGeminiRequest(GFGenerateContentURL(model), apiKey); // key in the header, never the URL
    // WAV = 44-byte header + 16 kHz 16-bit mono PCM; base64 is 4/3 the size.
    double audioSeconds = MAX(0.0, (b64Audio.length * 3.0 / 4.0 - 44.0) / 32000.0);
    request.timeoutInterval = retryIndex == 0 ? GFRestTimeoutForAudioSeconds(audioSeconds)
                                              : GFRestRetryTimeout(audioSeconds, [NSDate timeIntervalSinceReferenceDate] - startTime);
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSDictionary *audioPart = @{@"inlineData": @{@"mimeType": @"audio/wav", @"data": b64Audio}};
    NSDictionary *body;
    if ([model containsString:@"transcribe"]) {
        // Dedicated speech model: rejects systemInstruction ("Developer instruction is not enabled") and
        // returns its text in parts[].audioTranscription.text. Local polish removes fillers afterwards.
        body = @{@"contents": @[@{@"parts": @[audioPart]}],
                 @"generationConfig": @{@"temperature": @(0.0), @"maxOutputTokens": @(kRestMaxOutputTokens)}};
    } else {
        NSString *systemPrompt = @"You are a voice dictation and transcription engine. Output ONLY the clean, punctuated transcript of what the user dictated. Remove filler words (um, uh, like, you know) while preserving legitimate words and comparisons. Fix punctuation, capitalization, and resolve spoken self-corrections (for example, 'meet at 2 wait no 3pm' becomes 'meet at 3:00 PM'). Do not add line breaks, greetings formatting, or anything the user did not say. If the audio contains only silence or background noise with no intelligible speech, output an empty string (never repeat instructions). Output only the final text with no commentary or quotes.";
        NSMutableDictionary *genConfig = [@{@"temperature": @(0.0), @"maxOutputTokens": @(kRestMaxOutputTokens)} mutableCopy];
        if ([model containsString:@"3.8"]) {
            genConfig[@"thinkingConfig"] = @{@"thinkingLevel": @"LOW"};
        } else if (![model containsString:@"lite"] || [model containsString:@"3.1"]) {
            genConfig[@"thinkingConfig"] = @{@"thinkingBudget": @(0)}; // no reasoning overhead for dictation
        }
        body = @{@"systemInstruction": @{@"parts": @[@{@"text": systemPrompt}]},
                 @"contents": @[@{@"parts": @[audioPart, @{@"text": @"Transcribe and clean up this audio dictation."}]}],
                 @"generationConfig": genConfig};
    }
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    __weak typeof(self) weakSelf = self;
    void (^completion)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
        double elapsed = [NSDate timeIntervalSinceReferenceDate] - startTime;

        if (httpResp.statusCode != 200 || error || !data) {
            BOOL timedOut = (error.code == NSURLErrorTimedOut);
            GFLog(@"Gemini %@ failed after %.2fs (%.1fs audio, timeout %.0fs): HTTP %ld %@", model, elapsed, audioSeconds,
                  request.timeoutInterval, (long)httpResp.statusCode,
                  error ? error.localizedDescription : [[NSString alloc] initWithData:data ?: [NSData data] encoding:NSUTF8StringEncoding]);
            // One retry on the default model for a FAST transient server/quota error, or a slow explicit 429/503 that still fits
            // budget + 4 s (see GFRestShouldRetry), never after a timeout (that would double the wait). Same model: short backoff
            // first. Otherwise fall back to on-device.
            if (GFRestShouldRetry(httpResp.statusCode, timedOut, retryIndex, elapsed, audioSeconds)) {
                NSTimeInterval backoff = [model isEqualToString:kDefaultModel] ? kRestRetryBackoff : 0.0;
                GFLog(@"Gemini: transient HTTP %ld after %.2fs; retrying %@ in %.1fs%@", (long)httpResp.statusCode, elapsed,
                      kDefaultModel, backoff,
                      elapsed > 0.25 * GFRestTimeoutForAudioSeconds(audioSeconds) ? @" (slow failure, retry fits the deadline)" : @"");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(backoff * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [weakSelf callGeminiWithModel:kDefaultModel b64Audio:b64Audio apiKey:apiKey retryIndex:1 startTime:startTime
                                        dictation:dictation];
                });
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                GFLog(@"Falling back to on-device transcript.");
                [weakSelf finishWithOnDeviceTranscriptForDictation:dictation];
            });
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSMutableString *extractedText = [NSMutableString string];
        NSString *finishReason = @"?";
        @try {
            NSArray *candidates = json[@"candidates"];
            if (candidates.count > 0) {
                id fr = candidates[0][@"finishReason"]; // enum string (STOP, MAX_TOKENS, ...): safe to log, never the text
                if ([fr isKindOfClass:[NSString class]]) finishReason = fr;
                NSArray *parts = candidates[0][@"content"][@"parts"];
                for (NSDictionary *p in parts) {
                    if ([p[@"thought"] boolValue]) continue;
                    NSString *t = p[@"text"];
                    if (!t) t = p[@"audioTranscription"][@"text"]; // gemini-3.5-transcribe
                    if (t) [extractedText appendString:t];
                }
            }
        } @catch (NSException *e) {
            GFLog(@"Exception parsing Gemini response: %@", e);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *cleaned = [extractedText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            GFLog(@"Gemini %@ ok in %.2fs (%lu chars, %.1fs audio, finishReason %@)", model, elapsed,
                  (unsigned long)cleaned.length, audioSeconds, finishReason);
            if ([finishReason isEqualToString:@"MAX_TOKENS"]) {
                GFLog(@"Gemini %@: output hit maxOutputTokens (%ld); transcript may be truncated.", model, (long)kRestMaxOutputTokens);
            }
            if (cleaned.length > 0) {
                // Gemini supersedes the on-device stream for this dictation (a superseded dictation's recognizer is already
                // gone; the current one belongs to the newer press and must keep running)
                if (!dictation.superseded && !weakSelf.isRecording && weakSelf.recognitionTask) {
                    [weakSelf.recognitionTask cancel];
                    weakSelf.recognitionTask = nil;
                }
                if (![weakSelf restOutputPlausible:cleaned dictation:dictation]) {
                    [weakSelf showNoSpeechDetectedForDictation:dictation];
                    return;
                }
                [weakSelf applyFinalTranscript:[weakSelf polishOnDeviceTranscript:cleaned] dictation:dictation];
            } else {
                if (!dictation.earlyText && [weakSelf restOutputPlausible:@"." dictation:dictation]) {
                    // Note: empty REST output on no-loud-speech audio with <= 4 on-device noise chars shouldn't paste a stray noise syllable.
                    NSData *epcm = [weakSelf pcmForDictation:dictation];
                    GFSpeechEvidence eev = GFMeasureSpeechEvidence((const int16_t *)epcm.bytes, epcm.length / 2);
                    NSUInteger segs = dictation.superseded ? (dictation.liveHadTextAtSupersede ? 1 : 0) : weakSelf.liveSegments.count;
                    NSString *odt = dictation.superseded ? dictation.onDeviceText : weakSelf.latestOnDeviceTranscript;
                    NSUInteger odc = [odt ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length;
                    if (segs == 0 && GFNoLoudSpeech(eev.peakRMS, eev.evidenceSeconds) && odc <= kRestPlausibilityMaxNoiseOnDeviceChars) {
                        [weakSelf showNoSpeechDetectedForDictation:dictation];
                        return;
                    }
                }
                [weakSelf finishWithOnDeviceTranscriptForDictation:dictation];
            }
        });
    };
    if (retryIndex == 0 && self.e2eMode.length > 0 && self.e2eSecondPressFile.length > 0 && !self.e2eSecondPressStarted
        && dictation.serial == 1 && [@[@"rest", @"restfail"] containsObject:self.e2eSecondPressPhase ?: @""]) {
        // Test-only (--e2e-second-press <wav> rest|restfail; e2e mode only): start the second press now and hold this REST call
        // back 1 s, so it is still in flight (rest) or fails as if offline (restfail) after the new press started.
        BOOL fail = [self.e2eSecondPressPhase isEqualToString:@"restfail"];
        GFLog(@"E2E: holding press #1's REST call 1.0 s; second press starts now%@", fail ? @" (the call will fail: offline)" : @"");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf e2eStartSecondPress];
        });
        NSURLRequest *held = [request copy];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            if (fail) completion(nil, nil, [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil]);
            else [[[NSURLSession sharedSession] dataTaskWithRequest:held completionHandler:completion] resume];
        });
        return;
    }
    if (retryIndex == 0 && self.e2eMode.length > 0 && self.e2eRestFakeOkDelay > 0.0) {
        // Test-only (--e2e-rest-fake-ok <s>; never set outside e2e mode): the first REST call answers HTTP 200 with a canned
        // transcript after <s> seconds without touching the network, so a slow-but-successful REST can be tested offline.
        double fakeDelay = MIN(self.e2eRestFakeOkDelay, 30.0);
        GFLog(@"E2E: answering the first REST call with a canned transcript after %.2fs (no network)", fakeDelay);
        NSString *fakeText = self.e2eRestFakeText ?: kGFE2ECannedRestText;
        NSDictionary *fakeBody = @{@"candidates": @[@{@"finishReason": @"STOP", @"content": @{@"parts": @[@{@"text": fakeText}]}}]};
        NSData *fakeData = [NSJSONSerialization dataWithJSONObject:fakeBody options:0 error:nil];
        NSHTTPURLResponse *ok = [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://generativelanguage.googleapis.com/"]
                                                            statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(fakeDelay * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ completion(fakeData, ok, nil); });
        return;
    }
    if (retryIndex == 0 && self.e2eMode.length > 0 && self.e2eRestDelay > 0.0) {
        // Test-only (--e2e-rest-delay <s>; never set outside e2e mode): hold the first real REST call <s> seconds (slow REST).
        double hold = MIN(self.e2eRestDelay, 30.0);
        GFLog(@"E2E: holding the first REST call %.2fs (slow REST)", hold);
        NSURLRequest *heldReq = [request copy];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(hold * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [[[NSURLSession sharedSession] dataTaskWithRequest:heldReq completionHandler:completion] resume];
        });
        return;
    }
    if (retryIndex == 0 && self.e2eMode.length > 0 && self.e2eRestFaultOnce) {
        // Test-only fault injection (--e2e-file <wav> <model> --e2e-rest-503-once; never set outside e2e mode): the first REST
        // attempt "fails" with a fast HTTP 503 without touching the network, so the retry path can be tested unattended.
        // --e2e-rest-503-delay <s> makes the injected 503 arrive after that many seconds (a slow "high demand" answer).
        self.e2eRestFaultOnce = NO;
        double faultDelay = self.e2eRestFaultDelay > 0.0 ? MIN(self.e2eRestFaultDelay, 30.0) : 0.15;
        GFLog(@"E2E: injecting HTTP 503 on the first REST attempt (after %.2fs)", faultDelay);
        NSHTTPURLResponse *fake = [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://generativelanguage.googleapis.com/"]
                                                              statusCode:503 HTTPVersion:@"HTTP/1.1" headerFields:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(faultDelay * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            completion(nil, fake, nil);
        });
        return;
    }
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:completion] resume];
}

#pragma mark - On-Device Text Polish & Finalization

static void replaceRegex(NSMutableString *str, NSString *pattern, NSString *templ, NSRegularExpressionOptions opts) {
    NSError *err = nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:opts error:&err];
    if (re && !err) {
        [re replaceMatchesInString:str options:0 range:NSMakeRange(0, str.length) withTemplate:templ];
    }
}

// Spoken "new line" / "new paragraph" commands (backlog 4). A plain substring replace used to fire inside other words
// ("the new lineup" -> "the\nup"), and the whitespace cleanup later flattened the inserted breaks back into spaces.
// Now: whole words only (\b), case-insensitive; punctuation the model writes right after the command ("New line.") is part
// of it, punctuation before it ("Hi Sam, new line") is kept. Not a command after a determiner ("a new line of products",
// "the new paragraph") or right before "of". Each command becomes a private-use mark that no cleanup regex treats as
// whitespace; GFExpandSpokenLineBreaks turns the marks into "\n" / "\n\n" (no spaces around them) once cleanup is done.
#define kGFLineBreakMark @"\uE000"
#define kGFParagraphBreakMark @"\uE001"
static void GFMarkSpokenLineBreaks(NSMutableString *str) {
    static NSRegularExpression *cmdRe, *prevWordRe, *nextOfRe;
    static NSSet<NSString *> *determiners;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cmdRe = [NSRegularExpression regularExpressionWithPattern:@"[ \\t]*\\bnew[ \\t]+(line|paragraph)\\b[ \\t]*[.,;:!?]*[ \\t]*"
                                                          options:NSRegularExpressionCaseInsensitive error:nil];
        prevWordRe = [NSRegularExpression regularExpressionWithPattern:@"([A-Za-z]+)\\s*$" options:0 error:nil];
        nextOfRe = [NSRegularExpression regularExpressionWithPattern:@"^[ \\t]+of\\b" options:NSRegularExpressionCaseInsensitive error:nil];
        determiners = [NSSet setWithArray:@[@"a", @"an", @"the", @"this", @"that", @"these", @"those", @"my", @"your", @"our",
                                            @"their", @"his", @"her", @"its", @"another", @"every", @"each", @"any",
                                            @"some", @"no", @"whole", @"entire", @"brand"]];
    });
    // a mark already in the text (never expected) must not turn into a line break
    [str replaceOccurrencesOfString:kGFLineBreakMark withString:@"" options:0 range:NSMakeRange(0, str.length)];
    [str replaceOccurrencesOfString:kGFParagraphBreakMark withString:@"" options:0 range:NSMakeRange(0, str.length)];
    NSArray<NSTextCheckingResult *> *matches = [cmdRe matchesInString:str options:0 range:NSMakeRange(0, str.length)];
    for (NSTextCheckingResult *m in [matches reverseObjectEnumerator]) {
        NSRange r = m.range;
        NSUInteger from = r.location > 40 ? r.location - 40 : 0;
        NSString *before = [str substringWithRange:NSMakeRange(from, r.location - from)];
        NSTextCheckingResult *pw = [prevWordRe firstMatchInString:before options:0 range:NSMakeRange(0, before.length)];
        if (pw && [determiners containsObject:[[before substringWithRange:[pw rangeAtIndex:1]] lowercaseString]]) continue;
        NSUInteger end = NSMaxRange([m rangeAtIndex:1]); // right after "line"/"paragraph": "new line of code" is prose
        NSString *after = [str substringWithRange:NSMakeRange(end, MIN((NSUInteger)8, str.length - end))];
        if ([nextOfRe firstMatchInString:after options:0 range:NSMakeRange(0, after.length)]) continue;
        BOOL para = [[str substringWithRange:[m rangeAtIndex:1]] caseInsensitiveCompare:@"paragraph"] == NSOrderedSame;
        [str replaceCharactersInRange:r withString:para ? kGFParagraphBreakMark : kGFLineBreakMark];
    }
}

static void GFExpandSpokenLineBreaks(NSMutableString *str) {
    replaceRegex(str, @"[ \\t]*\\uE000[ \\t]*", @"\n", 0);
    replaceRegex(str, @"[ \\t]*\\uE001[ \\t]*", @"\n\n", 0);
}

// Phrase stutters and mid-thought restarts (backlog 0x, user request 2026-11-12). The single-word pass below only sees
// "the the". People also pause mid-thought and say a few words again, and Gemini Live writes the second attempt as it hears
// it, sometimes with a capital letter or a comma: "happy with my with my new app", "when I When I, for example".
// A word here is ASCII letters with apostrophes inside (straight or curly), compared without case. Words join into a phrase
// only across plain spaces, and a repeat may sit across ONE comma. Any other character between two words (. ? ! ; : - digits,
// quotes, line-break marks, non-ASCII letters) ends the phrase, so nothing is ever collapsed across a sentence end.
//
// Rule A, copies back to back: a phrase of 2-8 words said two or more times in a row keeps its first copy ("with my with my
// new" -> "with my new"). A lone contraction counts too ("it's it's broken"); the single-word pass can't see those.
// Kept as dictated (when unsure, the words stay):
//  - one word over and over ("no no no no": the single-word pass and its keep-list own that), number and spoken-symbol words,
//    spelled letters ("one two one two", "dot slash dot slash", "U S A U S A");
//  - courtesy, exclamation and rhythm phrases from the list ("thank you thank you", "oh my god, oh my god", "tick tock");
//  - names: every word capitalized in every copy, "I" not counting, two such words or more ("New York New York");
//  - idioms built on a connective: "X and X and" / "X or X or" ("again and again and I", "he ran and ran and fell"),
//    "X to/on/in/for/by/after/upon/over X" for the idiom nouns ("from time to time to refresh", "one on one on Monday"),
//    any chain a neighbour word continues ("day after day after day", "again, and again and again", "lists of lists of
//    lists"), and "of X of X" unless X is a determiner or the like ("a hash of hashes of hashes"; "of the of the" collapses);
//  - "a/an/the X of|to" twice ("a friend of a friend of mine", "a pointer to a pointer to"), except quantity nouns ("a lot of");
//  - 3+ words ending in and/or ("it rained and it rained and it rained"); 3+ words STARTING with and/or collapse only when
//    visibly unfinished, see below ("and then I and then I went" does, "and it rained and it rained" doesn't);
//  - a repeat right after what / if / when / everything ... ("what I have I have earned", "if we lose we lose"), and a
//    determiner phrase right after a give/show/tell verb ("show the user the user settings");
//  - with a COMMA between the copies the repeat reads as emphasis ("I know, I know", "it's fine, it's fine") and is kept,
//    unless the phrase is visibly unfinished: it ends in a word that can't end a thought ("with my, with my new app",
//    "when I, when I", "I want to, I want to go", "it's, it's"), or it ends in a helper verb, a think/want/need verb or a
//    this/some/not kind of word AND the sentence runs straight on after the last copy ("I would, I would repeat it" collapses,
//    "I do, I do." stays).
//
// Rule B, a restart that drops one aborted word: P + word + P with P of 3-8 words keeps one P ("I also want you to give some
// I also want you to give periodic updates"). Only when the dropped word can't stand on its own: a/an/the/my/your/our/their/
// its/every (a comma may follow it), or some/any/each/another with no comma at all. Any other middle word is content or a
// connective and everything stays ("it is too big it is too slow", "we have to do what we have to do", "compare what we
// have to what we have now").
#define kGFStutterMaxPhrase 8
typedef struct {
    NSUInteger start, end;
    uint8_t sep; // what separates the word from the one before it: 1 = spaces, 2 = spaces and one comma, 0 = anything else
    BOOL cap;    // written with a capital first letter
} GFStutterToken;

static NSSet<NSString *> *GFStutterWordSet(NSString *list) {
    return [NSSet setWithArray:[list componentsSeparatedByString:@" "]];
}

// Makes ONE collapse (the leftmost; the longest phrase first) and returns YES, or returns NO when there is nothing to collapse.
static BOOL GFCollapsePhraseRepeatOnce(NSMutableString *str) {
    static NSSet<NSString *> *spokenSymbols, *keepPhrases, *chainWords, *idiomChainWords, *idiomNouns, *quantityNouns, *ofFollowers,
                             *tautologyHeads, *determiners, *giveVerbs, *sContractions, *unfinishedEnd, *unfinishedIfContinues,
                             *helperVerbs, *beforeYou, *abortedStrong, *abortedBare;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        spokenSymbols = GFStutterWordSet(@"zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen "
                                         @"fifteen sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy "
                                         @"eighty ninety hundred thousand million billion oh double triple point dot dash slash "
                                         @"backslash colon star hash plus minus equals underscore");
        keepPhrases = [NSSet setWithArray:[@"thank you|no thank you|thank you so much|thank you very much|thanks so much|all right|"
                                           @"come on|hold on|good morning|good night|good evening|good afternoon|oh boy|oh man|"
                                           @"oh dear|oh my|oh no|oh yes|oh yeah|oh well|oh wow|my god|oh my god|oh my gosh|"
                                           @"my goodness|oh my goodness|et cetera|and so on|and so forth|so on|after another|"
                                           @"back and forth|up and down|in and out|on and off|to and fro|left and right|"
                                           @"here and there|tick tock|ding dong|left right|up down|in out|on off|yes no"
                                           componentsSeparatedByString:@"|"]];
        chainWords = GFStutterWordSet(@"and or of by after upon to in on for over");
        idiomChainWords = GFStutterWordSet(@"by after upon to in on for over");
        idiomNouns = GFStutterWordSet(@"time face back door day night end peer point wall head heart coast bumper toe nose mouth "
                                      @"cheek shoulder side person house place man one two week month year hour minute hand arm "
                                      @"word dollar step little bit piece line case page inch mile layer row generation");
        quantityNouns = GFStutterWordSet(@"lot couple bunch bit number ton kind sort rest majority variety series pair handful");
        ofFollowers = GFStutterWordSet(@"the a an my your his her our their its this that these those each every some any course "
                                       @"it them us you me him all what how which");
        tautologyHeads = GFStutterWordSet(@"what whatever who whoever whom which whichever where wherever when whenever how however "
                                          @"why if whether once because since as while until till unless though although "
                                          @"everything anything something nothing all");
        determiners = GFStutterWordSet(@"the a an my your his her our their its this that these those each every some any");
        giveVerbs = GFStutterWordSet(@"give gives gave given giving show shows showed shown showing tell tells told telling send "
                                     @"sends sent sending ask asks asked asking offer offers offered offering bring brings brought "
                                     @"bringing hand hands handed handing teach teaches taught teaching pay pays paid paying lend "
                                     @"lends lent lending get gets got getting buy buys bought buying make makes made making call "
                                     @"calls called calling name names named naming email emails emailed text texts texted assign "
                                     @"assigns assigned grant grants granted pass passes passed passing sell sells sold selling owe "
                                     @"owes owed promise promises promised read reads write writes wrote written save saves saved "
                                     @"find finds found leave leaves left forward forwards forwarded mail mails mailed serve serves "
                                     @"served throw throws threw feed feeds fed cook cooks cooked pour pours poured build builds "
                                     @"built order orders ordered book books booked wish wishes wished charge charges charged cost "
                                     @"costs allow allows allowed deny denies denied award awards awarded");
        sContractions = GFStutterWordSet(@"it's that's there's here's he's she's what's who's let's where's how's");
        unfinishedEnd = GFStutterWordSet(@"a an the my your our their its every i we they he she of with for from at into onto to "
                                         @"about and but or if because when while although unless until whether i'm we're they're "
                                         @"you're it's that's there's here's he's she's what's let's i'll we'll you'll they'll he'll "
                                         @"she'll it'll i've we've you've they've i'd we'd you'd they'd he'd she'd");
        helperVerbs = GFStutterWordSet(@"is are was were am be been will would can could should shall may might must have has had do "
                                       @"does did don't doesn't didn't won't wouldn't can't couldn't shouldn't isn't aren't wasn't "
                                       @"weren't haven't hasn't hadn't");
        unfinishedIfContinues = [helperVerbs setByAddingObjectsFromSet:
                                 GFStutterWordSet(@"think thought guess mean want wanted need needed hope suppose that this these those "
                                                  @"just also then not like going gonna wanna gotta trying some any more all no his her "
                                                  @"so really very")];
        beforeYou = [helperVerbs setByAddingObjectsFromSet:GFStutterWordSet(@"if when and so but that because as while once")];
        abortedStrong = GFStutterWordSet(@"a an the my your our their its every");
        abortedBare = GFStutterWordSet(@"some any each another");
    });

    NSUInteger len = str.length;
    if (len < 7) return NO; // the shortest repeat is "I'm I'm"
    unichar *low = malloc(len * sizeof(unichar));
    GFStutterToken *tok = malloc((len / 2 + 1) * sizeof(GFStutterToken));
    if (!low || !tok) { free(low); free(tok); return NO; }
    [str getCharacters:low range:NSMakeRange(0, len)];

    // words and what separates them
    NSUInteger T = 0, p = 0, prevEnd = 0;
    while (p < len) {
        unichar c = low[p];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))) { p++; continue; }
        NSUInteger s = p;
        BOOL cap = (c >= 'A' && c <= 'Z');
        while (p < len) {
            unichar d = low[p];
            BOOL letter = (d >= 'a' && d <= 'z') || (d >= 'A' && d <= 'Z');
            if (!letter) {
                unichar next = (p + 1 < len) ? low[p + 1] : 0;
                BOOL inner = (d == '\'' || d == 0x2019) && ((next >= 'a' && next <= 'z') || (next >= 'A' && next <= 'Z'));
                if (!inner) break;
            }
            p++;
        }
        uint8_t sep = 0;
        if (T > 0 && s > prevEnd) {
            NSUInteger commas = 0;
            BOOL plain = YES;
            for (NSUInteger q = prevEnd; q < s; q++) {
                unichar g = low[q];
                if (g == ',') commas++;
                else if (g != ' ' && g != '\t' && g != 0x00A0) { plain = NO; break; }
            }
            if (plain && commas <= 1) sep = (commas == 0) ? 1 : 2;
        }
        tok[T++] = (GFStutterToken){ s, p, sep, cap };
        prevEnd = p;
    }
    // compare without case, curly apostrophe = straight
    for (NSUInteger q = 0; q < len; q++) {
        if (low[q] >= 'A' && low[q] <= 'Z') low[q] += 32;
        else if (low[q] == 0x2019) low[q] = '\'';
    }

    BOOL (^same)(NSUInteger, NSUInteger) = ^BOOL(NSUInteger a, NSUInteger b) {
        NSUInteger la = tok[a].end - tok[a].start;
        return la == tok[b].end - tok[b].start && memcmp(low + tok[a].start, low + tok[b].start, la * sizeof(unichar)) == 0;
    };
    // words a..a+n-1 are words b..b+n-1, each group joined by plain spaces only
    BOOL (^sameRun)(NSUInteger, NSUInteger, NSUInteger) = ^BOOL(NSUInteger a, NSUInteger b, NSUInteger n) {
        for (NSUInteger k = 0; k < n; k++) {
            if (k > 0 && (tok[a + k].sep != 1 || tok[b + k].sep != 1)) return NO;
            if (!same(a + k, b + k)) return NO;
        }
        return YES;
    };
    NSString *(^word)(NSUInteger) = ^NSString *(NSUInteger k) {
        return [NSString stringWithCharacters:low + tok[k].start length:tok[k].end - tok[k].start];
    };
    // P = words i..i+n-1: one word n times, or only number/symbol words and spelled letters
    BOOL (^sameWordOrSpoken)(NSUInteger, NSUInteger) = ^BOOL(NSUInteger i, NSUInteger n) {
        BOOL allSame = (n >= 2), allSpoken = YES;
        for (NSUInteger k = 0; k < n; k++) {
            if (k > 0 && !same(i, i + k)) allSame = NO;
            if (tok[i + k].end - tok[i + k].start > 1 && ![spokenSymbols containsObject:word(i + k)]) allSpoken = NO;
        }
        return allSame || allSpoken;
    };

    NSRange cut = NSMakeRange(NSNotFound, 0);
    for (NSUInteger i = 0; i < T && cut.location == NSNotFound; i++) {
        // Rule A: copies back to back
        for (NSUInteger n = kGFStutterMaxPhrase; n >= 1 && cut.location == NSNotFound; n--) {
            if (i + 2 * n > T) continue;
            uint8_t junction = tok[i + n].sep;
            if (junction == 0 || !sameRun(i, i + n, n)) continue;
            NSString *first = word(i);
            if (n == 1) { // a lone word only when it is a contraction
                BOOL contraction = [first hasSuffix:@"n't"] || [first hasSuffix:@"'m"] || [first hasSuffix:@"'re"] ||
                                   [first hasSuffix:@"'ll"] || [first hasSuffix:@"'ve"] || [first hasSuffix:@"'d"] ||
                                   [sContractions containsObject:first];
                if (!contraction) continue;
            }
            // the same run one word to the left was already judged, and kept
            if (i > 0 && tok[i].sep == 1 && junction == 1 && same(i - 1, i + n - 1)) continue;
            NSUInteger copies = 2;
            while (i + (copies + 1) * n <= T && tok[i + copies * n].sep == junction && sameRun(i, i + copies * n, n)) copies++;
            NSUInteger last = i + copies * n - 1;
            NSString *end = word(i + n - 1);
            NSString *second = (n >= 2) ? word(i + 1) : nil;

            if (sameWordOrSpoken(i, n)) continue;
            NSMutableString *phrase = [NSMutableString stringWithString:first];
            for (NSUInteger k = 1; k < n; k++) [phrase appendFormat:@" %@", word(i + k)];
            if ([keepPhrases containsObject:phrase]) continue;
            NSString *before = (i > 0 && tok[i].sep == 1) ? word(i - 1) : nil; // joined by plain spaces
            if (before && [tautologyHeads containsObject:before]) continue;
            if (before && [determiners containsObject:first] && [giveVerbs containsObject:before]) continue;
            if (n >= 2) { // names, places, acronyms
                BOOL allCap = YES;
                NSUInteger nameWords = 0;
                for (NSUInteger k = i; k <= last; k++) if (!tok[k].cap) { allCap = NO; break; }
                for (NSUInteger k = 0; k < n; k++) {
                    NSString *w = word(i + k);
                    if (!([w isEqualToString:@"i"] || [w hasPrefix:@"i'"])) nameWords++;
                }
                if (allCap && nameWords >= 2) continue;
            }
            if (n == 2) {
                if ([end isEqualToString:@"and"] || [end isEqualToString:@"or"]) continue;
                if ([idiomChainWords containsObject:end] && [idiomNouns containsObject:first]) continue;
                if ([first isEqualToString:@"of"] && ![ofFollowers containsObject:end]) continue;
                // "X c X c X" / "X, c X c X": the neighbour continues the chain
                NSString *left = (i > 0 && tok[i].sep != 0) ? word(i - 1) : nil;
                NSString *right = (last + 1 < T && tok[last + 1].sep != 0) ? word(last + 1) : nil;
                BOOL chain = NO;
                if ([chainWords containsObject:first] && ([left isEqualToString:end] || [right isEqualToString:end])) chain = YES;
                if ([chainWords containsObject:end] && ([left isEqualToString:first] || [right isEqualToString:first])) chain = YES;
                if (chain) continue;
            }
            if (n == 3 && ([first isEqualToString:@"a"] || [first isEqualToString:@"an"] || [first isEqualToString:@"the"]) &&
                ([end isEqualToString:@"of"] || [end isEqualToString:@"to"]) && ![quantityNouns containsObject:second]) continue;
            if (n >= 3 && ([end isEqualToString:@"and"] || [end isEqualToString:@"or"])) continue;
            BOOL continues = (last + 1 < T && tok[last + 1].sep == 1);
            BOOL unfinished = [unfinishedEnd containsObject:end] ||
                              (continues && ([unfinishedIfContinues containsObject:end] ||
                                             (n >= 2 && [end isEqualToString:@"you"] && [beforeYou containsObject:word(i + n - 2)])));
            if (junction == 2 && !unfinished) continue;
            if (n >= 3 && ([first isEqualToString:@"and"] || [first isEqualToString:@"or"]) && !unfinished) continue;
            cut = NSMakeRange(tok[i + n - 1].end, tok[last].end - tok[i + n - 1].end);
        }
        // Rule B: P + one aborted word + P
        for (NSUInteger n = kGFStutterMaxPhrase; n >= 3 && cut.location == NSNotFound; n--) {
            if (i + 2 * n + 1 > T) continue;
            NSUInteger x = i + n, again = x + 1;
            if (tok[x].sep != 1 || tok[again].sep == 0 || !sameRun(i, again, n)) continue;
            NSString *aborted = word(x);
            if (!([abortedStrong containsObject:aborted] || (tok[again].sep == 1 && [abortedBare containsObject:aborted]))) continue;
            if (sameWordOrSpoken(i, n)) continue;
            cut = NSMakeRange(tok[i + n - 1].end, tok[again + n - 1].end - tok[i + n - 1].end);
        }
    }
    free(low);
    free(tok);
    if (cut.location == NSNotFound) return NO;
    [str deleteCharactersInRange:cut];
    return YES;
}

// Stutter cleanup (backlog 17): "the the" / "I I" / "we we we" collapse to one word, but grammatical doubles stay ("had had",
// "that that", "is is", "do do", "her her", "very very", number words in "five five five"), and so do capitalized repeats
// that look like names ("Bora Bora", "The The"; "I I" still collapses). When unsure, the words are kept.
// Then repeated phrases and mid-thought restarts collapse (backlog 0x, GFCollapsePhraseRepeatOnce above).
static void GFRemoveStutterRepeats(NSMutableString *str) {
    static NSRegularExpression *re;
    static NSSet<NSString *> *keep;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"\\b([a-zA-Z]+)((?:\\s+\\1\\b)+)" options:NSRegularExpressionCaseInsensitive error:nil];
        keep = [NSSet setWithArray:@[@"had", @"that", @"is", @"was", @"do", @"her", @"in", @"on", @"up", @"very", @"really", @"so",
                                     @"no", @"bye", @"yeah", @"ha", @"haha", @"now", @"well", @"far", @"many", @"long", @"please",
                                     @"knock", @"night", @"chop", @"tut", @"hush", @"my", @"oh", @"zero", @"one", @"two", @"three",
                                     @"four", @"five", @"six", @"seven", @"eight", @"nine", @"ten", @"eleven", @"twelve",
                                     @"hundred", @"thousand", @"double"]];
    });
    NSArray<NSTextCheckingResult *> *matches = [re matchesInString:str options:0 range:NSMakeRange(0, str.length)];
    for (NSTextCheckingResult *m in [matches reverseObjectEnumerator]) {
        NSString *word = [str substringWithRange:[m rangeAtIndex:1]];
        NSString *lower = word.lowercaseString;
        if ([keep containsObject:lower]) continue;
        NSString *repeats = [str substringWithRange:[m rangeAtIndex:2]];
        NSString *second = [repeats stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        BOOL nameLike = ![lower isEqualToString:@"i"] && second.length > 0 &&
                        [[NSCharacterSet uppercaseLetterCharacterSet] characterIsMember:[second characterAtIndex:0]];
        if (nameLike) continue;
        if (lower.length == 1 && ![lower isEqualToString:@"i"] && ![lower isEqualToString:@"a"]) continue; // spelled letters
        [str deleteCharactersInRange:[m rangeAtIndex:2]];
    }
    // phrases after single words ("I I would I would" -> "I would"); one collapse per call, the bound only stops a runaway loop
    for (int pass = 0; pass < 64 && GFCollapsePhraseRepeatOnce(str); pass++) {}
}

// "kind of" / "sort of" from rules.json extraFillers (backlog 0i, user decision 2026-11-10): removed only when clearly filler.
// Removed when set off as a pause/aside (", kind of," / a pause right after it mid-sentence / a dangling ", sort of." at the
// end) or next to another filler (um/uh/like/you know/I mean, or another kind of/sort of). Kept when meaningful: after a
// determiner, question word or a "type of" adjective ("what kind of car", "a sort of plan", "the same kind of thing"), in
// "kind of you/him/her..." ("that's kind of you"), and as a plain hedge with no pause ("it sort of works", "I kind of like it").
// Plural "kinds of" / "sorts of" never match. Runs on the raw text, before the vocal fillers and the other extraFillers are
// stripped, so the pauses and neighbouring fillers it looks at are still there.
static NSString *GFHedgeFillerKey(id item) {
    if (![item isKindOfClass:[NSString class]]) return nil;
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *p in [[(NSString *)item lowercaseString] componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]) {
        if (p.length > 0) [parts addObject:p];
    }
    NSString *key = [parts componentsJoinedByString:@" "];
    return ([key isEqualToString:@"kind of"] || [key isEqualToString:@"sort of"]) ? key : nil;
}

// stripLike (cleanLikeFiller): a filler "like" right before a stripped hedge goes with it (backlog 0k): "it's like kind of broken"
// -> "It's broken." The like rules (step 6) don't remove "like" before an adjective, so it used to be left behind. Only after a
// be-form, a conjunction/discourse word or at a sentence start, with plain spaces around it; the verb stays ("I like kind of
// broken things" -> "I like broken things").
static void GFRemoveHedgeFillers(NSMutableString *str, BOOL kindOf, BOOL sortOf, BOOL stripLike) {
    if ((!kindOf && !sortOf) || str.length == 0) return;
    static NSRegularExpression *leftFillerRe, *rightFillerRe, *leftHedgeRe, *rightHedgeRe, *prevWordRe, *startRe, *endRe,
                               *commaBeforeRe, *commaAfterRe, *pronounRe, *fillerLikeRe;
    static NSSet<NSString *> *keepAfter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSRegularExpressionOptions ci = NSRegularExpressionCaseInsensitive;
        NSString *fillers = @"um+|uh+|uhm+|erm+|ah+|hmm+|you\\s+know|i\\s+mean";
        // "like" counts only BEFORE the hedge ("it's like kind of broken"); after it, it's the verb/comparison ("I kind of like it")
        leftFillerRe = [NSRegularExpression regularExpressionWithPattern:
                        [NSString stringWithFormat:@"(?<![\\w'-])(?:%@|like)[\\s,]*$", fillers] options:ci error:nil];
        rightFillerRe = [NSRegularExpression regularExpressionWithPattern:
                         [NSString stringWithFormat:@"^[\\s,]*(?:%@)(?![\\w'-])", fillers] options:ci error:nil];
        leftHedgeRe = [NSRegularExpression regularExpressionWithPattern:@"(?<![\\w'-])(?:kind|sort)\\s+of[\\s,]*$" options:ci error:nil];
        rightHedgeRe = [NSRegularExpression regularExpressionWithPattern:@"^[\\s,]*(?:kind|sort)\\s+of(?![\\w'-])" options:ci error:nil];
        // the word before the hedge, skipping commas and fillers ("what, um, kind of car" -> "what")
        prevWordRe = [NSRegularExpression regularExpressionWithPattern:
                      [NSString stringWithFormat:@"(?<![\\w'])([\\w']+)(?:[\\s,]+(?:%@|like))*[\\s,]*$", fillers] options:ci error:nil];
        startRe = [NSRegularExpression regularExpressionWithPattern:@"(?:^|[.!?\\n\\uE000\\uE001])[\\s,]*$" options:0 error:nil];
        endRe = [NSRegularExpression regularExpressionWithPattern:@"^\\s*(?:[.!?\\n\\uE000\\uE001]|$)" options:0 error:nil];
        commaBeforeRe = [NSRegularExpression regularExpressionWithPattern:@",\\s*$" options:0 error:nil];
        commaAfterRe = [NSRegularExpression regularExpressionWithPattern:@"^\\s*," options:0 error:nil];
        pronounRe = [NSRegularExpression regularExpressionWithPattern:@"^\\s+(?:you|him|her|them|us|me)(?![\\w'-])(?!\\s+know\\b)"
                                                              options:ci error:nil];
        // "like" directly before the hedge (spaces only), after a be-form / conjunction / discourse word or at a sentence start
        fillerLikeRe = [NSRegularExpression regularExpressionWithPattern:
                        @"(?:^|[.!?\\n\\uE000\\uE001]|(?<![\\w'-])(?:am|is|are|was|were|be|been|i'm|it's|that's|we're|they're|you're|he's|"
                        @"she's|and|so|but|or|because|well|actually|basically|literally))[ \\t]*(like)[ \\t]+$" options:ci error:nil];
        keepAfter = [NSSet setWithArray:@[@"a", @"an", @"the", @"what", @"which", @"whatever", @"whichever", @"this", @"that",
                                          @"these", @"those", @"some", @"any", @"every", @"each", @"one", @"no", @"all", @"same",
                                          @"different", @"other", @"another", @"my", @"your", @"his", @"her", @"its", @"our",
                                          @"their", @"certain", @"right", @"wrong", @"new", @"special", @"particular", @"similar",
                                          @"weird", @"strange", @"odd", @"best", @"worst", @"perfect", @"exact", @"whole", @"main",
                                          @"only", @"first", @"last", @"usual", @"specific"]];
    });
    NSString *which = (kindOf && sortOf) ? @"kind|sort" : (kindOf ? @"kind" : @"sort");
    NSRegularExpression *hedgeRe = [NSRegularExpression regularExpressionWithPattern:
                                    [NSString stringWithFormat:@"(?<![\\w'-])(%@)\\s+of(?![\\w'-])", which]
                                                                             options:NSRegularExpressionCaseInsensitive error:nil];
    NSArray<NSTextCheckingResult *> *matches = [hedgeRe matchesInString:str options:0 range:NSMakeRange(0, str.length)];
    if (matches.count == 0) return;
    NSMutableArray<NSValue *> *cuts = [NSMutableArray array];
    for (NSTextCheckingResult *m in matches) {
        NSUInteger loc = m.range.location, end = NSMaxRange(m.range);
        NSUInteger from = loc > 160 ? loc - 160 : 0; // context window: the decision only looks a few words back
        NSRange left = NSMakeRange(from, loc - from), right = NSMakeRange(end, str.length - end);
        BOOL (^hit)(NSRegularExpression *, NSRange) = ^BOOL(NSRegularExpression *re, NSRange r) {
            return [re firstMatchInString:str options:0 range:r] != nil;
        };
        NSTextCheckingResult *pw = [prevWordRe firstMatchInString:str options:0 range:left];
        NSString *prev = pw ? [[str substringWithRange:[pw rangeAtIndex:1]] lowercaseString] : nil;
        if (prev && [keepAfter containsObject:prev]) continue;                 // "what kind of car", "a sort of plan"
        BOOL isKind = [[[str substringWithRange:[m rangeAtIndex:1]] lowercaseString] isEqualToString:@"kind"];
        if (isKind && hit(pronounRe, right)) continue;                         // "that's kind of you"
        BOOL commaBefore = hit(commaBeforeRe, left), commaAfter = hit(commaAfterRe, right);
        BOOL atStart = hit(startRe, left), atEnd = hit(endRe, right);
        BOOL nextToFiller = hit(leftFillerRe, left) || hit(rightFillerRe, right) || hit(leftHedgeRe, left) || hit(rightHedgeRe, right);
        // a pause right after it mid-sentence is a hesitation; at the start of a sentence ("Sort of, yes") it's an answer
        BOOL aside = (commaBefore && commaAfter) || (commaAfter && !atStart) || (commaBefore && atEnd);
        if (!nextToFiller && !aside) continue;                                 // plain hedge: "it sort of works"
        NSUInteger cutFrom = loc, cutTo = end;
        if (commaBefore && (commaAfter || atEnd)) cutFrom = [commaBeforeRe firstMatchInString:str options:0 range:left].range.location;
        NSTextCheckingResult *fl = stripLike ? [fillerLikeRe firstMatchInString:str options:0 range:left] : nil;
        if (fl && !commaAfter) cutFrom = [fl rangeAtIndex:1].location; // "it's like kind of broken" -> "it's broken"
        if (commaAfter) cutTo = NSMaxRange([commaAfterRe firstMatchInString:str options:0 range:right].range);
        NSRange cut = NSMakeRange(cutFrom, cutTo - cutFrom);
        NSValue *last = cuts.lastObject;
        if (last && cut.location <= NSMaxRange(last.rangeValue)) { // "kind of, sort of," share a comma: merge the cuts
            NSRange u = NSUnionRange(last.rangeValue, cut);
            cuts[cuts.count - 1] = [NSValue valueWithRange:u];
        } else {
            [cuts addObject:[NSValue valueWithRange:cut]];
        }
    }
    for (NSValue *v in [cuts reverseObjectEnumerator]) [str replaceCharactersInRange:v.rangeValue withString:@" "];
}

// The last sentence of a line (backlog 0j): the text after the last sentence end (. ! ? plus closing quotes/brackets, then
// whitespace). Not a sentence end: an ellipsis ("Wait... what"), or a "." after an abbreviation that rarely ends a sentence:
// titles ("Mr. Smith"), "etc."/"vs."/"e.g.", dotted letters ("U.S.", "p.m."), a single letter except "I" ("J. Smith";
// "So did I. What now" and "No. Why" do end sentences). When unsure, an
// earlier boundary (or the whole line) is used, which is the old behaviour. *afterQuestion: that sentence end was a "?".
static NSString *GFLastSentence(NSString *line, BOOL *afterQuestion) {
    if (afterQuestion) *afterQuestion = NO;
    if (line.length == 0) return line;
    static NSRegularExpression *endRe, *tokenRe, *abbrevRe;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        endRe = [NSRegularExpression regularExpressionWithPattern:@"([.!?\u2026]+)[\"'\u201d\u2019)\\]]*\\s+(?=\\S)" options:0 error:nil];
        tokenRe = [NSRegularExpression regularExpressionWithPattern:@"([\\w.'-]+)$" options:0 error:nil];
        abbrevRe = [NSRegularExpression regularExpressionWithPattern:
                    @"^(?:[a-hj-z]|(?:[a-z]\\.)+[a-z]|mr|mrs|ms|dr|prof|st|sr|jr|mt|vs|etc|cf|approx|incl|esp|fig|inc|ltd|co|corp|"
                    @"dept|gen|gov|lt|sgt|col|capt|rev|hon|ave|blvd|rd|jan|feb|mar|apr|jun|jul|aug|sep|sept|oct|nov|dec)$"
                                                             options:NSRegularExpressionCaseInsensitive error:nil];
    });
    NSArray<NSTextCheckingResult *> *ends = [endRe matchesInString:line options:0 range:NSMakeRange(0, line.length)];
    for (NSTextCheckingResult *m in [ends reverseObjectEnumerator]) {
        NSString *punct = [line substringWithRange:[m rangeAtIndex:1]];
        if ([punct containsString:@".."] || [punct containsString:@"\u2026"]) continue; // trailing off, not a sentence end
        if ([punct isEqualToString:@"."]) {
            NSUInteger at = m.range.location;
            NSUInteger from = at > 40 ? at - 40 : 0;
            NSTextCheckingResult *t = [tokenRe firstMatchInString:line options:0 range:NSMakeRange(from, at - from)];
            NSString *token = t ? [line substringWithRange:[t rangeAtIndex:1]] : @"";
            if (token.length == 0) continue; // "?." / stray dot
            if ([abbrevRe firstMatchInString:token options:0 range:NSMakeRange(0, token.length)]) continue;
        }
        if (afterQuestion) *afterQuestion = [punct hasSuffix:@"?"];
        return [line substringFromIndex:NSMaxRange(m.range)];
    }
    return line;
}

- (NSString *)polishOnDeviceTranscript:(NSString *)rawText {
    if (!rawText || rawText.length == 0) return @"";

    NSMutableString *str = [NSMutableString stringWithString:rawText];

    // Load configuration rules from rules.json if present
    BOOL cleanLike = YES;
    BOOL cleanVocal = YES;
    BOOL cleanStutter = YES;
    BOOL autoCap = YES;
    BOOL autoPunct = YES;
    NSArray *extraFillers = nil;
    NSDictionary *customReplacements = nil;

    NSString *home = NSHomeDirectory();
    NSString *rulesPath = [home stringByAppendingPathComponent:@"GeminiFlow/rules.json"];
    NSData *rulesData = [NSData dataWithContentsOfFile:rulesPath];
    if (!rulesData) {
        NSString *appSupportPath = [home stringByAppendingPathComponent:@"Library/Application Support/GeminiFlow/rules.json"];
        rulesData = [NSData dataWithContentsOfFile:appSupportPath];
    }

    if (rulesData) {
        NSError *jsonErr = nil;
        NSDictionary *rules = [NSJSONSerialization JSONObjectWithData:rulesData options:0 error:&jsonErr];
        if ([rules isKindOfClass:[NSDictionary class]]) {
            if (rules[@"cleanLikeFiller"] != nil) cleanLike = [rules[@"cleanLikeFiller"] boolValue];
            if (rules[@"cleanVocalFillers"] != nil) cleanVocal = [rules[@"cleanVocalFillers"] boolValue];
            if (rules[@"cleanStutterWords"] != nil) cleanStutter = [rules[@"cleanStutterWords"] boolValue];
            if (rules[@"autoCapitalize"] != nil) autoCap = [rules[@"autoCapitalize"] boolValue];
            if (rules[@"autoPunctuate"] != nil) autoPunct = [rules[@"autoPunctuate"] boolValue];
            if ([rules[@"extraFillers"] isKindOfClass:[NSArray class]]) {
                extraFillers = rules[@"extraFillers"];
            }
            if ([rules[@"customReplacements"] isKindOfClass:[NSDictionary class]]) {
                customReplacements = rules[@"customReplacements"];
            }
        }
    }

    // 1. Spoken formatting commands & character normalization
    GFMarkSpokenLineBreaks(str); // marks; expanded to "\n" / "\n\n" after cleanup (step 10b)
    replaceRegex(str, @"\\s*[\\u2014\\u2013]\\s*", @", ", 0);

    // 2. Custom phrase replacements from rules.json (if any)
    if (customReplacements && customReplacements.count > 0) {
        for (NSString *key in customReplacements) {
            id val = customReplacements[key];
            if ([val isKindOfClass:[NSString class]]) {
                [str replaceOccurrencesOfString:key withString:(NSString *)val options:NSCaseInsensitiveSearch range:NSMakeRange(0, str.length)];
            }
        }
    }

    // 2b. "kind of" / "sort of" in rules.json extraFillers: removed only when clearly filler (backlog 0i), by the dedicated
    // pass, not the blind extraFillers regex (step 5 skips them). It runs before steps 3-5 remove the fillers/commas it reads.
    BOOL hedgeKindOf = NO, hedgeSortOf = NO;
    for (id item in extraFillers) {
        NSString *key = GFHedgeFillerKey(item);
        if ([key isEqualToString:@"kind of"]) hedgeKindOf = YES;
        if ([key isEqualToString:@"sort of"]) hedgeSortOf = YES;
    }
    GFRemoveHedgeFillers(str, hedgeKindOf, hedgeSortOf, cleanLike);

    // 3. Remove vocal fillers (um, uh, uhm, erm, ah, hmm) including optional leading comma
    if (cleanVocal) {
        // not inside hyphenated words ("uh-huh", "uh-oh", "mm-hmm", "ah-ha" used to lose half and leave "-huh")
        replaceRegex(str, @"(?:,\\s*)?(?<![\\w'-])(um+|uh+|uhm+|erm+|ah+|hmm+)\\b(?!-)[,.]?\\s*", @" ", NSRegularExpressionCaseInsensitive);
    }

    // 4. Early pass: parenthetical ", like," and "be + like," before extraFillers strip surrounding commas
    if (cleanLike) {
        replaceRegex(str, @",\\s*like,\\s*", @" ", NSRegularExpressionCaseInsensitive);
        replaceRegex(str, @"\\b(am|is|are|was|were|be|been|i'm|it's|that's|we're|they're|you're|he's|she's)\\s+like,\\s*", @"$1 ", NSRegularExpressionCaseInsensitive);
    }

    // 5. Remove extra custom fillers from rules.json (e.g. "you know", "i mean"; "sort of" / "kind of" were handled in step 2b)
    if (extraFillers && extraFillers.count > 0) {
        for (id item in extraFillers) {
            if (GFHedgeFillerKey(item)) continue;
            if ([item isKindOfClass:[NSString class]] && [(NSString *)item length] > 0) {
                NSString *escaped = [NSRegularExpression escapedPatternForString:(NSString *)item];
                NSString *pattern = [NSString stringWithFormat:@"(?:,\\s*)?\\b%@\\b[,.]?\\s*", escaped];
                replaceRegex(str, pattern, @" ", NSRegularExpressionCaseInsensitive);
            }
        }
    }

    // 6. Context-aware "like" filler cleanup
    if (cleanLike) {
        // 6a. Second pass on ", like," and "be + like," after vocal/extra fillers are stripped
        replaceRegex(str, @",\\s*like,\\s*", @" ", NSRegularExpressionCaseInsensitive);
        replaceRegex(str, @"\\b(am|is|are|was|were|be|been|i'm|it's|that's|we're|they're|you're|he's|she's)\\s+like,\\s*", @"$1 ", NSRegularExpressionCaseInsensitive);

        // 6b. Unconditional filler: "like" before sentence adverbs or intensifiers
        replaceRegex(str, @"(?:,\\s*)?\\blike[,]?\\s+(?=(maybe|probably|definitely|honestly|basically|literally|actually|seriously|obviously|really|super|totally|completely|absolutely)\\b)", @" ", NSRegularExpressionCaseInsensitive);

        // 6c. Sentence-initial or clause-initial filler (start of string or after . ! ? \n)
        replaceRegex(str, @"(^|[.!?\\n\\uE000\\uE001]\\s*)[,\\s]*\\blike[,]?\\s+(?=(i|i'm|i'll|i've|i'd|we|we're|we'll|we've|you|you're|you'll|they|they're|he|he's|she|she's|it|it's|this|that|that's|there|there's|what|how|why|where|who|if|when|so|just|honestly|basically|literally|actually|maybe|probably|can|could|should|will|do|did|is|are|was|were)\\b)", @"$1", NSRegularExpressionCaseInsensitive);

        // 6d. Comma + "like" before a new clause subject or question word ("Wait, like what happened", "Well, like I said")
        replaceRegex(str, @",\\s*like[,]?\\s+(?=(i|i'm|i'll|i've|i'd|we|we're|we'll|we've|you're|you'll|they|they're|he|he's|she|she's|it's|that's|there's|what|how|why|where|who|if|when)\\b)", @", ", NSRegularExpressionCaseInsensitive);

        // 6e. After conjunctions and discourse particles ("and like", "so like", "but like", "or like", "because like")
        replaceRegex(str, @"\\b(and|so|but|or|because|well|actually|basically|literally)\\s+like,\\s*", @"$1 ", NSRegularExpressionCaseInsensitive);
        replaceRegex(str, @"\\b(and|so|but|or|because|well|actually|basically|literally)\\s+like\\s+(?=(i|i'm|i'll|i've|i'd|we|we're|we'll|we've|you|you're|they|they're|he|he's|she|she's|it's|it\\s+(?:is|was|will|would|could|should|can|has|had|seems|looks|feels|works|makes|takes)|that's|there|there's|what|how|why|where|who|if|when|just|really|very|totally|honestly|super|maybe|probably|definitely)\\b)", @"$1 ", NSRegularExpressionCaseInsensitive);

        // 6f. After "to be" forms before adverbs, qualifiers, or quantifiers ("was like really", "it's like super", "I'm like so")
        replaceRegex(str, @"\\b(am|is|are|was|were|be|been|i'm|it's|that's|we're|they're|you're|he's|she's)\\s+like[,]?\\s+(?=(really|super|very|so|totally|just|honestly|pretty|quite|always|completely|absolutely|almost|already|about|around)\\b)", @"$1 ", NSRegularExpressionCaseInsensitive);

        // 6g. Between modal/auxiliary/infinitive/pronoun markers and action verbs ("should like check", "can you like send", "need to like finish", "what do you like think")
        NSString *commonActionVerbs = @"check|send|get|make|finish|grab|see|do|go|say|tell|ask|find|take|give|keep|put|run|set|show|try|use|work|write|talk|call|look|build|create|update|fix|test|review|clean|move|open|close|start|stop|turn|add|remove|change|help|play|read|spend|wait|walk|watch|buy|bring|meet|pay|think|schedule|cancel|confirm|explain|discuss|share|upload|download|install|deploy|ship|launch|figure|focus";
        NSString *auxPattern = [NSString stringWithFormat:@"\\b(to|should|could|can|will|did|do|does|let's|lets|can\\s+you|could\\s+you|will\\s+you|do\\s+you|did\\s+you)\\s+like[,]?\\s+(?=(%@)\\b)", commonActionVerbs];
        replaceRegex(str, auxPattern, @"$1 ", NSRegularExpressionCaseInsensitive);

        // 6h. Before numbers/quantities after non-comparison verbs/prepositions ("have like ten", "cost like 50", "for like two hours", "in like five minutes")
        replaceRegex(str, @"\\b(have|has|had|got|take|takes|took|cost|costs|spent|spend|wait|waited|for|in|after|within)\\s+like[,]?\\s+(?=(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty|thirty|forty|fifty|hundred|thousand|a\\s+hundred|a\\s+thousand|a\\s+couple|a\\s+few|\\d+)\\b)", @"$1 ", NSRegularExpressionCaseInsensitive);
    }

    // 7. Remove accidental duplicate stutter words (e.g. "the the", "I I", "we we we") and repeated phrases / mid-thought
    // restarts ("with my with my new app"; backlog 0x). After the fillers, so "with my, um, with my" collapses too.
    if (cleanStutter) GFRemoveStutterRepeats(str);

    // 8. Fix standalone lowercase "i" and contractions. The pronoun only: not in abbreviations ("i.e.", "i.v."), paths, URLs,
    // filenames or code-ish tokens ("i.txt", "/usr/i/", "wi-fi", "i/o", "x_i"); "i." at the end of a sentence is the pronoun.
    replaceRegex(str, @"(?<![\\w.@/\\\\#$%&=+~-])i(?=$|[\\s,;:!?)\\]\"\u201d\u2026\\uE000\\uE001]|\\.(?![\\w])|['\u2019](?:m|ll|ve|d)\\b|['\u2019](?!\\w))", @"I", 0);
    replaceRegex(str, @"\\bi'm\\b", @"I'm", NSRegularExpressionCaseInsensitive);
    replaceRegex(str, @"\\bi'll\\b", @"I'll", NSRegularExpressionCaseInsensitive);
    replaceRegex(str, @"\\bi've\\b", @"I've", NSRegularExpressionCaseInsensitive);
    replaceRegex(str, @"\\bi'd\\b", @"I'd", NSRegularExpressionCaseInsensitive);

    // 9. Clean up multiple spaces and spaces before punctuation
    replaceRegex(str, @"\\s+([,;!?])", @"$1", 0);
    replaceRegex(str, @"\\s+(\\.)(?![\\w])", @"$1", 0); // not before ".env" / ".gitignore"
    replaceRegex(str, @",\\s*,+", @",", 0);
    replaceRegex(str, @"([.!?])\\s*,\\s*", @"$1 ", 0);
    replaceRegex(str, @"\\s{2,}", @" ", 0);

    // 10. Strip leading punctuation/spaces
    replaceRegex(str, @"^(?:[,;:\\s]|\\.(?![\\w]))+", @"", 0); // a leading ".env" keeps its dot

    NSString *trimmed = [str stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return @"";

    // 10b. Spoken line breaks become real ones (after the trim, so a leading/trailing "new line" survives; a press that was only
    // "new line" yields "\n")
    NSMutableString *result = [NSMutableString stringWithString:trimmed];
    GFExpandSpokenLineBreaks(result);

    // 11. Capitalize first letter of transcript and first letter after sentence-ending punctuation (. ! ? \n)
    if (autoCap) {
        // Not mixed-case or URL/filename/email tokens ("iPhone", "iOS", "eBay", "example.com", "a@b.c", "i.e."), and not after
        // an abbreviation that rarely ends a sentence ("i.e. the", "e.g. the", "5 p.m. on", "U.S. law", "etc. and", "vs. them").
        static NSRegularExpression *capRe, *abbrevRe;
        static dispatch_once_t capOnce;
        dispatch_once(&capOnce, ^{
            capRe = [NSRegularExpression regularExpressionWithPattern:@"(?:^|(?<=[.!?\\n])\\s+|(?<=\\n))([a-z])(?![\\w'-]*[A-Z])(?![\\w-]*[.@/:]\\w)"
                                                              options:0 error:nil];
            abbrevRe = [NSRegularExpression regularExpressionWithPattern:@"(?:(?<![\\w.])[a-z]\\.[a-z]\\.|\\b(?:etc|vs|cf|approx|incl|esp)\\.)$"
                                                                 options:NSRegularExpressionCaseInsensitive error:nil];
        });
        NSArray<NSTextCheckingResult *> *matches = [capRe matchesInString:result options:0 range:NSMakeRange(0, result.length)];
        for (NSTextCheckingResult *match in [matches reverseObjectEnumerator]) {
            NSRange r = [match rangeAtIndex:1];
            NSUInteger at = match.range.location; // where the whitespace after the punctuation starts
            NSUInteger from = at > 12 ? at - 12 : 0;
            if (at > 0 && [abbrevRe firstMatchInString:result options:0 range:NSMakeRange(from, at - from)]) continue;
            NSString *upper = [[result substringWithRange:r] uppercaseString];
            [result replaceCharactersInRange:r withString:upper];
        }
    }

    // 12. Smart terminal punctuation (. or ?)
    if (autoPunct) {
        // judge the last line: after a spoken line break that's the sentence being ended (no line break: the whole text)
        NSString *lastLine = [[result componentsSeparatedByString:@"\n"] lastObject];
        NSArray *words = [lastLine componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (words.count >= 2) {
            unichar lastChar = [result characterAtIndex:result.length - 1];
            if (lastChar != '.' && lastChar != '?' && lastChar != '!' && lastChar != ':' && lastChar != ';' && lastChar != '\n') {
                // ...and within it only the last sentence (backlog 0j): "What kind of car do you drive? I sort of like the blue
                // one" is a statement. A line of one sentence is judged as before.
                BOOL afterQuestion = NO;
                NSString *lastSentence = GFLastSentence(lastLine, &afterQuestion);
                NSMutableArray *sentenceWords = [NSMutableArray array];
                for (NSString *w in [lastSentence componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]) {
                    if (w.length > 0) [sentenceWords addObject:w];
                }
                if (lastSentence.length < lastLine.length && sentenceWords.count > 0) words = sentenceWords;
                NSString *firstWord = [[[words firstObject] lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet punctuationCharacterSet]];
                NSArray *questionStarters = @[@"who", @"what", @"when", @"where", @"why", @"how", @"can", @"could", @"would", @"should", @"will", @"shall", @"is", @"are", @"am", @"was", @"were", @"do", @"does", @"did", @"have", @"has", @"had", @"may", @"might"];
                BOOL isQuestion = [questionStarters containsObject:firstWord];
                // "Should we ship it? Or wait" -> "Or wait?" (an "or" alternative right after a question stays a question)
                if (!isQuestion && afterQuestion && [firstWord isEqualToString:@"or"]) isQuestion = YES;
                if (!isQuestion && words.count >= 3) {
                    NSArray *discourseStarters = @[@"so", @"and", @"but", @"well", @"okay", @"ok", @"hey", @"wait", @"actually", @"honestly"];
                    if ([discourseStarters containsObject:firstWord]) {
                        NSString *secondWord = [[words[1] lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet punctuationCharacterSet]];
                        NSString *thirdWord = [[words[2] lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet punctuationCharacterSet]];
                        NSArray *auxVerbs = @[@"did", @"do", @"does", @"is", @"are", @"was", @"were", @"can", @"could", @"would", @"should", @"will", @"have", @"has", @"had", @"you", @"we", @"they", @"he", @"she", @"it"];
                        if ([questionStarters containsObject:secondWord] && [auxVerbs containsObject:thirdWord]) {
                            isQuestion = YES;
                        }
                    }
                }
                if (isQuestion) {
                    [result appendString:@"?"];
                } else {
                    [result appendString:@"."];
                }
            }
        }
    }

    // Trailing space for natural back-to-back dictation
    if (![result hasSuffix:@"\n"]) {
        [result appendString:@" "];
    }

    return result;
}

// After endAudio, Apple's recognizer needs ~100-400ms to emit the last word(s) and its isFinal result.
// Poll for isFinal (instead of cancelling after a fixed beat, which dropped the final word).
- (void)waitForOnDeviceFinalWithTimeout:(NSTimeInterval)timeout completion:(void (^)(void))completion {
    [self pollOnDeviceFinalForSession:self.recognitionSessionId
                                start:[NSDate timeIntervalSinceReferenceDate]
                             deadline:[NSDate dateWithTimeIntervalSinceNow:timeout]
                           completion:completion];
}

- (void)pollOnDeviceFinalForSession:(NSUInteger)sessionId start:(NSTimeInterval)start deadline:(NSDate *)deadline completion:(void (^)(void))completion {
    if (self.recognitionSessionId != sessionId) return; // a new press started; abandon (startRecording delivers pending text)
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    // isFinal normally lands ~100-200 ms after endAudio. If it never comes, stop once results have been
    // quiet for 0.6 s rather than always burning the full timeout.
    BOOL quiet = (now - start) >= 0.3 && (now - MAX(start, self.lastOnDeviceResultTime)) >= 0.6;
    if (self.latestOnDeviceIsFinal || !self.recognitionTask || quiet || [deadline timeIntervalSinceNow] <= 0) {
        completion();
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self pollOnDeviceFinalForSession:sessionId start:start deadline:deadline completion:completion];
    });
}

- (void)finishWithOnDeviceTranscriptForDictation:(GFDictation *)dictation {
    // Bounded wait: REST failed after the on-device text was already delivered early; keep it (never deliver twice)
    if (dictation.earlyText) {
        if (!dictation.superseded && !self.isRecording && self.recognitionTask) { [self.recognitionTask cancel]; self.recognitionTask = nil; }
        [self resolveEarlyPastedDictation:dictation geminiText:nil];
        return;
    }
    // A newer press owns the recognizer and the buffers: finish from this dictation's snapshot instead (backlog 6). The old
    // code ignored the call here ("a new recording is in progress") and the dictation was lost.
    if (dictation.superseded) { [self finishSupersededDictationOnDevice:dictation]; return; }
    if (self.isFinalizingOnDevice) return;
    if (self.isRecording) {
        // A late Gemini fallback must never cancel or steal a newer in-progress recording
        NSLog(@"finishWithOnDeviceTranscript ignored: a new recording is in progress.");
        return;
    }
    self.isFinalizingOnDevice = YES;

    __weak typeof(self) weakSelf = self;
    [self waitForOnDeviceFinalWithTimeout:1.5 completion:^{
        if (!weakSelf.latestOnDeviceIsFinal) {
            GFLog(@"On-device final result not received within timeout; using accumulated partials.");
        }
        // Make sure any in-flight segment is included
        [weakSelf commitCurrentOnDeviceSegment];
        [weakSelf refreshAccumulatedOnDeviceTranscript];
        if (weakSelf.recognitionTask) {
            [weakSelf.recognitionTask cancel];
            weakSelf.recognitionTask = nil;
        }
        weakSelf.isFinalizingOnDevice = NO;

        NSString *liveText = [weakSelf.latestOnDeviceTranscript stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (liveText.length > 0) {
            [weakSelf applyFinalTranscript:[weakSelf polishOnDeviceTranscript:liveText] dictation:dictation];
            return;
        }

        // Fallback to WAV file if live stream didn't emit text
        [weakSelf fallbackToWAVURLRecognitionForDictation:dictation];
    }];
}

// Last on-device step for a dictation that a newer press superseded (backlog 6). Its live recognizer was stopped at the new press,
// so use the transcript saved then. If that is empty, recognize its saved recording, unless the recording is near-silent (then it
// is no speech, and no second recognition runs next to the newer press's recognizer).
- (void)finishSupersededDictationOnDevice:(GFDictation *)d {
    if (d.finished) return;
    NSString *text = d.onDeviceText ?: @"";
    if (!self.unitTestMode) {
        GFLog(@"Dictation #%lu: on-device fallback from its snapshot (%lu chars, %.2fs audio; a newer press is active)",
              (unsigned long)d.serial, (unsigned long)text.length, d.pcm.length / 32000.0);
    }
    if (text.length > 0) {
        [self applyFinalTranscript:[self polishOnDeviceTranscript:text] dictation:d];
        return;
    }
    GFSpeechEvidence ev = GFMeasureSpeechEvidence((const int16_t *)d.pcm.bytes, d.pcm.length / 2);
    if (ev.loudSeconds <= kNoSpeechMaxLoudSeconds || GFNoLoudSpeech(ev.peakRMS, ev.evidenceSeconds)) {
        [self showNoSpeechDetectedForDictation:d];
        return;
    }
    [self fallbackToWAVURLRecognitionForDictation:d];
}

- (void)fallbackToWAVURLRecognitionForDictation:(GFDictation *)dictation {
    NSData *pcm = [self pcmForDictation:dictation];
    if (pcm.length > 3200 && self.speechRecognizer) { // at least 0.1s of audio
        NSData *wavData = [self createWavDataFromPCM:pcm];
        double seconds = pcm.length / 32000.0;
        // Private temp file (0600, per-user temp dir), deleted when the recognition ends (backlog 8)
        BOOL started = GFWithTempAudioFile(wavData, ^(NSString *tmpPath, dispatch_block_t done) {
            if (!self.unitTestMode) GFLog(@"WAV fallback: recognizing %.2fs of audio from a private temp file: %@", seconds, tmpPath);
            // Backstop if the recognizer never calls back: the file must not stay on disk (the next launch also sweeps it)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(GFTempAudioBackstopSeconds(seconds) * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), done);
            [self recognizeWAVFileAtPath:tmpPath seconds:seconds dictation:dictation done:done];
        });
        if (started) return;
        GFLog(@"WAV fallback: could not write the private temp file (errno %d)", errno);
    }

    [self showNoSpeechDetectedForDictation:dictation];
}

// Ends exactly once, on main: the final result, an error, or the watchdog (backlog 9). Every end deletes the temp file first.
- (void)recognizeWAVFileAtPath:(NSString *)tmpPath seconds:(double)seconds dictation:(GFDictation *)dictation done:(dispatch_block_t)done {
    NSURL *fileUrl = [NSURL fileURLWithPath:tmpPath];
    SFSpeechURLRecognitionRequest *urlReq = [[SFSpeechURLRecognitionRequest alloc] initWithURL:fileUrl];
    urlReq.taskHint = SFSpeechRecognitionTaskHintDictation;
    if (@available(macOS 13.0, *)) {
        urlReq.addsPunctuation = YES;
    }
    if (self.speechRecognizer.supportsOnDeviceRecognition) {
        urlReq.requiresOnDeviceRecognition = YES;
    }

    __weak typeof(self) weakSelf = self;
    GFWavWatchdog *watchdog = [[GFWavWatchdog alloc] initWithLimit:GFWavWatchdogLimit(seconds) quiet:kGFWavWatchdogQuietSeconds
                                                               cap:GFTempAudioBackstopSeconds(seconds)];
    // Test hook (e2e only): "final" = the final result only counts as progress and errors are dropped (the recognizer
    // transcribed but never says it is done); "all" = every callback is dropped (it never answers at all).
    NSString *hang = self.e2eMode.length > 0 ? self.e2eWavHang : nil;
    if (hang.length > 0) GFLog(@"E2E: the WAV recognizer never ends (%@)", hang);

    void (^handle)(SFSpeechRecognitionResult *, NSError *) = ^(SFSpeechRecognitionResult *result, NSError *error) {
        if (watchdog.ended) return;
        if ([hang isEqualToString:@"all"]) return;
        BOOL hangFinal = [hang isEqualToString:@"final"];
        if (result && !(result.isFinal && !hangFinal) && !(error && !hangFinal)) { // a partial result: still progressing
            [watchdog noteProgress:result.bestTranscription.formattedString];
            return;
        }
        if (result && result.isFinal) {
            if (![watchdog end]) return;
            done(); // recognition finished: the audio file is no longer needed
            NSString *finalStr = [result.bestTranscription.formattedString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (finalStr.length > 0) {
                [weakSelf applyFinalTranscript:[weakSelf polishOnDeviceTranscript:finalStr] dictation:dictation];
            } else {
                [weakSelf showNoSpeechDetectedForDictation:dictation];
            }
        } else if (error && !hangFinal) {
            if (![watchdog end]) return;
            done();
            GFLog(@"On-device URL recognition error: %@ (domain=%@ code=%ld)", error.localizedDescription, error.domain, (long)error.code);
            [weakSelf showNoSpeechDetectedForDictation:dictation];
        }
    };
    id task = [self.speechRecognizer recognitionTaskWithRequest:urlReq resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ handle(result, error); }); // all state on main (as delivery always was)
    }];
    watchdog.task = task;
    [watchdog startWithExpiry:^(GFWavWatchdog *w, NSTimeInterval elapsed) {
        // Give up on the recognizer: cancel it (its late callbacks are ignored), delete the audio, deliver what it heard so far.
        [task cancel];
        done();
        NSString *partial = [w.partialText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        GFLog(@"WAV fallback: no final result after %.1fs (limit %.1fs for %.2fs audio, %lu partial results); ending with %lu chars",
              elapsed, w.limit, seconds, (unsigned long)w.progressCount, (unsigned long)partial.length);
        if (partial.length > 0) {
            [weakSelf applyFinalTranscript:[weakSelf polishOnDeviceTranscript:partial] dictation:dictation];
        } else {
            [weakSelf showNoSpeechDetectedForDictation:dictation];
        }
    }];
}

- (void)showNoSpeechDetected {
    [self showNoSpeechDetectedForDictation:nil];
}

- (void)showNoSpeechDetectedForDictation:(GFDictation *)d {
    if (d.earlyText) { [self resolveEarlyPastedDictation:d geminiText:nil]; return; } // its on-device text was delivered early
    if (d.superseded && d.finished) return; // already ended
    d.finished = YES;
    if (self.resultSink) { self.resultSink(nil, d ?: self.activeDictation); return; }
    if (self.e2eCompletion) {
        void (^done)(NSString *) = self.e2eCompletion;
        self.e2eCompletion = nil;
        done(@"<NO SPEECH>");
        return;
    }
    if (d.superseded) { // a newer press owns the HUD and icon (recording or Thinking): nothing to show for the old one
        if (!self.unitTestMode) GFLog(@"Dictation #%lu: no speech (a newer press keeps the HUD)", (unsigned long)d.serial);
        return;
    }
    [self returnToIdleWithStatusTitle:nil notice:@"No speech" mode:HUDModeNotice dismissAfter:1.0];
}

#pragma mark - Auto-Paste & History

- (void)applyFinalTranscript:(NSString *)text {
    [self applyFinalTranscript:text dictation:nil];
}

// Delivers a dictation (nil = the current one). A superseded dictation (a newer press started before it finished) is still
// delivered in full: clipboard, Recent Dictations and auto-paste, in the order the results arrive, but the newer press's HUD and
// menu icon are left alone and no Accessibility prompt is shown over it (backlog 6).
- (void)applyFinalTranscript:(NSString *)text dictation:(GFDictation *)d {
    if (d.earlyText) { [self resolveEarlyPastedDictation:d geminiText:text]; return; } // bounded wait: delivered early already
    // spaces/tabs only: polish never returns bare newlines except for a press that was only "new line" / "new paragraph"
    if ([text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].length == 0) {
        // Nothing left after polish (e.g. the user only said "um"): end the dictation instead of leaving the HUD
        // shimmering in "Thinking" (60 fps timer) and the menu icon in the thinking state.
        if (!self.unitTestMode) GFLog(@"applyFinalTranscript: empty after polish; returning to idle");
        [self showNoSpeechDetectedForDictation:d];
        return;
    }
    if (d.superseded && d.finished) { // never deliver one dictation twice
        if (!self.unitTestMode) GFLog(@"Dictation #%lu: dropped a second result (already delivered)", (unsigned long)d.serial);
        return;
    }
    d.finished = YES;
    if (!self.unitTestMode) {
        if (d.superseded) GFLog(@"applyFinalTranscript: %lu chars (dictation #%lu, delivered while a newer press is active)",
                                (unsigned long)text.length, (unsigned long)d.serial);
        else GFLog(@"applyFinalTranscript: %lu chars", (unsigned long)text.length);
    }
    if (self.resultSink) { self.resultSink(text, d ?: self.activeDictation); return; } // tests: no clipboard / paste

    if (self.e2eCompletion) { // test mode: report instead of touching clipboard / pasting
        void (^done)(NSString *) = self.e2eCompletion;
        self.e2eCompletion = nil;
        done(text);
        return;
    }

    // Add to recent dictations
    [self.recentDictations insertObject:text atIndex:0];
    if (self.recentDictations.count > 5) {
        [self.recentDictations removeLastObject];
    }
    [self updateRecentSubmenu];

    BOOL trusted = AXIsProcessTrusted();
    // Menu icon back to idle and HUD dismissed on BOTH paths (the clipboard-only path used to leave the icon "thinking")
    [self showDeliveredUIAccessibilityTrusted:trusted dictation:d];
    if (!trusted) {
        if (!self.pasteInFlight) [self setClipboardText:text]; // clipboard-only delivery
        if (d.superseded) return; // copied + in Recent Dictations; don't pop the Accessibility prompt over the newer press
        GFLog(@"Accessibility not trusted for current build. Prompting user...");
        NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
        return;
    }

    // Clipboard + simulated Cmd+V into the frontmost app, in delivery order (an idle queue pastes right away, as before)
    [self requestPasteOfText:text dictation:d];
}

- (NSMutableArray<NSString *> *)deferredPastes { if (!_deferredPastes) _deferredPastes = [NSMutableArray array]; return _deferredPastes; }
- (NSMutableArray<NSString *> *)pasteQueue { if (!_pasteQueue) _pasteQueue = [NSMutableArray array]; return _pasteQueue; }
- (NSMutableArray<NSString *> *)pasteLog { if (!_pasteLog) _pasteLog = [NSMutableArray array]; return _pasteLog; }

- (void)setClipboardText:(NSString *)text {
    if (self.unitTestMode) { self.testClipboard = text; return; }
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:text forType:NSPasteboardTypeString];
}

// A superseded dictation that finishes while the newer press is still RECORDING goes on the clipboard (and Recent Dictations) now,
// but its auto-paste waits for that press's release or Esc, and then runs before the newer press's own text. Pasting mid-recording
// could land in a field the user already left, fires Cmd+V while Fn is physically held, and makes text appear mid-dictation.
// If nothing is recording, it pastes right away (after anything already queued).
- (void)requestPasteOfText:(NSString *)text dictation:(GFDictation *)d {
    if (d.superseded && self.isRecording) {
        if (!self.pasteInFlight) [self setClipboardText:text];
        [self.deferredPastes addObject:text];
        if (!self.unitTestMode) GFLog(@"Dictation #%lu: copied; auto-paste deferred until the newer press is released", (unsigned long)d.serial);
        return;
    }
    [self enqueuePaste:text];
}

// Called when the newer press is released or cancelled: paste the deferred dictations first, in order.
- (void)flushDeferredPastes {
    if (_deferredPastes.count == 0) return;
    if (!self.unitTestMode) GFLog(@"Pasting %lu deferred dictation(s) before the newer press's text", (unsigned long)_deferredPastes.count);
    NSArray<NSString *> *pending = [_deferredPastes copy];
    [_deferredPastes removeAllObjects];
    for (NSString *t in pending) [self enqueuePaste:t];
}

- (void)enqueuePaste:(NSString *)text {
    [self.pasteQueue addObject:text];
    if (!self.pasteInFlight) [self pumpPasteQueue];
}

// One paste at a time: clipboard, Cmd+V 0.12 s later (unchanged timing), then 0.25 s for the target app to read the pasteboard
// before the next item may replace it.
- (void)pumpPasteQueue {
    if (self.pasteQueue.count == 0) { self.pasteInFlight = NO; return; }
    self.pasteInFlight = YES;
    NSString *text = self.pasteQueue.firstObject;
    [self.pasteQueue removeObjectAtIndex:0];
    [self setClipboardText:text];
    if (self.unitTestMode) [self.pasteLog addObject:text];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!strongSelf.unitTestMode) {
            [strongSelf pasteViaAccessibility];
            GFDictation *ed = strongSelf.earlyWatchDictation; // bounded wait: remember where the early on-device text went
            if (ed && ed.earlyText == text && ed.earlyPasteTime == 0) {
                ed.earlyPasteTime = [NSDate timeIntervalSinceReferenceDate];
                ed.earlyPid = [NSWorkspace sharedWorkspace].frontmostApplication.processIdentifier;
                ed.earlyElement = GFCopyFocusedElement();
                GFLog(@"Early paste: on-device text pasted (dictation #%lu, focused field %@)", (unsigned long)ed.serial,
                      ed.earlyElement ? @"known" : @"unknown");
            }
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf pumpPasteQueue];
        });
    });
}

- (void)pasteViaAccessibility {
    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
    CGKeyCode vKey = (CGKeyCode)0x09; // 'v' key

    CGEventRef keyDown = CGEventCreateKeyboardEvent(src, vKey, true);
    CGEventSetFlags(keyDown, kCGEventFlagMaskCommand);

    CGEventRef keyUp = CGEventCreateKeyboardEvent(src, vKey, false);
    CGEventSetFlags(keyUp, kCGEventFlagMaskCommand);
    CGEventSetIntegerValueField(keyDown, kCGEventSourceUserData, kGFSyntheticEventTag); // not user input (bounded-wait swap)
    CGEventSetIntegerValueField(keyUp, kCGEventSourceUserData, kGFSyntheticEventTag);

    CGEventPost(kCGHIDEventTap, keyDown);
    usleep(20000); // 20ms hold so Chrome/Docs/Slack register the keystroke
    CGEventPost(kCGHIDEventTap, keyUp);

    CFRelease(keyDown);
    CFRelease(keyUp);
    if (src) CFRelease(src);
}

- (void)updateRecentSubmenu {
    [self.recentSubmenu removeAllItems];
    if (self.recentDictations.count == 0) {
        NSMenuItem *none = [[NSMenuItem alloc] initWithTitle:@"No recent dictations" action:nil keyEquivalent:@""];
        [none setEnabled:NO];
        [self.recentSubmenu addItem:none];
        return;
    }

    for (NSUInteger i = 0; i < self.recentDictations.count; i++) {
        NSString *fullText = self.recentDictations[i];
        NSString *preview = [fullText stringByReplacingOccurrencesOfString:@"\n" withString:@"\u21B5"]; // keep the menu item one line
        if (preview.length > 45) {
            preview = [[preview substringToIndex:45] stringByAppendingString:@"..."];
        }
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%lu. %@", (unsigned long)(i + 1), preview]
                                                      action:@selector(copyRecentDictation:)
                                               keyEquivalent:@""];
        item.representedObject = fullText;
        [self.recentSubmenu addItem:item];
    }
}

- (void)copyRecentDictation:(NSMenuItem *)sender {
    NSString *text = sender.representedObject;
    if (text) {
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb setString:text forType:NSPasteboardTypeString];

        if (self.isRecording) return; // copied; don't cover a recording's HUD
        [self.hudPanel setHUDMode:HUDModeSuccess noticeText:@"Copied"];
        [self presentHUD];
        [self dismissHUDAfterDelay:0.9];
    }
}

- (void)showPermissionsWindow {
    BOOL micAllowed = YES;
    if (@available(macOS 10.14, *)) {
        AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
        micAllowed = (status == AVAuthorizationStatusAuthorized);
    }
    BOOL axAllowed = AXIsProcessTrusted();

    NSString *msg = [NSString stringWithFormat:
        @"GeminiFlow Status:\n\n"
        @"1. Microphone Access: %@\n"
        @"   (Needed to hear your voice when holding Fn)\n\n"
        @"2. Accessibility Auto-Paste: %@\n"
        @"   (Needed to paste text automatically at your cursor)\n\n"
        @"Tip: In System Settings > Keyboard, setting 'Press fn key to: Do Nothing' gives the smoothest Fn hotkey experience.",
        micAllowed ? @"Granted" : @"Not Granted (Check Privacy & Security > Microphone)",
        axAllowed ? @"Granted" : @"Not Granted (Check Privacy & Security > Accessibility)"];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Permissions & Keyboard Tips";
    alert.informativeText = msg;
    [alert addButtonWithTitle:@"Open Microphone Settings"];
    [alert addButtonWithTitle:@"Open Accessibility Settings"];
    [alert addButtonWithTitle:@"Open Keyboard Settings"];

    [NSApp activateIgnoringOtherApps:YES];
    NSModalResponse resp = [alert runModal];
    if (resp == NSAlertFirstButtonReturn) {
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"]];
    } else if (resp == NSAlertSecondButtonReturn) {
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
    } else if (resp == NSAlertThirdButtonReturn) {
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.Keyboard-Settings.extension"]];
    }
}

- (void)quitApp {
    [NSApp terminate:nil];
}

// Replays a recognizer event trace (from the test harness) through the real accumulation + polish code.
// Line format: [  4.07] partial meta=1 ... "text"   |   [ 11.37] --- Fn released: endAudio ---
- (int)runReplayOfTrace:(NSString *)path expected:(NSString *)expected {
    NSString *log = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!log) { printf("cannot read %s\n", path.UTF8String); return 2; }
    NSRegularExpression *evRe = [NSRegularExpression regularExpressionWithPattern:@"^\\[\\s*([0-9.]+)\\] (partial|FINAL)\\s+meta=(\\d).*?\"(.*)\"\\s*$" options:0 error:nil];
    NSRegularExpression *endRe = [NSRegularExpression regularExpressionWithPattern:@"^\\[\\s*([0-9.]+)\\] --- Fn released" options:0 error:nil];

    self.committedOnDeviceTranscript = [NSMutableString string];
    self.currentOnDeviceSegment = @"";
    self.lastCommittedOnDeviceSegment = nil;
    self.latestOnDeviceTranscript = @"";
    self.latestOnDeviceIsFinal = NO;
    NSString *oldLatest = @"";
    double endAt = -1;
    NSString *oldAtCancel = nil;

    for (NSString *line in [log componentsSeparatedByString:@"\n"]) {
        NSString *l = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSTextCheckingResult *em = [endRe firstMatchInString:l options:0 range:NSMakeRange(0, l.length)];
        if (em) { endAt = [[l substringWithRange:[em rangeAtIndex:1]] doubleValue]; continue; }
        NSTextCheckingResult *m = [evRe firstMatchInString:l options:0 range:NSMakeRange(0, l.length)];
        if (!m) continue;
        double t = [[l substringWithRange:[m rangeAtIndex:1]] doubleValue];
        BOOL fin = [[l substringWithRange:[m rangeAtIndex:2]] isEqualToString:@"FINAL"];
        BOOL meta = [[l substringWithRange:[m rangeAtIndex:3]] isEqualToString:@"1"];
        NSString *text = [l substringWithRange:[m rangeAtIndex:4]];
        // OLD app: keeps only the latest text, cancels 0.16 s after release (+0.12 s cushion before release)
        if (endAt >= 0 && !oldAtCancel && t > endAt + 0.16) oldAtCancel = oldLatest;
        if (text.length) oldLatest = text;
        // NEW app: events arriving within the 1.5 s finalization window are honoured
        if (endAt >= 0 && t > endAt + 1.5) break;
        [self handleOnDeviceText:text utteranceEnded:meta isFinal:fin];
        if (fin) break;
    }
    if (!oldAtCancel) oldAtCancel = oldLatest;
    [self commitCurrentOnDeviceSegment];
    [self refreshAccumulatedOnDeviceTranscript];

    NSString *oldOut = [[self polishOnDeviceTranscript:oldAtCancel] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *newOut = [[self polishOnDeviceTranscript:self.latestOnDeviceTranscript] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    printf("OLD: \"%s\"\nNEW: \"%s\"\n", oldOut.UTF8String, newOut.UTF8String);
    if (expected.length) {
        // Word-recall vs the script (case/punctuation-insensitive)
        NSCharacterSet *sep = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
        NSArray *(^words)(NSString *) = ^NSArray *(NSString *s) {
            NSMutableArray *w = [NSMutableArray array];
            for (NSString *p in [[s lowercaseString] componentsSeparatedByCharactersInSet:sep]) if (p.length) [w addObject:p];
            return w;
        };
        double (^recall)(NSString *) = ^double(NSString *out) {
            NSMutableArray *pool = [words(out) mutableCopy];
            NSArray *exp = words(expected);
            NSUInteger hit = 0;
            for (NSString *w in exp) { NSUInteger i = [pool indexOfObject:w]; if (i != NSNotFound) { hit++; [pool removeObjectAtIndex:i]; } }
            return exp.count ? (double)hit / exp.count : 0;
        };
        printf("RECALL old=%.0f%% new=%.0f%%\n", recall(oldOut) * 100, recall(newOut) * 100);
    }
    return 0;
}

- (int)runBuiltInTestSuite {
    @autoreleasepool {
        NSArray *cases = @[
            // --- SHOULD REMOVE "LIKE" (FILLERS) ---
            @[@"Like I was thinking about the project", @"I was thinking about the project."],
            @[@"like, we should probably meet tomorrow", @"We should probably meet tomorrow."],
            @[@"Um like what time works for you", @"What time works for you?"],
            @[@"I was like really surprised by that", @"I was really surprised by that."],
            @[@"It's like super fast now", @"It's super fast now."],
            @[@"And like we decided to ship it", @"And we decided to ship it."],
            @[@"So like why did it fail", @"So why did it fail?"],
            @[@"We have, like, ten minutes left", @"We have ten minutes left."],
            @[@"We have like ten minutes left", @"We have ten minutes left."],
            @[@"I was thinking like maybe we could wait", @"I was thinking maybe we could wait."],
            @[@"We should like definitely check the logs", @"We should definitely check the logs."],
            @[@"He was like totally fine with it", @"He was totally fine with it."],
            @[@"I'm like so tired today", @"I'm so tired today."],
            @[@"Can you like send me the link", @"Can you send me the link?"],
            @[@"I need to like finish this doc first", @"I need to finish this doc first."],
            @[@"Going to like grab some coffee", @"Going to grab some coffee."],
            @[@"I want to like make sure it works", @"I want to make sure it works."],
            @[@"Wait. Like I didn't mean that.", @"Wait. I didn't mean that."],
            @[@"It works well, and like, it's fast", @"It works well, and it's fast."],
            @[@"You know, like, I mean, it sort of works", @"It sort of works."], // backlog 0i (user-approved): a plain hedge stays
            @[@"Wait, like what are you talking about", @"Wait, what are you talking about?"],
            @[@"I like, really like this", @"I really like this."],
            @[@"What do you like, think about it", @"What do you think about it?"],
            @[@"It's like, you know, complicated", @"It's complicated."],
            @[@"Do you like, um, coffee", @"Do you like coffee?"],

            // --- SHOULD KEEP "LIKE" (REAL VERBS / COMPARISONS / PREPOSITIONS / QUOTATIVES) ---
            @[@"I like the new design", @"I like the new design."],
            @[@"Do you like how this looks", @"Do you like how this looks?"],
            @[@"I would like to schedule a call", @"I would like to schedule a call."],
            @[@"She likes coffee, and like me, she drinks it black", @"She likes coffee, and like me, she drinks it black."],
            @[@"Apps, like Slack and Notion, are useful", @"Apps, like Slack and Notion, are useful."],
            @[@"Cities, like Tokyo, are huge", @"Cities, like Tokyo, are huge."],
            @[@"It looks like rain today", @"It looks like rain today."],
            @[@"That sounds like a great idea", @"That sounds like a great idea."],
            @[@"It feels like summer outside", @"It feels like summer outside."],
            @[@"Like a boss, he handled it", @"Like a boss, he handled it."],
            @[@"Like last year, we hit our goals", @"Like last year, we hit our goals."],
            @[@"What is it like over there", @"What is it like over there?"],
            @[@"Tell me what you like most", @"Tell me what you like most."],
            @[@"I really like how smooth it is", @"I really like how smooth it is."],
            @[@"They didn't like the first version", @"They didn't like the first version."],
            @[@"I was like wait a second", @"I was like wait a second."]
        ];

        int passed = 0;
        int failed = 0;
        for (NSArray *tc in cases) {
            NSString *inp = tc[0];
            NSString *exp = tc[1];
            NSString *actual = [self polishOnDeviceTranscript:inp];
            NSString *trimmed = [actual stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            BOOL isPass = [trimmed isEqualToString:exp] && [actual hasSuffix:@" "];
            if (isPass) {
                passed++;
                printf("PASS: \"%s\" -> \"%s\"\n", [inp UTF8String], [actual UTF8String]);
            } else {
                failed++;
                printf("FAIL: \"%s\"\n  Expected: \"%s\"\n  Actual:   \"%s\"\n", [inp UTF8String], [exp UTF8String], [actual UTF8String]);
            }
        }
        // Spoken "new line" / "new paragraph" (backlog 4): exact output, including the trailing space (none after a line break).
        // Shown with "\n" escaped so each case prints on one line.
        NSArray *breakCases = @[
            // --- should NOT trigger: other words, plural, determiner, "of" ---
            @[@"the new lineup", @"The new lineup. "],
            @[@"a new linear model", @"A new linear model. "],
            @[@"newline character", @"Newline character. "],
            @[@"new lines of code", @"New lines of code. "],
            @[@"We launched a new line of products", @"We launched a new line of products. "],
            @[@"The new paragraph reads better", @"The new paragraph reads better. "],
            @[@"there is no new line at the end", @"There is no new line at the end. "],
            @[@"Renew line items today", @"Renew line items today. "],
            @[@"new paragraphs are easier to read", @"New paragraphs are easier to read. "],
            // --- should trigger ---
            @[@"first point new line second point", @"First point\nSecond point. "],
            @[@"end of section. New paragraph. Next section", @"End of section.\n\nNext section. "],
            @[@"New Line hello there", @"\nHello there. "],
            @[@"Item one NEW LINE item two", @"Item one\nItem two. "],
            @[@"Hi Sam, new line thanks for the update", @"Hi Sam,\nThanks for the update. "],
            @[@"Write it down new line", @"Write it down\n"],
            @[@"Write it down. New paragraph.", @"Write it down.\n\n"],
            @[@"new line", @"\n"],
            @[@"New paragraph.", @"\n\n"],
            @[@"first point new line what time is it", @"First point\nWhat time is it? "],
            @[@"um first point new line uh second point", @"First point\nSecond point. "],
            @[@"one new line two new line three", @"One\nTwo\nThree "],
            @[@"x new line new line y", @"X\n\nY "],
            @[@"done new line, of course we ship it", @"Done\nOf course we ship it. "],
            @[@"line one new line new lines of code follow", @"Line one\nNew lines of code follow. "],
        ];
        for (NSArray *tc in breakCases) {
            NSString *actual = [self polishOnDeviceTranscript:tc[0]];
            BOOL ok = [actual isEqualToString:tc[1]];
            if (ok) passed++; else failed++;
            NSString *(^esc)(NSString *) = ^NSString *(NSString *t) { return [t stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"]; };
            if (ok) printf("PASS: spoken line break: \"%s\" -> \"%s\"\n", [tc[0] UTF8String], [esc(actual) UTF8String]);
            else printf("FAIL: spoken line break: \"%s\"\n  Expected: \"%s\"\n  Actual:   \"%s\"\n", [tc[0] UTF8String],
                        [esc(tc[1]) UTF8String], [esc(actual) UTF8String]);
        }
        // Text-polish correctness (backlog 17): exact output including the trailing space.
        NSArray *polishCases = @[
            // --- pronoun "i" only: not abbreviations, paths, filenames, code-ish tokens ---
            @[@"use a short name, i.e. the first word", @"Use a short name, i.e. the first word. "],
            @[@"bring snacks, e.g. chips and fruit", @"Bring snacks, e.g. chips and fruit. "],
            @[@"he needs an i.v. drip now", @"He needs an i.v. drip now. "],
            @[@"i think i'm ready and i'll call, i've said i'd do it", @"I think I'm ready and I'll call, I've said I'd do it. "],
            @[@"so do i", @"So do I. "],
            @[@"and then i.", @"And then I. "],
            @[@"i\u2019m sure i\u2019ll be there", @"I\u2019m sure I\u2019ll be there. "],
            @[@"open config_i.txt or i.txt now", @"Open config_i.txt or i.txt now. "],
            @[@"the path is /usr/i/bin and wi-fi works", @"The path is /usr/i/bin and wi-fi works. "],
            @[@"check the i/o stats, then i will fix it", @"Check the i/o stats, then I will fix it. "],
            @[@"first point new line i will call", @"First point\nI will call. "],
            // --- capitalization after punctuation: abbreviations, decimals, ?/!, mixed-case words ---
            @[@"meet me at 9 a.m. tomorrow", @"Meet me at 9 a.m. tomorrow. "],
            @[@"we meet at 5 p.m. on Friday", @"We meet at 5 p.m. on Friday. "],
            @[@"bring pens, paper, etc. and a laptop", @"Bring pens, paper, etc. and a laptop. "],
            @[@"the rate is 3.5 percent. that is fine", @"The rate is 3.5 percent. That is fine. "],
            @[@"really? yes! it works", @"Really? Yes! It works. "],
            @[@"it works. then we ship", @"It works. Then we ship. "],
            @[@"iPhone sales are up", @"iPhone sales are up. "],
            @[@"it works. iOS is next", @"It works. iOS is next. "],
            @[@"it broke. example.com is down", @"It broke. example.com is down. "],
            @[@"the U.S. team won", @"The U.S. team won. "],
            @[@"we leave at 5 p.m. Then we eat", @"We leave at 5 p.m. Then we eat. "],
            @[@"version 2.0 ships today. great", @"Version 2.0 ships today. Great. "],
            // --- spacing around punctuation ---
            @[@"we are done .", @"We are done. "],
            @[@"wait , what is that", @"Wait, what is that? "],
            @[@"it ends , right", @"It ends, right. "],
            @[@"add the file .env to git", @"Add the file .env to git. "],
            // --- vocal fillers: hyphenated interjections stay whole ---
            @[@"uh-huh, that works", @"Uh-huh, that works. "],
            @[@"mm-hmm sounds good", @"Mm-hmm sounds good. "],
            @[@"uh-oh the build broke", @"Uh-oh the build broke. "],
            @[@"uh we should go", @"We should go. "],
            @[@"so, um, we ship it", @"So we ship it. "],
            @[@"Ah, I see the problem", @"I see the problem. "],
            @[@"hmm let me think", @"Let me think. "],
            // --- stutters still removed ---
            @[@"I I think we should go", @"I think we should go. "],
            @[@"the the build is green", @"The build is green. "],
            @[@"we we shipped it", @"We shipped it. "],
            @[@"the the the end is near", @"The end is near. "],
            @[@"i i i think so", @"I think so. "],
            @[@"it it's broken", @"It's broken. "],
            @[@"The the build is green", @"The build is green. "],
            @[@"a a big deal", @"A big deal. "],
            @[@"we went to to the store", @"We went to the store. "],
            // --- grammatical doubles kept ---
            @[@"She had had enough", @"She had had enough. "],
            @[@"I think that that is fine", @"I think that that is fine. "],
            @[@"I know that that's true", @"I know that that's true. "],
            @[@"The thing is, is that it works", @"The thing is, is that it works. "],
            @[@"The thing is is that it works", @"The thing is is that it works. "],
            @[@"They do do their homework", @"They do do their homework. "],
            @[@"All it was was a mistake", @"All it was was a mistake. "],
            @[@"I gave her her keys", @"I gave her her keys. "],
            @[@"It was very very good", @"It was very very good. "],
            @[@"Call five five five one two one two", @"Call five five five one two one two. "],
            @[@"We flew to Bora Bora last year", @"We flew to Bora Bora last year. "],
            // --- phrase stutters collapse (backlog 0x): the user's examples ---
            @[@"I'm so happy with my with my new dictation app", @"I'm so happy with my new dictation app. "],
            @[@"It happens when I When I, for example, pause mid-thought", @"It happens when I, for example, pause mid-thought. "],
            @[@"and then I would I would repeat the same phrase", @"And then I would repeat the same phrase. "],
            @[@"let's say, will do will do to show up two times", @"Let's say, will do to show up two times. "],
            @[@"I also want you to give some I also want you to give periodic updates", @"I also want you to give periodic updates. "],
            // --- phrase stutters collapse: comma, filler or dash at the pause ---
            @[@"I'm so happy with my, with my new dictation app", @"I'm so happy with my new dictation app. "],
            @[@"I'm so happy with my, um, with my new dictation app", @"I'm so happy with my new dictation app. "],
            @[@"I'm so happy with my uh with my new dictation app", @"I'm so happy with my new dictation app. "],
            @[@"I'm so happy with my, you know, with my new dictation app", @"I'm so happy with my new dictation app. "],
            @[@"I'm so happy with my \u2014 with my new dictation app", @"I'm so happy with my new dictation app. "],
            @[@"I think, I think we should go", @"I think we should go. "],
            @[@"I would, I would repeat it", @"I would repeat it. "],
            @[@"can you, can you send it", @"Can you send it? "],
            @[@"and then, and then we left", @"And then we left. "],
            @[@"we're going to, we're going to ship it", @"We're going to ship it. "],
            @[@"I'm not, I'm not sure", @"I'm not sure. "],
            @[@"this is a, this is a test", @"This is a test. "],
            @[@"I'm, I'm not sure", @"I'm not sure. "],
            // --- phrase stutters collapse: three copies, capitalized restarts, long phrases ---
            @[@"I'm so happy with my with my with my new dictation app", @"I'm so happy with my new dictation app. "],
            @[@"I'm so happy with my, with my, with my new dictation app", @"I'm so happy with my new dictation app. "],
            @[@"with my with my, with my new app", @"With my new app. "],
            @[@"I want you to I want you to I want you to check it", @"I want you to check it. "],
            @[@"I'm so happy with my With my new dictation app", @"I'm so happy with my new dictation app. "],
            @[@"So I So I went home", @"So I went home. "],
            @[@"But when I when I pause, it repeats", @"But when I pause, it repeats. "],
            @[@"we went to the we went to the store", @"We went to the store. "],
            @[@"so I think we should I think we should ship it", @"So I think we should ship it. "],
            @[@"I don\u2019t know I don't know what happened", @"I don\u2019t know what happened. "],
            @[@"it's going to it's going to work", @"It's going to work. "],
            @[@"So what I want to say is that what I want to say is that it works", @"So what I want to say is that it works. "],
            @[@"I was going to I was going to say something", @"I was going to say something. "],
            // --- phrase stutters collapse: short everyday restarts ---
            @[@"the build the build is green", @"The build is green. "],
            @[@"the the build the build is green", @"The build is green. "],
            @[@"I I would I would go", @"I would go. "],
            @[@"to the to the the store", @"To the store. "],
            @[@"and then I and then I went home", @"And then I went home. "],
            @[@"I want to go to go to the store", @"I want to go to the store. "],
            @[@"if you if you want", @"If you want. "],
            @[@"so that so that we can ship", @"So that we can ship. "],
            @[@"is that the is that the right one", @"Is that the right one? "],
            @[@"one more one more thing", @"One more thing. "],
            @[@"Sounds good will do will do", @"Sounds good will do. "],
            @[@"I know I know it's late", @"I know it's late. "],
            @[@"I know I know, I know", @"I know, I know. "],
            @[@"I would I would I think repeat it", @"I would I think repeat it. "],
            @[@"a lot of a lot of people came", @"A lot of people came. "],
            @[@"one of the one of the tests failed", @"One of the tests failed. "],
            @[@"one of one of the tests failed", @"One of the tests failed. "],
            @[@"most of the of the tests pass", @"Most of the tests pass. "],
            @[@"of course of course we can", @"Of course we can. "],
            @[@"because of because of the delay", @"Because of the delay. "],
            @[@"it was caused by caused by a bug", @"It was caused by a bug. "],
            @[@"it is based on based on the log", @"It is based on the log. "],
            @[@"I was looking for looking for the file", @"I was looking for the file. "],
            // --- phrase stutters collapse: repeated contractions ---
            @[@"I'm I'm not sure", @"I'm not sure. "],
            @[@"we're we're done", @"We're done. "],
            @[@"don't don't touch it", @"Don't touch it. "],
            @[@"It's it's it's broken", @"It's broken. "],
            // --- mid-thought restarts collapse: one aborted word between the copies ---
            @[@"I'm going to the I'm going to a store", @"I'm going to a store. "],
            @[@"I'm going to the, I'm going to a store", @"I'm going to a store. "],
            @[@"we need to fix the We need to fix this bug", @"We need to fix this bug. "],
            @[@"I want you to send my I want you to send our report", @"I want you to send our report. "],
            @[@"we want to see every we want to see all users", @"We want to see all users. "],
            // --- repeated phrases kept: one word many times, numbers, spelled letters, symbols, names ---
            @[@"she said no no no no", @"She said no no no no. "],
            @[@"it was very very very very good", @"It was very very very very good. "],
            @[@"mic check one two one two", @"Mic check one two one two. "],
            @[@"Count one two three one two three", @"Count one two three one two three. "],
            @[@"It cost two thousand two thousand", @"It cost two thousand two thousand. "],
            @[@"Spell it A B A B", @"Spell it A B A B. "],
            @[@"They chant U S A U S A", @"They chant U S A U S A. "],
            @[@"cd dot slash dot slash", @"Cd dot slash dot slash. "],
            @[@"New York, New York is a song", @"New York, New York is a song. "],
            @[@"New York New York is a hotel", @"New York New York is a hotel. "],
            @[@"I met John Smith John Smith was there", @"I met John Smith John Smith was there. "],
            @[@"O'Brien O'Brien called", @"O'Brien O'Brien called. "],
            // --- repeated phrases kept: idioms built on a connective ---
            @[@"again and again and again", @"Again and again and again. "],
            @[@"it gets more and more and more complex", @"It gets more and more and more complex. "],
            @[@"we did it over and over and over again", @"We did it over and over and over again. "],
            @[@"it goes on and on and on", @"It goes on and on and on. "],
            @[@"step by step by step", @"Step by step by step. "],
            @[@"side by side by side", @"Side by side by side. "],
            @[@"day after day after day", @"Day after day after day. "],
            @[@"year after year after year", @"Year after year after year. "],
            @[@"he ran and ran and ran", @"He ran and ran and ran. "],
            @[@"again, and again and again", @"Again, and again and again. "],
            @[@"back to back to back", @"Back to back to back. "],
            @[@"two plus two plus two", @"Two plus two plus two. "],
            @[@"you and you and you", @"You and you and you. "],
            @[@"it rained and it rained and it rained", @"It rained and it rained and it rained. "],
            @[@"We stayed home and it rained and it rained and it rained", @"We stayed home and it rained and it rained and it rained. "],
            @[@"I tried and I tried and then I gave up", @"I tried and I tried and then I gave up. "],
            @[@"and so on and so on", @"And so on and so on. "],
            @[@"et cetera et cetera", @"Et cetera et cetera. "],
            @[@"back and forth back and forth", @"Back and forth back and forth. "],
            @[@"tick tock tick tock", @"Tick tock tick tock. "],
            @[@"one after another after another", @"One after another after another. "],
            @[@"I read it from time to time to refresh my memory", @"I read it from time to time to refresh my memory. "],
            @[@"we met face to face to discuss it", @"We met face to face to discuss it. "],
            @[@"we talk one on one on Mondays", @"We talk one on one on Mondays. "],
            @[@"they sat side by side by the river", @"They sat side by side by the river. "],
            @[@"Just do it step by step by following the guide", @"Just do it step by step by following the guide. "],
            @[@"I tried again and again and I failed", @"I tried again and again and I failed. "],
            @[@"he ran and ran and fell", @"He ran and ran and fell. "],
            @[@"it grows more and more and it never stops", @"It grows more and more and it never stops. "],
            @[@"milk and milk and eggs", @"Milk and milk and eggs. "],
            @[@"a pointer to a pointer to the struct", @"A pointer to a pointer to the struct. "],
            @[@"she is a friend of a friend of mine", @"She is a friend of a friend of mine. "],
            @[@"it is a copy of a copy of the file", @"It is a copy of a copy of the file. "],
            @[@"store it in a hash of hashes of hashes", @"Store it in a hash of hashes of hashes. "],
            @[@"a list of lists of lists", @"A list of lists of lists. "],
            // --- repeated phrases kept: emphasis and courtesy ---
            @[@"I know, I know", @"I know, I know. "],
            @[@"I know, I know, but it's late", @"I know, I know, but it's late. "],
            @[@"I know, I know it's late", @"I know, I know it's late. "],
            @[@"it's fine, it's fine", @"It's fine, it's fine. "],
            @[@"come here, come here", @"Come here, come here. "],
            @[@"thank you, thank you", @"Thank you, thank you. "],
            @[@"thank you thank you so much", @"Thank you thank you so much. "],
            @[@"no thank you, no thank you", @"No thank you, no thank you. "],
            @[@"all right, all right", @"All right, all right. "],
            @[@"come on, come on", @"Come on, come on. "],
            @[@"hold on, hold on", @"Hold on, hold on. "],
            @[@"good morning, good morning", @"Good morning, good morning. "],
            @[@"oh my god, oh my god", @"Oh my god, oh my god. "],
            @[@"oh my, oh my", @"Oh my, oh my. "],
            @[@"I don't know, I don't know", @"I don't know, I don't know. "],
            @[@"I love you, I love you", @"I love you, I love you. "],
            @[@"let it go, let it go", @"Let it go, let it go. "],
            @[@"wait a minute, wait a minute", @"Wait a minute, wait a minute. "],
            @[@"yes we can, yes we can", @"Yes we can, yes we can. "],
            @[@"I do, I do", @"I do, I do. "],
            @[@"we will, we will", @"We will, we will. "],
            @[@"I think so, I think so", @"I think so, I think so. "],
            @[@"not now, not now", @"Not now, not now. "],
            @[@"very good, very good", @"Very good, very good. "],
            @[@"it's okay, it's okay", @"It's okay, it's okay. "],
            @[@"no way, no way", @"No way, no way. "],
            @[@"that's right, that's right", @"That's right, that's right. "],
            @[@"here we go, here we go", @"Here we go, here we go. "],
            @[@"I told you, I told you", @"I told you, I told you. "],
            @[@"I'm going, I'm going", @"I'm going, I'm going. "],
            @[@"come in, come in", @"Come in, come in. "],
            @[@"go on, go on", @"Go on, go on. "],
            @[@"yes sir, yes sir", @"Yes sir, yes sir. "],
            @[@"yes, sir, yes, sir", @"Yes, sir, yes, sir. "],
            @[@"back and forth, back and forth", @"Back and forth, back and forth. "],
            @[@"again and again, again and again", @"Again and again, again and again. "],
            @[@"Don't, don't", @"Don't, don't. "],
            // --- repeated phrases kept: the repeat is grammar, not a stutter ---
            @[@"We have to do what we have to do", @"We have to do what we have to do. "],
            @[@"I want to know what I want to know", @"I want to know what I want to know. "],
            @[@"I am going where I am going", @"I am going where I am going. "],
            @[@"It is what it is", @"It is what it is. "],
            @[@"I said what I said", @"I said what I said. "],
            @[@"I know what I know", @"I know what I know. "],
            @[@"But what I'm saying is what I'm saying", @"But what I'm saying is what I'm saying. "],
            @[@"a deal is a deal", @"A deal is a deal. "],
            @[@"enough is enough", @"Enough is enough. "],
            @[@"boys will be boys", @"Boys will be boys. "],
            @[@"to be or not to be", @"To be or not to be. "],
            @[@"a rose is a rose", @"A rose is a rose. "],
            @[@"I'll do it when I can do it", @"I'll do it when I can do it. "],
            @[@"Just do it because you want to do it", @"Just do it because you want to do it. "],
            @[@"And what I have I have earned", @"And what I have I have earned. "],
            @[@"And what I have, I have earned", @"And what I have, I have earned. "],
            @[@"Everything I do, I do it for you", @"Everything I do, I do it for you. "],
            @[@"if we lose we lose", @"If we lose we lose. "],
            @[@"Honestly if it works it works", @"Honestly if it works it works. "],
            @[@"I did what you said you said it was fine", @"I did what you said you said it was fine. "],
            @[@"I did what you said, you said it was fine", @"I did what you said, you said it was fine. "],
            @[@"show the user the user settings", @"Show the user the user settings. "],
            @[@"I gave the dog the dog food", @"I gave the dog the dog food. "],
            @[@"She told the team the team lead quit", @"She told the team the team lead quit. "],
            @[@"send the new client the new client report", @"Send the new client the new client report. "],
            @[@"compare what we have to what we have now", @"Compare what we have to what we have now. "],
            @[@"go from where we are to where we are going", @"Go from where we are to where we are going. "],
            @[@"the more you learn the more you earn", @"The more you learn the more you earn. "],
            @[@"the sooner we start the sooner we finish", @"The sooner we start the sooner we finish. "],
            @[@"out of sight out of mind", @"Out of sight out of mind. "],
            @[@"he said she said", @"He said she said. "],
            @[@"garbage in garbage out", @"Garbage in garbage out. "],
            @[@"equal to, not equal to, less than, less than or equal to", @"Equal to, not equal to, less than, less than or equal to. "],
            // --- repeated phrases kept: same opening, different thought (the middle word is content) ---
            @[@"it is too big it is too slow", @"It is too big it is too slow. "],
            @[@"it is too big, it is too slow", @"It is too big, it is too slow. "],
            @[@"I want to go home I want to go to bed", @"I want to go home I want to go to bed. "],
            @[@"I want to go home, I want to go to bed", @"I want to go home, I want to go to bed. "],
            @[@"I don't want to do this, I don't want to do that", @"I don't want to do this, I don't want to do that. "],
            @[@"I don't want to do this I don't want to do that", @"I don't want to do this I don't want to do that. "],
            @[@"we need to ship fast we need to ship clean", @"We need to ship fast we need to ship clean. "],
            @[@"I think we should go I think we should leave now", @"I think we should go I think we should leave now. "],
            @[@"I love you John I love you", @"I love you John I love you. "],
            @[@"I think so, yes, I think so", @"I think so, yes, I think so. "],
            @[@"thank you so much, John, thank you so much", @"Thank you so much, John, thank you so much. "],
            @[@"we should go, yes we should go", @"We should go, yes we should go. "],
            @[@"I want to try some, I want to try them all", @"I want to try some, I want to try them all. "],
            @[@"what are you looking at, what are you looking for", @"What are you looking at, what are you looking for? "],
            // --- repeated phrases kept: never across a sentence end, a line break or other punctuation ---
            @[@"I'm happy with my. With my new app", @"I'm happy with my. With my new app. "],
            @[@"I know. I know it works", @"I know. I know it works. "],
            @[@"Is it done? Is it done yet", @"Is it done? Is it done yet? "],
            @[@"it works with my... with my setup", @"It works with my... With my setup. "],
            @[@"the app works with my; with my setup", @"The app works with my; with my setup. "],
            @[@"wi-fi wi-fi works", @"Wi-fi wi-fi works. "],
            @[@"first point new line first point again", @"First point\nFirst point again. "],
        ];
        // "kind of" / "sort of" (backlog 0i, user decision 2026-11-10): removed only when clearly filler. Exact output.
        NSArray *hedgeCases = @[
            // --- KEEP: after determiners / question words / "type of" adjectives, "kind of you", plain hedge with no pause ---
            @[@"what kind of car do you drive", @"What kind of car do you drive? "],
            @[@"we need a sort of plan", @"We need a sort of plan. "],
            @[@"this kind of thing happens", @"This kind of thing happens. "],
            @[@"we tried all sorts of fixes", @"We tried all sorts of fixes. "],
            @[@"it sort of works", @"It sort of works. "],
            @[@"I kind of like it", @"I kind of like it. "],
            @[@"what, um, kind of car is it", @"What kind of car is it? "],
            @[@"tell me which kind of coffee you want", @"Tell me which kind of coffee you want. "],
            @[@"it's the same kind of bug", @"It's the same kind of bug. "],
            @[@"the right kind of person", @"The right kind of person. "],
            @[@"that's very kind of you", @"That's very kind of you. "],
            @[@"That's kind of you to say", @"That's kind of you to say. "],
            @[@"it's kind of a big deal", @"It's kind of a big deal. "],
            @[@"It's cheap, sort of like a car", @"It's cheap, sort of like a car. "],
            @[@"Sort of. It depends", @"Sort of. It depends. "],
            @[@"a different sort of, um, approach", @"A different sort of approach. "],
            // --- STRIP: set off as a pause/aside, dangling at the end, or next to other fillers ---
            @[@"It's, kind of, broken", @"It's broken. "],
            @[@"It works, sort of.", @"It works. "],
            @[@"It works, sort of", @"It works. "],
            @[@"It works, sort of. Then we ship", @"It works. Then we ship. "],
            @[@"It's kind of, um, slow", @"It's slow. "],
            @[@"um kind of we should wait", @"We should wait. "],
            @[@"you know, kind of, the main thing is speed", @"The main thing is speed. "],
            @[@"I kind of, sort of like it", @"I like it. "],
            @[@"We did it, kind of, I mean, mostly", @"We did it mostly. "],
            @[@"uh, sort of, yeah, that works", @"Yeah, that works. "],
            @[@"it's kind of, like, weird", @"It's weird. "],
            @[@"it was kind of you know weird", @"It was weird. "],
            @[@"it's um kind of broken", @"It's broken. "],
            // --- backlog 0k: a filler "like" right before a stripped hedge goes with it; the verb/comparison "like" stays ---
            @[@"It's like kind of broken", @"It's broken. "],
            @[@"I was like kind of shocked", @"I was shocked. "],
            @[@"it's like sort of a big deal", @"It's a big deal. "],
            @[@"so like kind of the main thing is speed", @"So the main thing is speed. "],
            @[@"Like kind of the main thing is speed", @"The main thing is speed. "],
            @[@"The demo went well. Like kind of the main thing is speed", @"The demo went well. The main thing is speed. "],
            @[@"I like kind of broken things", @"I like broken things. "],
            @[@"It's like a kind of puzzle", @"It's like a kind of puzzle. "],
            @[@"It's like, kind of broken", @"It's broken. "],
            @[@"It looks like kind of rain", @"It looks like rain. "],
            @[@"It's like it sort of works", @"It's like it sort of works. "],
        ];
        // Terminal "?" is judged on the last sentence only (backlog 0j). Exact output.
        NSArray *sentenceCases = @[
            @[@"What kind of car do you drive? I sort of like the blue one", @"What kind of car do you drive? I sort of like the blue one. "],
            @[@"Did you see it? I did", @"Did you see it? I did. "],
            @[@"Why? Because it broke", @"Why? Because it broke. "],
            @[@"How are you. I'm fine thanks", @"How are you. I'm fine thanks. "],
            @[@"I fixed the bug. Can you check it", @"I fixed the bug. Can you check it? "],
            @[@"I fixed the bug. So when do we ship", @"I fixed the bug. So when do we ship? "],
            @[@"I went home! Where were you", @"I went home! Where were you? "],
            @[@"I went home. Why", @"I went home. Why? "],
            @[@"So did I. What now", @"So did I. What now? "],
            @[@"No. Why not", @"No. Why not? "],
            @[@"Should we ship it? Or wait", @"Should we ship it? Or wait? "],
            @[@"We ship it. Or we wait", @"We ship it. Or we wait. "],
            @[@"He said \"done.\" Is it", @"He said \"done.\" Is it? "],
            @[@"I sent it to example.com. Can you check", @"I sent it to example.com. Can you check? "],
            // a "." after an abbreviation is not a sentence end: the question starts earlier
            @[@"What did Mr. Smith say", @"What did Mr. Smith say? "],
            @[@"How did the U.S. team do", @"How did the U.S. team do? "],
            @[@"Is it ready by 5 p.m. tomorrow", @"Is it ready by 5 p.m. tomorrow? "],
            @[@"Can we use apples, pears, etc. for the demo", @"Can we use apples, pears, etc. for the demo? "],
            @[@"Did J. Smith call", @"Did J. Smith call? "],
            // an ellipsis trails off; it doesn't end the sentence
            @[@"What do you mean... seriously", @"What do you mean... Seriously? "],
            @[@"Wait\u2026 is it done", @"Wait\u2026 is it done? "],
            // after a spoken line break, the last sentence of the last line
            @[@"Is it done? new line I think so", @"Is it done?\nI think so. "],
            @[@"I think so new line what is next", @"I think so\nWhat is next? "],
        ];
        for (NSArray *tc in sentenceCases) {
            NSString *actual = [self polishOnDeviceTranscript:tc[0]];
            BOOL ok = [actual isEqualToString:tc[1]];
            if (ok) passed++; else failed++;
            NSString *(^esc)(NSString *) = ^NSString *(NSString *t) { return [t stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"]; };
            if (ok) printf("PASS: last sentence: \"%s\" -> \"%s\"\n", [esc(tc[0]) UTF8String], [esc(actual) UTF8String]);
            else printf("FAIL: last sentence: \"%s\"\n  Expected: \"%s\"\n  Actual:   \"%s\"\n", [esc(tc[0]) UTF8String],
                        [esc(tc[1]) UTF8String], [esc(actual) UTF8String]);
        }
        for (NSArray *tc in hedgeCases) {
            NSString *actual = [self polishOnDeviceTranscript:tc[0]];
            BOOL ok = [actual isEqualToString:tc[1]];
            if (ok) passed++; else failed++;
            if (ok) printf("PASS: kind of/sort of: \"%s\" -> \"%s\"\n", [tc[0] UTF8String], [actual UTF8String]);
            else printf("FAIL: kind of/sort of: \"%s\"\n  Expected: \"%s\"\n  Actual:   \"%s\"\n", [tc[0] UTF8String],
                        [tc[1] UTF8String], [actual UTF8String]);
        }
        for (NSArray *tc in polishCases) {
            NSString *actual = [self polishOnDeviceTranscript:tc[0]];
            BOOL ok = [actual isEqualToString:tc[1]];
            if (ok) passed++; else failed++;
            NSString *(^esc)(NSString *) = ^NSString *(NSString *t) { return [t stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"]; };
            if (ok) printf("PASS: polish: \"%s\" -> \"%s\"\n", [esc(tc[0]) UTF8String], [esc(actual) UTF8String]);
            else printf("FAIL: polish: \"%s\"\n  Expected: \"%s\"\n  Actual:   \"%s\"\n", [esc(tc[0]) UTF8String],
                        [esc(tc[1]) UTF8String], [esc(actual) UTF8String]);
        }
        {
            // The stutter pass (single words + phrases, backlog 0x) on a two-minute dictation, about 300 words with two repeats
            // in it, must stay well under a millisecond. Best of 20 runs, so a busy Mac doesn't fail it.
            NSMutableString *longText = [NSMutableString string];
            for (int k = 0; k < 10; k++) {
                [longText appendString:@"The quick brown fox jumps over the lazy dog while the build finishes and we wait for the "
                                       @"tests to pass before shipping the release to everyone on the team today. "];
            }
            [longText appendString:@"I'm so happy with my with my new dictation app and then I would I would repeat it"];
            double bestMs = 1e9;
            NSString *collapsed = nil;
            for (int run = 0; run < 20; run++) {
                NSMutableString *work = [longText mutableCopy];
                CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
                GFRemoveStutterRepeats(work);
                double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
                if (ms < bestMs) bestMs = ms;
                collapsed = work;
            }
            BOOL ok = bestMs < 1.0 && [collapsed hasSuffix:@"so happy with my new dictation app and then I would repeat it"] &&
                      collapsed.length == longText.length - [@" with my I would" length];
            if (ok) passed++; else failed++;
            printf("%s: stutter pass on %lu characters took %.3f ms (limit 1 ms) and collapsed both repeats\n", ok ? "PASS" : "FAIL",
                   (unsigned long)longText.length, bestMs);
        }
        {
            // A press that was only "new line" ("\n" after polish) is delivered, not ended as "No speech"; blank text still is.
            NSMutableArray *got = [NSMutableArray array];
            AppDelegate *nlD = [[AppDelegate alloc] init];
            nlD.unitTestMode = YES;
            nlD.resultSink = ^(NSString *t, GFDictation *d) { [got addObject:t ?: @"<NO SPEECH>"]; };
            [nlD applyFinalTranscript:@"\n"];
            [nlD applyFinalTranscript:@"\n\n"];
            [nlD applyFinalTranscript:@" "];
            [nlD applyFinalTranscript:@""];
            BOOL nlOk = [got isEqualToArray:@[@"\n", @"\n\n", @"<NO SPEECH>", @"<NO SPEECH>"]];
            if (nlOk) passed++; else failed++;
            printf("%s: a spoken line break alone is delivered; blank text ends as No speech\n", nlOk ? "PASS" : "FAIL");
        }
        // REST safety-net budget: short dictations keep the 8 s timeout; long recordings get room to upload + transcribe.
        struct { double audio; double minT; double maxT; } budgets[] = {{0, 8.0, 8.0}, {5, 8.0, 9.5}, {124, 35.0, 45.0}, {600, 150.0, 200.0}};
        for (size_t i = 0; i < sizeof(budgets) / sizeof(budgets[0]); i++) {
            NSTimeInterval t = GFRestTimeoutForAudioSeconds(budgets[i].audio);
            BOOL ok = t >= budgets[i].minT && t <= budgets[i].maxT;
            if (ok) passed++; else failed++;
            printf("%s: REST timeout for %.0f s audio = %.2f s (want %.1f-%.1f)\n", ok ? "PASS" : "FAIL", budgets[i].audio, t, budgets[i].minT, budgets[i].maxT);
        }
        BOOL tokOk = kRestMaxOutputTokens >= 4096; // >= ~15 min of dictation (124 s needs ~550)
        if (tokOk) passed++; else failed++;
        printf("%s: REST maxOutputTokens = %ld (want >= 4096)\n", tokOk ? "PASS" : "FAIL", (long)kRestMaxOutputTokens);
        // REST retry policy: one retry for a fast 429/5xx (cycle 5 saw a 503 in 1.7 s on 124 s of audio), or for a slow 429/503
        // that still fits budget + 4 s (cycle 12); never after a timeout, a slow other failure, a client error or a second attempt.
        struct { NSInteger status; BOOL timedOut; NSUInteger idx; double elapsed; double audio; BOOL want; const char *what; } rp[] = {
            {503, NO, 0, 0.20, 3.0, YES, "fast 503, short clip"},
            {429, NO, 0, 0.30, 3.0, YES, "fast 429"},
            {503, NO, 0, 1.70, 124.0, YES, "503 after 1.7 s on 124 s audio"},
            {500, NO, 0, 1.90, 0.0, YES, "500 within 2 s"},
            {500, NO, 0, 3.00, 3.0, NO, "slow 500 on a short clip (slow retry is only for an explicit 429/503)"},
            {503, NO, 0, 5.97, 2.58, YES, "slow 503 after 5.97 s on a 2.6 s clip (real 2026-11-06 case; budget left)"},
            {503, NO, 0, 3.00, 3.0, YES, "slow 503 after 3 s on a short clip (budget left)"},
            {429, NO, 0, 6.00, 3.0, YES, "slow 429 after 6 s on a short clip (budget left)"},
            {503, NO, 0, 6.50, 0.0, YES, "slow 503 at the edge of the deadline (0 s audio: 6.5 + 0.5 + 5 = 12 s)"},
            {503, NO, 0, 6.60, 0.0, NO, "slow 503 just past the deadline (0 s audio)"},
            {503, NO, 0, 7.50, 2.58, NO, "slow 503 with no budget left (2.6 s clip)"},
            {429, NO, 0, 8.20, 3.0, NO, "slow 429 with no budget left"},
            {503, NO, 0, 30.0, 124.0, YES, "slow 503 after 30 s on 124 s audio (budget left)"},
            {503, NO, 0, 38.5, 124.0, NO, "slow 503 after 38.5 s on 124 s audio (no budget left)"},
            {502, NO, 0, 5.00, 3.0, NO, "slow 502 (not an explicit overload answer)"},
            {504, NO, 0, 5.00, 3.0, NO, "slow 504 gateway timeout"},
            {400, NO, 0, 5.97, 2.58, NO, "slow 400 client error"},
            {403, NO, 0, 0.20, 3.0, NO, "client error 403"},
            {404, NO, 0, 3.00, 3.0, NO, "client error 404"},
            {0, YES, 0, 6.00, 3.0, NO, "timeout after 6 s"},
            {503, YES, 0, 6.00, 3.0, NO, "timed-out request with a 503 status"},
            {503, NO, 1, 5.97, 2.58, NO, "slow 503 on the second attempt"},
            {400, NO, 0, 0.20, 3.0, NO, "client error 400"},
            {0, YES, 0, 8.00, 3.0, NO, "timeout"},
            {0, NO, 0, 0.10, 3.0, NO, "network error (no status)"},
            {503, NO, 1, 0.80, 3.0, NO, "second attempt"},
        };
        for (size_t i = 0; i < sizeof(rp) / sizeof(rp[0]); i++) {
            BOOL got = GFRestShouldRetry(rp[i].status, rp[i].timedOut, rp[i].idx, rp[i].elapsed, rp[i].audio);
            BOOL ok = got == rp[i].want;
            if (ok) passed++; else failed++;
            printf("%s: REST retry for %s = %s\n", ok ? "PASS" : "FAIL", rp[i].what, got ? "yes" : "no");
        }
        // Retry stays bounded: short backoff; the retry's timeout is the budget left (>= 5 s), so first try + backoff + retry
        // stays within about one request budget for short dictations.
        double rtShort = GFRestRetryTimeout(3.0, 0.7), rtLate = GFRestRetryTimeout(0.0, 7.5);
        BOOL boundOk = kRestRetryBackoff > 0.0 && kRestRetryBackoff <= 1.0
                       && rtShort >= 5.0 && 0.7 + rtShort <= GFRestTimeoutForAudioSeconds(3.0) + 0.01 && rtLate == 5.0;
        if (boundOk) passed++; else failed++;
        printf("%s: REST retry bounds (backoff %.1f s, retry timeout %.2f s after 0.7 s, %.2f s after 7.5 s)\n",
               boundOk ? "PASS" : "FAIL", kRestRetryBackoff, rtShort, rtLate);
        // Slow-retry worst case: the LATEST slow 429/503 that still gets a retry (found by scanning elapsed in 10 ms steps) +
        // backoff + the retry's idle timeout stays within budget + 4 s (short dictation: <= ~13 s), and every retry gets >= 5 s.
        double audios[] = {0.0, 2.58, 5.0, 30.0, 124.0};
        for (size_t i = 0; i < sizeof(audios) / sizeof(audios[0]); i++) {
            double budget = GFRestTimeoutForAudioSeconds(audios[i]), latest = -1.0, worst = 0.0, minRt = 1e9;
            for (double e = 0.0; e <= budget + 10.0; e += 0.01) {
                if (!GFRestShouldRetry(503, NO, 0, e, audios[i])) continue;
                double rt = GFRestRetryTimeout(audios[i], e + kRestRetryBackoff);
                latest = e; worst = MAX(worst, e + kRestRetryBackoff + rt); minRt = MIN(minRt, rt);
            }
            BOOL ok = latest > 0.25 * budget && worst <= budget + kRestSlowRetryGrace + 0.01 && minRt >= 5.0
                      && (audios[i] > 5.0 || worst <= 13.3);
            if (ok) passed++; else failed++;
            printf("%s: slow 503 retry bound for %.1f s audio: latest retry at %.2f s, worst case %.2f s (budget %.2f + %.0f s), min retry timeout %.1f s\n",
                   ok ? "PASS" : "FAIL", audios[i], latest, worst, budget, kRestSlowRetryGrace, minRt);
        }
        // Live empty final turn: only the echo of the release's own activityEnd, while its turn is still pending, means "no output".
        struct { NSUInteger echo, finalIdx, pending; BOOL want; const char *what; } le[] = {
            {1, 1, 1, YES, "single activity echoed before any generationComplete (no-speech press)"},
            {3, 3, 1, YES, "final activity after splits echoed while its turn is pending"},
            {1, 2, 1, NO, "split echo right after its generationComplete, final turn pending"},
            {2, 2, 0, NO, "final echo after its generationComplete"},
            {1, 0, 1, NO, "split echo before release (no final activityEnd yet)"},
            {2, 0, 0, NO, "released between activities (no final activityEnd)"},
        };
        for (size_t i = 0; i < sizeof(le) / sizeof(le[0]); i++) {
            BOOL got = GFLiveEchoMeansEmptyFinalTurn(le[i].echo, le[i].finalIdx, le[i].pending);
            BOOL ok = got == le[i].want;
            if (ok) passed++; else failed++;
            printf("%s: Live empty final turn for %s = %s\n", ok ? "PASS" : "FAIL", le[i].what, got ? "yes" : "no");
        }
        // Unsolicited turn end (backlog 0c): re-open only while still recording with our activity open and nothing pending.
        struct { NSUInteger pending; BOOL open, finalizing, ended, want; const char *what; } ut[] = {
            {0, YES, NO, NO, YES, "server ended the open activity's turn while recording"},
            {1, YES, NO, NO, NO, "our own split activityEnd is pending"},
            {0, NO, NO, NO, NO, "between activities (already closed)"},
            {0, YES, YES, NO, NO, "after release (finalizing)"},
            {0, YES, NO, YES, NO, "final activityEnd already sent"},
        };
        for (size_t i = 0; i < sizeof(ut) / sizeof(ut[0]); i++) {
            BOOL got = GFLiveReopenAfterUnsolicitedTurnEnd(ut[i].pending, ut[i].open, ut[i].finalizing, ut[i].ended);
            BOOL ok = got == ut[i].want;
            if (ok) passed++; else failed++;
            printf("%s: Live re-open after an unsolicited turn end, %s = %s\n", ok ? "PASS" : "FAIL", ut[i].what, got ? "yes" : "no");
        }
        {
            // State: generationComplete for a turn we never ended, mid-press (no socket: nothing is sent). The activity must be marked
            // closed (so the next speech re-opens it), what was sent counts as covered, splitting stops. After release: unchanged.
            AppDelegate *ud = [[AppDelegate alloc] init];
            ud.unitTestMode = YES;
            ud.livePendingActivityEnds = [NSMutableArray array];
            ud.liveActivityOpen = YES; ud.liveSentBytes = 64000; ud.liveCoveredBytes = 0;
            [ud handleLiveMessage:@{@"serverContent": @{@"generationComplete": @YES}} session:0];
            BOOL ok1 = !ud.liveActivityOpen && ud.liveCoveredBytes == 64000 && ud.liveSplitDisabled && !ud.liveSpeechActive;
            AppDelegate *rd = [[AppDelegate alloc] init];
            rd.unitTestMode = YES;
            rd.livePendingActivityEnds = [NSMutableArray array];
            rd.liveActivityOpen = YES; rd.liveFinalizing = YES; rd.liveSentBytes = 64000;
            [rd handleLiveMessage:@{@"serverContent": @{@"generationComplete": @YES}} session:0];
            BOOL ok2 = rd.liveActivityOpen;
            if (ok1) passed++; else failed++;
            printf("%s: unsolicited generationComplete mid-press closes the activity for re-open (covered %.1f s)\n", ok1 ? "PASS" : "FAIL",
                   ud.liveCoveredBytes / 32000.0);
            if (ok2) passed++; else failed++;
            printf("%s: unsolicited generationComplete after release leaves the activity state alone\n", ok2 ? "PASS" : "FAIL");
        }
        // Mid-press reconnect (backlog 0h): only while recording, on our own socket of an established session, at most 2 per press.
        struct { BOOL rec, fin, ours, conn; NSUInteger used; BOOL want; const char *what; } rc[] = {
            {YES, NO,  YES, YES, 0, YES, "server closed the socket while recording"},
            {YES, NO,  YES, YES, 1, YES, "second drop in the same press"},
            {YES, NO,  YES, YES, 2, NO,  "third drop (limit of 2 reached)"},
            {YES, YES, YES, YES, 0, NO,  "after release (finalizing)"},
            {NO,  NO,  YES, YES, 0, NO,  "press no longer recording (released / cancelled)"},
            {YES, NO,  NO,  YES, 0, NO,  "socket closed by the app (Esc / cancel / finish)"},
            {YES, NO,  YES, NO,  0, NO,  "never connected this press (offline: no retries)"},
        };
        for (size_t i = 0; i < sizeof(rc) / sizeof(rc[0]); i++) {
            BOOL got = GFLiveShouldReconnect(rc[i].rec, rc[i].fin, rc[i].ours, rc[i].conn, rc[i].used);
            BOOL ok = got == rc[i].want;
            if (ok) passed++; else failed++;
            printf("%s: Live reconnect, %s = %s\n", ok ? "PASS" : "FAIL", rc[i].what, got ? "yes" : "no");
        }
        {
            BOOL bOk = GFLiveReconnectBackoff(0) > 0.0 && GFLiveReconnectBackoff(0) <= 0.5
                       && GFLiveReconnectBackoff(1) >= GFLiveReconnectBackoff(0) && GFLiveReconnectBackoff(1) <= 1.0;
            if (bOk) passed++; else failed++;
            printf("%s: Live reconnect backoff %.2f s then %.2f s (short, non-decreasing, <= 1 s)\n", bOk ? "PASS" : "FAIL",
                   GFLiveReconnectBackoff(0), GFLiveReconnectBackoff(1));
            // Resume keeps the press's coverage and finished turns' text, drops the unfinished turn's text, resends from the covered byte.
            AppDelegate *rs = [[AppDelegate alloc] init];
            rs.unitTestMode = YES;
            rs.liveSegments = [@[@"one", @"two", @"partial"] mutableCopy]; rs.liveCoveredSegments = 2;
            rs.liveCoveredBytes = 64000; rs.liveSentBytes = 96000; rs.livePendingActivityEnds = [@[@80000] mutableCopy];
            rs.liveVoiceScannedBytes = 96000; rs.liveReconnects = 1; rs.liveEverConnected = YES; rs.liveActivityOpen = YES;
            rs.liveActivityEndsSent = 2; rs.liveActivityEndEchoes = 1;
            [rs liveResetSessionStateResuming:YES];
            BOOL okR = [[rs.liveSegments componentsJoinedByString:@" "] isEqualToString:@"one two"] && rs.liveSentBytes == 64000
                       && rs.liveCoveredBytes == 64000 && rs.livePendingActivityEnds.count == 0 && rs.liveVoiceScannedBytes == 96000
                       && rs.liveReconnects == 1 && rs.liveEverConnected && !rs.liveActivityOpen && rs.liveActivityStartByte == 64000
                       && rs.liveActivityEndsSent == 0 && rs.liveActivityEndEchoes == 0 && !rs.liveFailed;
            if (okR) passed++; else failed++;
            printf("%s: Live resume keeps 2 finished segments, drops the unfinished one, resends from %.1f s covered\n", okR ? "PASS" : "FAIL",
                   rs.liveSentBytes / 32000.0);
            [rs liveResetSessionStateResuming:NO];
            BOOL okF = rs.liveSegments.count == 0 && rs.liveSentBytes == 0 && rs.liveCoveredBytes == 0 && rs.liveReconnects == 0
                       && !rs.liveEverConnected && rs.liveCoveredSegments == 0 && rs.liveVoiceScannedBytes == 0;
            if (okF) passed++; else failed++;
            printf("%s: a fresh press resets the reconnect count and coverage\n", okF ? "PASS" : "FAIL");
            // liveConnectionLost state (sockets are created but never resumed: no network)
            NSURLSession *us = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
            NSURL *wsURL = [NSURL URLWithString:@"wss://generativelanguage.googleapis.com/"];
            AppDelegate *c1 = [[AppDelegate alloc] init]; // cancelled press: not recording -> fail as before
            c1.unitTestMode = YES; c1.liveEverConnected = YES; c1.liveSessionId = 5;
            c1.liveWebSocketTask = [us webSocketTaskWithURL:wsURL];
            [c1 liveConnectionLost:@"test" session:5 task:c1.liveWebSocketTask];
            BOOL okC1 = c1.liveFailed && c1.liveReconnects == 0;
            AppDelegate *c2 = [[AppDelegate alloc] init]; // limit reached -> fail as before
            c2.unitTestMode = YES; c2.isRecording = YES; c2.liveEverConnected = YES; c2.liveReconnects = 2; c2.liveSessionId = 5;
            c2.liveWebSocketTask = [us webSocketTaskWithURL:wsURL];
            [c2 liveConnectionLost:@"test" session:5 task:c2.liveWebSocketTask];
            BOOL okC2 = c2.liveFailed && c2.liveReconnects == 2;
            AppDelegate *c3 = [[AppDelegate alloc] init]; // recording -> reconnect scheduled; the press ends during the backoff
            c3.unitTestMode = YES; c3.isRecording = YES; c3.liveEverConnected = YES; c3.liveSessionId = 5;
            c3.liveWebSocketTask = [us webSocketTaskWithURL:wsURL];
            [c3 liveConnectionLost:@"test" session:5 task:c3.liveWebSocketTask];
            BOOL okC3a = !c3.liveFailed && c3.liveReconnects == 1 && c3.liveSessionId == 6 && !c3.liveWebSocketTask;
            [c3 liveConnectionLost:@"late duplicate" session:5 task:nil]; // stale callback of the dead socket: ignored
            c3.isRecording = NO;
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:GFLiveReconnectBackoff(0) + 0.15]];
            BOOL okC3b = okC3a && c3.liveSessionId == 6 && !c3.liveWebSocketTask && c3.liveReconnects == 1 && !c3.liveFailed;
            [us invalidateAndCancel];
            if (okC1) passed++; else failed++;
            printf("%s: connection lost on a cancelled press falls back as before (no reconnect)\n", okC1 ? "PASS" : "FAIL");
            if (okC2) passed++; else failed++;
            printf("%s: connection lost after 2 reconnects falls back as before\n", okC2 ? "PASS" : "FAIL");
            if (okC3a) passed++; else failed++;
            printf("%s: connection lost while recording schedules reconnect 1/2 and invalidates the dead socket\n", okC3a ? "PASS" : "FAIL");
            if (okC3b) passed++; else failed++;
            printf("%s: a press that ended during the backoff opens no new session\n", okC3b ? "PASS" : "FAIL");
        }
        {
            // Planned Live session rotation (backlog 0p): pure decisions, thresholds, resume state, liveConnectionLost classification
            BOOL thrOk = kLiveRotateAge >= 480.0 && kLiveRotateAge + 30.0 <= kLivePlannedCloseAge && kLivePlannedCloseAge + 15.0 <= 589.0
                         && kLiveGoAwayMinAge > 0 && kLiveGoAwayMinAge < kLiveRotateAge && kLiveE2EMinRotateAge >= 1.0;
            if (thrOk) passed++; else failed++;
            printf("%s: Live rotation thresholds: rotate at %.0f s, planned close from %.0f s (observed server close ~589 s)\n",
                   thrOk ? "PASS" : "FAIL", kLiveRotateAge, kLivePlannedCloseAge);
            struct { BOOL rec, fin, ended, conn, open; NSUInteger pending; double age; BOOL goAway; BOOL want; const char *what; } ro[] = {
                {YES, NO,  NO,  YES, NO,  0, 510.0, NO,  YES, "8.5 min old, split point, nothing pending"},
                {YES, NO,  NO,  YES, NO,  0, 509.9, NO,  NO,  "just under the rotation age"},
                {YES, NO,  NO,  YES, YES, 0, 600.0, NO,  NO,  "activity open (mid-speech): wait for a split"},
                {YES, NO,  NO,  YES, NO,  1, 600.0, NO,  NO,  "split turn still pending"},
                {YES, YES, NO,  YES, NO,  0, 600.0, NO,  NO,  "released (finalizing)"},
                {YES, NO,  YES, YES, NO,  0, 600.0, NO,  NO,  "final activityEnd already sent"},
                {NO,  NO,  NO,  YES, NO,  0, 600.0, NO,  NO,  "not recording"},
                {YES, NO,  NO,  NO,  NO,  0, 600.0, NO,  NO,  "not connected"},
                {YES, NO,  NO,  YES, NO,  0, NAN,   NO,  NO,  "no session age"},
                {YES, NO,  NO,  YES, NO,  0, 45.0,  YES, YES, "goAway received, session 45 s old"},
                {YES, NO,  NO,  YES, NO,  0, 10.0,  YES, NO,  "goAway on a 10 s old session (no rotation loop)"},
            };
            for (size_t i = 0; i < sizeof(ro) / sizeof(ro[0]); i++) {
                BOOL got = GFLiveShouldRotate(ro[i].rec, ro[i].fin, ro[i].ended, ro[i].conn, ro[i].open, ro[i].pending, ro[i].age,
                                              ro[i].goAway, kLiveRotateAge);
                BOOL ok = got == ro[i].want;
                if (ok) passed++; else failed++;
                printf("%s: Live planned rotation, %s = %s\n", ok ? "PASS" : "FAIL", ro[i].what, got ? "rotate" : "no");
            }
            struct { BOOL rec, fin, ours; double age; BOOL goAway; BOOL want; const char *what; } pc[] = {
                {YES, NO,  YES, 589.5, NO,  YES, "close at 589.5 s session age (the 2026-11-11 server close)"},
                {YES, NO,  YES, 570.0, NO,  YES, "close exactly at the planned-close age"},
                {YES, NO,  YES, 569.9, NO,  NO,  "close just under it: a real drop (counted)"},
                {YES, NO,  YES, 19.0,  NO,  NO,  "close 19 s in (the 2026-11-10 1011 drop): counted"},
                {YES, NO,  YES, NAN,   NO,  NO,  "socket never reached setupComplete: counted"},
                {YES, YES, YES, 600.0, NO,  NO,  "after release: falls back as before"},
                {NO,  NO,  YES, 600.0, NO,  NO,  "press over: falls back as before"},
                {YES, NO,  NO,  600.0, NO,  NO,  "not our socket"},
                {YES, NO,  YES, 45.0,  YES, YES, "close after a goAway, session 45 s old"},
                {YES, NO,  YES, 10.0,  YES, NO,  "close after a goAway on a 10 s old session: counted"},
            };
            for (size_t i = 0; i < sizeof(pc) / sizeof(pc[0]); i++) {
                BOOL got = GFLiveCloseIsPlannedRotation(pc[i].rec, pc[i].fin, pc[i].ours, pc[i].age, pc[i].goAway, kLivePlannedCloseAge);
                BOOL ok = got == pc[i].want;
                if (ok) passed++; else failed++;
                printf("%s: Live session close, %s = %s\n", ok ? "PASS" : "FAIL", pc[i].what, got ? "planned rotation" : "drop");
            }
            // Resume state: quiet (split point) keeps the held-back position, opens no activity; otherwise resend from the covered byte
            AppDelegate *q = [[AppDelegate alloc] init];
            q.unitTestMode = YES;
            q.recordedPCMData = [NSMutableData dataWithLength:96000];
            q.liveSegments = [@[@"one", @"two"] mutableCopy]; q.liveCoveredSegments = 2; q.liveCoveredBytes = 64000;
            q.liveSentBytes = 80000; q.liveEverConnected = YES; q.liveReconnects = 1; q.liveRotations = 1;
            [q liveResetSessionStateResuming:YES];
            [q liveApplyRotationResumeHeldBack:80000 quiet:YES];
            BOOL okQ = q.liveSentBytes == 80000 && q.liveActivityStartByte == 80000 && q.liveQuietResume && q.liveSocketIsRotation
                       && !q.liveActivityOpen && q.liveSegments.count == 2 && q.liveCoveredBytes == 64000 && q.liveReconnects == 1
                       && q.liveRotations == 1;
            [q liveApplyRotationResumeHeldBack:200000 quiet:YES]; // never past the recording
            BOOL okQ2 = q.liveSentBytes == 96000;
            AppDelegate *n = [[AppDelegate alloc] init];
            n.unitTestMode = YES;
            n.recordedPCMData = [NSMutableData dataWithLength:96000];
            n.liveSegments = [@[@"one", @"partial"] mutableCopy]; n.liveCoveredSegments = 1; n.liveCoveredBytes = 32000;
            n.liveSentBytes = 96000; n.liveActivityOpen = YES; n.liveEverConnected = YES;
            [n liveResetSessionStateResuming:YES];
            [n liveApplyRotationResumeHeldBack:96000 quiet:NO];
            BOOL okN = n.liveSentBytes == 32000 && !n.liveQuietResume && n.liveSocketIsRotation && n.liveSegments.count == 1;
            [n liveResetSessionStateResuming:YES]; // a later plain reconnect is not a rotation
            BOOL okN2 = !n.liveSocketIsRotation && !n.liveQuietResume && !n.liveGoAway;
            n.liveRotations = 3;
            [n liveResetSessionStateResuming:NO];
            BOOL okN3 = n.liveRotations == 0;
            if (okQ) passed++; else failed++;
            printf("%s: rotation at a split point keeps the held-back position (%.1f s > %.1f s covered), opens no activity, keeps text\n",
                   okQ ? "PASS" : "FAIL", 80000 / 32000.0, 64000 / 32000.0);
            if (okQ2) passed++; else failed++;
            printf("%s: rotation resume position never past the recording\n", okQ2 ? "PASS" : "FAIL");
            if (okN) passed++; else failed++;
            printf("%s: rotation mid-activity resends from the covered byte and drops the unfinished turn's text\n", okN ? "PASS" : "FAIL");
            if (okN2 && okN3) passed++; else failed++;
            printf("%s: a plain reconnect clears the rotation flags; a fresh press resets the rotation count\n", okN2 && okN3 ? "PASS" : "FAIL");
            // liveConnectionLost: an old session's close is a planned rotation even with the reconnect budget used up (sockets are
            // created but never resumed: no network; the press ends before the new session would open)
            NSURLSession *us2 = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
            NSURL *wsURL2 = [NSURL URLWithString:@"wss://generativelanguage.googleapis.com/"];
            NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
            AppDelegate *r1 = [[AppDelegate alloc] init];
            r1.unitTestMode = YES; r1.isRecording = YES; r1.liveEverConnected = YES; r1.liveReconnects = 2; r1.liveSessionId = 5;
            r1.liveSocketReadyTime = now - 589.5; r1.livePendingActivityEnds = [NSMutableArray array];
            r1.liveWebSocketTask = [us2 webSocketTaskWithURL:wsURL2];
            [r1 liveConnectionLost:@"test" session:5 task:r1.liveWebSocketTask];
            BOOL okR1a = !r1.liveFailed && r1.liveReconnects == 2 && r1.liveRotations == 1 && r1.liveSessionId == 6 && !r1.liveWebSocketTask;
            r1.isRecording = NO;
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            BOOL okR1b = okR1a && !r1.liveWebSocketTask && r1.liveSessionId == 6 && !r1.liveFailed;
            AppDelegate *r2 = [[AppDelegate alloc] init]; // a young session's close is a real drop: budget used up -> fail as before
            r2.unitTestMode = YES; r2.isRecording = YES; r2.liveEverConnected = YES; r2.liveReconnects = 2; r2.liveSessionId = 5;
            r2.liveSocketReadyTime = now - 300.0;
            r2.liveWebSocketTask = [us2 webSocketTaskWithURL:wsURL2];
            [r2 liveConnectionLost:@"test" session:5 task:r2.liveWebSocketTask];
            BOOL okR2 = r2.liveFailed && r2.liveReconnects == 2 && r2.liveRotations == 0;
            AppDelegate *r3 = [[AppDelegate alloc] init]; // young session, budget left -> counted reconnect, as before
            r3.unitTestMode = YES; r3.isRecording = YES; r3.liveEverConnected = YES; r3.liveSessionId = 5;
            r3.liveSocketReadyTime = now - 300.0;
            r3.liveWebSocketTask = [us2 webSocketTaskWithURL:wsURL2];
            [r3 liveConnectionLost:@"test" session:5 task:r3.liveWebSocketTask];
            BOOL okR3 = !r3.liveFailed && r3.liveReconnects == 1 && r3.liveRotations == 0;
            r3.isRecording = NO;
            AppDelegate *r4 = [[AppDelegate alloc] init]; // goAway seen, 45 s old session, budget used up -> planned rotation
            r4.unitTestMode = YES; r4.isRecording = YES; r4.liveEverConnected = YES; r4.liveReconnects = 2; r4.liveSessionId = 5;
            r4.liveSocketReadyTime = now - 45.0; r4.liveGoAway = YES;
            r4.liveWebSocketTask = [us2 webSocketTaskWithURL:wsURL2];
            [r4 liveConnectionLost:@"test" session:5 task:r4.liveWebSocketTask];
            BOOL okR4 = !r4.liveFailed && r4.liveReconnects == 2 && r4.liveRotations == 1;
            r4.isRecording = NO;
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:GFLiveReconnectBackoff(0) + 0.15]];
            BOOL okR34 = !r3.liveWebSocketTask && !r4.liveWebSocketTask;
            [us2 invalidateAndCancel];
            if (okR1a) passed++; else failed++;
            printf("%s: server close of a 589.5 s old session = planned rotation, reconnect budget untouched (2/2 used, still Live)\n",
                   okR1a ? "PASS" : "FAIL");
            if (okR1b) passed++; else failed++;
            printf("%s: a press that ended right after a planned close opens no new session\n", okR1b ? "PASS" : "FAIL");
            if (okR2) passed++; else failed++;
            printf("%s: a 300 s old session's close is a real drop: with 2 reconnects used it falls back as before\n", okR2 ? "PASS" : "FAIL");
            if (okR3) passed++; else failed++;
            printf("%s: a 300 s old session's close with budget left uses reconnect 1/2 as before\n", okR3 ? "PASS" : "FAIL");
            if (okR4 && okR34) passed++; else failed++;
            printf("%s: a close after a goAway (45 s old session) is a planned rotation\n", okR4 && okR34 ? "PASS" : "FAIL");
            // Press stats line: unchanged without rotations, "; planned rotations N" appended with them
            NSString *s0 = GFPressStatsLogLineWithRotations(600.04, YES, 598.66, 1, 48, 0);
            NSString *s1 = GFPressStatsLogLineWithRotations(1200.0, YES, 95.04, 0, 90, 2);
            NSString *s2 = GFPressStatsLogLineWithRotations(3.21, NO, 2.0, 0, 0, 1);
            BOOL sOk = [s0 isEqualToString:GFPressStatsLogLine(600.04, YES, 598.66, 1, 48)]
                       && [s1 isEqualToString:@"Press stats: 1200.0 s of audio; Live session age at release 95.0 s; reconnects 0; Live activities 90; planned rotations 2"]
                       && [s2 isEqualToString:@"Press stats: 3.2 s of audio; Live not used"];
            if (sOk) passed++; else failed++;
            printf("%s: per-press stats line with planned rotations (numbers only): %s\n", sOk ? "PASS" : "FAIL", s1.UTF8String);
        }
        BOOL graceOk = kLiveEmptyTurnGrace > 0.0 && kLiveEmptyTurnGrace <= 0.3;
        if (graceOk) passed++; else failed++;
        printf("%s: Live empty-turn grace %.2f s (0 < grace <= 0.3 s)\n", graceOk ? "PASS" : "FAIL", kLiveEmptyTurnGrace);
        // Release between turns (backlog 26): no activity open and no turn pending -> decide at once, with the grace timer's rules.
        struct { BOOL open; NSUInteger pending, segs; double unc; GFLiveIdleReleaseAction want; const char *what; } ir[] = {
            {YES, 0, 1, 0.00, GFLiveIdleReleaseWait,   "final activity still open (normal release)"},
            {NO,  1, 1, 0.00, GFLiveIdleReleaseWait,   "split turn still pending"},
            {NO,  2, 0, 0.00, GFLiveIdleReleaseWait,   "two split turns pending, no text yet"},
            {NO,  0, 2, 0.00, GFLiveIdleReleaseFinish, "every turn answered, silence since the split"},
            {NO,  0, 1, 0.35, GFLiveIdleReleaseFinish, "uncovered speech exactly at the 0.35 s limit"},
            {NO,  0, 2, 0.36, GFLiveIdleReleaseRest,   "uncovered speech above the limit (never finish with less)"},
            {NO,  0, 0, 0.00, GFLiveIdleReleaseWait,   "no text at all (grace timer / 2.5 s cap decide, as before)"},
            {NO,  0, 0, 1.00, GFLiveIdleReleaseRest,   "no text and uncovered speech"},
        };
        for (size_t i = 0; i < sizeof(ir) / sizeof(ir[0]); i++) {
            GFLiveIdleReleaseAction got = GFLiveIdleReleaseDecision(ir[i].open, ir[i].pending, ir[i].segs, ir[i].unc);
            BOOL ok = got == ir[i].want;
            if (ok) passed++; else failed++;
            printf("%s: Live release between turns, %s = %s\n", ok ? "PASS" : "FAIL", ir[i].what,
                   got == GFLiveIdleReleaseFinish ? "finish now" : (got == GFLiveIdleReleaseRest ? "REST" : "wait"));
        }
        {
            // Release-cushion measurement (backlog 27, numbers only): buffer end time from host time, reach past Fn up, log line.
            struct { double nowWall, nowHost; BOOL valid; double startHost, frames, rate, want; const char *what; } be[] = {
                {1000.0, 50.0, YES, 49.9, 4800, 48000, 1000.0,       "mic buffer whose last sample is 'now'"},
                {1000.0, 50.0, YES, 49.8, 4800, 48000, 999.9,        "mic buffer delivered 100 ms after its last sample"},
                {1000.0, 50.0, NO,  0.0,  1024, 16000, 1000.0,       "no host time (e2e file feed): entry time"},
                {1000.0, 50.0, YES, 49.9, 1024, 0,     1000.0,       "zero sample rate: entry time"},
            };
            for (size_t i = 0; i < sizeof(be) / sizeof(be[0]); i++) {
                NSTimeInterval got = GFCapturedBufferEndTime(be[i].nowWall, be[i].nowHost, be[i].valid, be[i].startHost, be[i].frames, be[i].rate);
                BOOL ok = fabs(got - be[i].want) < 1e-6;
                if (ok) passed++; else failed++;
                printf("%s: release cushion, buffer end of %s = %.4f\n", ok ? "PASS" : "FAIL", be[i].what, got);
            }
            double r1 = GFAudioReachPastReleaseMs(100.087, 100.0), r2 = GFAudioReachPastReleaseMs(99.98, 100.0);
            double r3 = GFAudioReachPastReleaseMs(0, 100.0), r4 = GFAudioReachPastReleaseMs(100.0, 0);
            BOOL reachOk = fabs(r1 - 87.0) < 1e-6 && fabs(r2 + 20.0) < 1e-6 && isnan(r3) && isnan(r4);
            if (reachOk) passed++; else failed++;
            printf("%s: release cushion reach past Fn up = %.0f / %.0f ms, unknown -> NAN (%d %d)\n", reachOk ? "PASS" : "FAIL", r1, r2, isnan(r3), isnan(r4));
            NSString *l1 = GFReleaseCushionLogLine(87.4, 123.6, 112.0, 410.2), *l2 = GFReleaseCushionLogLine(NAN, 380.0, 0, 0);
            BOOL lineOk = [l1 isEqualToString:@"Release cushion: captured audio reaches +87 ms past Fn up; stopped 124 ms after Fn up; "
                                              @"112 ms of audio arrived after Fn up (max RMS 410)"]
                          && [l2 isEqualToString:@"Release cushion: captured audio reaches n/a past Fn up; stopped 380 ms after Fn up; "
                                                 @"0 ms of audio arrived after Fn up (max RMS 0)"];
            if (lineOk) passed++; else failed++;
            printf("%s: release cushion log line (numbers only): %s\n", lineOk ? "PASS" : "FAIL", l1.UTF8String);
        }
        {
            // Backlog 0m: per-press stats line (numbers only) and the Live socket age it reports
            double a1 = GFLiveSessionAgeSeconds(1000.0, 400.0), a2 = GFLiveSessionAgeSeconds(1000.0, 0), a3 = GFLiveSessionAgeSeconds(1000.0, 1200.0);
            BOOL ageOk = fabs(a1 - 600.0) < 1e-9 && isnan(a2) && isnan(a3);
            if (ageOk) passed++; else failed++;
            printf("%s: Live session age at release = %.1f s; no socket / clock skew -> NAN (%d %d)\n", ageOk ? "PASS" : "FAIL", a1, isnan(a2), isnan(a3));
            NSString *p1 = GFPressStatsLogLine(600.04, YES, 598.66, 1, 48), *p2 = GFPressStatsLogLine(12.0, YES, NAN, 0, 0);
            NSString *p3 = GFPressStatsLogLine(3.21, NO, 2.0, 0, 0);
            BOOL pOk = [p1 isEqualToString:@"Press stats: 600.0 s of audio; Live session age at release 598.7 s; reconnects 1; Live activities 48"]
                       && [p2 isEqualToString:@"Press stats: 12.0 s of audio; Live session age at release n/a; reconnects 0; Live activities 0"]
                       && [p3 isEqualToString:@"Press stats: 3.2 s of audio; Live not used"];
            if (pOk) passed++; else failed++;
            printf("%s: per-press stats log line (numbers only): %s\n", pOk ? "PASS" : "FAIL", p1.UTF8String);
            // e2e harness watchdog covers a real-time 10 min feed + REST budget + slow-retry grace + WAV watchdog; never below the old rule
            BOOL wOk = GFE2EWatchdogSeconds(0) == 120.0 && GFE2EWatchdogSeconds(5.0) == 120.0 && GFE2EWatchdogSeconds(32.5) == 120.0;
            double audios[] = {5.0, 32.5, 124.0, 300.0, 600.0, 900.0};
            for (size_t i = 0; i < sizeof(audios) / sizeof(audios[0]); i++) {
                double f = audios[i], w = GFE2EWatchdogSeconds(f);
                double oldRule = MAX(120.0, f + 60.0 + (GFRestTimeoutForAudioSeconds(f) - 8.0));
                double chain = f + GFRestTimeoutForAudioSeconds(f) + kRestSlowRetryGrace + GFWavWatchdogLimit(f);
                if (w < oldRule || w < chain + 30.0 - 1e-9) wOk = NO;
            }
            if (wOk) passed++; else failed++;
            printf("%s: e2e watchdog fits a real-time feed + the fallback chain (600 s audio -> %.0f s)\n", wOk ? "PASS" : "FAIL", GFE2EWatchdogSeconds(600.0));
        }
        {
            // State: 9 s of speech covered by an answered split turn, then 2 s of silence, released (no socket: nothing is sent).
            NSMutableData *pcm = [NSMutableData dataWithLength:11 * 32000];
            int16_t *smp = (int16_t *)pcm.mutableBytes;
            for (NSUInteger i = 0; i < 9 * 16000; i++) smp[i] = (int16_t)(3000.0 * sin(i * 0.11) * (0.6 + 0.4 * sin(i * 0.0007)));
            AppDelegate *(^makeReleased)(NSMutableArray *, NSArray *) = ^AppDelegate *(NSMutableArray *sink, NSArray *pending) {
                AppDelegate *d = [[AppDelegate alloc] init];
                d.unitTestMode = YES;
                d.recordedPCMData = [pcm mutableCopy];
                d.activeDictation = [[GFDictation alloc] init];
                d.resultSink = ^(NSString *t, GFDictation *dd) { [sink addObject:t ?: @"<NO SPEECH>"]; };
                d.liveSegments = [@[@"we should ship the update on friday", @"then we can plan the next sprint"] mutableCopy];
                d.liveCoveredSegments = 2;
                d.livePendingActivityEnds = [pending mutableCopy];
                d.liveSentBytes = 9 * 32000; d.liveCoveredBytes = 9 * 32000; d.liveLastActivityEndByte = 9 * 32000;
                d.liveVoiceScannedBytes = 9 * 32000; d.liveLastVoicedByte = 9 * 32000;
                d.liveActivityOpen = NO; d.liveWebSocketConnected = YES; d.liveFinalizing = YES;
                d.liveReleaseTime = [NSDate timeIntervalSinceReferenceDate];
                return d;
            };
            NSMutableArray *got1 = [NSMutableArray array];
            AppDelegate *r1 = makeReleased(got1, @[]);
            [r1 sendLiveAudioStreamEnd];
            BOOL okS1 = got1.count == 1 && r1.hasCompletedGeminiTurn && r1.liveActivityEnded && !r1.liveFailed
                        && [got1.firstObject hasPrefix:@"We should ship the update on "] && [got1.firstObject containsString:@"next sprint"];
            if (okS1) passed++; else failed++;
            printf("%s: released in silence after an answered split finishes at once on Live (%lu delivered)\n", okS1 ? "PASS" : "FAIL",
                   (unsigned long)got1.count);
            NSMutableArray *got2 = [NSMutableArray array];
            AppDelegate *r2 = makeReleased(got2, @[@(9 * 32000)]);
            [r2 sendLiveAudioStreamEnd];
            BOOL okS2 = got2.count == 0 && !r2.hasCompletedGeminiTurn && r2.liveActivityEnded && !r2.liveFailed;
            if (okS2) passed++; else failed++;
            printf("%s: released in silence with the split turn still pending waits for it (nothing delivered yet)\n", okS2 ? "PASS" : "FAIL");
            // ...and its turn end then finishes the press as before
            [r2 handleLiveMessage:@{@"serverContent": @{@"generationComplete": @YES}} session:0];
            BOOL okS3 = got2.count == 1 && r2.hasCompletedGeminiTurn;
            if (okS3) passed++; else failed++;
            printf("%s: ...and the pending split turn's generationComplete finishes it\n", okS3 ? "PASS" : "FAIL");
            NSMutableArray *got4 = [NSMutableArray array];
            AppDelegate *r4 = makeReleased(got4, @[]);
            r4.liveFinalizing = NO; // never from mid-press
            [r4 liveFinishIfReleasedBetweenTurns];
            BOOL okS4 = got4.count == 0 && !r4.hasCompletedGeminiTurn;
            if (okS4) passed++; else failed++;
            printf("%s: the between-turns finish never fires while the press is still recording\n", okS4 ? "PASS" : "FAIL");
        }
        // Backlog 0r: seam after a slow split turn. Pure rules first.
        struct { BOOL voiced; NSUInteger pending; GFLiveBetweenAction want; const char *what; } ba[] = {
            {NO,  0, GFLiveBetweenDropSilence, "silence since the held position, nothing pending"},
            {NO,  1, GFLiveBetweenDropSilence, "silence while the split turn is pending"},
            {YES, 0, GFLiveBetweenReopen,      "speech, split turn answered"},
            {YES, 1, GFLiveBetweenHold,        "speech while the split turn is pending (no 1.5 s merge)"},
            {YES, 2, GFLiveBetweenHold,        "speech with two turns pending"},
        };
        for (size_t i = 0; i < sizeof(ba) / sizeof(ba[0]); i++) {
            GFLiveBetweenAction got = GFLiveBetweenActivitiesDecision(ba[i].voiced, ba[i].pending);
            BOOL ok = got == ba[i].want;
            if (ok) passed++; else failed++;
            printf("%s: Live between activities, %s = %ld\n", ok ? "PASS" : "FAIL", ba[i].what, (long)got);
        }
        struct { NSUInteger echo, sent, pending; NSInteger want; const char *what; } ep[] = {
            {1, 1, 1,  0, "split echo with its turn still pending (closed empty)"},
            {1, 1, 0, -1, "split echo right after its generationComplete"},
            {1, 2, 1, -1, "echo of an answered turn while the next end is pending (never covers the next end)"},
            {2, 2, 1,  0, "second echo, its turn pending"},
            {1, 2, 2,  0, "first of two pending ends"},
            {2, 2, 2,  1, "second echo while the first turn is still pending"},
            {3, 2, 0, -1, "echo beyond our activityEnds (server-initiated end)"},
            {0, 1, 1, -1, "no echo"},
        };
        for (size_t i = 0; i < sizeof(ep) / sizeof(ep[0]); i++) {
            NSInteger got = GFLiveEchoPendingIndex(ep[i].echo, ep[i].sent, ep[i].pending);
            BOOL ok = got == ep[i].want;
            if (ok) passed++; else failed++;
            printf("%s: Live echo -> pending activityEnd, %s = %ld\n", ok ? "PASS" : "FAIL", ep[i].what, (long)got);
        }
        {
            // Backlog 0r, the 2026-11-12 11:25 T26 sequence on a fresh AppDelegate (no socket: sends are no-ops). After rotation #3
            // activity #4 resends 0-27.08 s in 1 s chunks and is split at 27.08 s; speech resumes at 27.30 s ("Finally, remember
            // that the ..."); the split turn is answered only at 32.44 s sent (> 1.5 s); release at 32.50 s.
            const NSUInteger B = 32000, split = 27.08 * B + 0.5, voiceBack = 27.30 * B + 0.5, answer = 32.44 * B + 0.5, rel = 32.50 * B + 0.5;
            NSMutableData *full = [NSMutableData dataWithLength:rel];
            int16_t *fs = (int16_t *)full.mutableBytes;
            for (NSUInteger i = 0; i < rel / 2; i++) {
                BOOL voiced = i < (26.40 * 16000) || i >= voiceBack / 2;
                fs[i] = voiced ? (int16_t)(3000.0 * sin(i * 0.11) * (0.6 + 0.4 * sin(i * 0.0007))) : 0;
            }
            NSMutableData *(^upTo)(NSUInteger) = ^NSMutableData *(NSUInteger n) { return [[full subdataWithRange:NSMakeRange(0, n)] mutableCopy]; };
            AppDelegate *(^makeT26)(NSMutableArray *) = ^AppDelegate *(NSMutableArray *sink) {
                AppDelegate *d = [[AppDelegate alloc] init];
                d.unitTestMode = YES; d.liveTestSocketless = YES; d.liveWebSocketConnected = YES;
                d.activeDictation = [[GFDictation alloc] init];
                d.resultSink = ^(NSString *t, GFDictation *dd) { [sink addObject:t ?: @"<NO SPEECH>"]; };
                d.liveSegments = [NSMutableArray array];
                d.livePendingActivityEnds = [NSMutableArray array];
                d.liveRotations = 3; d.liveActivityCount = 4; d.liveActivityOpen = YES; d.liveActivityStartByte = 0;
                d.recordedPCMData = upTo(split);
                [d pumpLiveAudioForce:YES]; // resend + split check
                d.recordedPCMData = upTo(answer);
                d.liveSplitTime = [NSDate timeIntervalSinceReferenceDate] - 2.0; // the split turn is > 1.5 s late
                [d pumpLiveAudioForce:YES];
                return d;
            };
            NSDictionary *seg1 = @{@"serverContent": @{@"inputTranscription": @{@"text": @"first part of the update"}, @"generationComplete": @YES}};
            NSDictionary *seg2 = @{@"serverContent": @{@"inputTranscription": @{@"text": @"finally remember the offsite"}, @"generationComplete": @YES}};
            NSDictionary *echoEnd = @{@"voiceActivity": @{@"type": @"ACTIVITY_END"}};
            NSMutableArray *got = [NSMutableArray array];
            AppDelegate *t = makeT26(got);
            BOOL okSplit = t.liveActivityEndsSent == 1 && t.livePendingActivityEnds.count == 1
                           && t.livePendingActivityEnds.firstObject.unsignedIntegerValue == split;
            BOOL okHold = okSplit && !t.liveActivityOpen && t.liveActivityCount == 4 && t.liveSentBytes == split && !t.liveSplitDisabled;
            if (okHold) passed++; else failed++;
            printf("%s: T26 seam: speech after a split end is held (not merged) while the split turn is > 1.5 s late (sent %.2f s)\n",
                   okHold ? "PASS" : "FAIL", t.liveSentBytes / 32000.0);
            [t handleLiveMessage:seg1 session:0];
            BOOL okAns = t.liveCoveredBytes == split && t.livePendingActivityEnds.count == 0 && t.liveActivityOpen
                         && t.liveActivityCount == 5 && t.liveActivityStartByte == split && t.liveActivityStartByte < voiceBack
                         && t.liveSentBytes == answer && !t.liveSplitDisabled;
            if (okAns) passed++; else failed++;
            printf("%s: T26 seam: the late split answer covers only its own activity (covered %.2f s, not %.2f s) and reopens from %.2f s\n",
                   okAns ? "PASS" : "FAIL", t.liveCoveredBytes / 32000.0, answer / 32000.0, t.liveActivityStartByte / 32000.0);
            [t handleLiveMessage:echoEnd session:0];
            BOOL okEcho = t.liveCoveredBytes == split && t.liveActivityOpen;
            if (okEcho) passed++; else failed++;
            printf("%s: T26 seam: the split end's echo after the reopen moves nothing (covered %.2f s, activity open)\n",
                   okEcho ? "PASS" : "FAIL", t.liveCoveredBytes / 32000.0);
            t.recordedPCMData = upTo(rel);
            t.liveFinalizing = YES; t.liveReleaseTime = [NSDate timeIntervalSinceReferenceDate];
            [t sendLiveAudioStreamEnd];
            BOOL okRel = t.liveFinalEndIndex == 2 && t.livePendingActivityEnds.count == 1
                         && t.livePendingActivityEnds.firstObject.unsignedIntegerValue == rel && t.liveCoveredBytes == split;
            [t handleLiveMessage:seg2 session:0];
            BOOL okFin = okRel && got.count == 1 && t.liveCoveredBytes == rel && [got.firstObject rangeOfString:@"offsite"].location != NSNotFound
                         && [got.firstObject rangeOfString:@"update"].location != NSNotFound;
            if (okFin) passed++; else failed++;
            printf("%s: T26 seam: the final turn covers 27.08-32.50 s and the press finishes with both turns' text\n", okFin ? "PASS" : "FAIL");

            // Released while the split turn is still pending with speech held: the final activity waits for that turn.
            NSMutableArray *gotD = [NSMutableArray array];
            AppDelegate *r = makeT26(gotD);
            r.recordedPCMData = upTo(rel);
            r.liveFinalizing = YES; r.liveReleaseTime = [NSDate timeIntervalSinceReferenceDate];
            [r sendLiveAudioStreamEnd];
            BOOL okDef = r.liveFinalReopenDeferred && !r.liveActivityOpen && r.liveActivityCount == 4 && r.liveActivityEndsSent == 1
                         && r.liveSentBytes == split && r.liveActivityEnded && gotD.count == 0;
            if (okDef) passed++; else failed++;
            printf("%s: released behind a pending split turn: no activityStart while that turn is pending (final activity deferred)\n",
                   okDef ? "PASS" : "FAIL");
            [r handleLiveMessage:seg1 session:0];
            BOOL okDef2 = !r.liveFinalReopenDeferred && r.liveActivityCount == 5 && r.liveActivityStartByte == split && r.liveSentBytes == rel
                          && r.liveActivityEndsSent == 2 && r.liveFinalEndIndex == 2 && r.livePendingActivityEnds.count == 1
                          && r.livePendingActivityEnds.firstObject.unsignedIntegerValue == rel && r.liveCoveredBytes == split && gotD.count == 0;
            if (okDef2) passed++; else failed++;
            printf("%s: ...its answer opens, fills (from %.2f s) and ends the final activity; nothing finishes early\n",
                   okDef2 ? "PASS" : "FAIL", r.liveActivityStartByte / 32000.0);
            [r handleLiveMessage:echoEnd session:0];
            [r handleLiveMessage:seg2 session:0];
            BOOL okDef3 = gotD.count == 1 && r.liveCoveredBytes == rel && [gotD.firstObject rangeOfString:@"offsite"].location != NSNotFound;
            if (okDef3) passed++; else failed++;
            printf("%s: ...and the final turn finishes the press with both turns' text\n", okDef3 ? "PASS" : "FAIL");

            // A split turn that closes empty (echo, no generationComplete) releases the held speech after the grace.
            NSMutableArray *gotE = [NSMutableArray array];
            AppDelegate *e = makeT26(gotE);
            [e handleLiveMessage:echoEnd session:0];
            BOOL okE1 = !e.liveActivityOpen && e.livePendingActivityEnds.count == 1 && e.liveCoveredBytes == split;
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:kLiveEmptyTurnGrace + 0.15]];
            BOOL okE2 = okE1 && e.livePendingActivityEnds.count == 0 && e.liveActivityOpen && e.liveActivityStartByte == split
                        && e.liveSentBytes == answer && e.liveCoveredBytes == split;
            if (okE2) passed++; else failed++;
            printf("%s: an empty split turn (echo, no generationComplete) releases the held speech into a new activity after %.2f s\n",
                   okE2 ? "PASS" : "FAIL", kLiveEmptyTurnGrace);

            // The echo of an answered turn never covers a later, unanswered activity.
            AppDelegate *c = [[AppDelegate alloc] init];
            c.unitTestMode = YES;
            c.liveSegments = [NSMutableArray array];
            c.livePendingActivityEnds = [@[@(20 * B)] mutableCopy];
            c.liveActivityEndsSent = 2; c.liveCoveredBytes = 10 * B; c.liveLastActivityEndByte = 20 * B; c.liveSentBytes = 21 * B;
            [c handleLiveMessage:echoEnd session:0];
            BOOL okC = c.liveCoveredBytes == 10 * B && c.livePendingActivityEnds.count == 1;
            if (okC) passed++; else failed++;
            printf("%s: a late echo of an answered turn leaves coverage at its own end (%.1f s, not the pending 20.0 s)\n",
                   okC ? "PASS" : "FAIL", c.liveCoveredBytes / 32000.0);
        }
        // No-speech verdict (backlog 0e): all three signals must agree; any single sign of speech keeps REST. Rows with noLoud = NO
        // are the original rule (audio has loud speech evidence); backlog 0u rows add the speech-evidence rule.
        struct { BOOL live; NSUInteger segs; BOOL od; NSUInteger chars; double loud; BOOL noLoud; BOOL want; const char *what; } ns[] = {
            {YES, 0, YES, 0, 0.00, NO,  YES, "all three agree (accidental tap)"},
            {YES, 0, YES, 0, 0.10, NO,  YES, "100 ms click at the limit"},
            {NO,  0, YES, 0, 0.00, NO,  NO,  "Live final turn not empty"},
            {YES, 1, YES, 0, 0.00, NO,  NO,  "earlier Live turn had text"},
            {YES, 0, NO,  0, 0.00, NO,  NO,  "on-device gave no no-speech verdict"},
            {YES, 0, YES, 3, 0.00, NO,  NO,  "on-device has text"},
            {YES, 0, YES, 0, 0.12, NO,  NO,  "audio above the level floor"},
            // backlog 0u: real 2026-11-12 16:01 silent presses (numbers from the log)
            {YES, 0, YES, 0, 1.82, GFNoLoudSpeech(156, 1.82), YES, "0u: silent 2.3 s hold, loud 1.82 s, max RMS 156"},
            {YES, 0, YES, 0, 0.20, GFNoLoudSpeech(133, 0.20), YES, "0u: silent 0.39 s tap, loud 0.20 s, max RMS 133"},
            {YES, 0, YES, 0, 0.20, GFNoLoudSpeech(196, 0.20), YES, "0u: silent 0.39 s tap, loud 0.20 s, max RMS 196"},
            {YES, 0, YES, 0, 0.20, GFNoLoudSpeech(239, 0.20), YES, "0u: silent 0.39 s tap, loud 0.20 s, max RMS 239"},
            {YES, 0, NO,  0, 1.82, GFNoLoudSpeech(156, 1.82), YES, "0u: silent hold, on-device verdict not in yet"},
            // the test clips' numbers (T6/T11 quiet: max RMS 837, evidence 1.42 s, loud 2.18 s; T11 short / short_thanks)
            {YES, 0, YES, 0, 2.18, GFNoLoudSpeech(837, 1.42), NO, "0u: T11 quiet clip (-18 dB speech) keeps REST"},
            {YES, 0, YES, 0, 0.42, GFNoLoudSpeech(5967, 0.36), NO, "0u: T11 short (all-speech 0.43 s word) keeps REST"},
            {YES, 0, YES, 0, 0.52, GFNoLoudSpeech(3508, 0.22), NO, "0u: T11 short_thanks keeps REST"},
            {YES, 0, NO,  0, 11.90, GFNoLoudSpeech(560, 3.18), NO, "0u: quiet_long (-26 dB) keeps REST"},
            {YES, 0, YES, 4, 1.82, GFNoLoudSpeech(156, 1.82), NO, "0u: quiet room but on-device has text"},
            {YES, 1, YES, 0, 1.82, GFNoLoudSpeech(156, 1.82), NO, "0u: quiet room but an earlier Live turn had text"},
        };
        for (size_t i = 0; i < sizeof(ns) / sizeof(ns[0]); i++) {
            BOOL got = GFNoSpeechVerdict(ns[i].live, ns[i].segs, ns[i].od, ns[i].chars, ns[i].loud, ns[i].noLoud);
            BOOL ok = got == ns[i].want;
            if (ok) passed++; else failed++;
            printf("%s: no-speech verdict, %s = %s\n", ok ? "PASS" : "FAIL", ns[i].what, got ? "no speech" : "REST");
        }
        {
            // Level check on synthetic audio: room noise (sigma 40) reads 0 s; a 0.4 s word reads ~0.4 s even when the whole clip is
            // speech (the adaptive estimate reads such clips as ~0); a soft (RMS 113, about -49 dBFS) 0.3 s tone still counts; a 60 ms click doesn't.
            const NSUInteger n = 16000;
            int16_t *buf = calloc(n, sizeof(int16_t));
            uint32_t seed = 12345;
            for (NSUInteger i = 0; i < n; i++) {
                double u1 = ((seed = seed * 1103515245u + 12345u) >> 8) / 16777216.0 + 1e-9;
                double u2 = ((seed = seed * 1103515245u + 12345u) >> 8) / 16777216.0;
                buf[i] = (int16_t)lrint(40.0 * sqrt(-2.0 * log(u1)) * cos(2 * M_PI * u2));
            }
            double mx = 0;
            double noise = GFSecondsAboveRMS(buf, n, kNoSpeechFrameRMS, &mx);
            BOOL ok1 = noise == 0.0 && mx < kNoSpeechFrameRMS;
            int16_t *word = calloc(6400, sizeof(int16_t));
            for (NSUInteger i = 0; i < 6400; i++) word[i] = (int16_t)lrint(3000.0 * sin(2 * M_PI * 220.0 * i / 16000.0));
            double wordS = GFSecondsAboveRMS(word, 6400, kNoSpeechFrameRMS, NULL);
            BOOL ok2 = wordS >= 0.38;
            for (NSUInteger i = 0; i < 4800; i++) buf[4000 + i] = (int16_t)lrint(160.0 * sin(2 * M_PI * 180.0 * i / 16000.0));
            double soft = GFSecondsAboveRMS(buf, n, kNoSpeechFrameRMS, NULL);
            BOOL ok3 = soft > kNoSpeechMaxLoudSeconds;
            double click = GFSecondsAboveRMS(word, 960, kNoSpeechFrameRMS, NULL);
            BOOL ok4 = click <= kNoSpeechMaxLoudSeconds && GFSecondsAboveRMS(NULL, 0, kNoSpeechFrameRMS, NULL) == 0.0;
            free(buf); free(word);
            BOOL okAll[] = {ok1, ok2, ok3, ok4};
            const char *what[] = {"room noise reads silent", "all-speech 0.4 s word reads loud", "soft 0.3 s speech reads loud", "60 ms click / empty reads silent"};
            double val[] = {noise, wordS, soft, click};
            for (int i = 0; i < 4; i++) {
                if (okAll[i]) passed++; else failed++;
                printf("%s: no-speech level check, %s (%.2f s above RMS %.0f)\n", okAll[i] ? "PASS" : "FAIL", what[i], val[i], kNoSpeechFrameRMS);
            }
        }
        BOOL nsBoundsOk = kNoSpeechFrameRMS <= 60.0 && kNoSpeechMaxLoudSeconds <= 0.10 && kNoSpeechOnDeviceWait <= 1.0;
        if (nsBoundsOk) passed++; else failed++;
        printf("%s: no-speech thresholds stay conservative (RMS %.0f, %.2f s, wait %.1f s)\n", nsBoundsOk ? "PASS" : "FAIL",
               kNoSpeechFrameRMS, kNoSpeechMaxLoudSeconds, kNoSpeechOnDeviceWait);
        {
            // Backlog 0u: speech evidence on synthetic audio (16 kHz). Room noise whose level wanders between RMS 80 and 200 with
            // ~240-RMS clicks (like the real 2026-11-12 room: max RMS 133-239) and the same room with three loud 20 ms clicks
            // (RMS 1500-2000) must read "no loud speech"; an all-speech 0.4 s word, quiet speech (RMS ~600 over a RMS-65 floor)
            // and a short word over a loud floor must read speech.
            __block uint32_t seed = 777;
            double (^gauss)(void) = ^double {
                double u1 = ((seed = seed * 1103515245u + 12345u) >> 8) / 16777216.0 + 1e-9;
                double u2 = ((seed = seed * 1103515245u + 12345u) >> 8) / 16777216.0;
                return sqrt(-2.0 * log(u1)) * cos(2 * M_PI * u2);
            };
            int16_t *(^room)(NSUInteger, double, double) = ^int16_t *(NSUInteger n, double lo, double hi) {
                int16_t *b = calloc(n, sizeof(int16_t));
                for (NSUInteger i = 0; i < n; i++) {
                    double lvl = lo + (hi - lo) * (0.5 + 0.5 * sin((i / 320) / 7.0));
                    b[i] = (int16_t)lrint(MAX(-32768.0, MIN(32767.0, lvl * gauss())));
                }
                return b;
            };
            void (^burst)(int16_t *, NSUInteger, NSUInteger, double) = ^(int16_t *b, NSUInteger at, NSUInteger len, double rms) {
                for (NSUInteger i = at; i < at + len; i++) b[i] = (int16_t)lrint(MAX(-32768.0, MIN(32767.0, rms * gauss())));
            };
            const NSUInteger hold = 36800, tap = 6240; // 2.3 s hold, 0.39 s tap
            int16_t *h = room(hold, 80, 200);
            burst(h, 4800, 320, 240); burst(h, 17600, 320, 240); burst(h, 30400, 320, 240);
            GFSpeechEvidence eH = GFMeasureSpeechEvidence(h, hold);
            int16_t *t = room(tap, 80, 200);
            burst(t, 1600, 320, 240); burst(t, 4000, 320, 240);
            GFSpeechEvidence eT = GFMeasureSpeechEvidence(t, tap);
            int16_t *k = room(hold, 80, 200);
            burst(k, 8000, 320, 1500); burst(k, 8320, 320, 1500); burst(k, 24000, 320, 2000);
            GFSpeechEvidence eK = GFMeasureSpeechEvidence(k, hold);
            int16_t *w = calloc(6400, sizeof(int16_t));
            for (NSUInteger i = 0; i < 6400; i++) w[i] = (int16_t)lrint(3000.0 * sin(2 * M_PI * 220.0 * i / 16000.0));
            GFSpeechEvidence eW = GFMeasureSpeechEvidence(w, 6400);
            int16_t *q = room(41600, 65, 65); // 2.6 s, floor RMS 65, 1.4 s of quiet "speech" at RMS ~600
            for (NSUInteger i = 8000; i < 8000 + 22400; i++) q[i] = (int16_t)lrint(850.0 * sin(2 * M_PI * 190.0 * i / 16000.0));
            GFSpeechEvidence eQ = GFMeasureSpeechEvidence(q, 41600);
            int16_t *n = room(16000, 400, 400); // loud floor RMS 400, then a 0.3 s word at RMS ~2800
            for (NSUInteger i = 8000; i < 12800; i++) n[i] = (int16_t)lrint(4000.0 * sin(2 * M_PI * 200.0 * i / 16000.0));
            GFSpeechEvidence eN = GFMeasureSpeechEvidence(n, 16000);
            GFSpeechEvidence eE = GFMeasureSpeechEvidence(NULL, 0);
            struct { const char *what; GFSpeechEvidence e; BOOL wantNoLoud; } se[] = {
                {"room noise 2.3 s hold (RMS 80-200, 240 clicks)", eH, YES},
                {"room noise 0.39 s tap", eT, YES},
                {"room noise + three loud 20 ms clicks", eK, YES},
                {"empty buffer", eE, YES},
                {"all-speech 0.4 s word", eW, NO},
                {"quiet speech over a RMS-65 floor", eQ, NO},
                {"0.3 s word over a RMS-400 floor", eN, NO},
            };
            for (size_t i = 0; i < sizeof(se) / sizeof(se[0]); i++) {
                BOOL got = GFNoLoudSpeech(se[i].e.peakRMS, se[i].e.evidenceSeconds);
                BOOL ok = got == se[i].wantNoLoud;
                if (ok) passed++; else failed++;
                printf("%s: 0u speech evidence, %s: max RMS %.0f, noise RMS %.0f, %.2f s above RMS %.0f, loud %.2f s -> %s\n",
                       ok ? "PASS" : "FAIL", se[i].what, se[i].e.peakRMS, se[i].e.noiseRMS, se[i].e.evidenceSeconds,
                       se[i].e.thresholdRMS, se[i].e.loudSeconds, got ? "no loud speech" : "speech");
            }
            BOOL roomLoudOk = eH.loudSeconds > kNoSpeechMaxLoudSeconds; // the old RMS-60 check alone would have sent it to REST
            if (roomLoudOk) passed++; else failed++;
            printf("%s: 0u the synthetic room hold reads %.2f s above RMS 60 (the old check alone said speech)\n",
                   roomLoudOk ? "PASS" : "FAIL", eH.loudSeconds);
            free(h); free(t); free(k); free(w); free(q); free(n);
            BOOL thrOk = GFSpeechEvidenceThreshold(0) == 250.0 && GFSpeechEvidenceThreshold(100) == 300.0
                         && GFSpeechEvidenceThreshold(1862) == 1000.0;
            BOOL boundsOk = kSpeechPeakRMS <= 400.0 && kSpeechEvidenceMinSeconds <= 0.15 && kSpeechEvidenceCapRMS <= 1000.0
                            && kRestCharsPerSpeechSecond >= 30.0;
            if (thrOk) passed++; else failed++;
            if (boundsOk) passed++; else failed++;
            printf("%s: 0u evidence threshold = clamp(3 x noise, 250, 1000)\n", thrOk ? "PASS" : "FAIL");
            printf("%s: 0u speech-evidence bounds keep real speech (peak %.0f, %.2f s, cap %.0f, %.0f chars/s)\n",
                   boundsOk ? "PASS" : "FAIL", kSpeechPeakRMS, kSpeechEvidenceMinSeconds, kSpeechEvidenceCapRMS, kRestCharsPerSpeechSecond);

            // REST plausibility net (synthetic strings only; numbers from the real log / test clips)
            struct { NSUInteger segs; BOOL od; NSUInteger chars; BOOL want; const char *what; } na[] = {
                {0, YES, 0, YES, "Live no text + on-device no speech"},
                {1, YES, 0, NO,  "Live had text"},
                {0, NO,  0, NO,  "on-device gave no verdict (e.g. unavailable)"},
                {0, YES, 5, NO,  "on-device has text"},
            };
            for (size_t i = 0; i < sizeof(na) / sizeof(na[0]); i++) {
                BOOL got = GFRestPlausibilityNetApplies(na[i].segs, na[i].od, na[i].chars);
                BOOL ok = got == na[i].want;
                if (ok) passed++; else failed++;
                printf("%s: 0u REST net applies, %s = %d\n", ok ? "PASS" : "FAIL", na[i].what, got);
            }
            NSString *(^xs)(NSUInteger) = ^NSString *(NSUInteger len) { return [@"" stringByPaddingToLength:len withString:@"x" startingAtIndex:0]; };
            struct { NSString *text; BOOL noLoud; double ev, loud; GFRestPlausibility want; const char *what; } rp[] = {
                {xs(44), GFNoLoudSpeech(156, 1.82), 1.82, 1.82, GFRestImplausibleLength, "44 chars for the silent 2.3 s hold"},
                {xs(52), GFNoLoudSpeech(133, 0.20), 0.20, 0.20, GFRestImplausibleLength, "52 chars for a silent 0.39 s tap"},
                {@"0:00 --", GFNoLoudSpeech(196, 0.20), 0.20, 0.20, GFRestImplausibleTimestamp, "\"0:00 --\" on a silent tap"},
                {@"00:00 Synthetic sentence.", NO, 2.0, 2.0, GFRestImplausibleTimestamp, "\"00:00 ...\" prefix even with speech"},
                {@"[00:00] Synthetic.", NO, 2.0, 2.0, GFRestImplausibleTimestamp, "\"[00:00]\" prefix"},
                {@"Yes.", GFNoLoudSpeech(239, 0.20), 0.20, 0.20, GFRestPlausible, "4 chars on a quiet press (<= 10)"},
                {xs(62), GFNoLoudSpeech(837, 1.42), 1.42, 2.18, GFRestPlausible, "T11 quiet: 62 chars, evidence 1.42 s, loud 2.18 s"},
                {xs(6), GFNoLoudSpeech(5967, 0.36), 0.36, 0.42, GFRestPlausible, "T11 short: 6 chars"},
                {xs(381), GFNoLoudSpeech(560, 3.18), 3.18, 11.90, GFRestPlausible, "quiet_long: 381 chars, loud 11.9 s"},
                {xs(594), NO, 23.92, 26.58, GFRestPlausible, "handsfree_long: 594 chars"},
                {@"9:30 works for the synthetic test.", NO, 1.5, 1.8, GFRestPlausible, "a real time (not a zero timestamp)"},
                {@"10:00 synthetic.", NO, 1.0, 1.0, GFRestPlausible, "10:00 is not a zero timestamp"},
            };
            for (size_t i = 0; i < sizeof(rp) / sizeof(rp[0]); i++) {
                NSUInteger budget = GFRestCharBudget(rp[i].noLoud, rp[i].ev, rp[i].loud);
                GFRestPlausibility got = GFRestOutputPlausibility(rp[i].text, budget);
                BOOL ok = got == rp[i].want;
                if (ok) passed++; else failed++;
                printf("%s: 0u REST plausibility, %s (limit %lu) = %s\n", ok ? "PASS" : "FAIL", rp[i].what,
                       (unsigned long)budget, GFRestPlausibilityName(got));
            }
            // Prompt-echo + noisy-ondevice-blip regressions (2026-11-12 21:39: max RMS 118, evidence 0.00 s, ondevice_chars 2 -> prompt echoed)
            struct { NSString *text; NSUInteger segs; NSString *od; BOOL wantReject; const char *what; } pe[] = {
                {@"Transcribe and clean up this audio dictation.", 0, @"Uh", YES, "prompt echo with 2-char noise"},
                {@"Transcribe and clean up this text.", 0, @"", YES, "prompt echo variant"},
                {@"  transcribe and clean up this... ", 0, @"hello world", YES, "prompt echo even when on-device heard unrelated words"},
                {@"Output only the clean, punctuated transcript of what the user dictated.", 0, @"", YES, "system prompt leak"},
                {@"Transcribe and clean up this audio dictation.", 1, @"", NO, "Live already had segments (skipped)"},
                {@"Transcribe and clean up this audio dictation.", 0, @"transcribe and clean up this audio", NO, "user genuinely spoke it"},
                {@"Please clean up this document.", 0, @"", NO, "ordinary sentence with clean up"},
                {@"Transcribe the meeting notes.", 0, @"", NO, "ordinary sentence starting with transcribe"},
            };
            for (size_t i = 0; i < sizeof(pe) / sizeof(pe[0]); i++) {
                BOOL got = GFRestEchoRejected(pe[i].text, pe[i].segs, pe[i].od);
                BOOL ok = got == pe[i].wantReject;
                if (ok) passed++; else failed++;
                printf("%s: prompt echo, %s = %s\n", ok ? "PASS" : "FAIL", pe[i].what, got ? "rejected" : "kept");
            }
            struct { NSUInteger segs; BOOL odNoSpeech; NSUInteger odChars; BOOL noLoud; BOOL want; const char *what; } sc[] = {
                {0, NO,  2, YES, YES, "21:39 real log: no loud speech + 2-char on-device noise blip"},
                {0, NO,  0, YES, YES, "no loud speech + on-device gave no verdict yet"},
                {0, YES, 0, NO,  YES, "explicit on-device no speech + 0 chars"},
                {0, NO,  5, YES, NO,  "no loud speech but 5+ on-device chars"},
                {0, NO,  2, NO,  NO,  "loud speech present + 2 on-device chars"},
                {1, NO,  0, YES, NO,  "Live had segments"},
            };
            for (size_t i = 0; i < sizeof(sc) / sizeof(sc[0]); i++) {
                BOOL got = GFRestShouldCheckPlausibility(sc[i].segs, sc[i].odNoSpeech, sc[i].odChars, sc[i].noLoud);
                BOOL ok = got == sc[i].want;
                if (ok) passed++; else failed++;
                printf("%s: REST plausibility gate, %s = %d\n", ok ? "PASS" : "FAIL", sc[i].what, got);
            }
            // End-to-end restOutputPlausible:dictation: on a fresh AppDelegate with quiet room noise (1.6 s, peak 118, evidence 0)
            NSMutableData *room16 = [NSMutableData dataWithLength:(NSUInteger)(1.6 * 32000)];
            int16_t *rs16 = (int16_t *)room16.mutableBytes;
            for (NSUInteger i = 0; i < (NSUInteger)(1.6 * 16000); i++) rs16[i] = (int16_t)(160.0 * sin(i * 0.13)); // ~113 RMS
            AppDelegate *(^makeRestCheck)(NSString *, BOOL, BOOL, NSData *) = ^AppDelegate *(NSString *odText, BOOL odNoSp, BOOL sup, NSData *pcmBuf) {
                AppDelegate *d = [[AppDelegate alloc] init]; d.unitTestMode = YES;
                d.recordedPCMData = [pcmBuf mutableCopy];
                if (!sup) { d.latestOnDeviceTranscript = odText; d.onDeviceReportedNoSpeech = odNoSp; }
                return d;
            };
            GFDictation *dActive = [[GFDictation alloc] init]; dActive.serial = 1;
            AppDelegate *a1 = makeRestCheck(@"Uh", NO, NO, room16);
            BOOL p1 = ![a1 restOutputPlausible:@"Transcribe and clean up this audio dictation." dictation:dActive];
            BOOL p2 = ![a1 restOutputPlausible:@"Send the quarterly report to Sarah." dictation:dActive];
            BOOL p3 = [a1 restOutputPlausible:@"Yes." dictation:dActive];
            GFDictation *dSup = [[GFDictation alloc] init]; dSup.serial = 2; dSup.superseded = YES;
            dSup.pcm = room16; dSup.onDeviceText = @"Uh"; dSup.onDeviceNoSpeechAtSupersede = NO;
            AppDelegate *a2 = makeRestCheck(@"", NO, YES, [NSMutableData data]);
            BOOL p4 = ![a2 restOutputPlausible:@"Transcribe and clean up this audio dictation." dictation:dSup];
            NSMutableData *loud16 = [NSMutableData dataWithLength:(NSUInteger)(1.6 * 32000)];
            int16_t *ls16 = (int16_t *)loud16.mutableBytes;
            for (NSUInteger i = 0; i < (NSUInteger)(1.6 * 16000); i++) ls16[i] = (int16_t)(3000.0 * sin(i * 0.13));
            AppDelegate *a3 = makeRestCheck(@"Hello world", NO, NO, loud16);
            BOOL p5 = ![a3 restOutputPlausible:@"Transcribe and clean up this text." dictation:dActive];
            AppDelegate *a4 = makeRestCheck(@"Transcribe and clean up this audio dictation", NO, NO, loud16);
            BOOL p6 = [a4 restOutputPlausible:@"Transcribe and clean up this audio dictation." dictation:dActive];
            BOOL rpAll = p1 && p2 && p3 && p4 && p5 && p6;
            if (rpAll) passed++; else failed++;
            printf("%s: restOutputPlausible integration (21:39 echo+noise, superseded, loud echo vs spoken) = %d/%d/%d/%d/%d/%d\n",
                   rpAll ? "PASS" : "FAIL", p1, p2, p3, p4, p5, p6);
        }
        // HUD / menu-state transitions (no windows: hudPanel and statusItem stay nil in fresh delegates, so these exercise the
        // state logic only). Each case is one terminal path of a dictation.
        {
            AppDelegate *(^fresh)(void) = ^AppDelegate *{ AppDelegate *d = [[AppDelegate alloc] init]; d.unitTestMode = YES; return d; };
            // (1) Empty polished transcript (user only said "um") must end the dictation: icon idle, HUD dismissed.
            AppDelegate *emptyD = fresh();
            [emptyD setMenuIconState:2];
            [emptyD applyFinalTranscript:@""];
            AppDelegate *nilD = fresh();
            [nilD setMenuIconState:2];
            [nilD applyFinalTranscript:nil];
            // (2) A stale dismissal ("No speech" 1.0 s, "Cancelled"-style) must not hide the HUD of a NEW recording.
            AppDelegate *staleD = fresh();
            [staleD showNoSpeechDetected];          // schedules a 1.0 s dismissal
            staleD.isRecording = YES;                // user presses again right away
            [staleD setMenuIconState:1];
            [staleD presentHUD];
            AppDelegate *fastStaleD = fresh();       // post-paste style 0.05 s fade vs. a quick re-press
            [fastStaleD dismissHUDAfterDelay:0.05];
            [fastStaleD presentHUD];
            AppDelegate *controlD = fresh();         // control: no new recording -> the "No speech" dismissal must happen
            [controlD showNoSpeechDetected];
            // (3) Clipboard-only delivery (Accessibility not trusted) must reset the menu icon too.
            AppDelegate *axD = fresh();
            [axD setMenuIconState:2];
            [axD showDeliveredUIAccessibilityTrusted:NO];
            AppDelegate *pasteD = fresh();
            [pasteD setMenuIconState:2];
            [pasteD showDeliveredUIAccessibilityTrusted:YES];
            // Late delivery of the previous dictation while a new one records: leave the recording's icon/HUD alone.
            AppDelegate *lateD = fresh();
            lateD.isRecording = YES;
            [lateD setMenuIconState:1];
            [lateD presentHUD];
            [lateD showDeliveredUIAccessibilityTrusted:YES];
            [lateD applyFinalTranscript:@""];
            // Backlog 6: a superseded dictation finishing while the newer press is already Thinking (isRecording NO, so the
            // returnToIdle guard alone would not protect it) must not reset the newer press's icon or dismiss its HUD.
            AppDelegate *thinkD = fresh();
            GFDictation *oldA = [[GFDictation alloc] init];
            oldA.serial = 1;
            oldA.superseded = YES;
            [thinkD setMenuIconState:2];
            [thinkD presentHUD];
            [thinkD showDeliveredUIAccessibilityTrusted:YES dictation:oldA];
            [thinkD showDeliveredUIAccessibilityTrusted:NO dictation:oldA];
            [thinkD showNoSpeechDetectedForDictation:oldA];
            [thinkD applyFinalTranscript:@"" dictation:oldA];
            AppDelegate *ownD = fresh();             // control: the newest press's own delivery still returns to idle
            GFDictation *curB = [[GFDictation alloc] init];
            curB.serial = 2;
            [ownD setMenuIconState:2];
            [ownD showDeliveredUIAccessibilityTrusted:YES dictation:curB];

            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.6]; // longest scheduled dismissal is 2.2 s
            while ([deadline timeIntervalSinceNow] > 0) {
                [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            }
            struct { __unsafe_unretained AppDelegate *d; NSInteger icon; NSUInteger honored; NSUInteger dropped; const char *what; } hc[] = {
                {emptyD, 0, 1, 0, "empty transcript -> idle icon + HUD dismissed"},
                {nilD, 0, 1, 0, "nil transcript -> idle icon + HUD dismissed"},
                {staleD, 1, 0, 1, "stale No-speech dismissal dropped for a new recording"},
                {fastStaleD, 0, 0, 1, "stale post-paste fade dropped after a re-press"},
                {controlD, 0, 1, 0, "No speech without a new press -> HUD dismissed"},
                {axD, 0, 1, 0, "clipboard-only (Accessibility untrusted) -> idle icon"},
                {pasteD, 0, 1, 0, "auto-paste delivery -> idle icon + HUD dismissed"},
                {lateD, 1, 0, 0, "late delivery during a new recording keeps its icon/HUD"},
                {thinkD, 2, 0, 0, "superseded dictation finishing keeps the newer press's Thinking icon/HUD"},
                {ownD, 0, 1, 0, "newest press's own delivery -> idle icon + HUD dismissed"},
            };
            for (size_t i = 0; i < sizeof(hc) / sizeof(hc[0]); i++) {
                BOOL ok = hc[i].d.menuIconState == hc[i].icon && hc[i].d.hudDismissalsHonored == hc[i].honored
                          && hc[i].d.hudDismissalsDropped == hc[i].dropped;
                if (ok) passed++; else failed++;
                printf("%s: HUD state: %s (icon %ld, dismissed %lu, stale-dropped %lu)\n", ok ? "PASS" : "FAIL", hc[i].what,
                       (long)hc[i].d.menuIconState, (unsigned long)hc[i].d.hudDismissalsHonored, (unsigned long)hc[i].d.hudDismissalsDropped);
            }
        }
        // Backlog 7: a press whose microphone can't be used ends at once with a clear notice (no audio hardware touched here).
        {
            const long ok = AVAuthorizationStatusAuthorized, denied = AVAuthorizationStatusDenied;
            const long restricted = AVAuthorizationStatusRestricted, undetermined = AVAuthorizationStatusNotDetermined;
            struct { GFMicProblem p; long auth; BOOL tried; GFMicAction want; const char *notice; const char *what; } mc[] = {
                {GFMicProblemStartError, ok, NO, GFMicActionRebuild, NULL, "start error -> one engine rebuild first"},
                {GFMicProblemStartError, ok, YES, GFMicActionGiveUp, "Mic unavailable", "start error after the rebuild -> Mic unavailable"},
                {GFMicProblemBadFormat, ok, NO, GFMicActionRebuild, NULL, "0 Hz / 0 channel format -> one engine rebuild first"},
                {GFMicProblemBadFormat, ok, YES, GFMicActionGiveUp, "Mic unavailable", "0 Hz format after the rebuild -> Mic unavailable"},
                {GFMicProblemNoBuffers, ok, NO, GFMicActionRebuild, NULL, "no buffers -> one engine rebuild first"},
                {GFMicProblemNoBuffers, ok, YES, GFMicActionGiveUp, "Mic unavailable", "still no buffers after the rebuild -> Mic unavailable"},
                {GFMicProblemStartError, denied, NO, GFMicActionGiveUp, "Mic access needed", "mic permission denied -> permission notice, no rebuild"},
                {GFMicProblemNone, denied, NO, GFMicActionGiveUp, "Mic access needed", "denied mic that 'starts' (macOS feeds silence) -> permission notice"},
                {GFMicProblemNone, restricted, NO, GFMicActionGiveUp, "Mic access needed", "restricted mic -> permission notice"},
                {GFMicProblemNone, ok, NO, GFMicActionProceed, NULL, "mic started -> normal press, no notice"},
                {GFMicProblemNone, undetermined, NO, GFMicActionProceed, NULL, "mic started, permission not determined -> normal press"},
                {GFMicProblemNone, ok, YES, GFMicActionProceed, NULL, "mic started after the rebuild -> normal press"},
            };
            for (size_t i = 0; i < sizeof(mc) / sizeof(mc[0]); i++) {
                GFMicAction got = GFMicProblemDecision(mc[i].p, mc[i].auth, mc[i].tried);
                BOOL good = got == mc[i].want && (!mc[i].notice || [GFMicProblemNotice(mc[i].auth) isEqualToString:@(mc[i].notice)]);
                if (good) passed++; else failed++;
                printf("%s: mic failure: %s (action %ld)\n", good ? "PASS" : "FAIL", mc[i].what, (long)got);
            }
            // The watchdog must never fire on a slow but working mic: > 3x the slowest real first buffer (0.58 s), bounded.
            BOOL tOk = kMicFirstBufferTimeout >= 3 * 0.58 && kMicFirstBufferTimeout <= 3.0 && kMicRebuildBufferTimeout >= 1.0
                       && kMicFirstBufferTimeout + kMicRebuildBufferTimeout <= 4.0 && kMicNoBufferReleaseMinPress >= 1.5 * 0.58;
            if (tOk) passed++; else failed++;
            printf("%s: mic failure: watchdog %.1fs (+%.1fs after rebuild) is > 3x the slowest real first buffer, notice within 4 s\n",
                   tOk ? "PASS" : "FAIL", kMicFirstBufferTimeout, kMicRebuildBufferTimeout);
            struct { BOOL seen; NSUInteger bytes; double held; BOOL want; const char *what; } rc[] = {
                {NO, 0, 1.5, YES, "release after 1.5 s with no buffer at all -> Mic unavailable"},
                {NO, 0, 0.3, NO, "quick tap released before any buffer -> normal (No speech) path"},
                {YES, 0, 1.5, NO, "buffers arrived (data still queued) -> normal path"},
                {YES, 32000, 3.0, NO, "buffers arriving -> normal path"},
                {NO, 640, 1.5, NO, "recorded audio present -> normal path"},
            };
            for (size_t i = 0; i < sizeof(rc) / sizeof(rc[0]); i++) {
                BOOL good = GFMicNoBuffersAtRelease(rc[i].seen, rc[i].bytes, rc[i].held) == rc[i].want;
                if (good) passed++; else failed++;
                printf("%s: mic failure at release: %s\n", good ? "PASS" : "FAIL", rc[i].what);
            }
            // State: the abort resets the press like Esc does (recording + hands-free off, icon idle, HUD dismissed).
            AppDelegate *(^freshM)(void) = ^AppDelegate *{ AppDelegate *d = [[AppDelegate alloc] init]; d.unitTestMode = YES; return d; };
            AppDelegate *abortD = freshM();
            abortD.isRecording = YES; abortD.isHandsFree = YES; [abortD setMenuIconState:1];
            [abortD abortPressForMicProblem:GFMicProblemStartError micAuth:ok closeLive:YES];
            AppDelegate *permD = freshM();
            permD.isRecording = YES; [permD setMenuIconState:1];
            [permD abortPressForMicProblem:GFMicProblemNone micAuth:denied closeLive:NO];
            // Watchdog: no buffer (rebuild already used, so no hardware is touched) -> ends; buffers arriving -> never fires;
            // a newer press (serial changed) -> the old watchdog is stale.
            AppDelegate *wdFire = freshM();
            wdFire.isRecording = YES; wdFire.micRebuildTried = YES; [wdFire setMenuIconState:1];
            [wdFire armMicWatchdogAfter:0.05];
            AppDelegate *wdBuf = freshM();
            wdBuf.isRecording = YES; wdBuf.micRebuildTried = YES; [wdBuf setMenuIconState:1];
            [wdBuf armMicWatchdogAfter:0.05];
            wdBuf.micBuffersSeen = YES;
            AppDelegate *wdStale = freshM();
            wdStale.isRecording = YES; wdStale.micRebuildTried = YES; [wdStale setMenuIconState:1];
            [wdStale armMicWatchdogAfter:0.05];
            wdStale.dictationSerial += 1;
            NSDate *mdl = [NSDate dateWithTimeIntervalSinceNow:2.3]; // the mic notice is dismissed after 2.0 s
            while ([mdl timeIntervalSinceNow] > 0) {
                [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            }
            struct { __unsafe_unretained AppDelegate *d; BOOL rec; NSInteger icon; NSUInteger honored; const char *notice; const char *what; } ms[] = {
                {abortD, NO, 0, 1, "Mic unavailable", "abort: recording + hands-free off, idle icon, notice, HUD dismissed"},
                {permD, NO, 0, 1, "Mic access needed", "abort (permission denied): permission notice, idle"},
                {wdFire, NO, 0, 1, "Mic unavailable", "watchdog with no buffer ends the press with the notice"},
                {wdBuf, YES, 1, 0, NULL, "watchdog never fires once buffers arrive"},
                {wdStale, YES, 1, 0, NULL, "watchdog of an older press never fires"},
            };
            for (size_t i = 0; i < sizeof(ms) / sizeof(ms[0]); i++) {
                AppDelegate *d = ms[i].d;
                BOOL good = d.isRecording == ms[i].rec && !d.isHandsFree && d.menuIconState == ms[i].icon
                            && d.hudDismissalsHonored == ms[i].honored
                            && (ms[i].notice ? [d.lastMicNotice isEqualToString:@(ms[i].notice)] : d.lastMicNotice == nil);
                if (good) passed++; else failed++;
                printf("%s: mic failure state: %s (recording %d, icon %ld, dismissed %lu, notice %s)\n", good ? "PASS" : "FAIL",
                       ms[i].what, d.isRecording, (long)d.menuIconState, (unsigned long)d.hudDismissalsHonored,
                       d.lastMicNotice.UTF8String ?: "none");
            }
        }
        // Backlog 6: a new press must never lose the previous dictation. Snapshot + late-fallback logic (no windows, no audio).
        {
            struct { NSUInteger segs; double uncovered; NSUInteger od; double loud; BOOL noLoud; GFSupersededLiveAction want; const char *what; } sd[] = {
                {2, 0.10, 40, 3.00, NO, GFSupersededUseLiveText, "Live text covers the speech"},
                {2, 1.20, 40, 3.00, NO, GFSupersededUseRest, "speech after the last Live turn"},
                {0, 0.00, 25, 2.00, NO, GFSupersededUseRest, "no Live text yet, speech"},
                {0, 0.00, 0, 1.50, NO, GFSupersededUseRest, "no Live/on-device text but loud audio"},
                {0, 0.00, 5, 0.00, NO, GFSupersededUseRest, "on-device text on quiet audio"},
                {0, 0.00, 0, 0.04, NO, GFSupersededNoSpeech, "accidental tap (no text, near-silent)"},
                // backlog 0u: real 2026-11-12 16:01:32 silent 2.1 s hold (loud 1.58 s; max RMS < 350) superseded by a new press
                {0, 0.02, 0, 1.58, YES, GFSupersededNoSpeech, "0u: silent hold in a quiet room (loud 1.58 s, no loud speech)"},
                {0, 0.02, 3, 1.58, YES, GFSupersededUseRest, "0u: quiet room but on-device has text"},
                {2, 0.10, 0, 1.58, YES, GFSupersededUseLiveText, "0u: Live text wins over the evidence check"},
            };
            for (size_t i = 0; i < sizeof(sd) / sizeof(sd[0]); i++) {
                GFSupersededLiveAction got = GFSupersededLiveDecision(sd[i].segs, sd[i].uncovered, sd[i].od, sd[i].loud, sd[i].noLoud);
                BOOL ok = got == sd[i].want;
                if (ok) passed++; else failed++;
                printf("%s: superseded press, %s = %s\n", ok ? "PASS" : "FAIL", sd[i].what, GFSupersededActionName(got));
            }
            AppDelegate *snapD = [[AppDelegate alloc] init];
            snapD.unitTestMode = YES;
            NSMutableData *pcmA = [NSMutableData dataWithLength:6400];
            ((int16_t *)pcmA.mutableBytes)[0] = 1234;
            snapD.recordedPCMData = pcmA;
            snapD.committedOnDeviceTranscript = [NSMutableString stringWithString:@"First part."];
            snapD.currentOnDeviceSegment = @"hello world";
            GFDictation *dA = [[GFDictation alloc] init];
            dA.serial = 1;
            snapD.activeDictation = dA;
            [snapD supersedePreviousDictation];                                     // press B starts
            GFDictation *dB = [[GFDictation alloc] init];
            dB.serial = 2;
            snapD.activeDictation = dB;
            snapD.isRecording = YES;
            [snapD.recordedPCMData appendData:[NSMutableData dataWithLength:64000]]; // B records 2 s
            BOOL snapOk = dA.superseded && dA.pcm.length == 6400 && ((const int16_t *)dA.pcm.bytes)[0] == 1234
                          && snapD.recordedPCMData != dA.pcm && [snapD pcmForDictation:dA].length == 6400;
            BOOL textOk = [dA.onDeviceText isEqualToString:@"First part. hello world"];
            BOOL bufOk = [snapD pcmForDictation:dB].length == 64000 && [snapD pcmForDictation:nil].length == 64000;
            // A's REST fails / returns nothing while B records: the old code ignored it ("a new recording is in progress").
            NSMutableArray *got = [NSMutableArray array];
            snapD.resultSink = ^(NSString *t, GFDictation *d) { [got addObject:@[t ?: @"<NO SPEECH>", @(d.serial)]]; };
            [snapD finishWithOnDeviceTranscriptForDictation:dA];
            [snapD finishWithOnDeviceTranscriptForDictation:dA];                    // a second late callback: no double paste
            BOOL lateOk = got.count == 1 && [got[0][1] unsignedIntegerValue] == 1
                          && [[got[0][0] lowercaseString] containsString:@"first part. hello world"];
            BOOL bOk = snapD.isRecording && snapD.activeDictation == dB && !dB.superseded && !dB.finished
                       && [snapD pcmForDictation:dB].length == 64000;
            // Superseded with no on-device text and near-silent audio (accidental tap): no speech, no second recognizer.
            GFDictation *dQ = [[GFDictation alloc] init];
            dQ.serial = 3;
            dQ.superseded = YES;
            dQ.onDeviceText = @"";
            dQ.pcm = [NSMutableData dataWithLength:32000];
            [snapD finishWithOnDeviceTranscriptForDictation:dQ];
            BOOL quietOk = got.count == 2 && [got[1][0] isEqualToString:@"<NO SPEECH>"] && [got[1][1] unsignedIntegerValue] == 3;
            // C presses while B is still finishing: B gets its own snapshot; A's stays untouched.
            [snapD setIsRecording:NO];
            [snapD supersedePreviousDictation];
            BOOL chainOk = dB.superseded && dB.pcm.length == 64000 && dA.pcm.length == 6400 && snapD.recordedPCMData.length == 0;
            BOOL okAll[] = {snapOk, textOk, bufOk, lateOk, bOk, quietOk, chainOk};
            const char *what[] = {"previous press's PCM frozen at the new press (new press records into a fresh buffer)",
                                  "previous press's on-device text frozen (incl. the in-flight segment)",
                                  "the new press's fallbacks read its own buffer",
                                  "late fallback of the previous press delivers its saved text once, during the new recording",
                                  "the new press stays untouched (recording, buffer, not finished)",
                                  "superseded near-silent press ends as no speech",
                                  "third press snapshots the second; the first snapshot is unchanged"};
            for (int i = 0; i < 7; i++) {
                if (okAll[i]) passed++; else failed++;
                printf("%s: new press keeps the previous dictation: %s\n", okAll[i] ? "PASS" : "FAIL", what[i]);
            }
            // Paste ordering: A finishes while B records -> clipboard now, paste deferred; B released -> A pastes, then B.
            AppDelegate *(^freshP)(void) = ^AppDelegate *{ AppDelegate *d = [[AppDelegate alloc] init]; d.unitTestMode = YES; return d; };
            GFDictation *pa = [[GFDictation alloc] init]; pa.serial = 1; pa.superseded = YES;
            GFDictation *pb = [[GFDictation alloc] init]; pb.serial = 2;
            AppDelegate *ordD = freshP();
            ordD.activeDictation = pb;
            ordD.isRecording = YES;
            [ordD requestPasteOfText:@"A text " dictation:pa];
            BOOL deferOk = ordD.pasteLog.count == 0 && ordD.deferredPastes.count == 1 && [ordD.testClipboard isEqualToString:@"A text "];
            ordD.isRecording = NO;                       // B released (stopRecordingAndProcess flushes here)
            [ordD flushDeferredPastes];
            [ordD requestPasteOfText:@"B text " dictation:pb]; // B's text arrives inside A's paste window
            BOOL notYetB = ordD.pasteLog.count == 1;          // B waits until A's Cmd+V has been read
            // B cancelled with Esc: the deferred A still pastes.
            AppDelegate *escD = freshP();
            escD.activeDictation = pb;
            escD.isRecording = YES;
            [escD requestPasteOfText:@"A text " dictation:pa];
            [escD cancelRecording];
            // A finishes after B was already pasted (nothing recording): paste right away.
            AppDelegate *lateP = freshP();
            [lateP requestPasteOfText:@"A text " dictation:pa];
            BOOL immediateOk = lateP.pasteLog.count == 1;
            NSDate *pd = [NSDate dateWithTimeIntervalSinceNow:1.2];
            while ([pd timeIntervalSinceNow] > 0) [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            BOOL orderOk = [ordD.pasteLog isEqualToArray:@[@"A text ", @"B text "]] && !ordD.pasteInFlight
                           && [ordD.testClipboard isEqualToString:@"B text "];
            BOOL escOk = [escD.pasteLog isEqualToArray:@[@"A text "]] && escD.deferredPastes.count == 0;
            BOOL pOk[] = {deferOk, notYetB && orderOk, escOk, immediateOk};
            const char *pWhat[] = {"previous dictation finishing during a recording is copied, paste deferred",
                                   "at release: previous dictation pastes first, then the new one (never interleaved)",
                                   "new press cancelled (Esc): the deferred previous dictation still pastes",
                                   "previous dictation finishing when nothing records pastes right away"};
            for (int i = 0; i < 4; i++) {
                if (pOk[i]) passed++; else failed++;
                printf("%s: paste order: %s\n", pOk[i] ? "PASS" : "FAIL", pWhat[i]);
            }
        }
        // Bounded wait on the Live-failure path (user-approved 2026-11-10): early on-device paste, then a swap only when provably safe
        {
            NSString *pastedT = @"On device text. ", *gem = @"Gemini text. ";
            struct { const char *what; NSString *g; double since; BOOL input, app, field, newer, busy; GFLateSwap want; } ls[] = {
                {"all conditions hold", gem, 2.0, NO, YES, YES, NO, NO, GFLateSwapReplace},
                {"user typed or clicked since the paste", gem, 2.0, YES, YES, YES, NO, NO, GFLateKeepUserInput},
                {"another app is focused", gem, 2.0, NO, NO, YES, NO, NO, GFLateKeepFocusChanged},
                {"another field is focused", gem, 2.0, NO, YES, NO, NO, NO, GFLateKeepFocusChanged},
                {"window over (10.5 s after the paste)", gem, 10.5, NO, YES, YES, NO, NO, GFLateKeepTimeout},
                {"window over even if no input was seen", gem, 30.0, NO, YES, YES, NO, NO, GFLateKeepTimeout},
                {"identical text", @"On device text. ", 2.0, NO, YES, YES, NO, NO, GFLateKeepIdentical},
                {"early text never pasted (clipboard-only)", gem, -1.0, NO, YES, YES, NO, NO, GFLateKeepNotPasted},
                {"a newer press started", gem, 2.0, NO, YES, YES, YES, NO, GFLateKeepNewerPress},
                {"another paste is in flight", gem, 2.0, NO, YES, YES, NO, YES, GFLateKeepPasteBusy},
                {"keystroke and focus change together", gem, 2.0, YES, NO, NO, NO, NO, GFLateKeepUserInput},
            };
            for (size_t i = 0; i < sizeof(ls) / sizeof(ls[0]); i++) {
                GFLateSwap got = GFLateSwapDecision(pastedT, ls[i].g, ls[i].since, ls[i].input, ls[i].app, ls[i].field, ls[i].newer, ls[i].busy);
                BOOL ok = got == ls[i].want;
                if (ok) passed++; else failed++;
                printf("%s: bounded wait swap, %s = %s\n", ok ? "PASS" : "FAIL", ls[i].what, GFLateSwapName(got));
            }
            struct { const char *what; NSUInteger chars; BOOL noSpeech; double loud; BOOL newer, done, want; } ep[] = {
                {"on-device has text, speech", 42, NO, 1.2, NO, NO, YES},
                {"no-speech press (recognizer: no speech, nothing loud)", 0, YES, 0.0, NO, NO, NO},
                {"on-device empty", 0, NO, 1.2, NO, NO, NO},
                {"near-silent audio despite on-device text", 5, NO, 0.05, NO, NO, NO},
                {"recognizer said no speech", 5, YES, 1.0, NO, NO, NO},
                {"a newer press started", 42, NO, 1.2, YES, NO, NO},
                {"on-device finalization already running", 42, NO, 1.2, NO, YES, NO},
            };
            for (size_t i = 0; i < sizeof(ep) / sizeof(ep[0]); i++) {
                BOOL got = GFEarlyPasteAllowed(ep[i].chars, ep[i].noSpeech, ep[i].loud, ep[i].newer, ep[i].done);
                BOOL ok = got == ep[i].want;
                if (ok) passed++; else failed++;
                printf("%s: bounded wait early paste, %s = %s\n", ok ? "PASS" : "FAIL", ep[i].what, got ? "paste" : "wait");
            }
            BOOL tOk = fabs(GFEarlyPasteDelay(0.0) - 3.0) < 1e-9 && fabs(GFEarlyPasteDelay(0.6) - 2.4) < 1e-9
                       && fabs(GFEarlyPasteDelay(2.5) - 1.0) < 1e-9 && fabs(GFEarlyPasteDelay(9.0) - 1.0) < 1e-9
                       && kLateSwapWindow > 0 && kLateSwapWindow <= 10.0;
            if (tOk) passed++; else failed++;
            printf("%s: bounded wait timing (on-device at %.1f s after release, REST gets >= %.1f s, swap window %.0f s)\n",
                   tOk ? "PASS" : "FAIL", kEarlyPasteAfterRelease, kEarlyPasteMinRestTime, kLateSwapWindow);
            // A late Gemini result after an early paste that can't be proven safe: clipboard + Recent, never a paste; only once
            AppDelegate *bw = [[AppDelegate alloc] init]; bw.unitTestMode = YES; bw.recentDictations = [NSMutableArray array];
            GFDictation *ed = [[GFDictation alloc] init]; ed.serial = 1; ed.finished = YES;
            ed.earlyText = pastedT; ed.earlyPasteTime = [NSDate timeIntervalSinceReferenceDate] - 1.0;
            bw.activeDictation = ed; [bw.recentDictations addObject:pastedT];
            [bw applyFinalTranscript:gem dictation:ed];
            BOOL keepOk = bw.pasteLog.count == 0 && [bw.testClipboard isEqualToString:gem] && ed.earlyResolved
                          && [bw.recentDictations isEqualToArray:@[gem, pastedT]];
            [bw applyFinalTranscript:@"Another late result. " dictation:ed];
            BOOL onceOk = keepOk && bw.pasteLog.count == 0 && [bw.testClipboard isEqualToString:gem] && bw.recentDictations.count == 2;
            // REST failed after the early paste: the on-device fallback / no-speech paths must not deliver it again
            AppDelegate *bf = [[AppDelegate alloc] init]; bf.unitTestMode = YES;
            GFDictation *ef = [[GFDictation alloc] init]; ef.serial = 2; ef.finished = YES; ef.earlyText = @"Kept text. ";
            bf.activeDictation = ef;
            [bf finishWithOnDeviceTranscriptForDictation:ef];
            [bf showNoSpeechDetectedForDictation:ef];
            BOOL failOk = ef.earlyResolved && bf.pasteLog.count == 0 && bf.testClipboard == nil && !bf.isFinalizingOnDevice;
            BOOL bOk[] = {keepOk, onceOk, failOk};
            const char *bWhat[] = {"late Gemini text without proof of safety goes to clipboard + Recent, no paste",
                                   "a second late result for the same dictation is ignored",
                                   "REST failure after the early paste keeps it (no second delivery, no No-speech)"};
            for (int i = 0; i < 3; i++) {
                if (bOk[i]) passed++; else failed++;
                printf("%s: bounded wait state: %s\n", bOk[i] ? "PASS" : "FAIL", bWhat[i]);
            }
        }
        // Private temp audio for the WAV fallback (backlog 8): per-user temp dir, 0600, deleted after use, stale files swept
        {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *tmpDir = [NSTemporaryDirectory() stringByStandardizingPath];
            NSString *p1 = GFNewTempAudioPath(), *p2 = GFNewTempAudioPath();
            BOOL pathOk = [[p1 stringByDeletingLastPathComponent].stringByStandardizingPath isEqualToString:tmpDir]
                          && [p1.lastPathComponent hasPrefix:kGFTempAudioPrefix] && [p1.pathExtension isEqualToString:@"wav"]
                          && ![p1 isEqualToString:p2] && ![p1 isEqualToString:kGFLegacyTempAudioPath];
            NSMutableData *wav = [NSMutableData dataWithLength:6400];
            ((uint8_t *)wav.mutableBytes)[100] = 7;
            struct stat st;
            BOOL wrote = GFWritePrivateFile(wav, p1);
            BOOL modeOk = wrote && stat(p1.fileSystemRepresentation, &st) == 0 && (st.st_mode & 0777) == 0600
                          && [[NSData dataWithContentsOfFile:p1] isEqualToData:wav];
            BOOL exclOk = !GFWritePrivateFile([NSData dataWithBytes:"x" length:1], p1) && [[NSData dataWithContentsOfFile:p1] isEqualToData:wav];
            unlink(p1.fileSystemRepresentation);
            NSString *noDir = [tmpDir stringByAppendingPathComponent:@"gf-no-such-dir/geminiflow-x.wav"];
            BOOL failOk = !GFWritePrivateFile(wav, noDir) && ![fm fileExistsAtPath:noDir];
            // Lifecycle: the file exists (0600) while the recognition runs, and done() from another thread deletes it.
            __block NSString *usedPath = nil;
            __block BOOL existedPrivate = NO;
            __block dispatch_block_t doneBlock = nil;
            BOOL started = GFWithTempAudioFile(wav, ^(NSString *path, dispatch_block_t done) {
                struct stat st2;
                usedPath = path;
                existedPrivate = stat(path.fileSystemRepresentation, &st2) == 0 && (st2.st_mode & 0777) == 0600;
                doneBlock = done;
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), done);
            });
            NSDate *ld = [NSDate dateWithTimeIntervalSinceNow:2.0];
            while ([ld timeIntervalSinceNow] > 0 && usedPath && [fm fileExistsAtPath:usedPath])
                [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
            BOOL deletedOk = started && existedPrivate && usedPath && ![fm fileExistsAtPath:usedPath]
                             && [[usedPath stringByDeletingLastPathComponent].stringByStandardizingPath isEqualToString:tmpDir];
            // A second done() (e.g. the backstop timer) is a no-op, and never removes a file that reuses the path.
            if (usedPath) [wav writeToFile:usedPath atomically:NO];
            if (doneBlock) doneBlock();
            BOOL doubleOk = usedPath && [fm fileExistsAtPath:usedPath];
            if (usedPath) unlink(usedPath.fileSystemRepresentation);
            // Stale sweep: old geminiflow-*.wav and the legacy file go; fresh ones and unrelated files stay.
            NSString *dir = [tmpDir stringByAppendingPathComponent:[NSString stringWithFormat:@"gf-test-%@", [NSUUID UUID].UUIDString]];
            [fm createDirectoryAtPath:dir withIntermediateDirectories:NO attributes:nil error:nil];
            NSString *oldWav = [dir stringByAppendingPathComponent:@"geminiflow-old.wav"];
            NSString *newWav = [dir stringByAppendingPathComponent:@"geminiflow-new.wav"];
            NSString *other = [dir stringByAppendingPathComponent:@"other.wav"];
            NSString *legacy = [dir stringByAppendingPathComponent:@"geminiflow_last.wav"];
            NSDictionary *old = @{NSFileModificationDate: [NSDate dateWithTimeIntervalSinceNow:-3600]};
            for (NSString *f in @[oldWav, newWav, other, legacy]) [fm createFileAtPath:f contents:wav attributes:nil];
            for (NSString *f in @[oldWav, other, legacy]) [fm setAttributes:old ofItemAtPath:f error:nil];
            NSUInteger removed = GFRemoveStaleTempAudio(dir, legacy, kGFStaleTempAudioAge);
            BOOL sweepOk = removed == 2 && ![fm fileExistsAtPath:oldWav] && ![fm fileExistsAtPath:legacy]
                           && [fm fileExistsAtPath:newWav] && [fm fileExistsAtPath:other]
                           && GFRemoveStaleTempAudio(dir, [dir stringByAppendingPathComponent:@"missing.wav"], 0) == 1; // fresh one at age 0
            [fm removeItemAtPath:dir error:nil];
            BOOL tOk[] = {pathOk, modeOk, exclOk, failOk, deletedOk, doubleOk, sweepOk};
            const char *tWhat[] = {"temp audio path is unique, inside NSTemporaryDirectory(), never the legacy /tmp file",
                                   "temp audio is written with mode 0600 and the exact bytes",
                                   "an existing file is never reused or overwritten (O_EXCL)",
                                   "a write that fails leaves nothing behind",
                                   "temp audio exists (0600) while in use and is deleted after use (done from another thread)",
                                   "a second done() is a no-op",
                                   "launch sweep removes old dictation audio + legacy file, keeps fresh and unrelated files"};
            for (int i = 0; i < 7; i++) {
                if (tOk[i]) passed++; else failed++;
                printf("%s: private temp audio: %s\n", tOk[i] ? "PASS" : "FAIL", tWhat[i]);
            }
        }
        // Log rotation at launch (backlog 13): > threshold rotates to .1 (replacing an older .1), <= threshold stays; the cached
        // log descriptor follows a rotation to the new file. All in a private temp dir (never the user's real log).
        {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *dir = [[NSTemporaryDirectory() stringByStandardizingPath]
                             stringByAppendingPathComponent:[NSString stringWithFormat:@"gf-logtest-%@", [NSUUID UUID].UUIDString]];
            [fm createDirectoryAtPath:dir withIntermediateDirectories:NO attributes:nil error:nil];
            NSString *log = [dir stringByAppendingPathComponent:@"GeminiFlow.log"];
            NSString *log1 = [log stringByAppendingString:@".1"];
            const unsigned long long limit = 1000;
            NSData *(^bytes)(NSUInteger, char) = ^NSData *(NSUInteger n, char c) {
                NSMutableData *d = [NSMutableData dataWithLength:n]; memset(d.mutableBytes, c, n); return d;
            };
            NSArray<NSString *> *(^listing)(void) = ^NSArray<NSString *> *{
                return [[fm contentsOfDirectoryAtPath:dir error:nil] sortedArrayUsingSelector:@selector(compare:)];
            };
            BOOL limitOk = kGFLogMaxBytes == 5ull * 1024 * 1024;
            BOOL missingOk = GFRotateLogIfNeeded(log, limit) == 0 && listing().count == 0;
            NSData *small = bytes(999, 'a'), *exact = bytes(1000, 'b'), *big = bytes(1001, 'c'), *bigger = bytes(4000, 'd');
            [small writeToFile:log atomically:NO];
            BOOL smallOk = GFRotateLogIfNeeded(log, limit) == 0 && [[NSData dataWithContentsOfFile:log] isEqualToData:small]
                           && ![fm fileExistsAtPath:log1];
            [exact writeToFile:log atomically:NO];
            BOOL exactOk = GFRotateLogIfNeeded(log, limit) == 0 && [[NSData dataWithContentsOfFile:log] isEqualToData:exact]
                           && ![fm fileExistsAtPath:log1];
            [big writeToFile:log atomically:NO];
            BOOL bigOk = GFRotateLogIfNeeded(log, limit) == 1001 && ![fm fileExistsAtPath:log]
                         && [[NSData dataWithContentsOfFile:log1] isEqualToData:big];
            [bigger writeToFile:log atomically:NO]; // an older .1 (the 1001-byte log) already exists
            BOOL replaceOk = GFRotateLogIfNeeded(log, limit) == 4000 && ![fm fileExistsAtPath:log]
                             && [[NSData dataWithContentsOfFile:log1] isEqualToData:bigger]
                             && [listing() isEqualToArray:@[@"GeminiFlow.log.1"]];
            NSString *notFile = [dir stringByAppendingPathComponent:@"adir"];
            [fm createDirectoryAtPath:notFile withIntermediateDirectories:NO attributes:nil error:nil];
            BOOL dirOk = GFRotateLogIfNeeded(notFile, 0) == 0 && [fm fileExistsAtPath:notFile];
            [fm removeItemAtPath:notFile error:nil];
            // Cached descriptor: two lines land in one file; after a rotation the next line creates a fresh log (not into .1).
            [fm removeItemAtPath:log1 error:nil];
            GFLogAppendLine(log, @"one\n");
            GFLogAppendLine(log, @"two\n");
            NSString *(^text)(NSString *) = ^NSString *(NSString *f) { return [NSString stringWithContentsOfFile:f encoding:NSUTF8StringEncoding error:nil]; };
            BOOL appendOk = [text(log) isEqualToString:@"one\ntwo\n"];
            BOOL followOk = GFRotateLogIfNeeded(log, 3) == 8;
            GFLogAppendLine(log, @"three\n");
            followOk = followOk && [text(log) isEqualToString:@"three\n"] && [text(log1) isEqualToString:@"one\ntwo\n"];
            [fm removeItemAtPath:log error:nil]; // deleted under the open descriptor: the next line recreates it
            GFLogAppendLine(log, @"four\n");
            followOk = followOk && [text(log) isEqualToString:@"four\n"];
            [fm removeItemAtPath:dir error:nil];
            BOOL rOk[] = {limitOk, missingOk, smallOk, exactOk, bigOk, replaceOk, dirOk, appendOk, followOk};
            const char *rWhat[] = {"rotation threshold is 5 MB",
                                   "a missing log is not rotated and nothing is created",
                                   "a log below the threshold is not rotated",
                                   "a log exactly at the threshold is not rotated",
                                   "a log above the threshold moves to .1 with its exact bytes",
                                   "an existing .1 is replaced (exactly one old log kept)",
                                   "a non-regular file is never rotated",
                                   "cached log descriptor appends lines in order",
                                   "after a rotation or deletion the next line goes to a fresh log, never into .1"};
            for (int i = 0; i < 9; i++) {
                if (rOk[i]) passed++; else failed++;
                printf("%s: log rotation: %s\n", rOk[i] ? "PASS" : "FAIL", rWhat[i]);
            }
        }
        // WAV fallback watchdog (backlog 9): a recognizer that never calls back ends the dictation after a limit scaled to the
        // audio, with what it heard so far; a recognizer that is still sending results is never cut off before the hard cap.
        {
            void (^pump)(NSTimeInterval, BOOL (^)(void)) = ^(NSTimeInterval secs, BOOL (^stop)(void)) {
                NSDate *until = [NSDate dateWithTimeIntervalSinceNow:secs];
                while ([until timeIntervalSinceNow] > 0 && !(stop && stop()))
                    [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            };
            // Limit: >= 5 s, >= 13x the slowest real recognition (0.184 s for 5.07 s = 0.0363 s per audio second), under the cap
            BOOL limitOk = fabs(GFWavWatchdogLimit(5.07) - 7.535) < 1e-9 && fabs(GFWavWatchdogLimit(0) - 5.0) < 1e-9
                           && GFTempAudioBackstopSeconds(10) == 300.0 && GFTempAudioBackstopSeconds(100) == 400.0;
            for (double a = 0.1; a <= 3600.0; a *= 1.1)
                if (GFWavWatchdogLimit(a) < MAX(5.0, 13.0 * 0.0363 * a) || GFWavWatchdogLimit(a) >= GFTempAudioBackstopSeconds(a)) limitOk = NO;
            // Wait: never gives up before the limit; at/after it only once results have been quiet >= 3 s; always at the cap
            BOOL waitOk = YES;
            const double L = 7.5, Q = kGFWavWatchdogQuietSeconds, C = 300.0;
            for (double e = 0; e < L; e += 0.05) {
                if (fabs(GFWavWatchdogWait(e, L, Q, C, -1) - (L - e)) > 1e-9) waitOk = NO;
                for (double sp = 0; sp <= e; sp += 0.25) if (GFWavWatchdogWait(e, L, Q, C, sp) <= 0) waitOk = NO;
            }
            for (double e = L; e < C; e += 0.37) {
                if (GFWavWatchdogWait(e, L, Q, C, -1) != 0) waitOk = NO;
                for (double sp = 0; sp < Q * 2; sp += 0.1) {
                    double w = GFWavWatchdogWait(e, L, Q, C, sp);
                    if (sp < Q - 1e-9 ? fabs(w - MIN(Q - sp, C - e)) > 1e-9 : w != 0) waitOk = NO;
                }
            }
            if (GFWavWatchdogWait(C, L, Q, C, 0) != 0 || GFWavWatchdogWait(C + 1, L, Q, C, 0) != 0) waitOk = NO;
            // Lifecycle (scaled timings): silent recognizer -> fires at the limit with no text
            __block NSTimeInterval firedAt = -1; __block NSString *firedText = nil; __block int fires = 0;
            void (^onExpire)(GFWavWatchdog *, NSTimeInterval) = ^(GFWavWatchdog *w, NSTimeInterval el) { fires++; firedAt = el; firedText = w.partialText; };
            GFWavWatchdog *w1 = [[GFWavWatchdog alloc] initWithLimit:0.3 quiet:0.2 cap:5];
            [w1 startWithExpiry:onExpire];
            pump(1.0, ^BOOL { return fires > 0; });
            pump(0.1, nil);
            BOOL silentOk = fires == 1 && firedAt >= 0.3 && firedAt < 0.6 && [firedText isEqualToString:@""] && w1.ended && ![w1 end];
            // Partial text then nothing (stuck before its final): fires at the limit with the partial text
            fires = 0; firedAt = -1; firedText = nil;
            GFWavWatchdog *w2 = [[GFWavWatchdog alloc] initWithLimit:0.3 quiet:0.2 cap:5];
            [w2 startWithExpiry:onExpire];
            pump(0.05, nil);
            [w2 noteProgress:@"hello there"];
            [w2 noteProgress:@""]; // an empty partial keeps the last text
            pump(1.0, ^BOOL { return fires > 0; });
            BOOL partialOk = fires == 1 && firedAt >= 0.3 && firedAt < 0.6 && [firedText isEqualToString:@"hello there"] && w2.progressCount == 2;
            [w2 noteProgress:@"late"];
            partialOk = partialOk && [w2.partialText isEqualToString:@"hello there"] && w2.progressCount == 2;
            // Still progressing past the limit: not cut off until results stop for the quiet window
            fires = 0; firedAt = -1;
            GFWavWatchdog *w3 = [[GFWavWatchdog alloc] initWithLimit:0.3 quiet:0.2 cap:5];
            [w3 startWithExpiry:onExpire];
            NSTimeInterval t3 = [NSDate timeIntervalSinceReferenceDate];
            BOOL early3 = NO;
            for (int i = 1; i <= 8; i++) { pump(0.1, nil); if (fires) early3 = YES; [w3 noteProgress:[NSString stringWithFormat:@"word %d", i]]; }
            NSTimeInterval lastNote = [NSDate timeIntervalSinceReferenceDate] - t3;
            pump(1.5, ^BOOL { return fires > 0; });
            BOOL progressOk = !early3 && fires == 1 && firedAt >= lastNote + 0.2 - 0.02 && firedAt < lastNote + 0.5
                              && [firedText isEqualToString:@"word 8"];
            // A final result before the limit: the watchdog never fires
            fires = 0;
            GFWavWatchdog *w4 = [[GFWavWatchdog alloc] initWithLimit:0.2 quiet:0.1 cap:5];
            [w4 startWithExpiry:onExpire];
            w4.task = [NSObject new];
            pump(0.05, nil);
            BOOL endedFirst = [w4 end];
            pump(0.5, nil);
            BOOL finalOk = endedFirst && fires == 0 && ![w4 end] && w4.task == nil;
            // Endless partial results: the hard cap still ends it
            fires = 0; firedAt = -1;
            GFWavWatchdog *w5 = [[GFWavWatchdog alloc] initWithLimit:0.2 quiet:0.3 cap:0.6];
            [w5 startWithExpiry:onExpire];
            for (int i = 0; i < 30 && !fires; i++) { [w5 noteProgress:@"again"]; pump(0.05, nil); }
            BOOL capOk = fires == 1 && firedAt >= 0.6 - 0.02 && firedAt < 0.9;
            BOOL wOk[] = {limitOk, waitOk, silentOk, partialOk, progressOk, finalOk, capOk};
            const char *wWhat[] = {"limit = 5 s + 0.5 s/audio s: >= 13x the slowest real recognition, below the temp-file backstop",
                                   "never gives up before the limit; past it only after 3 s without a result; always at the cap",
                                   "a recognizer that never calls back is ended at the limit (no text -> no speech)",
                                   "one stuck before its final is ended at the limit with its latest partial text, once",
                                   "a recognizer still sending results past the limit is not cut off until they stop",
                                   "a final result before the limit ends it once; the watchdog never fires and drops the task",
                                   "endless partial results still end at the hard cap"};
            for (int i = 0; i < 7; i++) {
                if (wOk[i]) passed++; else failed++;
                printf("%s: WAV fallback watchdog: %s\n", wOk[i] ? "PASS" : "FAIL", wWhat[i]);
            }
        }
        {
            // API key out of URLs (backlog 15): log redaction, request builders, Live header-auth fallback decision
            NSString *fake = [@"AI" stringByAppendingString:@"zaSyFAKE0123456789abcdefghijKLMNOPQRS"]; // split: not a real key; keeps secret scanners quiet
            NSError *urlErr = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:@{
                @"NSErrorFailingURLStringKey": [NSString stringWithFormat:@"%@/models/m:generateContent%@%@", kGeminiRESTBase, @"?key=", fake],
                NSURLErrorFailingURLErrorKey: [NSURL URLWithString:[@"https://generativelanguage.googleapis.com/v1beta/models?key=" stringByAppendingString:fake]],
                NSLocalizedDescriptionKey: @"The request timed out."}];
            struct { NSString *in; NSString *known; NSString *mustNot; NSString *must; } rd[] = {
                {[@"GET https://h/v1beta/models?page=1&key=" stringByAppendingString:fake], nil, fake, @"&key=<redacted>"},
                {@"failed: https://h/x?key=abc123DEF&alt=json", nil, @"abc123DEF", @"?key=<redacted>&alt=json"},
                {@"wss://h/ws/Bidi?key=k-_9xyz) closed", nil, @"k-_9xyz", @"?key=<redacted>) closed"},
                {@"redirect=https%3A%2F%2Fh%2Fx%3Fkey%3Dzzz999 end", nil, @"zzz999", @"key%3D<redacted> end"},
                {@"header x-goog-api-key: hdrSecret77, next", nil, @"hdrSecret77", @"x-goog-api-key: <redacted>, next"},
                {@"{\"x-goog-api-key\":\"jsonSecret88\"}", nil, @"jsonSecret88", @"<redacted>"},
                {@"oops MyPlainKey123456 leaked", @"MyPlainKey123456", @"MyPlainKey123456", @"oops <redacted> leaked"},
                {[NSString stringWithFormat:@"REST error %@", urlErr], nil, fake, [NSString stringWithFormat:@"NSErrorFailingURLStringKey=%@/models/m:generateContent%@", kGeminiRESTBase, @"?key=<redacted>"]},
                {@"POST /x?api_key=pk111&apiKey=pk222 done", nil, @"pk1", @"?api_key=<redacted>&apiKey=<redacted> done"},
                {[NSString stringWithFormat:@"bare %@ in text", fake], nil, fake, @"bare <redacted> in text"},
                {@"Live: setupComplete", nil, @"<redacted>", @"Live: setupComplete"},
                {@"modifier event via tap: keyCode=63 fnFlag=1", @"short", @"<redacted>", @"keyCode=63 fnFlag=1"},
            };
            for (size_t i = 0; i < sizeof(rd) / sizeof(rd[0]); i++) {
                NSString *o = GFRedactSecrets(rd[i].in, rd[i].known);
                BOOL ok = ![o containsString:rd[i].mustNot] && [o containsString:rd[i].must];
                if (ok) passed++; else failed++;
                printf("%s: log redaction #%zu -> %s\n", ok ? "PASS" : "FAIL", i + 1, ok ? [rd[i].must UTF8String] : [o UTF8String]);
            }
            NSString *k = @"TESTKEY-0123456789_abc";
            NSURLRequest *rq[] = {GFGeminiRequest(GFGenerateContentURL(kDefaultModel), k), GFGeminiRequest(GFRestWarmupURL(), k),
                                  GFGeminiRequest(GFModelInfoURL(kDefaultLiveModel), k), GFLiveWebSocketRequest(k, NO)};
            const char *rqName[] = {"REST generateContent", "REST pre-warm HEAD", "API key check", "Live upgrade (header auth)"};
            NSString *rqSuffix[] = {@":generateContent", @"/models?pageSize=1", [@"/models/" stringByAppendingString:kDefaultLiveModel],
                                    @".GenerativeService.BidiGenerateContent"};
            for (int i = 0; i < 4; i++) {
                NSString *u = rq[i].URL.absoluteString;
                BOOL ok = u.length > 0 && [u rangeOfString:@"key=" options:NSCaseInsensitiveSearch].location == NSNotFound && ![u containsString:k]
                          && [u hasSuffix:rqSuffix[i]] && [[rq[i] valueForHTTPHeaderField:@"x-goog-api-key"] isEqualToString:k];
                if (ok) passed++; else failed++;
                printf("%s: %s request: no key in the URL, key in the x-goog-api-key header\n", ok ? "PASS" : "FAIL", rqName[i]);
            }
            NSURLRequest *fb = GFLiveWebSocketRequest(k, YES);
            BOOL okFb = [fb.URL.absoluteString isEqualToString:[NSString stringWithFormat:@"%@%@%@", kGeminiLiveWSURL, @"?key=", k]]
                        && [fb valueForHTTPHeaderField:@"x-goog-api-key"] == nil;
            if (okFb) passed++; else failed++;
            printf("%s: Live key-in-URL fallback request = the old URL form (no header)\n", okFb ? "PASS" : "FAIL");
            BOOL okNoKey = [GFGeminiRequest(GFRestWarmupURL(), nil) valueForHTTPHeaderField:@"x-goog-api-key"] == nil;
            if (okNoKey) passed++; else failed++;
            printf("%s: no key -> no header\n", okNoKey ? "PASS" : "FAIL");
            struct { NSInteger http, close; NSString *reason; NSString *dom; NSInteger code; BOOL want; } au[] = {
                {401, 0, nil, NSURLErrorDomain, NSURLErrorBadServerResponse, YES},
                {403, 0, nil, nil, 0, YES},
                {400, 0, nil, nil, 0, YES},
                {0, 1008, nil, NSPOSIXErrorDomain, 57, YES},
                {0, 1007, @"API key not valid. Please pass a valid API key.", nil, 0, YES},
                {0, 1000, @"Request had invalid authentication credentials.", nil, 0, YES},
                {0, 0, nil, NSURLErrorDomain, NSURLErrorBadServerResponse, YES},
                {0, 0, nil, NSURLErrorDomain, NSURLErrorNotConnectedToInternet, NO},
                {0, 0, nil, NSURLErrorDomain, NSURLErrorTimedOut, NO},
                {0, 0, nil, NSURLErrorDomain, NSURLErrorNetworkConnectionLost, NO},
                {0, 0, nil, NSURLErrorDomain, NSURLErrorCannotFindHost, NO},
                {0, 0, nil, NSURLErrorDomain, NSURLErrorCancelled, NO},
                {0, 1011, @"Internal error encountered.", NSPOSIXErrorDomain, 57, NO},
                {503, 0, nil, NSURLErrorDomain, NSURLErrorBadServerResponse, YES}, // bad response code wins; one retry is harmless
                {0, 0, nil, nil, 0, NO},
            };
            int auBad = 0;
            for (size_t i = 0; i < sizeof(au) / sizeof(au[0]); i++)
                if (GFLiveFailureLooksLikeAuth(au[i].http, au[i].close, au[i].reason, au[i].dom, au[i].code) != au[i].want) {
                    auBad++; printf("  auth classifier case %zu wrong\n", i + 1);
                }
            if (auBad == 0) passed++; else failed++;
            printf("%s: Live auth-failure classifier (4xx / close 1007-1008 / auth reason / bad response = auth; offline, timeout, reset, 1011 = not)\n",
                   auBad == 0 ? "PASS" : "FAIL");
            struct { BOOL hdr, setup; GFLiveAuthMode mode; BOOL rec, fin, ours, auth, want; } rt[] = {
                {YES, NO, GFLiveAuthUntested, YES, NO, YES, YES, YES},
                {YES, NO, GFLiveAuthKeyInURL, YES, NO, YES, YES, YES},
                {NO,  NO, GFLiveAuthUntested, YES, NO, YES, YES, NO},  // already the key-in-URL session: no second retry
                {YES, YES, GFLiveAuthUntested, YES, NO, YES, YES, NO}, // after setupComplete: the mid-press reconnect logic owns it
                {YES, NO, GFLiveAuthHeaderOK, YES, NO, YES, YES, NO},  // header auth confirmed this run: never fall back
                {YES, NO, GFLiveAuthUntested, NO, NO, YES, YES, NO},   // press cancelled/finished
                {YES, NO, GFLiveAuthUntested, YES, YES, YES, YES, NO}, // released before setup: REST as before
                {YES, NO, GFLiveAuthUntested, YES, NO, NO, YES, NO},   // stale socket
                {YES, NO, GFLiveAuthUntested, YES, NO, YES, NO, NO},   // network failure: fail as before
            };
            int rtBad = 0;
            for (size_t i = 0; i < sizeof(rt) / sizeof(rt[0]); i++)
                if (GFLiveShouldRetryWithKeyInURL(rt[i].hdr, rt[i].setup, rt[i].mode, rt[i].rec, rt[i].fin, rt[i].ours, rt[i].auth) != rt[i].want) {
                    rtBad++; printf("  key-in-URL retry case %zu wrong\n", i + 1);
                }
            if (rtBad == 0) passed++; else failed++;
            printf("%s: Live key-in-URL retry only for an auth failure of a header session before setupComplete, while recording\n",
                   rtBad == 0 ? "PASS" : "FAIL");
            // An offline header-auth connect that fails before setupComplete fails exactly as before (no key-in-URL retry)
            NSURLSession *us4 = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
            AppDelegate *c4 = [[AppDelegate alloc] init];
            c4.unitTestMode = YES; c4.isRecording = YES; c4.liveSessionId = 7; c4.liveAuthViaHeader = YES;
            c4.liveWebSocketTask = [us4 webSocketTaskWithRequest:GFLiveWebSocketRequest(k, NO)];
            [c4 liveConnectionLost:@"receive: offline" session:7 task:c4.liveWebSocketTask
                             error:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil]];
            BOOL okC4 = c4.liveFailed && !c4.liveNextConnectKeyInURL && c4.liveSessionId == 7 && c4.liveReconnects == 0;
            [us4 invalidateAndCancel];
            if (okC4) passed++; else failed++;
            printf("%s: offline header-auth connect failure falls back as before (no key-in-URL retry)\n", okC4 ? "PASS" : "FAIL");

            // Live setup message + the e2e-only setup probe hook (backlog 0y-probe, --e2e-live-setup-extra <json>)
            NSString *sm = kDefaultLiveModel;
            NSData *(^ser)(id, NSJSONWritingOptions) = ^NSData *(id o, NSJSONWritingOptions opt) {
                return [NSJSONSerialization dataWithJSONObject:o options:opt error:nil];
            };
            // exactly what startGeminiLiveWebSocketResuming: built inline before the probe hook existed
            NSDictionary *todaySetup = @{@"setup": @{@"model": [NSString stringWithFormat:@"models/%@", sm],
                                                     @"generationConfig": @{@"responseModalities": @[@"TEXT"]},
                                                     @"realtimeInputConfig": @{@"automaticActivityDetection": @{@"disabled": @YES}}}};
            NSString *todaySorted = @"{\"setup\":{\"generationConfig\":{\"responseModalities\":[\"TEXT\"]},\"model\":\"models\\/gemini-3.5-transcribe-live\","
                                    @"\"realtimeInputConfig\":{\"automaticActivityDetection\":{\"disabled\":true}}}}";
            BOOL okToday = YES;
            for (NSDictionary *noExtra in @[[NSNull null], @{}]) {
                NSDictionary *m = GFLiveSetupMessage(sm, [noExtra isKindOfClass:[NSDictionary class]] ? noExtra : nil);
                okToday = okToday && [m isEqual:todaySetup] && [ser(m, 0) isEqualToData:ser(todaySetup, 0)] && ser(m, 0).length > 0
                          && [[[NSString alloc] initWithData:ser(m, NSJSONWritingSortedKeys) encoding:NSUTF8StringEncoding] isEqualToString:todaySorted];
            }
            if (okToday) passed++; else failed++;
            printf("%s: Live setup message without the probe hook (nil or {}) = today's message, byte for byte (%lu bytes)\n",
                   okToday ? "PASS" : "FAIL", (unsigned long)ser(GFLiveSetupMessage(sm, nil), 0).length);
            NSDictionary *px = GFParseLiveSetupExtra(@"{\"inputAudioTranscription\":{\"languageCodes\":[\"en-US\"],\"customVocabulary\":[\"Siobhan\",\"Zyphra\"],\"mode\":\"SMART\"},"
                                                     @"\"generationConfig\":{\"responseModalities\":[\"AUDIO\"],\"speechConfig\":{\"languageCode\":\"en-US\"}},"
                                                     @"\"realtimeInputConfig\":{\"automaticActivityDetection\":{\"startOfSpeechSensitivity\":\"START_SENSITIVITY_HIGH\"}}}");
            NSDictionary *wantMerged = @{@"setup": @{
                @"model": [NSString stringWithFormat:@"models/%@", sm],
                @"generationConfig": @{@"responseModalities": @[@"AUDIO"], @"speechConfig": @{@"languageCode": @"en-US"}},
                @"realtimeInputConfig": @{@"automaticActivityDetection": @{@"disabled": @YES, @"startOfSpeechSensitivity": @"START_SENSITIVITY_HIGH"}},
                @"inputAudioTranscription": @{@"languageCodes": @[@"en-US"], @"customVocabulary": @[@"Siobhan", @"Zyphra"], @"mode": @"SMART"}}};
            NSDictionary *merged = GFLiveSetupMessage(sm, px);
            BOOL okMerge = px != nil && [merged isEqual:wantMerged] && [NSJSONSerialization isValidJSONObject:merged]
                           && [GFParseLiveSetupExtra([[NSString alloc] initWithData:ser(merged, 0) encoding:NSUTF8StringEncoding]) isEqual:wantMerged]
                           && [GFLiveSetupMessage(sm, nil) isEqual:todaySetup]; // the base is not mutated by a merge
            if (okMerge) passed++; else failed++;
            printf("%s: Live setup probe extra is deep-merged into setup (nested dictionaries merge, arrays are replaced, new keys added)\n",
                   okMerge ? "PASS" : "FAIL");
            NSDictionary *pn = GFParseLiveSetupExtra(@"{\"realtimeInputConfig\":null,\"model\":\"models/other\","
                                                     @"\"generationConfig\":{\"responseModalities\":null,\"x\":{\"y\":null,\"z\":1}},\"absent\":null}");
            NSDictionary *wantNull = @{@"setup": @{@"model": @"models/other", @"generationConfig": @{@"x": @{@"z": @1}}}};
            BOOL okNull = pn != nil && [GFLiveSetupMessage(sm, pn) isEqual:wantNull]
                          && [GFJSONDeepMerge(@{@"a": @"text"}, @{@"a": @{@"b": @2}}) isEqual:@{@"a": @{@"b": @2}}]
                          && [GFJSONDeepMerge(@{@"a": @{@"b": @2}}, @{@"a": @"text"}) isEqual:@{@"a": @"text"}];
            if (okNull) passed++; else failed++;
            printf("%s: Live setup probe extra: null removes a key, scalars and objects replace each other\n", okNull ? "PASS" : "FAIL");
            BOOL okParse = [GFParseLiveSetupExtra(@"{}") isEqual:@{}] && [GFParseLiveSetupExtra(@"{\"a\":{\"b\":[1,2]}}") isEqual:@{@"a": @{@"b": @[@1, @2]}}]
                           && GFParseLiveSetupExtra(@"[1,2]") == nil && GFParseLiveSetupExtra(@"\"text\"") == nil && GFParseLiveSetupExtra(@"{not json") == nil
                           && GFParseLiveSetupExtra(@"") == nil && GFParseLiveSetupExtra(nil) == nil;
            if (okParse) passed++; else failed++;
            printf("%s: --e2e-live-setup-extra accepts only a JSON object\n", okParse ? "PASS" : "FAIL");
            // The hook is honoured only in e2e mode: outside it the app sends today's message whatever the property holds
            AppDelegate *pd = [[AppDelegate alloc] init];
            pd.unitTestMode = YES;
            pd.e2eLiveSetupExtra = px;
            BOOL okGuardOff = [pd liveSetupProbeExtra] == nil && [GFLiveSetupMessage(sm, [pd liveSetupProbeExtra]) isEqual:todaySetup]
                              && [ser(GFLiveSetupMessage(sm, [pd liveSetupProbeExtra]), 0) isEqualToData:ser(todaySetup, 0)];
            [pd handleLiveMessage:@{@"voiceActivity": @{@"type": @"ACTIVITY_START"}} session:0]; // no probe state outside e2e mode
            okGuardOff = okGuardOff && pd.e2eLiveSeenFields == nil;
            pd.e2eMode = @"file";
            BOOL okGuardOn = [pd liveSetupProbeExtra] == px && [GFLiveSetupMessage(sm, [pd liveSetupProbeExtra]) isEqual:wantMerged];
            pd.e2eLiveSetupExtra = nil;
            okGuardOn = okGuardOn && [pd liveSetupProbeExtra] == nil; // e2e mode without the flag: nothing either
            if (okGuardOff && okGuardOn) passed++; else failed++;
            printf("%s: the setup probe extra is ignored outside e2e mode (and absent in e2e mode without the flag)\n",
                   okGuardOff && okGuardOn ? "PASS" : "FAIL");
            // Probe log lines: fixed shapes (parsed by run_tests.py), names and numbers only
            pd.e2eLiveSeenFields = [NSMutableSet set];
            [pd e2eNoteLiveProbeMessage:@{@"serverContent": @{@"inputTranscription": @{@"text": @"secret words", @"extra": @{@"deep": @"x"}}}}];
            [pd e2eNoteLiveProbeMessage:@{@"serverContent": @{@"generationComplete": @YES}, @"usageMetadata": @{}}];
            NSString *fieldsLine = GFLiveProbeFieldsLine(pd.e2eLiveSeenFields);
            BOOL okLines = [fieldsLine isEqualToString:@"E2E: Live setup probe: server message fields seen: [serverContent.generationComplete, "
                                                       @"serverContent.inputTranscription.extra, serverContent.inputTranscription.text, usageMetadata]"]
                && [GFLiveProbeSetupLine(1, @{}, 150, NO) isEqualToString:@"E2E: Live setup probe: session 1 sends the setup with 0 extra field(s) [] (150 bytes, key via header)"]
                && [GFLiveProbeSetupLine(2, px, 400, YES) isEqualToString:@"E2E: Live setup probe: session 2 sends the setup with 6 extra field(s) "
                    @"[setup.generationConfig.responseModalities, setup.generationConfig.speechConfig.languageCode, setup.inputAudioTranscription.customVocabulary, "
                    @"setup.inputAudioTranscription.languageCodes, setup.inputAudioTranscription.mode, "
                    @"setup.realtimeInputConfig.automaticActivityDetection.startOfSpeechSensitivity] (400 bytes, key via URL)"]
                && [GFLiveProbeSetupCompleteLine(1, YES, 183.4) isEqualToString:@"E2E: Live setup probe: setupComplete=1 (session 1, key via header, 183 ms after the setup was sent)"]
                && [GFLiveProbeCloseLine(NO, 1, YES, 0, 1007, @"Unknown name \"mode\"\nat 'setup'", NSPOSIXErrorDomain, 57)
                    isEqualToString:@"E2E: Live setup probe: socket closed before setupComplete (setupComplete=0, session 1, key via header, HTTP 0, close code 1007, "
                                    @"error NSPOSIXErrorDomain 57) close reason \"Unknown name 'mode' at 'setup'\""]
                && [GFLiveProbeCloseLine(YES, 3, NO, 101, 1011, nil, nil, 0)
                    isEqualToString:@"E2E: Live setup probe: socket closed after setupComplete (setupComplete=1, session 3, key via URL, HTTP 101, close code 1011, "
                                    @"error none 0) close reason \"\""]
                && [GFLiveProbeErrorFrameLine(@{@"error": @{@"code": @400, @"status": @"INVALID_ARGUMENT", @"message": @"Bad \"mode\"."}}, NO)
                    isEqualToString:@"E2E: Live setup probe: server error frame (setupComplete=0, code 400, status INVALID_ARGUMENT) message \"Bad 'mode'.\""]
                && [GFLiveProbeErrorFrameLine(@{@"error": @"boom"}, YES)
                    isEqualToString:@"E2E: Live setup probe: server error frame (setupComplete=1, code 0, status none) message \"boom\""]
                && GFLiveProbeErrorFrameLine(@{@"serverContent": @{@"error": @"not top level"}}, YES) == nil
                && [fieldsLine rangeOfString:@"secret"].location == NSNotFound
                && GFLiveProbeClean([@"" stringByPaddingToLength:500 withString:@"r" startingAtIndex:0], 400).length == 403;
            if (okLines) passed++; else failed++;
            printf("%s: setup probe log lines: setup fields, setupComplete, close before/after setupComplete, error frame, server field names (no values)\n",
                   okLines ? "PASS" : "FAIL");
            // In a probe run a socket failure takes the same decisions as always (the probe only adds its log line): an offline
            // failure before setupComplete fails the Live session, with no key-in-URL retry and no reconnect.
            NSURLSession *us5 = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
            AppDelegate *c5 = [[AppDelegate alloc] init];
            c5.unitTestMode = YES; c5.e2eMode = @"file"; c5.e2eLiveSetupExtra = px;
            c5.isRecording = YES; c5.liveSessionId = 7; c5.liveAuthViaHeader = YES;
            c5.liveWebSocketTask = [us5 webSocketTaskWithRequest:GFLiveWebSocketRequest(k, NO)];
            c5.e2eLiveSeenFields = [NSMutableSet setWithObject:@"setupComplete"];
            [c5 liveConnectionLost:@"receive: offline" session:7 task:c5.liveWebSocketTask
                             error:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil]];
            BOOL okC5 = c5.liveFailed && !c5.liveNextConnectKeyInURL && c5.liveSessionId == 7 && c5.liveReconnects == 0
                        && c5.liveWebSocketTask == nil && c5.e2eLiveSeenFields == nil;
            [us5 invalidateAndCancel];
            if (okC5) passed++; else failed++;
            printf("%s: a socket failure in a setup probe run falls back exactly as a normal one (probe adds log lines only)\n", okC5 ? "PASS" : "FAIL");
        }
        // Changelog data & filter invariants (Foundation-only; also runs in GFEngine --test on iOS)
        {
            NSArray<NSDictionary *> *builtIn = GFBuiltInChangelogEntries();
            NSString *valReason = nil;
            BOOL validBuiltIn = GFChangelogValidateEntries(builtIn, &valReason) && builtIn.count >= 15 && [builtIn.firstObject[@"cycle"] integerValue] >= 34;
            if (validBuiltIn) passed++; else failed++;
            printf("%s: built-in Changelog has %lu contiguous descending cycles (latest #%ld), valid scopes, zero em/en dashes (%s)\n",
                   validBuiltIn ? "PASS" : "FAIL", (unsigned long)builtIn.count,
                   (long)[builtIn.firstObject[@"cycle"] integerValue], (valReason ?: @"ok").UTF8String);

            // If changelog.json is present next to the binary or repo cwd, verify exact parity with built-in entries
            NSData *diskData = [NSData dataWithContentsOfFile:@"changelog.json"];
            BOOL parityOk = YES;
            if (diskData) {
                NSArray<NSDictionary *> *diskEntries = GFChangelogParseJSONData(diskData);
                parityOk = diskEntries != nil && [diskEntries isEqualToArray:builtIn];
            }
            if (parityOk) passed++; else failed++;
            printf("%s: changelog.json schema & built-in parity check (%s)\n",
                   parityOk ? "PASS" : "FAIL", diskData ? "verified on disk" : "no cwd file, skipped");

            // Validation rejects em/en dashes, out-of-order cycles, and invalid scopes
            NSArray *badDash = @[@{@"cycle": @(2), @"scope": @"engine", @"timestamp": @"13 Nov", @"title": @"Bad \u2014 dash", @"highlights": @[@"ok"]}];
            NSArray *badGap  = @[@{@"cycle": @(5), @"scope": @"engine", @"timestamp": @"13 Nov", @"title": @"Top", @"highlights": @[@"ok"]},
                                 @{@"cycle": @(3), @"scope": @"engine", @"timestamp": @"12 Nov", @"title": @"Gap", @"highlights": @[@"ok"]}];
            NSArray *badScope= @[@{@"cycle": @(1), @"scope": @"ios", @"timestamp": @"13 Nov", @"title": @"Bad scope", @"highlights": @[@"ok"]}];
            BOOL rejectOk = !GFChangelogValidateEntries(badDash, NULL) &&
                            !GFChangelogValidateEntries(badGap, NULL) &&
                            !GFChangelogValidateEntries(badScope, NULL) &&
                            GFChangelogParseJSONData([@"{not json" dataUsingEncoding:NSUTF8StringEncoding]) == nil;
            if (rejectOk) passed++; else failed++;
            printf("%s: GFChangelogValidateEntries rejects em/en dashes, cycle gaps, invalid scopes, and malformed JSON\n",
                   rejectOk ? "PASS" : "FAIL");

            // Filtering: empty, #N exact cycle, bare cycle number, text match, scope filter, and miss
            NSArray *fAll   = GFChangelogFilterEntries(builtIn, @"", @"all");
            NSArray *fHash  = GFChangelogFilterEntries(builtIn, @"#33", @"all");
            NSArray *fBare  = GFChangelogFilterEntries(builtIn, @"29", @"all");
            NSArray *fText  = GFChangelogFilterEntries(builtIn, @"prompt-echo", @"all");
            NSArray *fEng   = GFChangelogFilterEntries(builtIn, @"", @"engine");
            NSArray *fMiss  = GFChangelogFilterEntries(builtIn, @"zzzz-nonexistent-query", @"all");
            BOOL allEngScope = fEng.count > 0 && fEng.count < builtIn.count;
            for (NSDictionary *e in fEng) if (![e[@"scope"] isEqualToString:@"engine"]) allEngScope = NO;
            BOOL filterOk = fAll.count == builtIn.count &&
                            fHash.count == 1 && [fHash[0][@"cycle"] integerValue] == 33 &&
                            fBare.count >= 1 && [fBare[0][@"cycle"] integerValue] == 29 &&
                            fText.count >= 1 && [fText[0][@"cycle"] integerValue] == 33 &&
                            allEngScope && fMiss.count == 0;
            if (filterOk) passed++; else failed++;
            printf("%s: GFChangelogFilterEntries supports #cycle, number, keyword, and engine-scope filtering (%lu engine / %lu total)\n",
                   filterOk ? "PASS" : "FAIL", (unsigned long)fEng.count, (unsigned long)builtIn.count);
        }
        {
            BOOL sanOk = [GFSanitizeApiKeyInput(@"  AIzaSyTestKey1234567890  \n") isEqualToString:@"AIzaSyTestKey1234567890"] &&
                         [GFSanitizeApiKeyInput(@"export GEMINI_API_KEY=\"AIzaSyQuotedKey123456789\"") isEqualToString:@"AIzaSyQuotedKey123456789"] &&
                         [GFSanitizeApiKeyInput(@"GEMINI_API_KEY = 'AIzaSySingle1234567890'") isEqualToString:@"AIzaSySingle1234567890"] &&
                         [GFSanitizeApiKeyInput(@"curl 'https://generativelanguage.googleapis.com/v1beta/models?key=AIzaSyFromURL12345678'") isEqualToString:@"AIzaSyFromURL12345678"] &&
                         [GFSanitizeApiKeyInput(@"https://aistudio.google.com/apikey") isEqualToString:@""] &&
                         [GFSanitizeApiKeyInput(@"   ") isEqualToString:@""];
            if (sanOk) passed++; else failed++;
            printf("%s: GFSanitizeApiKeyInput cleans .env/export/quotes/URLs and rejects keyless URLs\n", sanOk ? "PASS" : "FAIL");
        }
        // Backlog 0s (replaces the cycle-26 0n rim/glow tests): hands-free (locked) mode has NO green at or around the pill edge, only a
        // strong green dot + green waveform bars inside the pill; hold-to-talk, Thinking and notices have no green at all.
        // Renders the real HUD view offscreen.
        {
            NSRect big = NSMakeRect(0, 0, kHUDPillWidth + 2.0 * kHUDGlowPad, kHUDPillHeight + 2.0 * kHUDGlowPad);
            NSRect pillR = NSInsetRect(big, kHUDGlowPad, kHUDGlowPad);
            NSBezierPath *innerCore = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(pillR, 3.0, 3.0)
                                                                      xRadius:kHUDPillHeight / 2.0 - 3.0 yRadius:kHUDPillHeight / 2.0 - 3.0];
            // Any greenish tint (also the old mint rim 0.25/0.90/0.60 and the old pale-mint bars 0.75/1.0/0.90); white/blue-white is not.
            BOOL (^isGreenish)(const unsigned char *) = ^BOOL(const unsigned char *px) {
                if (px[3] < 24) return NO;
                double a = px[3], r = px[0] / a, g = px[1] / a, bl = px[2] / a;
                return g - r > 0.15 && g - bl > 0.05;
            };
            // Strong, saturated, nearly opaque green (the hands-free dot and bars).
            BOOL (^isStrongGreen)(const unsigned char *) = ^BOOL(const unsigned char *px) {
                if (px[3] < 200) return NO;
                double a = px[3], r = px[0] / a, g = px[1] / a, bl = px[2] / a;
                return g > 0.7 && g - r > 0.5 && g - bl > 0.25;
            };
            CGFloat waveStartX = NSMinX(pillR) + (kHUDPillWidth - (13 * 2.2 + 12 * 3.2)) / 2.0; // as in -drawRect:
            // Counts: greenish px at/near the pill edge (outside the 3 px-inset core), anything drawn outside the pill rect, strong-green
            // px in the dot area (left of the waveform) and in the waveform area, and greenish px anywhere.
            typedef struct { int edge, margin, dot, bars, any; } GreenCounts;
            GreenCounts (^countGreen)(NSBitmapImageRep *) = ^GreenCounts(NSBitmapImageRep *rep) {
                GreenCounts c = {0, 0, 0, 0, 0};
                if (!rep) { c.edge = c.margin = 9999; return c; }
                const unsigned char *d = rep.bitmapData;
                NSInteger W = rep.pixelsWide, H = rep.pixelsHigh, bpr = rep.bytesPerRow;
                for (NSInteger y = 0; y < H; y++)
                    for (NSInteger x = 0; x < W; x++) {
                        const unsigned char *px = d + y * bpr + x * 4;
                        NSPoint pt = NSMakePoint(x + 0.5, (H - 1 - y) + 0.5); // bitmap rows run top-down
                        if (!NSPointInRect(pt, pillR)) { if (px[3] != 0) c.margin++; continue; }
                        BOOL gr = isGreenish(px);
                        if (gr) c.any++;
                        if (![innerCore containsPoint:pt]) { if (gr) c.edge++; continue; }
                        if (isStrongGreen(px)) { if (pt.x < waveStartX - 2.0) c.dot++; else if (pt.x >= waveStartX - 1.0) c.bars++; }
                    }
                return c;
            };
            FloatingHUDView *hv = [[FloatingHUDView alloc] initWithFrame:big];
            hv.pillInset = kHUDGlowPad;
            // (a) No green at or outside the pill edge in ANY mode: per mode on ONE view switched between modes (as the panel does), and
            //     hands-free over a whole slow halo pulse, quiet and while speaking. Nothing is drawn outside the pill at all.
            struct { HUDMode m; const char *name; BOOL hf; } seq[] = {
                {HUDModeListeningHold, "hold-to-talk", NO}, {HUDModeListeningHandsFree, "hands-free", YES},
                {HUDModeThinking, "Thinking (after stop)", NO}, {HUDModeListeningHandsFree, "hands-free again", YES},
                {HUDModeNotice, "notice (Esc / mic failure)", NO}, {HUDModeListeningHandsFree, "hands-free (3rd)", YES},
                {HUDModeSuccess, "success notice", NO}, {HUDModeListeningHold, "hold-to-talk after hands-free", NO},
            };
            int edgeBad = 0, onlyBad = 0;
            for (size_t i = 0; i < sizeof(seq) / sizeof(seq[0]); i++) {
                hv.mode = seq[i].m; hv.smoothedLevel = 0.7f; hv.animPhase = 2.0f;
                hv.noticeText = (seq[i].m == HUDModeNotice) ? @"Cancelled" : @"Copied";
                GreenCounts c = countGreen(GFRenderHUDView(hv, 1.0, NO));
                if (c.edge != 0 || c.margin != 0) { edgeBad++; printf("  HUD %s: %d green px at the pill edge, %d px outside the pill\n", seq[i].name, c.edge, c.margin); }
                // (b) data: strong green dot + bars only in hands-free; no green anywhere otherwise.
                BOOL ok = seq[i].hf ? (c.dot >= 20 && c.bars >= 60) : (c.any == 0 && c.dot == 0 && c.bars == 0);
                if (!ok) { onlyBad++; printf("  HUD %s: green dot %d px, green bar %d px, greenish %d px\n", seq[i].name, c.dot, c.bars, c.any); }
            }
            hv.mode = HUDModeListeningHandsFree;
            int minDot = INT_MAX, minQuietBars = INT_MAX;
            for (int lv = 0; lv < 2; lv++)
                for (int f = 0; f <= 24; f++) {
                    hv.smoothedLevel = lv ? 0.8f : 0.0f;
                    hv.animPhase = f * (2.0f * (float)M_PI / 0.31f) / 24.0f;
                    GreenCounts c = countGreen(GFRenderHUDView(hv, 1.0, NO));
                    if (c.edge != 0 || c.margin != 0) edgeBad++;
                    if (c.dot < minDot) minDot = c.dot;
                    if (!lv && c.bars < minQuietBars) minQuietBars = c.bars;
                }
            if (edgeBad == 0) passed++; else failed++;
            printf("%s: HUD has no green rim/glow: no green at or outside the pill edge in any mode (hands-free pulse + speech too)\n", edgeBad == 0 ? "PASS" : "FAIL");
            // (b) Strong green dot + bars only while hands-free, also when quiet and at every point of the halo pulse.
            BOOL onlyOk = onlyBad == 0 && minDot >= 20 && minQuietBars >= 30;
            if (onlyOk) passed++; else failed++;
            printf("%s: HUD strong green dot + green bars only in hands-free (min dot %d px, min quiet bars %d px); other modes no green\n",
                   onlyOk ? "PASS" : "FAIL", minDot, minQuietBars);

            // (c0) The green bars keep the hold-to-talk motion: per bar, the same height as hold-to-talk (within 1 px) at several levels
            //      and phases, and they grow with the voice level.
            FloatingHUDView *bgV = [[FloatingHUDView alloc] initWithFrame:big];
            bgV.pillInset = kHUDGlowPad; bgV.mode = HUDModeNotice; bgV.noticeText = @""; // the pill's sheen + hairline only
            NSBitmapImageRep *bgRep = GFRenderHUDView(bgV, 1.0, NO);
            NSInteger (^barHeight)(NSBitmapImageRep *, int) = ^NSInteger(NSBitmapImageRep *rep, int bar) {
                if (!rep || !bgRep) return -1;
                NSInteger col = (NSInteger)floor(waveStartX + bar * (2.2 + 3.2)) + 1; // fully covered column of this bar
                NSInteger H = rep.pixelsHigh, n = 0; int maxInk = 0;
                for (NSInteger y = 0; y < H; y++) {
                    int ink = (int)rep.bitmapData[y * rep.bytesPerRow + col * 4 + 3] - (int)bgRep.bitmapData[y * bgRep.bytesPerRow + col * 4 + 3];
                    if (ink > maxInk) maxInk = ink;
                }
                for (NSInteger y = 0; y < H; y++) {
                    int ink = (int)rep.bitmapData[y * rep.bytesPerRow + col * 4 + 3] - (int)bgRep.bitmapData[y * bgRep.bytesPerRow + col * 4 + 3];
                    if (maxInk > 0 && ink * 2 > maxInk) n++;
                }
                return n;
            };
            float levels[] = {0.0f, 0.35f, 0.7f, 1.0f}, phases[] = {0.0f, 1.3f, 2.9f, 5.1f};
            int motionBad = 0; NSInteger sumQuiet = 0, sumLoud = 0;
            FloatingHUDView *holdV = [[FloatingHUDView alloc] initWithFrame:big];
            holdV.pillInset = kHUDGlowPad; holdV.mode = HUDModeListeningHold;
            for (int li = 0; li < 4; li++)
                for (int pi = 0; pi < 4; pi++) {
                    hv.smoothedLevel = holdV.smoothedLevel = levels[li];
                    hv.animPhase = holdV.animPhase = phases[pi];
                    NSBitmapImageRep *rh = GFRenderHUDView(holdV, 1.0, NO), *rf = GFRenderHUDView(hv, 1.0, NO);
                    for (int bar = 0; bar < 13; bar++) {
                        NSInteger hh = barHeight(rh, bar), hf = barHeight(rf, bar);
                        if (hh < 1 || hf < 1 || labs((long)(hh - hf)) > 1) {
                            motionBad++;
                            if (motionBad <= 5) printf("  HUD bar %d level %.2f phase %.1f: hold %ld px, hands-free %ld px\n", bar, levels[li], phases[pi], (long)hh, (long)hf);
                        }
                        if (li == 0) sumQuiet += hf;
                        if (li == 3) sumLoud += hf;
                    }
                }
            BOOL motionOk = motionBad == 0 && sumLoud > sumQuiet * 2;
            if (motionOk) passed++; else failed++;
            printf("%s: HUD hands-free green bars keep the hold-to-talk heights/motion (%d mismatches; quiet %ld px vs loud %ld px)\n",
                   motionOk ? "PASS" : "FAIL", motionBad, (long)sumQuiet, (long)sumLoud);

            // (c) Other modes look unchanged: the pill area renders exactly like the old pill-sized view, and the glow margin stays empty.
            HUDMode same[] = {HUDModeListeningHold, HUDModeThinking, HUDModeNotice, HUDModeSuccess};
            int sameBad = 0;
            for (int i = 0; i < 4; i++) {
                FloatingHUDView *oldV = [[FloatingHUDView alloc] initWithFrame:NSMakeRect(0, 0, kHUDPillWidth, kHUDPillHeight)];
                oldV.pillInset = 0; oldV.mode = same[i]; oldV.smoothedLevel = 0.5f; oldV.animPhase = 2.0f; oldV.noticeText = @"No speech";
                FloatingHUDView *newV = [[FloatingHUDView alloc] initWithFrame:big];
                newV.pillInset = kHUDGlowPad; newV.mode = same[i]; newV.smoothedLevel = 0.5f; newV.animPhase = 2.0f; newV.noticeText = @"No speech";
                NSBitmapImageRep *ro = GFRenderHUDView(oldV, 1.0, NO), *rn = GFRenderHUDView(newV, 1.0, NO);
                if (!ro || !rn) { sameBad++; continue; }
                int maxDiff = 0, marginInk = 0, ink = 0;
                NSInteger pad = (NSInteger)kHUDGlowPad;
                for (NSInteger y = 0; y < rn.pixelsHigh; y++)
                    for (NSInteger x = 0; x < rn.pixelsWide; x++) {
                        const unsigned char *n = rn.bitmapData + y * rn.bytesPerRow + x * 4;
                        BOOL inPill = x >= pad && x < pad + (NSInteger)kHUDPillWidth && y >= pad && y < pad + (NSInteger)kHUDPillHeight;
                        if (!inPill) { if (n[3] != 0) marginInk++; continue; }
                        const unsigned char *o = ro.bitmapData + (y - pad) * ro.bytesPerRow + (x - pad) * 4;
                        if (o[3] > 0) ink++;
                        for (int c = 0; c < 4; c++) { int dlt = abs((int)n[c] - (int)o[c]); if (dlt > maxDiff) maxDiff = dlt; }
                    }
                if (maxDiff > 2 || marginInk != 0 || ink < 500) {
                    sameBad++; printf("  HUD mode %ld: max diff %d, %d px drawn in the glow margin, %d px ink\n", (long)same[i], maxDiff, marginInk, ink);
                }
            }
            if (sameBad == 0) passed++; else failed++;
            printf("%s: HUD hold/Thinking/notice pixels match the old pill-only HUD (glow margin empty)\n", sameBad == 0 ? "PASS" : "FAIL");

            // (d) The bigger window keeps the pill at its old screen position and size (centred, 68 pt above the visible bottom).
            NSRect screens[] = {NSMakeRect(0, 0, 1512, 945), NSMakeRect(0, 25, 1728, 1080), NSMakeRect(-1920, 40, 1920, 1040), NSMakeRect(1512, -200, 2560, 1415)};
            int geoBad = 0;
            for (int i = 0; i < 4; i++) {
                NSPoint o = GFHUDWindowOriginForVisibleFrame(screens[i], big.size);
                NSRect pillOnScreen = NSMakeRect(o.x + kHUDGlowPad, o.y + kHUDGlowPad, kHUDPillWidth, kHUDPillHeight);
                NSRect oldPill = NSMakeRect(screens[i].origin.x + (screens[i].size.width - 144.0) / 2.0, screens[i].origin.y + 68.0, 144.0, 36.0);
                if (!NSEqualRects(pillOnScreen, oldPill)) geoBad++;
            }
            BOOL geoOk = geoBad == 0 && kHUDPillWidth == 144.0 && kHUDPillHeight == 36.0 && kHUDGlowPad >= 4.0 && kHUDGlowPad <= 12.0;
            if (geoOk) passed++; else failed++;
            printf("%s: HUD window grows by %.0f pt per side but the pill keeps its old screen position and 144x36 size\n", geoOk ? "PASS" : "FAIL", kHUDGlowPad);
        }
        // Backlog 0c1: Changelog menu item & monochrome Light/Dark AppKit view checks
        {
            GFChangelogDocumentView *dv = [[GFChangelogDocumentView alloc] initWithFrame:NSMakeRect(0, 0, 480, 500)];
            CGFloat collapsedH = [dv preferredHeightForWidth:480.0];
            [dv.expandedCycles addObject:@(33)];
            [dv.expandedCycles addObject:@(32)];
            CGFloat expandedH = [dv preferredHeightForWidth:480.0];
            [dv.expandedCycles removeAllObjects];
            CGFloat recollapsedH = [dv preferredHeightForWidth:480.0];
            BOOL layoutOk = expandedH > collapsedH + 60.0 && fabs(collapsedH - recollapsedH) < 1.0;
            if (layoutOk) passed++; else failed++;
            printf("%s: Changelog document view expands/collapses earlier cycles cleanly (%.0f -> %.0f -> %.0f pt)\n",
                   layoutOk ? "PASS" : "FAIL", collapsedH, expandedH, recollapsedH);

            NSBitmapImageRep *lightRep = GFRenderChangelogSnapshot(NO, @"", @"all", nil);
            NSBitmapImageRep *darkRep  = GFRenderChangelogSnapshot(YES, @"", @"all", [NSSet setWithObject:@(33)]);
            GFSetupState readySt = {YES, 3, YES, 3, YES};
            GFSetupState freshSt = {NO, 0, NO, 0, NO};
            NSBitmapImageRep *setupLight = GFRenderSetupSnapshot(NO, freshSt);
            NSBitmapImageRep *setupDark  = GFRenderSetupSnapshot(YES, readySt);
            BOOL renderOk = lightRep != nil && darkRep != nil && lightRep.pixelsWide == 1040 && darkRep.pixelsWide == 1040 &&
                            darkRep.pixelsHigh > lightRep.pixelsHigh && setupLight != nil && setupDark != nil &&
                            setupLight.pixelsWide == 940 && setupDark.pixelsWide == 940;
            // Verify monochrome Light canvas is light and Dark canvas is dark (top-left corner pixel)
            if (renderOk) {
                const unsigned char *lp = lightRep.bitmapData;
                const unsigned char *dp = darkRep.bitmapData;
                renderOk = lp[0] > 220 && lp[1] > 220 && lp[2] > 220 && dp[0] < 35 && dp[1] < 35 && dp[2] < 40;
            }
            if (renderOk) passed++; else failed++;
            printf("%s: Changelog renders crisp 2x Light and Dark monochrome snapshots\n", renderOk ? "PASS" : "FAIL");

            // User report 2026-11-13: the window title sat next to the close/minimize/zoom buttons. Titles now sit in the row BELOW
            // them: the top 26 pt right of the buttons is empty in both windows, and the title's dark ink is underneath.
            BOOL (^stripClear)(NSBitmapImageRep *) = ^BOOL(NSBitmapImageRep *r) {
                if (!r) return NO;
                for (NSInteger y = 0; y < 26 * 2; y++)
                    for (NSInteger x = 76 * 2; x < r.pixelsWide; x++) {
                        const unsigned char *px = r.bitmapData + y * r.bytesPerRow + x * 4;
                        if (px[0] < 235 || px[1] < 235 || px[2] < 235) return NO;
                    }
                return YES;
            };
            NSInteger (^titleInk)(NSBitmapImageRep *, NSInteger, NSInteger) = ^NSInteger(NSBitmapImageRep *r, NSInteger topPt, NSInteger bottomPt) {
                NSInteger n = 0;
                if (!r) return 0;
                for (NSInteger y = topPt * 2; y < bottomPt * 2 && y < r.pixelsHigh; y++)
                    for (NSInteger x = 24 * 2; x < 200 * 2 && x < r.pixelsWide; x++) {
                        const unsigned char *px = r.bitmapData + y * r.bytesPerRow + x * 4;
                        if (px[0] < 90 && px[1] < 90 && px[2] < 90) n++;
                    }
                return n;
            };
            NSInteger clInk = titleInk(lightRep, 28, 84), suInk = titleInk(setupLight, 28, 62);
            BOOL hdrOk = stripClear(lightRep) && clInk > 200 && stripClear(setupLight) && suInk > 200;
            if (hdrOk) passed++; else failed++;
            printf("%s: Changelog and Setup titles sit below the window buttons (button row empty; title ink %ld / %ld px)\n",
                   hdrOk ? "PASS" : "FAIL", (long)clInk, (long)suInk);

            // Brand mark shared with the iOS app: the menu bar icon is three bars slanted clockwise (the tall bar's top end is right of
            // its bottom end), a template image; listening has more ink than idle, thinking (three dots) less.
            NSInteger inkN[3] = {0, 0, 0}, rowN[72] = {0}; double rowX[72] = {0};
            for (int st = 0; st < 3; st++) {
                NSBitmapImageRep *ir = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:72 pixelsHigh:72 bitsPerSample:8
                    samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:72 * 4 bitsPerPixel:32];
                memset(ir.bitmapData, 0, 72 * 72 * 4);
                [NSGraphicsContext saveGraphicsState];
                [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:ir]];
                [[self menuBarIconForState:st] drawInRect:NSMakeRect(0, 0, 72, 72) fromRect:NSZeroRect
                                                operation:NSCompositingOperationSourceOver fraction:1.0];
                [NSGraphicsContext restoreGraphicsState];
                for (NSInteger y = 0; y < 72; y++)
                    for (NSInteger x = 0; x < 72; x++) {
                        if (ir.bitmapData[y * ir.bytesPerRow + x * 4 + 3] < 128) continue;
                        inkN[st]++;
                        if (st == 0) { rowX[y] += x; rowN[y]++; }
                    }
            }
            // Mean x of the idle icon's top 3 and bottom 3 inked rows: both belong to the tall middle bar (bitmap rows run top-down)
            double topX = 0, botX = 0; NSInteger topN = 0, botN = 0, rowsSeen = 0;
            for (NSInteger y = 0; y < 72 && rowsSeen < 3; y++) if (rowN[y] > 0) { topX += rowX[y]; topN += rowN[y]; rowsSeen++; }
            rowsSeen = 0;
            for (NSInteger y = 71; y >= 0 && rowsSeen < 3; y--) if (rowN[y] > 0) { botX += rowX[y]; botN += rowN[y]; rowsSeen++; }
            BOOL markOk = inkN[1] > inkN[0] && inkN[0] > inkN[2] && inkN[2] > 100 && topN > 0 && botN > 0
                          && topX / topN > botX / botN + 4.0 && [self menuBarIconForState:0].isTemplate;
            if (markOk) passed++; else failed++;
            printf("%s: menu bar icon is the brand mark: slanted clockwise, template, ink idle %ld < listening %ld, thinking dots %ld\n",
                   markOk ? "PASS" : "FAIL", (long)inkN[0], (long)inkN[1], (long)inkN[2]);
        }
        printf("\nSummary: %d passed, %d failed (trailing space verified)\n", passed, failed);
        return failed == 0 ? 0 : 1;
    }
}

@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        AppDelegate *delegate = [[AppDelegate alloc] init];

        if (argc > 1 && strcmp(argv[1], "--test") == 0) {
            return [delegate runBuiltInTestSuite];
        }
        if (argc > 2 && strcmp(argv[1], "--render-hud-png") == 0) {
            // Test hook (offline, backlog 0n/0s): write 2x previews of the HUD to <dir>: hands-free while speaking and quiet,
            // hold-to-talk and Thinking.
            NSString *dir = [NSString stringWithUTF8String:argv[2]];
            HUDMode modes[] = {HUDModeListeningHandsFree, HUDModeListeningHold, HUDModeThinking, HUDModeListeningHandsFree};
            NSString *names[] = {@"hud-handsfree.png", @"hud-hold.png", @"hud-thinking.png", @"hud-handsfree-quiet.png"};
            float levels[] = {0.55f, 0.55f, 0.55f, 0.0f};
            int bad = 0;
            for (int i = 0; i < 4; i++) {
                FloatingHUDView *v = [[FloatingHUDView alloc] initWithFrame:NSMakeRect(0, 0, kHUDPillWidth + 2.0 * kHUDGlowPad,
                                                                                       kHUDPillHeight + 2.0 * kHUDGlowPad)];
                v.pillInset = kHUDGlowPad;
                v.mode = modes[i];
                v.smoothedLevel = levels[i];
                v.animPhase = 3.0f; // halo pulse near its middle
                NSData *png = [GFRenderHUDView(v, 2.0, YES) representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                NSString *path = [dir stringByAppendingPathComponent:names[i]];
                if (png && [png writeToFile:path atomically:YES]) printf("WROTE %s\n", path.UTF8String);
                else { printf("FAILED %s\n", path.UTF8String); bad++; }
            }
            return bad ? 1 : 0;
        }
        if (argc > 2 && strcmp(argv[1], "--render-changelog-png") == 0) {
            NSString *dir = [NSString stringWithUTF8String:argv[2]];
            GFSetupState freshSt = {NO, 0, NO, 0, NO};
            GFSetupState readySt = {YES, 3, YES, 3, YES};
            NSBitmapImageRep *reps[] = {
                GFRenderChangelogSnapshot(NO, @"", @"all", nil),
                GFRenderChangelogSnapshot(YES, @"", @"all", [NSSet setWithObject:@(33)]),
                GFRenderSetupSnapshot(NO, freshSt),
                GFRenderSetupSnapshot(YES, readySt),
                GFRenderBrandPreview(@[[delegate menuBarIconForState:0], [delegate menuBarIconForState:1], [delegate menuBarIconForState:2]])
            };
            NSString *names[] = {@"changelog-light.png", @"changelog-dark-expanded.png", @"setup-first-run-light.png", @"setup-ready-dark.png",
                                 @"brand-preview.png"};
            int bad = 0;
            for (int i = 0; i < 5; i++) {
                NSData *png = [reps[i] representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                NSString *path = [dir stringByAppendingPathComponent:names[i]];
                if (png && [png writeToFile:path atomically:YES]) printf("WROTE %s\n", path.UTF8String);
                else { printf("FAILED %s\n", path.UTF8String); bad++; }
            }
            return bad ? 1 : 0;
        }
        if (argc > 1 && strcmp(argv[1], "--dump-gemini-requests") == 0) {
            // Test hook (offline, backlog 15): print the Gemini requests the app builds, using a dummy key (never the real one).
            NSString *dk = @"DUMMYKEY-gf-request-check";
            NSURLRequest *rq[] = {GFGeminiRequest(GFGenerateContentURL(kDefaultModel), dk), GFGeminiRequest(GFRestWarmupURL(), dk),
                                  GFGeminiRequest(GFModelInfoURL(kDefaultLiveModel), dk), GFLiveWebSocketRequest(dk, NO)};
            const char *names[] = {"rest-generateContent", "rest-prewarm", "api-key-check", "live-header-auth"};
            printf("DUMMY KEY: %s\n", dk.UTF8String);
            for (int i = 0; i < 4; i++)
                printf("REQUEST %s url=%s header=%s\n", names[i], rq[i].URL.absoluteString.UTF8String,
                       [[rq[i] valueForHTTPHeaderField:@"x-goog-api-key"] isEqualToString:dk] ? "set" : "missing");
            return 0;
        }
        if (argc > 1 && strcmp(argv[1], "--dump-live-probe-lines") == 0) {
            // Test hook (offline, backlog 0y-probe): sample "Live setup probe" log lines from the real formatters, so the test
            // runner's parser is checked against the app's exact wording without a network (run_tests.py: T28 selection).
            NSDictionary *ex = GFParseLiveSetupExtra(@"{\"inputAudioTranscription\":{\"languageCodes\":[\"en-US\"],\"customVocabulary\":[\"Siobhan\"]},"
                                                     @"\"generationConfig\":{\"speechConfig\":{}}}");
            NSString *setupStr = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:GFLiveSetupMessage(kDefaultLiveModel, ex)
                                                                                                options:0 error:nil] encoding:NSUTF8StringEncoding];
            NSMutableSet<NSString *> *seen = [NSMutableSet set];
            GFJSONCollectKeyPaths(@{@"setupComplete": @{}}, @"", 3, seen);
            GFJSONCollectKeyPaths(@{@"serverContent": @{@"inputTranscription": @{@"text": @"never shown"}}}, @"", 3, seen);
            GFJSONCollectKeyPaths(@{@"serverContent": @{@"generationComplete": @YES}}, @"", 3, seen);
            NSArray<NSString *> *lines = @[
                GFLiveProbeSetupLine(1, @{}, 150, NO),
                GFLiveProbeSetupLine(2, ex, setupStr.length, YES),
                GFLiveProbeSetupCompleteLine(1, YES, 183.4),
                GFLiveProbeCloseLine(NO, 1, YES, 0, 1007, @"Invalid JSON payload received. Unknown name \"customVocabulary\" at 'setup.input_audio_transcription': Cannot find field.",
                                     NSPOSIXErrorDomain, 57),
                GFLiveProbeCloseLine(NO, 2, NO, 400, 0, nil, NSURLErrorDomain, NSURLErrorBadServerResponse),
                GFLiveProbeCloseLine(YES, 3, YES, 101, 1011, @"Internal error\nencountered.", nil, 0),
                GFLiveProbeErrorFrameLine(@{@"error": @{@"code": @400, @"status": @"INVALID_ARGUMENT", @"message": @"Unsupported \"mode\" value."}}, NO),
                GFLiveProbeFieldsLine(seen)];
            for (NSString *l in lines) printf("%s\n", l.UTF8String);
            printf("E2E LIVE RAW: \"%s\"\n", "sample raw text");
            return 0;
        }
        if (argc > 2 && strcmp(argv[1], "--replay") == 0) {
            return [delegate runReplayOfTrace:@(argv[2]) expected:(argc > 3 ? @(argv[3]) : nil)];
        }
        if (argc > 2 && strcmp(argv[1], "--e2e-file") == 0) {
            delegate.e2eMode = @"file";
            delegate.e2eAudioFile = @(argv[2]);
            // optional: run the Gemini path with this model (a "--" flag in its place means on-device mode with flags)
            int firstFlag = 3;
            if (argc > 3 && strncmp(argv[3], "--", 2) != 0) { delegate.e2eGeminiModel = @(argv[3]); firstFlag = 4; }
            // optional, test-only: the first REST attempt fails with a fast HTTP 503 (exercises the REST retry unattended)
            // optional, test-only: ignore Live's serverContent so its final turn closes empty (exercises the no-speech check)
            for (int i = firstFlag; i < argc; i++) {
                if (strcmp(argv[i], "--e2e-rest-503-once") == 0) delegate.e2eRestFaultOnce = YES;
                // optional, test-only: the injected 503 arrives after <seconds> (a slow "high demand" answer); implies -once
                if (strcmp(argv[i], "--e2e-rest-503-delay") == 0 && i + 1 < argc) {
                    delegate.e2eRestFaultOnce = YES;
                    delegate.e2eRestFaultDelay = atof(argv[i + 1]);
                    i += 1;
                }
                if (strcmp(argv[i], "--e2e-live-drop-output") == 0) delegate.e2eLiveDropOutput = YES;
                // optional, test-only: the first REST call answers HTTP 200 with a canned transcript after <seconds> (no network)
                if (strcmp(argv[i], "--e2e-rest-fake-ok") == 0 && i + 1 < argc) {
                    delegate.e2eRestFakeOkDelay = atof(argv[i + 1]);
                    i += 1;
                    continue;
                }
                if (strcmp(argv[i], "--e2e-rest-fake-text") == 0 && i + 1 < argc) {
                    delegate.e2eRestFakeText = [NSString stringWithUTF8String:argv[i + 1]];
                    i += 1;
                    continue;
                }
                // optional, test-only: the first real REST call is held <seconds> before it is sent (slow REST)
                if (strcmp(argv[i], "--e2e-rest-delay") == 0 && i + 1 < argc) {
                    delegate.e2eRestDelay = atof(argv[i + 1]);
                    i += 1;
                    continue;
                }
                // optional, test-only: the Live server ends the open turn on its own after <seconds> of audio (Fn still held)
                if (strcmp(argv[i], "--e2e-live-server-turn-end") == 0 && i + 1 < argc) {
                    delegate.e2eServerTurnEndAt = atof(argv[i + 1]);
                    i += 1;
                }
                // optional, test-only: force-close the Live socket after <seconds> of audio sent (Fn still held), see e2eMaybeDropLiveSocket
                if (strcmp(argv[i], "--e2e-live-drop-at") == 0 && i + 1 < argc) {
                    delegate.e2eLiveDropAt = atof(argv[i + 1]);
                    i += 1;
                    continue;
                }
                // optional, test-only (backlog 0p): planned Live session rotation at <seconds> of session age instead of 8.5 min
                if (strcmp(argv[i], "--e2e-live-rotate-age") == 0 && i + 1 < argc) {
                    delegate.e2eLiveRotateAge = atof(argv[i + 1]);
                    i += 1;
                    continue;
                }
                // optional, test-only (backlog 0p): every Live session is closed at <seconds> of session age, see e2eMaybeSimulateLifetimeClose
                if (strcmp(argv[i], "--e2e-live-lifetime") == 0 && i + 1 < argc) {
                    delegate.e2eLiveLifetime = atof(argv[i + 1]);
                    i += 1;
                    continue;
                }
                // optional, test-only (backlog 0y-probe): a JSON object deep-merged into the Live `setup` object, see GFLiveSetupMessage
                if (strcmp(argv[i], "--e2e-live-setup-extra") == 0 && i + 1 < argc) {
                    delegate.e2eLiveSetupExtra = GFParseLiveSetupExtra(@(argv[i + 1]));
                    if (!delegate.e2eLiveSetupExtra) {
                        printf("E2E: --e2e-live-setup-extra needs a JSON object, e.g. '{\"inputAudioTranscription\":{}}'\n");
                        return 2;
                    }
                    i += 1;
                    continue;
                }
                // optional, test-only: the microphone fails (start | start-once | nobuffers | denied), see startAudioEngine
                if (strcmp(argv[i], "--e2e-mic-fail") == 0 && i + 1 < argc) {
                    delegate.e2eMicFail = @(argv[i + 1]);
                    i += 1;
                    continue;
                }
                // optional, test-only: ignore streaming on-device results so the release takes the WAV fallback
                if (strcmp(argv[i], "--e2e-wav-fallback") == 0) delegate.e2eWavFallback = YES;
                // optional, test-only: the WAV fallback's recognizer never ends (final | all); implies --e2e-wav-fallback
                if (strcmp(argv[i], "--e2e-wav-hang") == 0 && i + 1 < argc) {
                    delegate.e2eWavFallback = YES;
                    delegate.e2eWavHang = @(argv[i + 1]);
                    i += 1;
                    continue;
                }
                // optional, test-only: a second press (another WAV) starts while the first dictation is still finishing
                if (strcmp(argv[i], "--e2e-second-press") == 0 && i + 2 < argc) {
                    delegate.e2eSecondPressFile = @(argv[i + 1]);
                    delegate.e2eSecondPressPhase = @(argv[i + 2]);
                    i += 2;
                }
            }
        } else if (argc > 2 && strcmp(argv[1], "--e2e-mic") == 0) {
            delegate.e2eMode = @"mic";
            delegate.e2eMicSeconds = atof(argv[2]);
        }

        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];

        // Setup standard application edit menu for copy/paste support
        NSMenu *mainMenu = [[NSMenu alloc] init];
        NSMenuItem *editMenuItem = [[NSMenuItem alloc] init];
        NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
        [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
        [editMenu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
        [editMenu addItem:[NSMenuItem separatorItem]];
        [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
        [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
        [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
        [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
        [editMenuItem setSubmenu:editMenu];
        [mainMenu addItem:editMenuItem];
        [app setMainMenu:mainMenu];

        [app setDelegate:delegate];
        [app run];
    }
    return 0;
}
