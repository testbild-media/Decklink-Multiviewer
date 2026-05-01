#import "DeckLinkBridge.h"
#import "CaptureEngine.hpp"
#import <atomic>
#import <array>

@implementation SDIFrame
@end

@implementation SDIDeckLinkDevice
@end

@interface SDIDeckLinkBridge () {
    std::unique_ptr<CaptureEngine> _engine;
    id<MTLDevice> _metalDevice;
}
@property (nonatomic, readwrite) SDICaptureFormat activeFormat;
@property (nonatomic, readwrite) BOOL input0Connected;
@property (nonatomic, readwrite) BOOL input1Connected;
@property (nonatomic, readwrite) BOOL input2Connected;
@property (nonatomic, readwrite) BOOL input3Connected;
@property (nonatomic, readwrite) NSString *input0Format;
@property (nonatomic, readwrite) NSString *input1Format;
@property (nonatomic, readwrite) NSString *input2Format;
@property (nonatomic, readwrite) NSString *input3Format;
@end

static BMDDisplayMode bmdModeForFormat(SDICaptureFormat f) {
    switch (f) {
        case SDICaptureFormat1080p50:   return bmdModeHD1080p50;
        case SDICaptureFormat1080p25:   return bmdModeHD1080p25;
        case SDICaptureFormat1080p2997: return bmdModeHD1080p2997;
        case SDICaptureFormat1080i50:   return bmdModeHD1080i50;
        case SDICaptureFormat1080i5994: return bmdModeHD1080i5994;
        case SDICaptureFormat720p50:    return bmdModeHD720p50;
        case SDICaptureFormat720p5994:  return bmdModeHD720p5994;
        default:                        return bmdModeHD1080p50;
    }
}

@implementation SDIDeckLinkBridge

+ (NSArray<SDIDeckLinkDevice *> *)enumerateDevices {
    NSMutableArray *result = [NSMutableArray array];
    IDeckLinkIterator *iter = CreateDeckLinkIteratorInstance();
    if (!iter) return result;
    IDeckLink *dl = nullptr;
    NSInteger idx = 0;
    while (iter->Next(&dl) == S_OK) {
        IDeckLinkInput *input = nullptr;
        if (dl->QueryInterface(IID_IDeckLinkInput, (void **)&input) == S_OK) {
            CFStringRef name = nullptr;
            dl->GetDisplayName(&name);
            SDIDeckLinkDevice *dev = [[SDIDeckLinkDevice alloc] init];
            dev.displayName = name
                ? (__bridge_transfer NSString *)name
                : [NSString stringWithFormat:@"DeckLink %ld", (long)idx];
            dev.deviceIndex = idx;
            [result addObject:dev];
            input->Release();
        }
        dl->Release();
        idx++;
    }
    iter->Release();
    return result;
}

- (instancetype)initWithDevice:(id<MTLDevice>)metalDevice {
    self = [super init];
    if (!self) return nil;
    _metalDevice = metalDevice;
    _input0Format = @""; _input1Format = @"";
    _input2Format = @""; _input3Format = @"";
    try {
        _engine = std::make_unique<CaptureEngine>(metalDevice);
    } catch (const std::exception &e) {
        NSLog(@"[DecklinkMultiviewer] CaptureEngine init failed: %s", e.what());
        return nil;
    }
    __weak SDIDeckLinkBridge *weakSelf = self;
    _engine->onConnectionChanged = [weakSelf](int slot, bool connected) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SDIDeckLinkBridge *s = weakSelf;
            if (!s) return;
            switch (slot) {
                case 0: s.input0Connected = connected; break;
                case 1: s.input1Connected = connected; break;
                case 2: s.input2Connected = connected; break;
                case 3: s.input3Connected = connected; break;
                default: break;
            }
        });
    };

    _engine->onFormatChanged = [weakSelf](int slot, const char *fmt) {
        NSString *fmtStr = fmt ? [NSString stringWithUTF8String:fmt] : @"";
        dispatch_async(dispatch_get_main_queue(), ^{
            SDIDeckLinkBridge *s = weakSelf;
            if (!s) return;
            switch (slot) {
                case 0: s.input0Format = fmtStr; break;
                case 1: s.input1Format = fmtStr; break;
                case 2: s.input2Format = fmtStr; break;
                case 3: s.input3Format = fmtStr; break;
                default: break;
            }
        });
    };
    return self;
}

- (BOOL)assignDevice:(NSInteger)deviceIndex toInput:(NSInteger)inputSlot {
    if (!_engine) return NO;
    return _engine->assignDevice((int)deviceIndex, (int)inputSlot) ? YES : NO;
}

- (BOOL)startCaptureWithFormat:(SDICaptureFormat)format error:(NSError **)outError {
    if (!_engine) {
        if (outError) *outError = [NSError errorWithDomain:@"DecklinkMultiviewer" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"Capture engine not initialized"}];
        return NO;
    }
    bool ok = _engine->start(bmdModeForFormat(format));
    if (!ok && outError) *outError = [NSError errorWithDomain:@"DecklinkMultiviewer" code:2
        userInfo:@{NSLocalizedDescriptionKey: @"Failed to start DeckLink capture"}];
    if (ok) self.activeFormat = format;
    return ok ? YES : NO;
}

- (void)stopCapture {
    if (_engine) _engine->stop();
}

- (nullable SDIFrame *)latestFrameForInput:(NSInteger)inputSlot {
    if (!_engine) return nil;
    FrameSlot *slot = _engine->latestSlot((int)inputSlot);
    if (!slot || !slot->ready.load(std::memory_order_acquire)) return nil;
    if (!slot->luma || !slot->chroma) return nil;
    SDIFrame *frame         = [[SDIFrame alloc] init];
    frame.lumaTexture       = slot->luma;
    frame.chromaTexture     = slot->chroma;
    frame.hardwareTimestamp = slot->pts;
    frame.inputIndex        = (int)inputSlot;
    return frame;
}

@end
