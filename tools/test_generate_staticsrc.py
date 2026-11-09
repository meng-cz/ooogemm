"""Focused generator and six-configuration differential SRAM tests.

Run: python3 -m unittest discover -s tools -p 'test_generate_staticsrc.py' -v
"""
from collections import Counter
import csv
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
MODULE = importlib.util.spec_from_file_location("generate_staticsrc", HERE / "generate_staticsrc.py")
g = importlib.util.module_from_spec(MODULE)
sys.modules[MODULE.name] = g
MODULE.loader.exec_module(g)


class TokenAndIdentityTest(unittest.TestCase):
    def test_parameter_groups_nested_expressions_and_comments(self):
        text = """module sample #(
            // parameter fake = 99; comments must not become declarations.
            parameter int A = 2, B = f(3, 4),
            parameter bit C = 1'b0
        )(input logic [A-1:0] x); endmodule"""
        unit = g.Unit("sample", g.ROOT / "src/fixture.sv", text)
        self.assertEqual(unit.parameters, [("A", "int"), ("B", "int"), ("C", "bit")])

    def test_typed_identity_ignores_literal_spelling_and_parameter_order(self):
        typ = {"kind": "basicdtype", "name": "int", "range": [31, 0], "signed": True}
        a = {"X": {"value": 8, "type": typ, "literal": "32'sh8"},
             "Y": {"value": 2, "type": typ, "literal": "32'sh2"}}
        b = {"Y": a["Y"], "X": dict(a["X"], literal="32'sd8")}
        self.assertEqual(g.identity("leaf", a), g.identity("leaf", b))
        self.assertNotEqual(g.identity("other_leaf", a), g.identity("leaf", a))
        self.assertNotEqual(g.identity("leaf", a), g.identity("leaf", dict(a, X=dict(a["X"], value=9))))

    def test_signed_constant_and_xml_name_decoding(self):
        self.assertEqual(g.constant("32'shffffffff"), -1)
        self.assertEqual(g.constant("32'hffffffff"), 4294967295)
        self.assertEqual(g.xml_name("pe___05FL4_P32"), "pe__L4_P32")
        self.assertEqual(g.normalized_scope("gen_cost___05Fstatic_3"), "gen_cost[3]")

    def test_invalid_verilator_diagnostic_xml_reference(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "diagnostic.xml"
            path.write_text('<test name="file&#30;name&#10;next"/>')
            self.assertEqual(g.parse_xml(path).get("name"), "file&#30;name\nnext")


class ElaborationAndSimulationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tool = g.Verilator()
        g.CACHE.mkdir(parents=True, exist_ok=True)

    def test_actual_elaboration_dedup_generate_pruning_packages_and_connections(self):
        with tempfile.TemporaryDirectory(prefix="fixture-", dir=g.CACHE) as tmp:
            tmp = Path(tmp)
            source = tmp / "fixture.sv"
            source.write_text("""
package fixture_pkg; typedef logic [7:0] byte_t; endpackage
module leaf #(parameter int WIDTH=8)(input logic [WIDTH-1:0] a, output logic [WIDTH-1:0] y);
  assign y = a;
endmodule
module other_leaf #(parameter int WIDTH=1)(); endmodule
module parent #(parameter int COUNT=3)(input fixture_pkg::byte_t a);
  for(genvar i=1; i<=COUNT; i++) begin : gen_cost
    leaf #(.WIDTH(i)) u(.a(a[i-1:0]), .y());
  end
  if (COUNT == 0) begin : inactive
    leaf #(.WIDTH(99)) dead(.a('0),.y());
  end
endmodule
module fixture_top(input fixture_pkg::byte_t a);
  parent implicit_default(.a);
  parent #(.COUNT(1+2)) explicit_default(.a);
  other_leaf #(.WIDTH(1)) separate();
endmodule
""")
            units = g.load_units([source])
            specs = g.extract_specs(self.tool.elaborate("fixture_top", [source]), units)
            names = {k: s.name for k, s in specs.items()}
            parents = [s for s in specs.values() if s.unit.name == "parent"]
            self.assertEqual(len(parents), 1)
            self.assertEqual(sorted(s.parameters["WIDTH"]["value"] for s in specs.values()
                                    if s.unit.name == "leaf"), [1, 2, 3])
            parent = parents[0]
            rendered = g.render_spec(parent, names)
            self.assertIn("gen_cost__static_1", rendered)
            self.assertIn("gen_cost__static_3", rendered)
            self.assertIn("Inactive instance", rendered)
            self.assertNotIn("#(", rendered)
            generated = tmp / "fixed"
            generated.mkdir()
            package = generated / "fixed_package.sv"
            package.write_text(units["fixture_pkg"].text)
            files = [package]
            for spec in specs.values():
                path = generated / (spec.name + ".sv")
                path.write_text(g.render_spec(spec, names))
                files.append(path)
            root = self.tool.elaborate("fixture_top", files)
            modules = root.findall("./netlist/module")
            self.assertEqual(len(modules), len(specs))
            self.assertTrue(all(not any(v.get("param") == "true" for v in m.findall("var")) for m in modules))
            top = specs[g.identity("fixture_top", {})]
            self.assertEqual(top.children[parent.key], 2)
            # Exercise the same complete port/connection validator as --check.
            closure = [p.relative_to(generated).as_posix() for p in files]
            g.validate(self.tool, generated, specs, names, {s.name: closure for s in specs.values()}, ["fixture_top"])

    def test_inventory_counts_and_six_sram_configurations(self):
        manifest = json.loads((g.OUTPUT / "manifest.json").read_text())
        with (g.OUTPUT / "sram_inventory.csv").open() as source:
            rows = list(csv.DictReader(source))
        self.assertEqual({(r["kind"], int(r["depth"]), int(r["width"])) for r in rows}, {
            ("sram1r1w", 8, 256), ("sram1r1w", 16, 256), ("sram1r1w", 32, 256),
            ("sram2r1w", 8, 50), ("sram2r1w", 32, 50), ("sram2r1w", 128, 50)})
        for top in manifest["tops"]:
            counts = {kind: sum(int(r[top + "_instances"]) for r in rows if r["kind"] == kind)
                      for kind in ("sram1r1w", "sram2r1w")}
            side = 64 if "L1W64" in top else 32 if "L4W32" in top else 16
            self.assertEqual(counts["sram2r1w"], side * side)
            self.assertEqual(counts["sram1r1w"], 2 * side if top.endswith("_full") else 0)

    def test_all_sram_variants_match_original_and_read_first(self):
        manifest = json.loads((g.OUTPUT / "manifest.json").read_text())
        variants = [m for m in manifest["modules"] if m["original_module"] in ("sram1r1w", "sram2r1w")]
        with tempfile.TemporaryDirectory(prefix="sram-sim-", dir=g.CACHE) as tmp:
            tmp = Path(tmp)
            blocks = []
            for index, spec in enumerate(variants):
                depth = spec["parameters"]["SIZE"]["value"]
                width = spec["parameters"]["WIDTH"]["value"]
                aw = (depth - 1).bit_length()
                two = spec["original_module"] == "sram2r1w"
                blocks.append(f"""begin : pair{index}
  logic wen=0, ren=0;
  logic [{aw-1}:0] wa=0, ra=0, rb=0;
  logic [{width-1}:0] wd=0, orig0, fixed0, orig1, fixed1;
""")
                if two:
                    ports = ".clk(clk),.wr_en_i(wen),.wr_addr_i(wa),.wr_data_i(wd),.rd0_en_i(ren),.rd0_addr_i(ra),.rd1_en_i(ren),.rd1_addr_i(rb)"
                    out0 = ".rd0_data_o(orig0),.rd1_data_o(orig1)"
                    out1 = ".rd0_data_o(fixed0),.rd1_data_o(fixed1)"
                else:
                    ports = ".clk(clk),.wr_en_i(wen),.wr_addr_i(wa),.wr_data_i(wd),.rd_en_i(ren),.rd_addr_i(ra)"
                    out0, out1 = ".rd_data_o(orig0)", ".rd_data_o(fixed0)"
                blocks.append(f"{spec['original_module']} #(.SIZE({depth}),.WIDTH({width})) original({ports},{out0});\n")
                blocks.append(f"{spec['name']} fixed_instance({ports},{out1});\n")
                check1 = "if (orig1 !== fixed1) $fatal(1, \"second read port mismatch\");" if two else ""
                blocks.append(f"""
  initial begin
    // Initialize every word before reading an unreset memory.
    for (int address=0; address<{depth}; address++) begin
      @(negedge clk); wen=1; wa={aw}'(address); wd={width}'(address+1);
    end
    @(negedge clk); wen=0; ren=1; ra=0; rb={aw}'({depth-1});
    @(posedge clk); #1;
    if (orig0 !== {width}'(1) || fixed0 !== orig0) $fatal(1,"registered read mismatch");
    {check1}
    // Same-address read/write must return the old word, then the new word.
    @(negedge clk); wen=1; wa=0; wd='1; ra=0; rb=0;
    @(posedge clk); #1;
    if (orig0 !== {width}'(1) || fixed0 !== orig0) $fatal(1,"READ_FIRST mismatch");
    {check1}
    @(negedge clk); wen=0;
    @(posedge clk); #1;
    if (orig0 !== {{{width}{{1'b1}}}} || fixed0 !== orig0) $fatal(1,"write/readback mismatch");
    {check1}
    // Disabled reads retain the previous registered value.
    @(negedge clk); ren=0; ra=1; rb=1;
    repeat(2) @(posedge clk);
    #1;
    if (orig0 !== {{{width}{{1'b1}}}} || fixed0 !== orig0) $fatal(1,"read enable mismatch");
    {check1}
    done[{index}]=1;
  end
end
""")
            bench = tmp / "sram_compare.sv"
            bench.write_text("module sram_compare;\nlogic clk=0; always #5 clk=~clk;\n"
                             "logic [5:0] done=0;\ngenerate\n" + "".join(blocks) +
                             "endgenerate\ninitial begin wait (&done); $display(\"SRAM_COMPARE_PASS: six variants\"); $finish; end\n"
                             "initial begin #100000; $fatal(1,\"timeout\"); end\nendmodule\n")
            command = [self.tool.executable, "--binary", "--timing", "-Wno-fatal", "--build-jobs", "2",
                       "--top-module", "sram_compare", "--Mdir", str(tmp / "obj"),
                       str(g.ROOT / "src/sram/sram1r1w.sv"), str(g.ROOT / "src/sram/sram2r1w.sv"),
                       *[str(g.OUTPUT / v["file"]) for v in variants], str(bench)]
            build = subprocess.run(command, capture_output=True, text=True, timeout=90)
            self.assertEqual(build.returncode, 0, build.stdout[-2500:] + build.stderr[-2500:])
            run = subprocess.run([str(tmp / "obj/Vsram_compare")], capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("SRAM_COMPARE_PASS: six variants", run.stdout)


if __name__ == "__main__":
    unittest.main()
