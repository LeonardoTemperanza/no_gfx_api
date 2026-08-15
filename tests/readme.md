
You can use this

For local testing, you can generate goldens for your specific GPU vendor, drivers and OS, and then compare using those, like this:
- Generate goldens in "goldens_local"
- Compare against those. New images will be put into "output".
You can also set the output and golden directories to be viewed as large icons in your file explorer of choice, so that you can quickly view them all together.

For automated testing, github actions will be used to generate goldens using a CPU implementation of Vulkan (to get deterministic results),
and those images will be source controlled and put into "goldens". When submitting a new PR, that same CPU implementation will be used to check for any mismatches.
