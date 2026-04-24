# The Zynq MPSoC block design owns the PS-generated PL clock constraints.
# Keep board-level constraints here only; adding another explicit clock on
# pl_clk0 creates a duplicate clock source and obscures the real timing state.
