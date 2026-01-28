#include "graphics_capture_manager.h"
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.System.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <chrono>
#include <psapi.h>

using namespace winrt;
using namespace Windows::Graphics::Capture;
using namespace Windows::Graphics::DirectX;
using namespace Windows::Graphics::DirectX::Direct3D11;
using namespace Windows::Foundation;

namespace screen_recorder_windows {

GraphicsCaptureManager::GraphicsCaptureManager()
    : is_capturing_(false) {
    // Initialize WinRT
    init_apartment();
}

GraphicsCaptureManager::~GraphicsCaptureManager() {
    StopCapture();
}

bool GraphicsCaptureManager::RequestPermission(HWND parent_window) {
    try {
        // Windows 10 Build 17763+ requires explicit permission via picker
        // For now, return true - permission is requested when capture starts
        return true;
    } catch (...) {
        return false;
    }
}

bool GraphicsCaptureManager::CheckPermissions() {
    // Graphics Capture API doesn't have a pre-check mechanism
    // Permission is granted when user selects source via picker
    return true;
}

std::vector<WindowInfoNative> GraphicsCaptureManager::GetAvailableWindows() {
    std::vector<WindowInfoNative> windows;

    try {
        // Enumerate all top-level windows
        EnumWindows([](HWND hwnd, LPARAM lparam) -> BOOL {
            auto* windows_list = reinterpret_cast<std::vector<WindowInfoNative>*>(lparam);

            // Skip invisible windows
            if (!IsWindowVisible(hwnd)) {
                return TRUE;
            }

            // Get window title
            wchar_t title[256];
            GetWindowTextW(hwnd, title, 256);
            if (wcslen(title) == 0) {
                return TRUE; // Skip windows without title
            }

            // Get process name
            DWORD process_id;
            GetWindowThreadProcessId(hwnd, &process_id);

            HANDLE process = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, FALSE, process_id);
            wchar_t process_name[MAX_PATH];
            if (process) {
                GetModuleBaseNameW(process, NULL, process_name, MAX_PATH);
                CloseHandle(process);
            } else {
                wcscpy_s(process_name, L"Unknown");
            }

            // Get window rect
            RECT rect;
            GetWindowRect(hwnd, &rect);

            WindowInfoNative info;
            info.id = std::to_string(reinterpret_cast<uintptr_t>(hwnd));

            // Convert wide strings to UTF-8
            int title_len = WideCharToMultiByte(CP_UTF8, 0, title, -1, nullptr, 0, nullptr, nullptr);
            std::string title_utf8(title_len, 0);
            WideCharToMultiByte(CP_UTF8, 0, title, -1, &title_utf8[0], title_len, nullptr, nullptr);
            info.title = title_utf8.c_str();

            int owner_len = WideCharToMultiByte(CP_UTF8, 0, process_name, -1, nullptr, 0, nullptr, nullptr);
            std::string owner_utf8(owner_len, 0);
            WideCharToMultiByte(CP_UTF8, 0, process_name, -1, &owner_utf8[0], owner_len, nullptr, nullptr);
            info.owner_name = owner_utf8.c_str();

            info.x = rect.left;
            info.y = rect.top;
            info.width = rect.right - rect.left;
            info.height = rect.bottom - rect.top;
            info.is_on_screen = true;

            windows_list->push_back(info);
            return TRUE;
        }, reinterpret_cast<LPARAM>(&windows));

    } catch (...) {
        // Return empty list on error
    }

    return windows;
}

std::vector<ScreenInfoNative> GraphicsCaptureManager::GetAvailableScreens() {
    std::vector<ScreenInfoNative> screens;

    try {
        // Enumerate monitors
        int monitor_index = 0;
        auto pair_data = std::make_pair(&screens, &monitor_index);
        EnumDisplayMonitors(nullptr, nullptr, [](HMONITOR monitor, HDC, LPRECT, LPARAM lparam) -> BOOL {
            auto* data = reinterpret_cast<std::pair<std::vector<ScreenInfoNative>*, int*>*>(lparam);
            auto* screens_list = data->first;
            int& index = *data->second;

            MONITORINFOEXW info;
            info.cbSize = sizeof(MONITORINFOEXW);
            if (GetMonitorInfoW(monitor, &info)) {
                ScreenInfoNative screen;
                screen.id = std::to_string(reinterpret_cast<uintptr_t>(monitor));

                // Convert device name to UTF-8
                int name_len = WideCharToMultiByte(CP_UTF8, 0, info.szDevice, -1, nullptr, 0, nullptr, nullptr);
                std::string name_utf8(name_len, 0);
                WideCharToMultiByte(CP_UTF8, 0, info.szDevice, -1, &name_utf8[0], name_len, nullptr, nullptr);
                screen.name = name_utf8.c_str();

                screen.width = info.rcMonitor.right - info.rcMonitor.left;
                screen.height = info.rcMonitor.bottom - info.rcMonitor.top;
                screen.is_primary = (info.dwFlags & MONITORINFOF_PRIMARY) != 0;

                screens_list->push_back(screen);
            }

            index++;
            return TRUE;
        }, reinterpret_cast<LPARAM>(&pair_data));

    } catch (...) {
        // Return empty list on error
    }

    return screens;
}

bool GraphicsCaptureManager::StartCapture(const std::string& source_id, int fps, FrameCallback callback) {
    if (is_capturing_) {
        return false;
    }

    try {
        frame_callback_ = callback;

        // Create capture item from source ID
        capture_item_ = FindCaptureItem(source_id);
        if (!capture_item_) {
            return false;
        }

        // Create D3D11 device
        com_ptr<ID3D11Device> d3d_device;
        D3D11CreateDevice(
            nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
            D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            nullptr, 0, D3D11_SDK_VERSION,
            d3d_device.put(), nullptr, nullptr);

        // Wrap in WinRT interface
        com_ptr<IDXGIDevice> dxgi_device;
        d3d_device.as(dxgi_device);

        com_ptr<IInspectable> inspectable;
        CreateDirect3D11DeviceFromDXGIDevice(dxgi_device.get(), inspectable.put());
        device_ = inspectable.as<IDirect3DDevice>();

        // Create frame pool
        auto size = capture_item_.Size();
        frame_pool_ = Direct3D11CaptureFramePool::Create(
            device_,
            DirectXPixelFormat::B8G8R8A8UIntNormalized,
            2, // Number of buffers
            size);

        // Set up frame callback
        frame_pool_.FrameArrived([this](auto&& sender, auto&& args) {
            OnFrameArrived(sender, args);
        });

        // Start capture session
        capture_session_ = frame_pool_.CreateCaptureSession(capture_item_);
        capture_session_.StartCapture();

        is_capturing_ = true;
        return true;

    } catch (...) {
        return false;
    }
}

void GraphicsCaptureManager::StopCapture() {
    if (!is_capturing_) {
        return;
    }

    try {
        if (capture_session_) {
            capture_session_.Close();
            capture_session_ = nullptr;
        }

        if (frame_pool_) {
            frame_pool_.Close();
            frame_pool_ = nullptr;
        }

        capture_item_ = nullptr;
        device_ = nullptr;
        is_capturing_ = false;

    } catch (...) {
        // Ignore errors during cleanup
    }
}

void GraphicsCaptureManager::OnFrameArrived(
    Direct3D11CaptureFramePool const& sender,
    IInspectable const&) {

    try {
        auto frame = sender.TryGetNextFrame();
        if (!frame) {
            return;
        }

        auto surface = frame.Surface();
        int width, height;
        auto frame_data = ConvertD3D11TextureToBGRA(surface, width, height);

        // Get timestamp
        auto now = std::chrono::system_clock::now();
        auto micros = std::chrono::duration_cast<std::chrono::microseconds>(
            now.time_since_epoch()).count();

        FrameDataNative native_frame;
        native_frame.data = std::move(frame_data);
        native_frame.width = width;
        native_frame.height = height;
        native_frame.timestamp_micros = micros;

        if (frame_callback_) {
            frame_callback_(native_frame);
        }

    } catch (...) {
        // Drop frame on error
    }
}

GraphicsCaptureItem GraphicsCaptureManager::FindCaptureItem(const std::string& id) {
    try {
        // Convert ID back to HWND or HMONITOR
        uintptr_t handle = std::stoull(id);
        HWND hwnd = reinterpret_cast<HWND>(handle);

        // Try as window first
        if (IsWindow(hwnd)) {
            auto interop = get_activation_factory<GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
            GraphicsCaptureItem item{nullptr};
            check_hresult(interop->CreateForWindow(hwnd, guid_of<ABI::Windows::Graphics::Capture::IGraphicsCaptureItem>(), put_abi(item)));
            return item;
        }

        // Try as monitor
        HMONITOR monitor = reinterpret_cast<HMONITOR>(handle);
        auto interop = get_activation_factory<GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
        GraphicsCaptureItem item{nullptr};
        check_hresult(interop->CreateForMonitor(monitor, guid_of<ABI::Windows::Graphics::Capture::IGraphicsCaptureItem>(), put_abi(item)));
        return item;

    } catch (...) {
        return nullptr;
    }
}

std::vector<uint8_t> GraphicsCaptureManager::ConvertD3D11TextureToBGRA(
    IDirect3DSurface const& surface, int& width, int& height) {

    // Get D3D11 texture from surface
    com_ptr<::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess> dxgi_access;
    surface.as(dxgi_access);

    com_ptr<ID3D11Texture2D> texture;
    check_hresult(dxgi_access->GetInterface(guid_of<ID3D11Texture2D>(), texture.put_void()));

    D3D11_TEXTURE2D_DESC desc;
    texture->GetDesc(&desc);
    width = desc.Width;
    height = desc.Height;

    // Create staging texture for CPU access
    com_ptr<ID3D11Device> device;
    texture->GetDevice(device.put());

    D3D11_TEXTURE2D_DESC staging_desc = desc;
    staging_desc.Usage = D3D11_USAGE_STAGING;
    staging_desc.BindFlags = 0;
    staging_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    staging_desc.MiscFlags = 0;

    com_ptr<ID3D11Texture2D> staging_texture;
    check_hresult(device->CreateTexture2D(&staging_desc, nullptr, staging_texture.put()));

    // Copy to staging
    com_ptr<ID3D11DeviceContext> context;
    device->GetImmediateContext(context.put());
    context->CopyResource(staging_texture.get(), texture.get());

    // Map and read pixels
    D3D11_MAPPED_SUBRESOURCE mapped;
    check_hresult(context->Map(staging_texture.get(), 0, D3D11_MAP_READ, 0, &mapped));

    std::vector<uint8_t> frame_data(width * height * 4);

    // Copy row by row (handle potential pitch differences)
    for (int y = 0; y < height; y++) {
        memcpy(
            frame_data.data() + y * width * 4,
            reinterpret_cast<uint8_t*>(mapped.pData) + y * mapped.RowPitch,
            width * 4);
    }

    context->Unmap(staging_texture.get(), 0);

    return frame_data;
}

} // namespace screen_recorder_windows
