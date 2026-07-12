# Odin VMA

Bindings for [Vulkan Memory Allocator][] **v3.4.0** in [Odin Programming Language][].

## Basic Usage

Copy the `vma` folder to your project or `shared` directory.

```odin
// Initializes a subset of Vulkan functions required by VMA
vma_vulkan_functions := vma.create_vulkan_functions()

vma_create_info: vma.AllocatorCreateInfo = {
    flags            = { .BUFFER_DEVICE_ADDRESS },
    instance         = vk_instance,
    physicalDevice   = vk_physical_device,
    device           = vk_device,
    pVulkanFunctions = &vma_vulkan_functions,
    vulkanApiVersion = api_version,
}

// Create the VMA (Vulkan Memory Allocator)
allocator: vma.Allocator = ---
vma.CreateAllocator(vma_create_info, &allocator)

defer vma.DestroyAllocator(allocator)
```

## Building VMA

Precompiled binaries are not available, but you can easily compile the library using
[Premake](https://premake.github.io/).

### Prerequisites

- [Premake5](https://premake.github.io) - the build configuration
  - You can download the [Pre-Built Binaries](https://premake.github.io/download), simply need
    to be unpacked and placed somewhere on the system search path or any other convenient
    location.
  - For Unix, also requires **GNU libc 2.38**.
- [Git](http://git-scm.com/downloads) - required for clone dependencies

### Windows

1. Clone or [download](https://github.com/Capati/odin-vma/archive/refs/heads/main.zip) this
   repository

2. Download and install **premake5.exe**.

    Either add to PATH or copy to project directory.

3. Open a command window, navigate to the project directory and generate Visual Studio 2022
   project files with desired `vk-version`.

    `vk-version` specifies the Vulkan minor version. For example, 3 corresponds to `1003000`
      (Vulkan 1.3).

    ```shell
    premake5 --vk-version=3 vs2026 # 1003000 (1.3)
    ```

4. From the project folder, open the directory `build\make\windows`, them open the generated
   solution **vma.sln**.

5. In Visual Studio, confirm that the dropdown box at the top says “x64” (not “x86”); and then
   use **Build** > **Build Solution**.

    The generated library file `vma_windows_x86_64.lib` will be located in the root of the
    project directory.

#### Compiling Without Visual Studio

If you do not have Visual Studio installed, you can use the **Build Tools for Visual Studio
2022**, which includes only the required tools to build.

1. Follow the steps above to use `premake5` for generating the project files.
2. [Download MSVC compiler/linker][] & Windows SDK without installing full Visual Studio.
3. Make sure you have the required folder in the PATH:

    - `<portable-msvc>\msvc\VC\Auxiliary\Build` - for `vcvars64.bat`
    - `<portable-msvc>\msvc\VC\Tools\MSVC\14.43.34808\bin\Hostx64\x64` - for `cl` and `lib`

4. Open a command window, navigate to the `build` directory, and locate the `build.bat` file.
   This batch file will use the generated project files to build VMA.
5. Compile and link VMA:

    ```bash
    build.bat
    ```

[Download MSVC compiler/linker]: https://gist.github.com/mmozeiko/7f3162ec2988e81e56d5c4e22cde9977

### Unix (macOS/Linux)

1. Clone or [download](https://github.com/Capati/odin-vma/archive/refs/heads/main.zip) this
   repository

2. Download and install **premake5**

3. Open a terminal window, navigate to the project directory and generate the makefiles with
   desired `vk-version`:

    `vk-version` specifies the Vulkan minor version. For example, 3 corresponds to `1003000`
      (Vulkan 1.3).

    ```bash
    premake5 --vk-version=3 gmake  # 1003000 (1.3)
    # On macOS, you can also use Xcode:
    premake5 --vk-version=3 xcode4
    ```

4. From the project folder, navigate to the generated build directory:

    ```bash
    cd build/make/linux
    # Or
    cd build/make/macosx
    ```

5. Compile the project using the `make` command:

    ```bash
    make config=release_x86_64
    # Or for debug build:
    # make config=debug_x86_64
    ```

    On macOS, the `make` command might need different configuration flags:

    ```bash
    make config=release_x86_64   # For Intel Macs
    # or
    make config=release_arm64    # For Apple Silicon (M1/M2/M3) Macs
    ```

    The generated library file will be located in the root of the project directory.

## License

MIT License - See [LICENSE](./LICENSE) file for details.

[Vulkan Memory Allocator]: https://github.com/GPUOpen-LibrariesAndSDKs/VulkanMemoryAllocator
[Odin Programming Language]: https://odin-lang.org/
[Odin Naming Convention]: https://github.com/odin-lang/Odin/wiki/Naming-Convention
