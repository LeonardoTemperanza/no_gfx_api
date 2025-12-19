
package main

import "core:fmt"

main :: proc()
{
    print_preamble()
}

print_preamble :: proc()
{
    fmt.println("#version 460")
    fmt.println("#extension GL_EXT_buffer_reference : require")
    fmt.println("#extension GL_EXT_buffer_reference2 : require")
}
