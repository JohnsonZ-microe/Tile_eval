import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def source(relative):
    text = (ROOT / relative).read_text(encoding='utf-8')
    return re.sub(r'//[^\n]*|/\*.*?\*/', '', text, flags=re.S)


def scheduler_connections(text):
    instances = re.findall(r'\bsched_u\s*\((.*?)\)\s*;', text, re.S)
    if len(instances) != 1:
        raise ValueError('Expected exactly one sched_u instance port list')
    return re.findall(r'\.([a-zA-Z_]\w*)\s*\(', instances[0])


class Vcs90222SourceTests(unittest.TestCase):
    def test_tb_load_uses_connected_signals(self):
        text = source('tb/tb_tile_v4.sv')
        self.assertNotRegex(text, r'dut\.sim_(?:load|addr|data)\s*=')
        for port in ('sim_load', 'sim_addr', 'sim_data'):
            self.assertIn('.{0}({0}_r)'.format(port), text)
        self.assertRegex(text, r'begin\s+@\(negedge clk\);\s+sim_load_r =')
        self.assertRegex(text, r'@\(negedge clk\);\s+sim_load_r = 1\x27b0;')
        self.assertRegex(text, r'@\(negedge clk\);\s+rst_n = 1;')

    def test_sram_uses_elaboration_time_latency_branch(self):
        text = source('rtl/pe4_sram.sv')
        self.assertRegex(text, r'if \(LAT == 2\) begin : lat2\s+always_ff')
        self.assertRegex(text, r'end else begin : lat3plus\s+logic')
        first_branch = text.split('begin : lat2', 1)[1].split('begin : lat3plus', 1)[0]
        self.assertNotIn('LAT-3', first_branch)

    def test_quant_tag_width_matches_scheduler(self):
        quant = source('rtl/pe4_quant.sv')
        scheduler = source('rtl/pe4_sched.sv')
        for name in ('in_tag', 'out_tag', 'tag_q'):
            self.assertRegex(quant, r'logic\s+\[10:0\]\s+' + name + r'\b')
        for name in ('quant_tag', 'quant_otag'):
            self.assertRegex(scheduler, r'(?:wire|logic)\s+\[10:0\]\s+' + name + r'\b')

    def test_scheduler_ports_are_all_explicit(self):
        scheduler = source('rtl/pe4_sched.sv').split(');', 1)[0]
        ports = []
        for declaration in re.split(r'\b(?:input|output)\s+logic\s+', scheduler)[1:]:
            declaration = re.sub(r'\[[^]]+\]', '', declaration)
            ports.extend(re.findall(r'\b[a-zA-Z_]\w*\b', declaration))
        connected = scheduler_connections(source('rtl/tile_ffn_v4.sv'))
        self.assertEqual(set(ports), set(connected))
        self.assertEqual(len(connected), len(set(connected)))

    def test_scheduler_instance_parser(self):
        for prefix in ('pe4_sched', 'pe4_sched #(.TILE_ID(SRC_ID[5:0]))'):
            with self.subTest(prefix=prefix):
                text = prefix + ' sched_u (\n.clk(clk), .rst_n(rst_n)\n);'
                self.assertEqual(scheduler_connections(text), ['clk', 'rst_n'])
        for text in ('', 'pe4_sched sched_u (.clk(clk))',
                     'pe4_sched sched_u (); pe4_sched sched_u ();'):
            with self.subTest(text=text):
                with self.assertRaises(ValueError):
                    scheduler_connections(text)


if __name__ == '__main__':
    unittest.main()
