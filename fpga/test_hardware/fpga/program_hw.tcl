set hw_server_url [lindex $argv 0]
set hw_device_name [lindex $argv 1]
set bit_file [lindex $argv 2]

if {$hw_server_url eq ""} {
    set hw_server_url "TCP:localhost:3121"
}

if {$hw_device_name eq ""} {
    set hw_device_name "xczu9_0"
}

if {$bit_file eq ""} {
    set bit_file "fpga.bit"
}

open_hw_manager
connect_hw_server -url $hw_server_url
open_hw_target

set hw_device [get_hw_devices $hw_device_name]
if {$hw_device eq ""} {
    error "No se ha encontrado el dispositivo hardware $hw_device_name"
}

current_hw_device $hw_device
set_property PROGRAM.FILE $bit_file $hw_device
program_hw_devices $hw_device

puts "FPGA programada correctamente con $bit_file"
