# SPDX-License-Identifier: BSD-2-Clause-Views

set params [dict create]

# Cache/test parameters
dict set params TABLE_DEPTH "4096"
dict set params TABLE_COUNT "4"
dict set params PORT_GLOBAL_COUNT "8"
dict set params TRACE_DEPTH "32768"

# Compatibility parameters required by  fpga.v
dict set params TABLE_KEY_WIDTH "48"
dict set params TABLE_STORE_WIDTH "16"
dict set params TABLE_LOOP_COUNT "100"
dict set params TABLE_CONFIG_ENABLE "1"
dict set params TABLE_REGISTER_STORE_STATE "2"

dict set params TABLE_INSERTION_INITIAL_FILTER "1"
dict set params TABLE_INSERTION_INITIAL_STRATEGY "0"
dict set params TABLE_INSERTION_REALLOCATE_FILTER "1"
dict set params TABLE_INSERTION_REALLOCATE_STRATEGY "0"

dict set params TABLE_LFSR_WIDTH "32"
dict set params TABLE_LFSR_POLY "128'hc8f698af1dca6d1fedB8832004c11db7"
dict set params TABLE_LFSR_STATE_IN "32'hffffffff"
dict set params TABLE_LFSR_CONFIG "GALOIS"
dict set params TABLE_LFSR_FEED_FORWARD "0"
dict set params TABLE_LFSR_REVERSE "1"
dict set params TABLE_LFSR_STYLE "AUTO"

# UART/XFCP parameters
dict set params INTERMEDIATE_FREQUENCY "100000000"
dict set params BAUD_RATE "115200"

set param_list {}
dict for {name value} $params {
    lappend param_list $name=$value
}

set_property generic $param_list [get_filesets sources_1]
