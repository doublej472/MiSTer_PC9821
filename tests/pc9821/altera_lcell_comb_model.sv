// The Altera `*_lcell_comb` atoms generic_lcell_comb (sys/pll_cfg/
// altera_pll_reconfig_core.v:2112) selects between, as plain simulation models: a 6-input LUT
// whose `lut_mask` is indexed {dataf, datae, datad, datac, datab, dataa}, the atom's convention.
// The design instantiates generic_lcell_comb with its default family "Cyclone V", so only
// cyclonev_lcell_comb is elaborated; the other three names exist because Verilator resolves the
// defparams of generic_lcell_comb's unselected generate arms too.
//
// This file is NOT part of the design and must never be added to a build list. Only
// tb_pc9821_pll_cfg_lockstep (which elaborates the real reconfiguration cores) uses it.
module cyclonev_lcell_comb #(
	parameter [63:0] lut_mask   = 64'hFFFF_FFFF_FFFF_FFFF,
	parameter        dont_touch = "off"
) (
	input  wire dataa,
	input  wire datab,
	input  wire datac,
	input  wire datad,
	input  wire datae,
	input  wire dataf,
	output wire combout
);
	assign combout = lut_mask[{dataf, datae, datad, datac, datab, dataa}];
endmodule

module arriav_lcell_comb #(
	parameter [63:0] lut_mask   = 64'hFFFF_FFFF_FFFF_FFFF,
	parameter        dont_touch = "off"
) (
	input  wire dataa,
	input  wire datab,
	input  wire datac,
	input  wire datad,
	input  wire datae,
	input  wire dataf,
	output wire combout
);
	cyclonev_lcell_comb #(.lut_mask(lut_mask), .dont_touch(dont_touch)) atom (
		.dataa(dataa), .datab(datab), .datac(datac), .datad(datad), .datae(datae),
		.dataf(dataf), .combout(combout));
endmodule

module arriavgz_lcell_comb #(
	parameter [63:0] lut_mask   = 64'hFFFF_FFFF_FFFF_FFFF,
	parameter        dont_touch = "off"
) (
	input  wire dataa,
	input  wire datab,
	input  wire datac,
	input  wire datad,
	input  wire datae,
	input  wire dataf,
	output wire combout
);
	cyclonev_lcell_comb #(.lut_mask(lut_mask), .dont_touch(dont_touch)) atom (
		.dataa(dataa), .datab(datab), .datac(datac), .datad(datad), .datae(datae),
		.dataf(dataf), .combout(combout));
endmodule

module stratixv_lcell_comb #(
	parameter [63:0] lut_mask   = 64'hFFFF_FFFF_FFFF_FFFF,
	parameter        dont_touch = "off"
) (
	input  wire dataa,
	input  wire datab,
	input  wire datac,
	input  wire datad,
	input  wire datae,
	input  wire dataf,
	output wire combout
);
	cyclonev_lcell_comb #(.lut_mask(lut_mask), .dont_touch(dont_touch)) atom (
		.dataa(dataa), .datab(datab), .datac(datac), .datad(datad), .datae(datae),
		.dataf(dataf), .combout(combout));
endmodule
