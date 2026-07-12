newoption {
    trigger = "vk-version",
    value = "VERSION",
    description = "Choose a specif Vulkan version to target",
    allowed = {
       { "4", "1004000" },
       { "3", "1003000" },
       { "2", "1002000" },
       { "1", "1001000" },
       { "0", "1000000" },
    },
    default = "1"
}

-- Check Premake version
if _PREMAKE_VERSION < "5.0" then
    error("This script requires Premake 5.0 or later.")
end

-- Constants and options
VMA_VERSION = "v3.4.0"
VULKAN_HEADERS_VERSION = "v1.4.355"

-- Utility functions
local redirectNul = (os.host() == "windows") and ">nul 2>&1" or ">/dev/null 2>&1"

local function hasCommand(cmd)
    return os.execute(cmd .. " " .. redirectNul)
end

local function getOsAndArchitecture()
    local target_arch = os.targetarch()
    if target_arch == nil then target_arch = os.hostarch() end
    return os.target(), target_arch:lower()
end

-- Setup functions
local function setupDirectories()
    BUILD_DIR = path.getabsolute("./build")
    DEPS_DIR = path.join(BUILD_DIR, "deps")
    os.mkdir(BUILD_DIR)
    os.mkdir(DEPS_DIR)
end

local function downloadDependencies()
    if not hasCommand("git --version") then
        error("Git is required but not found. Please install it.")
    end

    VMA_DIR = path.join(DEPS_DIR, "vma")
    VULKAN_HEADERS_DIR = path.join(DEPS_DIR, "vulkan_headers")

    local function cloneRepo(repoName, repoDir, repoUrl, repoVersion)
        -- Ignore already cloned
        if not os.isdir(repoDir) then
            print("Cloning " .. repoName .. " " .. repoVersion .. "...")
            if not os.execute("git clone " .. repoUrl .. " " .. repoDir) then
                error("Failed to clone " .. repoName .. " repository.")
            end
            if not os.execute("cd " .. repoDir .. " && git checkout " .. repoVersion .. redirectNul) then
                error("Failed to checkout " .. repoVersion .. " for " .. repoName .. ".")
            end
        end
    end

    cloneRepo(
        "VMA", VMA_DIR, "https://github.com/GPUOpen-LibrariesAndSDKs/VulkanMemoryAllocator.git",
        VMA_VERSION)
    cloneRepo(
        "Vulkan-Headers", VULKAN_HEADERS_DIR, "https://github.com/KhronosGroup/Vulkan-Headers.git",
        VULKAN_HEADERS_VERSION)
end

local function generateBuildFile()
    local implFile = path.join(BUILD_DIR, "build.bat")
    local f = assert(io.open(implFile, "w"))

    local include_vma = path.join(VMA_DIR, "include")
    local include_vulkan = path.join(VULKAN_HEADERS_DIR, "include")

    local content = [[
@echo off
setlocal enabledelayedexpansion

where /Q cl.exe || (
    set __VSCMD_ARG_NO_LOGO=1
    for /f "tokens=*" %%i in ('"C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath') do set VS=%%i
    if "!VS!" equ "" (
        echo ERROR: MSVC installation not found
        exit /b 1
    )
    call "!VS!\Common7\Tools\vsdevcmd.bat" -arch=x64 -host_arch=x64 || exit /b 1
)

if "%VSCMD_ARG_TGT_ARCH%" neq "x64" (
    if "%ODIN_IGNORE_MSVC_CHECK%" == "" (
        echo ERROR: please run this from MSVC x64 native tools command prompt, 32-bit target is not supported!
        exit /b 1
    )
)

echo Building VMA static library...

:: Compile the VMA library
cl /c /EHsc /std:c++17 ^
    /MD ^
    /O2 ^
    /DNDEBUG ^
    /I "]] .. include_vma .. [[" ^
    /I "]] .. include_vulkan .. [[" ^
    /Fo:vk_mem_alloc.obj ^
    vk_mem_alloc.cpp
if errorlevel 1 (
    echo ERROR: Compilation failed
    exit /b 1
)

:: Create the static library
lib vk_mem_alloc.obj /OUT:..\vma_windows_x86_64.lib
if errorlevel 1 (
    echo ERROR: Linking lib failed
    exit /b 1
)

:: Cleanup
del vk_mem_alloc.obj

echo Done.

endlocal
]]

    f:write(content)
    f:close()
end

local function generateImplFile(vulkanVersion)
    local implFile = path.join(BUILD_DIR, "vk_mem_alloc.cpp")
    local f = assert(io.open(implFile, "w"))
    f:write(string.format([[
#define VMA_VULKAN_VERSION %d
#define VMA_STATIC_VULKAN_FUNCTIONS 0
#define VMA_DYNAMIC_VULKAN_FUNCTIONS 0
#define VMA_IMPLEMENTATION
#include "vk_mem_alloc.h"
]], vulkanVersion))
    f:close()
end

-- Workspace and project configuration
workspace "vma"
    configurations { "Debug", "Release" }
    location(path.join("build", "make", os.host()))
    targetdir "bin/%{cfg.buildcfg}"

    -- Execute setup
    local osName, arch = getOsAndArchitecture()
    print("Detected OS: " .. osName .. ", Architecture: " .. arch)
    setupDirectories()
    downloadDependencies()

    local vmaVersionMap = {
        ["4"] = "1004000",
        ["3"] = "1003000",
        ["2"] = "1002000",
        ["1"] = "1001000",
        ["0"] = "1000000",
    }
    local vmaVersion = vmaVersionMap[_OPTIONS["vk-version"]] or vmaVersionMap["1"]
    generateImplFile(tonumber(vmaVersion))
    generateBuildFile()

    -- Define supported platforms
    platforms { "x86_64", "ARM64" }
    defaultplatform(arch)

project "vma"
    kind "StaticLib"
    language "C++"
    cppdialect "C++17"
    staticruntime "Off"
    exceptionhandling "On"
    rtti "Off"

    targetdir "./"
    targetname("vma_%{os.host()}_%{cfg.platform}")

    includedirs {
        path.join(VMA_DIR, "include"),
        path.join(VULKAN_HEADERS_DIR, "include")
    }

    files {
        path.join(BUILD_DIR, "vk_mem_alloc.cpp"),
    }

    filter "system:windows"
        buildoptions { "/MD", "/O2" }
    filter { "system:windows", "configurations:Debug" }
        buildoptions { "/MDd" }

    filter { "system:linux or system:macosx or system:bsd" }
        buildoptions {
            "-fPIC",
            "-Wall",
            "-Wextra",
        }
        pic "On"

    filter "system:macosx"
        buildoptions {
            "-stdlib=libc++",
        }

    filter "system:linux or system:macosx"
        buildoptions { "-fPIC" }

    filter "configurations:Debug"
        defines { "DEBUG" }
        symbols "Full"
        optimize "Off"

    filter "configurations:Release"
        defines { "NDEBUG" }
        optimize "Speed"
        symbols "Off"
        minimalrebuild "Off"
