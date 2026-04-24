proc require_ip {pattern} {
    set matches [lsort [get_ipdefs $pattern]]
    if {[llength $matches] == 0} {
        set matches [lsort [get_ipdefs -all $pattern]]
    }
    if {[llength $matches] == 0} {
        error "missing IP definition matching $pattern"
    }
    return [lindex $matches end]
}

proc detect_kv260_board_part {} {
    if {[info exists ::env(KV260_BOARD_PART)] && $::env(KV260_BOARD_PART) ne ""} {
        return $::env(KV260_BOARD_PART)
    }

    set matches [lsort [get_board_parts -quiet *kv260*]]
    if {[llength $matches] > 0} {
        return [lindex $matches 0]
    }
    return ""
}

proc detect_hw_mode {} {
    if {[info exists ::env(KV260_SIGV_HW_MODE)] && $::env(KV260_SIGV_HW_MODE) ne ""} {
        set mode [string tolower $::env(KV260_SIGV_HW_MODE)]
    } else {
        set mode "full"
    }

    if {$mode eq "bringup"} {
        return 1
    }
    if {$mode eq "full"} {
        return 0
    }
    error "unsupported KV260_SIGV_HW_MODE '$mode'; expected 'full' or 'bringup'"
}

proc set_addr_segment {master_space pattern offset range} {
    set matches {}
    foreach seg [get_bd_addr_segs -quiet -of_objects $master_space] {
        if {[string match "*$pattern*" $seg]} {
            lappend matches $seg
        }
    }
    if {[llength $matches] != 1} {
        error "expected exactly one address segment for $pattern, got [llength $matches]"
    }
    set seg [lindex $matches 0]
    set_property offset $offset $seg
    set_property range $range $seg
}

proc connect_if_present {src_pin_name dst_pin_name} {
    set src_pin [get_bd_pins -quiet $src_pin_name]
    set dst_pin [get_bd_pins -quiet $dst_pin_name]
    if {[llength $src_pin] == 1 && [llength $dst_pin] == 1} {
        if {[catch {connect_bd_net $src_pin $dst_pin} err]} {
            puts "Skipping optional connection ${src_pin_name} -> ${dst_pin_name}: $err"
        }
    } else {
        puts "Skipping optional connection ${src_pin_name} -> ${dst_pin_name}"
    }
}

set project_dir [lindex $argv 0]
if {$project_dir eq ""} {
    set project_dir [file normalize [file join [pwd] build vivado]]
}

set project_name [lindex $argv 1]
if {$project_name eq ""} {
    set project_name kv260_sigv
}

set hw_dir [lindex $argv 2]
if {$hw_dir eq ""} {
    set hw_dir [file normalize [file join [pwd] build hw]]
}

set script_dir [file dirname [file normalize [info script]]]
set kv260_dir [file dirname $script_dir]
set repo_root [file normalize [file join $kv260_dir .. ..]]
set rtl_dir [file join $repo_root fpga rtl]
set src_dir [file join $kv260_dir src]
set xdc_dir [file join $kv260_dir xdc]
set board_part [detect_kv260_board_part]
set bringup_mode [detect_hw_mode]
set device_part xck26-sfvc784-2LV-c

file mkdir $project_dir
file mkdir $hw_dir

create_project -force $project_name $project_dir -part $device_part
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

if {$board_part ne ""} {
    puts "Using board part $board_part"
    set_property board_part $board_part [current_project]
    if {[string match "xilinx.com:kv260_som:*" $board_part]} {
        set_property board_connections {som240_1_connector xilinx.com:kv260_carrier:som240_1_connector:*} [current_project]
    }
} else {
    puts "WARNING: no KV260 board files were found; continuing with part-only project setup"
}

add_files -norecurse [glob -directory $rtl_dir *.v]
add_files -norecurse [glob -directory $rtl_dir *.vh]
add_files -norecurse [glob -directory $src_dir *.v]
add_files -fileset constrs_1 -norecurse [glob -directory $xdc_dir *.xdc]
set_property include_dirs [list $rtl_dir] [current_fileset]
update_compile_order -fileset sources_1

set bd_name kv260_sigv_bd
create_bd_design $bd_name

set zynq_ip [require_ip "xilinx.com:ip:zynq_ultra_ps_e:*"]
set smartconnect_ip [require_ip "xilinx.com:ip:smartconnect:*"]
set proc_sys_reset_ip [require_ip "xilinx.com:ip:proc_sys_reset:*"]
set xlconstant_ip [require_ip "xilinx.com:ip:xlconstant:*"]
set axi_bram_ctrl_ip [require_ip "xilinx.com:ip:axi_bram_ctrl:*"]
set blk_mem_gen_ip [require_ip "xilinx.com:ip:blk_mem_gen:*"]
create_bd_cell -type ip -vlnv $zynq_ip zynq_ultra_ps_e_0
if {$board_part ne ""} {
    apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
        -config {apply_board_preset "1"} \
        [get_bd_cells zynq_ultra_ps_e_0]
}
set_property -dict [list \
    CONFIG.PSU__USE__CLK {1} \
    CONFIG.PSU__USE__CLK0 {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} \
    CONFIG.PSU__USE__IRQ0 {1} \
    CONFIG.PSU__USE__M_AXI_GP1 {0} \
    CONFIG.PSU__UART0__PERIPHERAL__ENABLE {0} \
    CONFIG.PSU__UART1__PERIPHERAL__ENABLE {1} \
    CONFIG.PSU__UART1__PERIPHERAL__IO {MIO 36 .. 37} \
] [get_bd_cells zynq_ultra_ps_e_0]

create_bd_cell -type module -reference kv260_sigv_top sigv_pl_0
set_property -dict [list CONFIG.BRINGUP_MODE $bringup_mode] [get_bd_cells sigv_pl_0]
create_bd_cell -type ip -vlnv $smartconnect_ip axi_smc
create_bd_cell -type ip -vlnv $proc_sys_reset_ip rst_pl
create_bd_cell -type ip -vlnv $xlconstant_ip const_one
create_bd_cell -type ip -vlnv $xlconstant_ip const_zero
create_bd_cell -type ip -vlnv $axi_bram_ctrl_ip axi_bram_ctrl_message
create_bd_cell -type ip -vlnv $axi_bram_ctrl_ip axi_bram_ctrl_job
create_bd_cell -type ip -vlnv $blk_mem_gen_ip blk_mem_gen_message
create_bd_cell -type ip -vlnv $blk_mem_gen_ip blk_mem_gen_job

set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {3}] [get_bd_cells axi_smc]
set_property -dict [list CONFIG.C_EXT_RESET_HIGH {0} CONFIG.C_AUX_RESET_HIGH {0}] [get_bd_cells rst_pl]
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] [get_bd_cells const_one]
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] [get_bd_cells const_zero]
set_property -dict [list CONFIG.DATA_WIDTH {32} CONFIG.SINGLE_PORT_BRAM {1}] [get_bd_cells axi_bram_ctrl_message]
set_property -dict [list CONFIG.DATA_WIDTH {32} CONFIG.SINGLE_PORT_BRAM {1}] [get_bd_cells axi_bram_ctrl_job]

set_property -dict [list \
    CONFIG.Memory_Type {True_Dual_Port_RAM} \
    CONFIG.Write_Width_A {32} \
    CONFIG.Read_Width_A {32} \
    CONFIG.Write_Width_B {32} \
    CONFIG.Read_Width_B {32} \
    CONFIG.Write_Depth_A {1024} \
    CONFIG.Register_PortB_Output_of_Memory_Primitives {false} \
] [get_bd_cells blk_mem_gen_message]

set_property -dict [list \
    CONFIG.Memory_Type {True_Dual_Port_RAM} \
    CONFIG.Write_Width_A {32} \
    CONFIG.Read_Width_A {32} \
    CONFIG.Write_Width_B {32} \
    CONFIG.Read_Width_B {32} \
    CONFIG.Write_Depth_A {8192} \
    CONFIG.Register_PortB_Output_of_Memory_Primitives {false} \
] [get_bd_cells blk_mem_gen_job]

connect_bd_intf_net [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_FPD] [get_bd_intf_pins axi_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M00_AXI] [get_bd_intf_pins sigv_pl_0/S_AXI_CTRL]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M01_AXI] [get_bd_intf_pins axi_bram_ctrl_message/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M02_AXI] [get_bd_intf_pins axi_bram_ctrl_job/S_AXI]

connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins axi_smc/aclk]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins sigv_pl_0/ap_clk]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins axi_bram_ctrl_message/s_axi_aclk]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins axi_bram_ctrl_job/s_axi_aclk]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins rst_pl/slowest_sync_clk]

connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] [get_bd_pins rst_pl/ext_reset_in]
connect_bd_net [get_bd_pins const_one/dout] [get_bd_pins rst_pl/aux_reset_in]
connect_bd_net [get_bd_pins const_one/dout] [get_bd_pins rst_pl/dcm_locked]
connect_bd_net [get_bd_pins const_zero/dout] [get_bd_pins rst_pl/mb_debug_sys_rst]
connect_bd_net [get_bd_pins rst_pl/peripheral_aresetn] [get_bd_pins axi_smc/aresetn]
connect_bd_net [get_bd_pins rst_pl/peripheral_aresetn] [get_bd_pins sigv_pl_0/ap_rst_n]
connect_bd_net [get_bd_pins rst_pl/peripheral_aresetn] [get_bd_pins axi_bram_ctrl_message/s_axi_aresetn]
connect_bd_net [get_bd_pins rst_pl/peripheral_aresetn] [get_bd_pins axi_bram_ctrl_job/s_axi_aresetn]

connect_bd_intf_net [get_bd_intf_pins axi_bram_ctrl_message/BRAM_PORTA] [get_bd_intf_pins blk_mem_gen_message/BRAM_PORTA]
connect_bd_intf_net [get_bd_intf_pins axi_bram_ctrl_job/BRAM_PORTA] [get_bd_intf_pins blk_mem_gen_job/BRAM_PORTA]

connect_bd_net [get_bd_pins sigv_pl_0/message_bram_clk] [get_bd_pins blk_mem_gen_message/clkb]
connect_bd_net [get_bd_pins sigv_pl_0/message_bram_rst] [get_bd_pins blk_mem_gen_message/rstb]
connect_bd_net [get_bd_pins sigv_pl_0/message_bram_en] [get_bd_pins blk_mem_gen_message/enb]
connect_if_present sigv_pl_0/message_bram_regce blk_mem_gen_message/regceb
connect_bd_net [get_bd_pins sigv_pl_0/message_bram_we] [get_bd_pins blk_mem_gen_message/web]
connect_bd_net [get_bd_pins sigv_pl_0/message_bram_addr] [get_bd_pins blk_mem_gen_message/addrb]
connect_bd_net [get_bd_pins sigv_pl_0/message_bram_din] [get_bd_pins blk_mem_gen_message/dinb]
connect_bd_net [get_bd_pins sigv_pl_0/message_bram_dout] [get_bd_pins blk_mem_gen_message/doutb]

connect_bd_net [get_bd_pins sigv_pl_0/job_bram_clk] [get_bd_pins blk_mem_gen_job/clkb]
connect_bd_net [get_bd_pins sigv_pl_0/job_bram_rst] [get_bd_pins blk_mem_gen_job/rstb]
connect_bd_net [get_bd_pins sigv_pl_0/job_bram_en] [get_bd_pins blk_mem_gen_job/enb]
connect_if_present sigv_pl_0/job_bram_regce blk_mem_gen_job/regceb
connect_bd_net [get_bd_pins sigv_pl_0/job_bram_we] [get_bd_pins blk_mem_gen_job/web]
connect_bd_net [get_bd_pins sigv_pl_0/job_bram_addr] [get_bd_pins blk_mem_gen_job/addrb]
connect_bd_net [get_bd_pins sigv_pl_0/job_bram_din] [get_bd_pins blk_mem_gen_job/dinb]
connect_bd_net [get_bd_pins sigv_pl_0/job_bram_dout] [get_bd_pins blk_mem_gen_job/doutb]

connect_if_present zynq_ultra_ps_e_0/pl_clk0 zynq_ultra_ps_e_0/maxihpm0_fpd_aclk
connect_if_present sigv_pl_0/irq zynq_ultra_ps_e_0/pl_ps_irq0

set clk_wiz_cells [get_bd_cells -quiet clk_wiz*]
if {[llength $clk_wiz_cells] != 0} {
    error "unexpected clock wizard cells in single-clock design: $clk_wiz_cells"
}

assign_bd_address
set master_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data]
set_addr_segment $master_space "axi_bram_ctrl_message" 0xA0010000 0x00010000
set_addr_segment $master_space "axi_bram_ctrl_job" 0xA0020000 0x00010000
set_addr_segment $master_space "sigv_pl_0" 0xA0000000 0x00010000

regenerate_bd_layout
validate_bd_design
save_bd_design

set bd_file [get_files [file join $project_dir $project_name.srcs sources_1 bd $bd_name $bd_name.bd]]
make_wrapper -files $bd_file -top
add_files -norecurse [file join $project_dir $project_name.gen sources_1 bd $bd_name hdl ${bd_name}_wrapper.v]
set_property top ${bd_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1
