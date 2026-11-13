"""Unit tests for the standalone cycle-accurate model (tile_cycles.py)."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from tile_cycles import (LATENCIES, TileCycleModel, analytic_matrix_rate,  # noqa: E402
                         format_params, profile, _Phase, _SimState)


class TestFormatParams(unittest.TestCase):
    def test_fp4(self):
        ncols, sw, period, ng, ngd, guw, dw = format_params(0)
        self.assertEqual((ncols, sw, period, ng, ngd), (8, 1, 1, 9, 10))
        self.assertEqual(guw, 160 * 1 + 160 * 9)     # 1600
        self.assertEqual(dw, 72 + 720)               # 792

    def test_bf16(self):
        ncols, sw, period, ng, ngd, guw, dw = format_params(5)
        self.assertEqual((ncols, sw, period, ng), (2, 0, 1, 36))
        self.assertEqual(guw, 160 * 36)

    def test_fp8f32(self):
        ncols, sw, period, ng, ngd, guw, dw = format_params(2)
        self.assertEqual((ncols, sw, period, ng), (4, 3, 4, 18))
        self.assertEqual(guw, (160 // 4) * 3 + 160 * 18)


class TestSteadyStateRate(unittest.TestCase):
    """The occupancy rule caps the matrix rate at ngroups/REACCEPT."""

    def check(self, fmt, tol=0.03):
        m = TileCycleModel(fmt=fmt, n_tok=4)
        rep = m.run_pass()
        gu = rep.phases[0]
        want = analytic_matrix_rate(fmt)
        self.assertGreater(gu.matrix_words, 0)
        self.assertLess(abs(gu.matrix_rate - want) / want, tol,
                        'fmt=%s got %.4f want %.4f'
                        % (fmt, gu.matrix_rate, want))
        return rep

    def test_all_formats(self):
        for fmt in range(6):
            self.check(fmt)


class TestPhaseSemantics(unittest.TestCase):
    def test_staging_group_waits_for_every_token(self):
        for tokens in range(1,5):
            model = TileCycleModel(n_tok=tokens)
            phase = _Phase(0,'GU',0,tokens,False)
            phase.timing.latch = 0
            state = _SimState(6)
            for lane in range(tokens):
                model._fill([phase],lane+1,state)
                self.assertEqual(phase.xs_popped[0],lane==tokens-1)
            for lane in range(tokens):
                model._fill([phase],tokens+lane+1,state)
                self.assertEqual(phase.x_popped[0],lane==tokens-1)
            self.assertEqual(state.counters['CNT_X_POP'],2*tokens)

    def test_credit_and_queue_stalls_are_distinguished(self):
        for return_cycle, count, expected in ((20, 3, 'rram_inflight'), (1, 4, 'rq_full')):
            model = TileCycleModel()
            phase = _Phase(0, 'GU', 0, 4, False)
            phase.timing.latch = 0
            phase.wi = 1
            state = _SimState(6)
            state.rq.extend(dict(ret=return_cycle) for index in range(count))
            model._issue([phase], state, 10)
            self.assertEqual(state.stalls[expected], 1)
            self.assertEqual(state.stalls['rram_credit'], 1)
            self.assertEqual(state.counters['CNT_RRAM_STALL'], 1)
            self.assertEqual(phase.wi, 1)

    def test_memory_stall_subtotals_conserve_legacy_counter(self):
        for fmt in range(6):
            report = TileCycleModel(fmt=fmt).run_pass()
            self.assertEqual(report.stalls['rram_credit'],
                             report.stalls['rram_inflight']+report.stalls['rq_full'])
            self.assertEqual(report.stalls['rram_credit'],report.counters['CNT_RRAM_STALL'])

    def test_return_fill_must_precede_consume_edge(self):
        for fmt in range(6):
            model = TileCycleModel(fmt=fmt, n_tok=1, bias_en=True)
            model.run_pass()
            returns = {entry['transaction']: entry['cycle'] for entry in model.events
                       if entry['event'] == 'rram_return'}
            consumed = [entry for entry in model.events if entry['event'] == 'rram_consume']
            self.assertEqual(len(consumed), len(returns))
            for entry in consumed:
                self.assertGreater(entry['cycle'], returns[entry['transaction']],
                                   'RQ full is registered on the return edge')

    def test_fp4_gu_duration(self):
        # fp4 GU: 1440 matrix words at 9/36 rate + fill/drain overheads
        rep = TileCycleModel(fmt=0, n_tok=4).run_pass()
        gu = rep.phases[0]
        steady = 1440 / (9.0 / LATENCIES['REACCEPT'])
        self.assertGreater(gu.sync1, steady * 0.9)
        self.assertLess(gu.sync1, steady * 1.5)

    def test_d_waits_h_bank_full(self):
        # a slow H broadcast delays the D matrix stream (h-bank fence)
        fast = TileCycleModel(fmt=0, n_tok=4, h_gap=1).run_pass()
        slow = TileCycleModel(fmt=0, n_tok=4, h_gap=8).run_pass()
        self.assertGreater(slow.phases[1].first_issue,
                           fast.phases[1].first_issue)
        self.assertGreater(slow.counters['CNT_X_STALL'] +
                           slow.stalls.get('operand_h', 0), 0)

    def test_hup_beat_count(self):
        for n_tok in (1, 4):
            rep = TileCycleModel(fmt=0, n_tok=n_tok).run_pass()
            self.assertEqual(
                rep.counters['CNT_GU'], 1)
            self.assertGreater(rep.phases[0].sync1,
                               rep.phases[0].last_commit)

    def test_d_sync1_after_last_commit(self):
        rep = TileCycleModel(fmt=1, n_tok=2).run_pass()
        d = rep.phases[1]
        self.assertGreaterEqual(d.sync1, d.last_commit + 1)

    def test_yacc_duration_in_drain(self):
        n_tok = 4
        rep = TileCycleModel(fmt=0, n_tok=n_tok, drain=True).run_pass()
        rows = n_tok * 10
        self.assertGreaterEqual(
            rep.finish_cycle,
            rep.phases[1].sync1 + LATENCIES['YACC_WARM'] + rows *
            LATENCIES['YACC_ROW'])

    def test_up_credit_period_slows_hup(self):
        fast = TileCycleModel(fmt=0, n_tok=4,
                              up_credit_period=1).run_pass()
        slow = TileCycleModel(fmt=0, n_tok=4,
                              up_credit_period=4).run_pass()
        self.assertGreater(slow.phases[0].sync1, fast.phases[0].sync1)


class TestStepOverlap(unittest.TestCase):
    def test_two_passes_overlap(self):
        rep1 = TileCycleModel(fmt=0, n_tok=4).run_pass()
        rep2 = TileCycleModel(fmt=0, n_tok=4).run_step(2)
        two_serial = 2 * rep1.finish_cycle
        self.assertLess(rep2.finish_cycle, two_serial,
                        'overlap must beat serial execution')
        self.assertEqual(rep2.counters['CNT_GU'], 2)
        self.assertEqual(rep2.counters['CNT_D'], 2)

    def test_bias_adds_two_words_per_phase(self):
        plain = TileCycleModel(fmt=0, n_tok=4, bias_en=False).run_pass()
        biased = TileCycleModel(fmt=0, n_tok=4, bias_en=True).run_pass()
        self.assertEqual(biased.phases[0].words,
                         plain.phases[0].words + 2)
        self.assertEqual(biased.phases[1].words,
                         plain.phases[1].words + 2)

    def test_deterministic(self):
        a = profile(fmt=2, n_tok=3)
        b = profile(fmt=2, n_tok=3)
        self.assertEqual(a, b)


if __name__ == '__main__':
    unittest.main()
