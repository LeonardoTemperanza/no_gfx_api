@echo off
setlocal

set flags=

for %%f in (*.glsl) do (
    glslangvalidator %flags% -V "%%f" -o "%%~nf.spv"
)

