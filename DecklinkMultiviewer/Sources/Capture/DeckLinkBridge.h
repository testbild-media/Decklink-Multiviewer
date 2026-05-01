#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

typedef NS_ENUM(NSInteger, SDICaptureFormat) {
    SDICaptureFormat1080p50   = 0,
    SDICaptureFormat1080p25   = 1,
    SDICaptureFormat1080p2997 = 2,
    SDICaptureFormat1080i50   = 3,
    SDICaptureFormat1080i5994 = 4,
    SDICaptureFormat720p50    = 5,
    SDICaptureFormat720p5994  = 6,
};

NS_ASSUME_NONNULL_BEGIN

@interface SDIFrame : NSObject
@property (nonatomic, strong) id<MTLTexture> lumaTexture;
@property (nonatomic, strong) id<MTLTexture> chromaTexture;
@property (nonatomic, assign) uint64_t       hardwareTimestamp;
@property (nonatomic, assign) int            inputIndex;
@end

@interface SDIDeckLinkDevice : NSObject
@property (nonatomic, copy)   NSString *displayName;
@property (nonatomic, assign) NSInteger deviceIndex;
@end

@interface SDIDeckLinkBridge : NSObject

+ (NSArray<SDIDeckLinkDevice *> *)enumerateDevices;

- (nullable instancetype)initWithDevice:(id<MTLDevice>)metalDevice;

- (BOOL)assignDevice:(NSInteger)deviceIndex toInput:(NSInteger)inputSlot;

- (BOOL)startCaptureWithFormat:(SDICaptureFormat)format error:(NSError * _Nullable * _Nullable)error;
- (void)stopCapture;

- (nullable SDIFrame *)latestFrameForInput:(NSInteger)inputSlot;

@property (nonatomic, readonly) SDICaptureFormat activeFormat;

@property (nonatomic, readonly) BOOL input0Connected;
@property (nonatomic, readonly) BOOL input1Connected;
@property (nonatomic, readonly) BOOL input2Connected;
@property (nonatomic, readonly) BOOL input3Connected;

@property (nonatomic, readonly) NSString *input0Format;
@property (nonatomic, readonly) NSString *input1Format;
@property (nonatomic, readonly) NSString *input2Format;
@property (nonatomic, readonly) NSString *input3Format;

@end

NS_ASSUME_NONNULL_END
