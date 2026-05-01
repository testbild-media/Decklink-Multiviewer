#pragma once

#include "DeckLinkAPI.h"
#include "DeckLinkAPITypes.h"

#import <Metal/Metal.h>
#include <atomic>
#include <array>
#include <functional>
#include <mutex>
#include <memory>
#include <string>

static constexpr int kInputCount = 4;
static constexpr int kRingDepth  = 3;

struct FrameSlot {
    id<MTLTexture>   luma   = nil;
    id<MTLTexture>   chroma = nil;
    uint64_t         pts    = 0;
    std::atomic<bool> ready {false};

    FrameSlot() = default;
    FrameSlot(const FrameSlot&) = delete;
    FrameSlot& operator=(const FrameSlot&) = delete;
};

class InputContext : public IDeckLinkInputCallback {
public:
    int               slotIndex = -1;
    IDeckLink        *device    = nullptr;
    IDeckLinkInput   *input     = nullptr;
    id<MTLDevice>     mtlDevice = nil;

    std::array<FrameSlot, kRingDepth> ring;
    std::atomic<int> writeIdx {0};
    std::atomic<bool> connected {false};

    std::function<void(int, bool)> onConnectionChanged;
    std::function<void(int, const char*)> onFormatChanged;

    HRESULT VideoInputFormatChanged(BMDVideoInputFormatChangedEvents,
                                    IDeckLinkDisplayMode *,
                                    BMDDetectedVideoInputFormatFlags) override;
    HRESULT VideoInputFrameArrived(IDeckLinkVideoInputFrame *,
                                   IDeckLinkAudioInputPacket *) override;

    HRESULT QueryInterface(REFIID, LPVOID *) override { return E_NOINTERFACE; }
    ULONG   AddRef()  override { return ++_refCount; }
    ULONG   Release() override {
        ULONG r = --_refCount;
        if (r == 0) delete this;
        return r;
    }

private:
    std::atomic<ULONG> _refCount {1};
    void uploadFrame(IDeckLinkVideoInputFrame *);
};

class CaptureEngine {
public:
    explicit CaptureEngine(id<MTLDevice> device);
    ~CaptureEngine();

    bool assignDevice(int physicalDeviceIndex, int slotIndex);

    bool start(BMDDisplayMode mode);
    void stop();

    FrameSlot *latestSlot(int slotIndex);

    std::function<void(int slot, bool connected)> onConnectionChanged;
    std::function<void(int slot, const char *format)> onFormatChanged;

private:
    id<MTLDevice> _metalDevice;
    BMDDisplayMode _mode = bmdModeHD1080p50;
    bool _running = false;

    std::array<int, kInputCount> _slotAssignment = {0, 1, 2, 3};
    std::array<std::unique_ptr<InputContext>, kInputCount> _contexts;

    std::mutex _assignMutex;

    std::vector<IDeckLink *> _allDevices;
    void enumerateDevices();
};
