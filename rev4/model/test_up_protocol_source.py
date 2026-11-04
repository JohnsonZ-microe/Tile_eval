import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class UpProtocolSourceTests(unittest.TestCase):
    def test_replay_waits_for_phase_commit_and_each_drain(self):
        text = (ROOT / 'tb/tb_tile_v4.sv').read_text(encoding='utf-8')
        replay = text.split('begin : replay', 1)[1]
        self.assertIn('wait_phase(phase_requests);', replay)
        self.assertIn('wait_y_ready(pay[17], pay[16:11]);', replay)
        self.assertIn('if (is_drain) wait_y_packet(drain_target);', replay)
        for name in ('wait_phase', 'wait_y_ready', 'wait_y_packet'):
            task = text.split('task automatic ' + name, 1)[1].split('endtask', 1)[0]
            self.assertIn('$fatal(1,', task)
            self.assertIn('@(negedge clk)', task)
        self.assertIn('dut.yacc_u.vbit[bank][slot_id]', text)

    def test_ctrl_is_not_reserved(self):
        text = (ROOT / 'rtl/pe4_bus.sv').read_text(encoding='utf-8')
        self.assertIn("dn_valid && (dtype == 3'd6 || dtype == 3'd7)", text)

    def test_send_requires_selected_source_valid(self):
        text = (ROOT / 'rtl/pe4_bus.sv').read_text(encoding='utf-8')
        fire = text.split('assign beat_fire =', 1)[1].split(';', 1)[0]
        for number, name in enumerate(('hup_valid', 'ysrc_valid', 'st_valid'), 1):
            self.assertIn("grant == 2'd%d && %s" % (number, name), fire)

    def test_sideband_uses_same_beat_metadata(self):
        text = (ROOT / 'rtl/pe4_bus.sv').read_text(encoding='utf-8')
        assignments = re.findall(r'up_sideband <= (.*?);', text, re.S)
        self.assertEqual(len(assignments), 4)
        self.assertNotRegex(' '.join(assignments), r'\w+_q\b')
        self.assertIn('st_tag, st_src[6:0]', assignments[-1])

    def test_drain_holds_until_valid_ready_and_clears_valid(self):
        text = (ROOT / 'rtl/pe4_yacc.sv').read_text(encoding='utf-8')
        for state in ('DSEND', 'DV0'):
            block = text.split(state + ': begin', 1)[1]
            self.assertIn('if (!yb_valid) begin', block)
            self.assertRegex(block, r'if \(yb_valid && yb_ready\) begin\s+yb_valid <= 0;')


if __name__ == '__main__':
    unittest.main()
