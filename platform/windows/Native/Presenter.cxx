// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
//
// Direct3D 11 presenter for a WinUI SwapChainPanel (DESKTOP.md section 1,
// DECISIONS.md D11). The core renders 256x256 opaque BGRA tiles at device
// resolution; they are uploaded into a persistent texture the size of the
// swap chain, which is copied into the back buffer on present. The persistent
// texture keeps the frame when the swap chain's buffers rotate, so a present
// only needs the tiles that changed.

#include "tidyvnc_windows.h"

#include <windows.h>
#include <d3d11_1.h>
#include <dxgi1_3.h>
#include <wrl/client.h>

#include <cstring>
#include <mutex>
#include <new>

using Microsoft::WRL::ComPtr;

namespace {

// microsoft.ui.xaml.media.dxinterop.h (Windows App SDK). Declared here so the
// CMake build does not depend on the NuGet package layout.
MIDL_INTERFACE("63aad0b8-7c24-40ff-85a8-640d944cc325")
ISwapChainPanelNative : public IUnknown
{
public:
  virtual HRESULT STDMETHODCALLTYPE SetSwapChain(IDXGISwapChain* swapChain) = 0;
};

constexpr UINT maximumDimension = 16384;
constexpr UINT bufferCount = 2;
constexpr DXGI_FORMAT format = DXGI_FORMAT_B8G8R8A8_UNORM;

bool clip(const tvw_rect& area, UINT width, UINT height, D3D11_BOX& box)
{
  if (area.width <= 0 || area.height <= 0)
    return false;
  LONGLONG left = area.x < 0 ? 0 : area.x;
  LONGLONG top = area.y < 0 ? 0 : area.y;
  LONGLONG right = (LONGLONG)area.x + area.width;
  LONGLONG bottom = (LONGLONG)area.y + area.height;
  if (right > width)
    right = width;
  if (bottom > height)
    bottom = height;
  if (left >= right || top >= bottom)
    return false;
  box = {(UINT)left, (UINT)top, 0, (UINT)right, (UINT)bottom, 1};
  return true;
}

} // namespace

struct tvw_presenter {
  // Serializes the render thread with attach/destroy. The D3D device is also
  // multithread-protected for the XAML compositor's use of the swap chain.
  std::mutex lock;
  ComPtr<ID3D11Device> device;
  ComPtr<ID3D11DeviceContext1> context;
  ComPtr<IDXGISwapChain2> swapChain;
  ComPtr<ID3D11Texture2D> frame;
  ComPtr<ID3D11RenderTargetView> frameView;
  UINT width = 0, height = 0;
  bool presented = false;
};

namespace {

// One Direct3D device for every presenter in the process. Each device that has
// had a composition swap chain keeps two process handles in the driver after it
// is released (measured on this machine's NVIDIA driver; bare devices and swap
// chains on a kept device release fully), so a desktop view reattaching or
// moving to a full-screen surface leaked with a device per presenter. The
// device lives for the process and is replaced only after it has been lost;
// presenters keep their own references, and every context call names its
// resources, so presenters on different render threads can share it (the
// device is multithread-protected).
std::mutex sharedLock;
ComPtr<ID3D11Device> sharedDevice;
ComPtr<ID3D11DeviceContext1> sharedContext;

HRESULT createDevice(tvw_presenter& presenter);

HRESULT acquireDevice(tvw_presenter& presenter)
{
  std::lock_guard<std::mutex> lock(sharedLock);
  if (sharedDevice && sharedDevice->GetDeviceRemovedReason() != S_OK) {
    sharedDevice.Reset();
    sharedContext.Reset();
  }
  if (!sharedDevice) {
    HRESULT hr = createDevice(presenter);
    if (FAILED(hr))
      return hr;
    sharedDevice = presenter.device;
    sharedContext = presenter.context;
    return S_OK;
  }
  presenter.device = sharedDevice;
  presenter.context = sharedContext;
  return S_OK;
}

HRESULT createDevice(tvw_presenter& presenter)
{
  const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1,
                                      D3D_FEATURE_LEVEL_10_0};
  UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
  ComPtr<ID3D11Device> device;
  ComPtr<ID3D11DeviceContext> context;
  HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags, levels, ARRAYSIZE(levels),
                                 D3D11_SDK_VERSION, &device, nullptr, &context);
  if (FAILED(hr)) {
    // Software rendering (basic display driver, some VMs).
    hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, flags, levels, ARRAYSIZE(levels), D3D11_SDK_VERSION,
                           &device, nullptr, &context);
  }
  if (FAILED(hr))
    return hr;
  ComPtr<ID3D10Multithread> multithread;
  if (SUCCEEDED(context.As(&multithread)))
    multithread->SetMultithreadProtected(TRUE);
  hr = context.As(&presenter.context);
  if (FAILED(hr))
    return hr;
  presenter.device = device;
  return S_OK;
}

HRESULT createFrame(tvw_presenter& presenter, UINT width, UINT height)
{
  D3D11_TEXTURE2D_DESC desc = {};
  desc.Width = width;
  desc.Height = height;
  desc.MipLevels = 1;
  desc.ArraySize = 1;
  desc.Format = format;
  desc.SampleDesc.Count = 1;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_RENDER_TARGET;
  ComPtr<ID3D11Texture2D> frame;
  ComPtr<ID3D11RenderTargetView> view;
  HRESULT hr = presenter.device->CreateTexture2D(&desc, nullptr, &frame);
  if (SUCCEEDED(hr))
    hr = presenter.device->CreateRenderTargetView(frame.Get(), nullptr, &view);
  if (FAILED(hr))
    return hr;
  const float black[4] = {0.0f, 0.0f, 0.0f, 1.0f};
  presenter.context->ClearRenderTargetView(view.Get(), black);
  presenter.frame = frame;
  presenter.frameView = view;
  presenter.width = width;
  presenter.height = height;
  return S_OK;
}

HRESULT createSwapChain(tvw_presenter& presenter)
{
  ComPtr<IDXGIDevice> dxgiDevice;
  ComPtr<IDXGIAdapter> adapter;
  ComPtr<IDXGIFactory2> factory;
  HRESULT hr = presenter.device.As(&dxgiDevice);
  if (SUCCEEDED(hr))
    hr = dxgiDevice->GetAdapter(&adapter);
  if (SUCCEEDED(hr))
    hr = adapter->GetParent(IID_PPV_ARGS(&factory));
  if (FAILED(hr))
    return hr;

  DXGI_SWAP_CHAIN_DESC1 desc = {};
  desc.Width = 1;
  desc.Height = 1;
  desc.Format = format;
  desc.SampleDesc.Count = 1;
  desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
  desc.BufferCount = bufferCount;
  desc.Scaling = DXGI_SCALING_STRETCH;
  desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
  desc.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
  ComPtr<IDXGISwapChain1> swapChain;
  hr = factory->CreateSwapChainForComposition(presenter.device.Get(), &desc, nullptr, &swapChain);
  if (SUCCEEDED(hr))
    hr = swapChain.As(&presenter.swapChain);
  if (SUCCEEDED(hr))
    hr = createFrame(presenter, 1, 1);
  return hr;
}

} // namespace

extern "C" {

int32_t tvw_presenter_create(tvw_presenter** out)
{
  if (!out)
    return E_POINTER;
  *out = nullptr;
  auto* presenter = new (std::nothrow) tvw_presenter();
  if (!presenter)
    return E_OUTOFMEMORY;
  HRESULT hr = acquireDevice(*presenter);
  if (SUCCEEDED(hr))
    hr = createSwapChain(*presenter);
  if (FAILED(hr)) {
    delete presenter;
    return hr;
  }
  *out = presenter;
  return S_OK;
}

int32_t tvw_presenter_attach(tvw_presenter* presenter, void* panel)
{
  if (!presenter)
    return E_POINTER;
  if (!panel)
    return S_OK; // Detaching happens when the panel releases its swap chain.
  ComPtr<ISwapChainPanelNative> native;
  HRESULT hr = static_cast<IUnknown*>(panel)->QueryInterface(IID_PPV_ARGS(&native));
  if (FAILED(hr))
    return hr;
  std::lock_guard<std::mutex> lock(presenter->lock);
  return native->SetSwapChain(presenter->swapChain.Get());
}

int32_t tvw_presenter_resize(tvw_presenter* presenter, uint32_t width, uint32_t height, float scale_x, float scale_y)
{
  if (!presenter)
    return E_POINTER;
  if (width == 0 || height == 0 || width > maximumDimension || height > maximumDimension || !(scale_x > 0.0f) ||
      !(scale_y > 0.0f))
    return E_INVALIDARG;
  std::lock_guard<std::mutex> lock(presenter->lock);
  HRESULT hr = S_OK;
  if (width != presenter->width || height != presenter->height) {
    presenter->frameView.Reset();
    presenter->frame.Reset();
    presenter->context->ClearState();
    presenter->context->Flush();
    hr = presenter->swapChain->ResizeBuffers(bufferCount, width, height, format, 0);
    if (SUCCEEDED(hr))
      hr = createFrame(*presenter, width, height);
    if (FAILED(hr))
      return hr;
    presenter->presented = false;
  }
  // The panel scales its content by the composition scale; undo it so one
  // swap-chain pixel is one physical pixel.
  DXGI_MATRIX_3X2_F inverse = {1.0f / scale_x, 0.0f, 0.0f, 1.0f / scale_y, 0.0f, 0.0f};
  return presenter->swapChain->SetMatrixTransform(&inverse);
}

int32_t tvw_presenter_clear(tvw_presenter* presenter, const tvw_rect* area)
{
  if (!presenter || !area)
    return E_POINTER;
  std::lock_guard<std::mutex> lock(presenter->lock);
  if (!presenter->frame)
    return E_NOT_VALID_STATE; // A failed resize; recreate the presenter.
  D3D11_BOX box;
  if (!clip(*area, presenter->width, presenter->height, box))
    return S_OK;
  const float black[4] = {0.0f, 0.0f, 0.0f, 1.0f};
  D3D11_RECT rect = {(LONG)box.left, (LONG)box.top, (LONG)box.right, (LONG)box.bottom};
  presenter->context->ClearView(presenter->frameView.Get(), black, &rect, 1);
  return S_OK;
}

int32_t tvw_presenter_upload(tvw_presenter* presenter, const uint8_t* bgra, uint32_t stride, const tvw_rect* area)
{
  if (!presenter || !bgra || !area)
    return E_POINTER;
  if (area->width <= 0 || area->height <= 0 || stride < (uint64_t)area->width * 4)
    return E_INVALIDARG;
  std::lock_guard<std::mutex> lock(presenter->lock);
  if (!presenter->frame)
    return E_NOT_VALID_STATE; // A failed resize; recreate the presenter.
  D3D11_BOX box;
  if (!clip(*area, presenter->width, presenter->height, box))
    return S_OK;
  const uint8_t* source = bgra + (size_t)(box.top - area->y) * stride + (size_t)(box.left - area->x) * 4;
  presenter->context->UpdateSubresource(presenter->frame.Get(), 0, &box, source, stride, 0);
  return S_OK;
}

int32_t tvw_presenter_present(tvw_presenter* presenter, const tvw_rect* dirty, uint32_t count)
{
  if (!presenter || (count && !dirty))
    return E_POINTER;
  std::lock_guard<std::mutex> lock(presenter->lock);
  if (!presenter->frame)
    return E_NOT_VALID_STATE; // A failed resize; recreate the presenter.
  ComPtr<ID3D11Texture2D> backBuffer;
  HRESULT hr = presenter->swapChain->GetBuffer(0, IID_PPV_ARGS(&backBuffer));
  if (FAILED(hr))
    return hr;
  presenter->context->CopyResource(backBuffer.Get(), presenter->frame.Get());

  // Dirty rectangles are a hint to the compositor; the first present after a
  // resize must cover the whole surface.
  RECT rects[64];
  UINT used = 0;
  if (presenter->presented && count > 0 && count <= ARRAYSIZE(rects)) {
    for (uint32_t i = 0; i < count; i++) {
      D3D11_BOX box;
      if (clip(dirty[i], presenter->width, presenter->height, box))
        rects[used++] = {(LONG)box.left, (LONG)box.top, (LONG)box.right, (LONG)box.bottom};
    }
    if (used == 0)
      return S_OK; // Nothing visible changed.
  }
  DXGI_PRESENT_PARAMETERS parameters = {};
  parameters.DirtyRectsCount = used;
  parameters.pDirtyRects = used ? rects : nullptr;
  hr = presenter->swapChain->Present1(1, 0, &parameters);
  if (SUCCEEDED(hr))
    presenter->presented = true;
  return hr == DXGI_STATUS_OCCLUDED ? S_OK : hr;
}

int32_t tvw_presenter_read(tvw_presenter* presenter, const tvw_rect* area, uint8_t* bgra, uint32_t stride)
{
  if (!presenter || !area || !bgra)
    return E_POINTER;
  std::lock_guard<std::mutex> lock(presenter->lock);
  if (!presenter->frame)
    return E_NOT_VALID_STATE; // A failed resize; recreate the presenter.
  if (area->x < 0 || area->y < 0 || area->width <= 0 || area->height <= 0 ||
      (int64_t)area->x + area->width > presenter->width || (int64_t)area->y + area->height > presenter->height ||
      stride < (uint64_t)area->width * 4)
    return E_INVALIDARG;
  D3D11_TEXTURE2D_DESC desc = {};
  desc.Width = (UINT)area->width;
  desc.Height = (UINT)area->height;
  desc.MipLevels = 1;
  desc.ArraySize = 1;
  desc.Format = format;
  desc.SampleDesc.Count = 1;
  desc.Usage = D3D11_USAGE_STAGING;
  desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  ComPtr<ID3D11Texture2D> staging;
  HRESULT hr = presenter->device->CreateTexture2D(&desc, nullptr, &staging);
  if (FAILED(hr))
    return hr;
  D3D11_BOX box = {(UINT)area->x, (UINT)area->y, 0, (UINT)(area->x + area->width), (UINT)(area->y + area->height), 1};
  presenter->context->CopySubresourceRegion(staging.Get(), 0, 0, 0, 0, presenter->frame.Get(), 0, &box);
  D3D11_MAPPED_SUBRESOURCE mapped;
  hr = presenter->context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped);
  if (FAILED(hr))
    return hr;
  for (int32_t row = 0; row < area->height; row++)
    memcpy(bgra + (size_t)row * stride, static_cast<const uint8_t*>(mapped.pData) + (size_t)row * mapped.RowPitch,
           (size_t)area->width * 4);
  presenter->context->Unmap(staging.Get(), 0);
  return S_OK;
}

void tvw_presenter_destroy(tvw_presenter* presenter)
{
  if (!presenter)
    return;
  {
    std::lock_guard<std::mutex> lock(presenter->lock);
    // The context is shared: finish this presenter's work without resetting others' state.
    presenter->frameView.Reset();
    presenter->frame.Reset();
    presenter->swapChain.Reset();
    if (presenter->context)
      presenter->context->Flush();
  }
  delete presenter;
}

} // extern "C"
