#include "CaptureEngine.hpp"
#include <stdexcept>
#include <cstring>

static inline uint16_t scale10to16(uint32_t v10) {
    uint32_t v = v10 & 0x3FF;
    return static_cast<uint16_t>((v << 6) | (v >> 4));
}

static void decodeV210Row(const uint32_t *src, int srcWords,
                          uint16_t *dstY, uint16_t *dstCbCr, int width)
{
    int yIdx = 0, cbcrIdx = 0;
    for (int w = 0; w + 3 < srcWords && yIdx + 5 < width; w += 4) {
        uint32_t w0 = src[w], w1 = src[w+1], w2 = src[w+2], w3 = src[w+3];

        uint16_t Cb0 = scale10to16((w0)       & 0x3FF);
        uint16_t Y0  = scale10to16((w0 >> 10) & 0x3FF);
        uint16_t Cr0 = scale10to16((w0 >> 20) & 0x3FF);
        uint16_t Y1  = scale10to16((w1)       & 0x3FF);
        uint16_t Cb2 = scale10to16((w1 >> 10) & 0x3FF);
        uint16_t Y2  = scale10to16((w1 >> 20) & 0x3FF);
        uint16_t Cr2 = scale10to16((w2)       & 0x3FF);
        uint16_t Y3  = scale10to16((w2 >> 10) & 0x3FF);
        uint16_t Cb4 = scale10to16((w2 >> 20) & 0x3FF);
        uint16_t Y4  = scale10to16((w3)       & 0x3FF);
        uint16_t Cr4 = scale10to16((w3 >> 10) & 0x3FF);
        uint16_t Y5  = scale10to16((w3 >> 20) & 0x3FF);

        dstY[yIdx++]=Y0; dstY[yIdx++]=Y1; dstY[yIdx++]=Y2;
        dstY[yIdx++]=Y3; dstY[yIdx++]=Y4; dstY[yIdx++]=Y5;

        dstCbCr[cbcrIdx++]=Cb0; dstCbCr[cbcrIdx++]=Cr0;
        dstCbCr[cbcrIdx++]=Cb2; dstCbCr[cbcrIdx++]=Cr2;
        dstCbCr[cbcrIdx++]=Cb4; dstCbCr[cbcrIdx++]=Cr4;
    }
}

HRESULT InputContext::VideoInputFormatChanged(
        BMDVideoInputFormatChangedEvents events,
        IDeckLinkDisplayMode *newMode,
        BMDDetectedVideoInputFormatFlags detectedFlags)
{
    if (!newMode || !input) return S_OK;

    CFStringRef modeNameCF = nullptr;
    newMode->GetName(&modeNameCF);
    std::string modeName = "Unknown";
    if (modeNameCF) {
        char buf[64];
        CFStringGetCString(modeNameCF, buf, sizeof(buf), kCFStringEncodingUTF8);
        modeName = buf;
        CFRelease(modeNameCF);
    }

    if (onFormatChanged) onFormatChanged(slotIndex, modeName.c_str());

    BMDDisplayMode mode  = newMode->GetDisplayMode();
    BMDPixelFormat pxFmt = (detectedFlags & bmdDetectedVideoInputRGB444)
                           ? bmdFormat10BitRGB : bmdFormat10BitYUV;
    IDeckLinkInput *inp = input;

    auto *ringPtr = ring.data();

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        inp->StopStreams();
        inp->DisableVideoInput();

        for (int r = 0; r < kRingDepth; ++r) {
            ringPtr[r].ready.store(false, std::memory_order_release);
            dispatch_async(dispatch_get_main_queue(), ^{
                ringPtr[r].luma   = nil;
                ringPtr[r].chroma = nil;
            });
        }

        inp->EnableVideoInput(mode, pxFmt, bmdVideoInputEnableFormatDetection);
        inp->StartStreams();
    });

    return S_OK;
}

HRESULT InputContext::VideoInputFrameArrived(
        IDeckLinkVideoInputFrame *videoFrame,
        IDeckLinkAudioInputPacket *)
{
    if (!videoFrame) return S_OK;

    bool hasSignal = !(videoFrame->GetFlags() & bmdFrameHasNoInputSource);
    bool wasConnected = connected.exchange(hasSignal, std::memory_order_relaxed);
    if (wasConnected != hasSignal && onConnectionChanged)
        onConnectionChanged(slotIndex, hasSignal);

    if (!hasSignal) return S_OK;
    uploadFrame(videoFrame);
    return S_OK;
}

void InputContext::uploadFrame(IDeckLinkVideoInputFrame *frame) {
    long w        = frame->GetWidth();
    long h        = frame->GetHeight();
    long rowBytes = frame->GetRowBytes();
    int  wordsPerRow = (int)(rowBytes / 4);

    IDeckLinkVideoBuffer *videoBuffer = nullptr;
    if (frame->QueryInterface(IID_IDeckLinkVideoBuffer,
                              reinterpret_cast<void **>(&videoBuffer)) != S_OK
        || !videoBuffer) {
        return;
    }

    videoBuffer->StartAccess(bmdBufferAccessRead);

    void *rawData = nullptr;
    videoBuffer->GetBytes(&rawData);

    if (!rawData) {
        videoBuffer->EndAccess(bmdBufferAccessRead);
        videoBuffer->Release();
        return;
    }

    int wSlot = (writeIdx.load(std::memory_order_relaxed) + 1) % kRingDepth;
    FrameSlot &slot = ring[wSlot];

    if (!slot.luma) {
        auto ld = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatR16Unorm
            width:w height:h mipmapped:NO];
        ld.usage = MTLTextureUsageShaderRead;
        ld.storageMode = MTLStorageModeManaged;
        slot.luma = [mtlDevice newTextureWithDescriptor:ld];

        auto cd = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRG16Unorm
            width:w/2 height:h mipmapped:NO];
        cd.usage = MTLTextureUsageShaderRead;
        cd.storageMode = MTLStorageModeManaged;
        slot.chroma = [mtlDevice newTextureWithDescriptor:cd];
    }

    static thread_local std::vector<uint16_t> lumaStage;
    static thread_local std::vector<uint16_t> chromaStage;
    lumaStage  .resize(w * h);
    chromaStage.resize((w / 2) * h * 2);

    const uint32_t *src32 = static_cast<const uint32_t *>(rawData);
    for (int row = 0; row < h; ++row) {
        decodeV210Row(src32 + row * wordsPerRow,
                      wordsPerRow,
                      lumaStage.data()   + row * w,
                      chromaStage.data() + row * (w / 2) * 2,
                      (int)w);
    }

    videoBuffer->EndAccess(bmdBufferAccessRead);
    videoBuffer->Release();

    [slot.luma replaceRegion:MTLRegionMake2D(0, 0, w, h)
                 mipmapLevel:0
                   withBytes:lumaStage.data()
                 bytesPerRow:w * sizeof(uint16_t)];

    [slot.chroma replaceRegion:MTLRegionMake2D(0, 0, w/2, h)
                   mipmapLevel:0
                     withBytes:chromaStage.data()
                   bytesPerRow:(w/2) * 2 * sizeof(uint16_t)];

    BMDTimeValue pts = 0, dur = 0;
    frame->GetStreamTime(&pts, &dur, 50);
    slot.pts = static_cast<uint64_t>(pts);

    slot.ready.store(true, std::memory_order_release);
    writeIdx.store(wSlot, std::memory_order_release);
}

CaptureEngine::CaptureEngine(id<MTLDevice> device) : _metalDevice(device) {
    enumerateDevices();
    for (int i = 0; i < kInputCount; ++i) _slotAssignment[i] = i;
}

void CaptureEngine::enumerateDevices() {
    IDeckLinkIterator *iter = CreateDeckLinkIteratorInstance();
    if (!iter) return;
    IDeckLink *dl = nullptr;
    while (iter->Next(&dl) == S_OK) _allDevices.push_back(dl);
    iter->Release();
}

CaptureEngine::~CaptureEngine() {
    stop();
    for (auto *dl : _allDevices) dl->Release();
}

bool CaptureEngine::assignDevice(int physicalDeviceIndex, int slotIndex) {
    if (slotIndex < 0 || slotIndex >= kInputCount) return false;
    if (physicalDeviceIndex < 0 || physicalDeviceIndex >= (int)_allDevices.size()) return false;
    std::lock_guard<std::mutex> lock(_assignMutex);
    _slotAssignment[slotIndex] = physicalDeviceIndex;
    return true;
}

bool CaptureEngine::start(BMDDisplayMode mode) {
    std::lock_guard<std::mutex> lock(_assignMutex);
    _mode = mode;

    for (int slot = 0; slot < kInputCount; ++slot) {
        int physIdx = _slotAssignment[slot];
        if (physIdx < 0 || physIdx >= (int)_allDevices.size()) continue;

        IDeckLink *dl = _allDevices[physIdx];
        IDeckLinkInput *inputIface = nullptr;
        if (dl->QueryInterface(IID_IDeckLinkInput, (void **)&inputIface) != S_OK) continue;

        auto ctx = std::make_unique<InputContext>();
        ctx->slotIndex = slot;
        ctx->device    = dl;
        ctx->input     = inputIface;
        ctx->mtlDevice = _metalDevice;
        ctx->onConnectionChanged = onConnectionChanged;
        ctx->onFormatChanged     = onFormatChanged;

        BMDVideoInputFlags inputFlags = bmdVideoInputEnableFormatDetection;
        if (inputIface->EnableVideoInput(mode, bmdFormat10BitYUV,
                                         inputFlags) != S_OK) {
            inputIface->Release();
            continue;
        }
        inputIface->SetCallback(ctx.get());
        inputIface->StartStreams();
        _contexts[slot] = std::move(ctx);
    }
    _running = true;
    return true;
}

void CaptureEngine::stop() {
    if (!_running) return;
    _running = false;
    for (int i = 0; i < kInputCount; ++i) {
        if (_contexts[i] && _contexts[i]->input) {
            _contexts[i]->input->StopStreams();
            _contexts[i]->input->DisableVideoInput();
            _contexts[i]->input->SetCallback(nullptr);
            _contexts[i]->input->Release();
            _contexts[i]->input = nullptr;
        }
        _contexts[i].reset();
    }
}

FrameSlot *CaptureEngine::latestSlot(int slotIndex) {
    if (slotIndex < 0 || slotIndex >= kInputCount) return nullptr;
    if (!_contexts[slotIndex]) return nullptr;
    auto &ctx = *_contexts[slotIndex];
    int r = ctx.writeIdx.load(std::memory_order_acquire);
    FrameSlot &slot = ctx.ring[r];
    return slot.ready.load(std::memory_order_acquire) ? &slot : nullptr;
}
