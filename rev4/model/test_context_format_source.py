import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class ContextFormatSourceTests(unittest.TestCase):
    def test_reserved_formats_have_explicit_gate(self):
        source = (ROOT/'rtl/pe4_sched.sv').read_text(encoding='utf-8')
        resolver = source.split('function automatic classp_t resolve_class', 1)[1].split('endfunction', 1)[0]
        self.assertIn("r.legal = (r.fmt <= 3'd5)", resolver)

    def test_control_probe_uses_external_inputs_and_requires_rejection(self):
        source = (ROOT/'tb/tb_control_v4.sv').read_text(encoding='utf-8')
        probe = source.split('task automatic check_context_formats;', 1)[1].split('endtask', 1)[0]
        self.assertNotIn('force ', probe)
        for text in ('format_id < 8', 'format_id >= 6', 'dn_valid = 1; dn_sideband = 0;',
                     'reserved format started work', 'reserved format CMD_ILLEGAL missing', 'reserved format W1C failed'):
            self.assertIn(text, probe)
        self.assertIn('context_cases != 8 || rejected_commands != 2', source)

    def test_busy_mode_words_guarded_and_event_has_active_owner(self):
        rtl = (ROOT/'rtl/pe4_sched.sv').read_text(encoding='utf-8')
        self.assertIn("if (reg_wr_addr == 12'h140 && !run_active_any)", rtl)
        self.assertIn("if (reg_wr_addr == 12'h1c0 && !run_active_any)", rtl)
        self.assertIn("if (reg_wr_valid && run_active_any && reg_wr_addr[1:0] == 2'b00 &&", rtl)
        self.assertEqual(rtl.count('ev_ctxbusy <= 1;'), 1)
        bench = (ROOT/'tb/tb_control_v4.sv').read_text(encoding='utf-8')
        probe = bench.split('task automatic check_context_busy;', 1)[1].split('endtask', 1)[0]
        self.assertNotIn('force ', probe)
        for text in ('waiting CMD', 'index < 4', 'busy CTX write modified storage',
                     'CTX_BUSY missing or active CMD disturbed', 'CTX_BUSY W1C failed',
                     'reset did not cancel CMD'):
            self.assertIn(text, probe)

    def test_unaligned_write_cannot_alias_context_word(self):
        rtl = (ROOT/'rtl/pe4_sched.sv').read_text(encoding='utf-8')
        self.assertIn("if (reg_wr_valid && reg_wr_addr[1:0] == 2'b00) begin", rtl)
        self.assertIn('end else if (reg_wr_valid) begin\n                ev_regaddr <= 1;', rtl)
        bench = (ROOT/'tb/tb_control_v4.sv').read_text(encoding='utf-8')
        probe = bench.split('task automatic check_unaligned_context;', 1)[1].split('endtask', 1)[0]
        for text in ('bank < 2', 'offset < 4', 'unaligned CTX write aliased a word',
                     'unaligned CTX write REG_ADDR missing', 'REG_ADDR W1C failed'):
            self.assertIn(text, probe)
        self.assertIn('unaligned_cases != 6', bench)


if __name__ == '__main__':
    unittest.main()
