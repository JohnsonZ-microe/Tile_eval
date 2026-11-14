"""Behavioral Python probes; not evidence of HDL execution."""
import unittest
from pathlib import Path
from types import SimpleNamespace
from collections import deque

from probe_reference import audit_rom, sigmoid_decimal, round_fp32_positive
from fractions import Fraction
from tile_reference import TileRef
from tile_cycles import TileCycleModel, _SimState
from vectors import scenario_matrix


class AuditArithmeticTests(unittest.TestCase):
    def test_actual_run_phase_all_ones_and_weight_change(self):
        activation = sum(0x38 << (8 * element) for element in range(32))
        for fmt, code, width, scale in ((0, 2, 4, 127), (1, 0x38, 8, 127),
                                       (2, 0x38, 8, 0x3f800000),
                                       (3, 0x38, 8, 0x3f80), (4, 1, 4, 0x3f80),
                                       (5, 0x3f80, 16, 0)):
            ref = TileRef({}, fmt)
            cols = ref.ncols
            scale_word = sum(scale << (ref.wbits * column) for column in range(cols))
            word = sum(code << (width * element) for element in range(cols * 32))
            ref.image.update({index: scale_word for index in range(ref.sw)})
            ref.image[ref.sw] = word
            ref.run_phase(0, lambda lane, kb: activation,
                          lambda lane, kb: 127, 0b1010, 1, 1, cols)
            for column in range(cols):
                self.assertEqual(ref.rf.rf[column], [0, 0x42000000, 0, 0x42000000])
            ref.image[ref.sw] = 0
            ref.run_phase(0, lambda lane, kb: activation,
                          lambda lane, kb: 127, 0b1010, 1, 1, cols)
            for column in range(cols):
                self.assertEqual(ref.rf.rf[column], [0, 0, 0, 0])

    def test_independent_rounding(self):
        self.assertEqual(round_fp32_positive(Fraction(1, 2**150)), 0)
        self.assertEqual(round_fp32_positive(Fraction(3, 2**150)), 2)
        self.assertEqual(round_fp32_positive(Fraction(1)), 0x3f800000)
        self.assertEqual(sigmoid_decimal(0xc2ca), 10)

    def test_rom_exhaustive_independent(self):
        failures = audit_rom(Path(__file__).resolve().parents[1] /
                             'rtl/pe4_sigmoid_rom.hex')
        self.assertEqual(failures, [], str(failures[:8]))

    def test_suite_matrix(self):
        self.assertEqual(scenario_matrix('full'), (tuple(range(6)), (1, 2, 3, 4)))
        self.assertEqual(scenario_matrix('legacy'), (tuple(range(6)), (1, 4)))
        self.assertEqual(scenario_matrix('smoke'), ((0,), (1,)))


class CycleProbes(unittest.TestCase):
    def test_returned_words_do_not_use_inflight_credit(self):
        model = TileCycleModel()
        state = _SimState(6)
        state.issued = 3
        state.rq = deque([dict(ret=1), dict(ret=2), dict(ret=3)])
        phase = SimpleNamespace(wi=1, words=[{}, dict(kind='W', g=1, kb=0)],
                                timing=SimpleNamespace(latch=0, first_issue=None,
                                last_issue=None, words=0, matrix_words=0))
        model._issue([phase], state, 4)
        self.assertEqual(state.issued, 4)
        self.assertEqual(len(state.rq), 4)
        model._issue([SimpleNamespace(wi=1, words=[{}, dict(kind='W', g=1, kb=0)],
                      timing=phase.timing)], state, 5)
        self.assertEqual(len(state.rq), 4)

    def test_y_ready_after_last_row_completion(self):
        model = TileCycleModel(n_tok=4)
        state = _SimState(6)
        phase = SimpleNamespace(timing=SimpleNamespace(sync1=None), retired=False)
        model._arm_dcommit(phase, state, 7)
        # y_q entries = publication + 1 (NBA edge -> consumable on next edge);
        # yacc_free = last publication edge (no +1, commit_busy drops at NBA)
        expected = [7 + model.lat['YACC_WARM'] + (lane+1)*10*model.lat['YACC_ROW'] + 1
                    for lane in range(4)]
        self.assertEqual([entry[0] for entry in state.y_q], expected)
        self.assertEqual(expected[-1] - 1, state.yacc_free)

    def test_model_timeout_is_failure(self):
        model = TileCycleModel()
        model.max_cycles = 4
        model.lat['UP_CREDITS'] = 0
        with self.assertRaisesRegex(RuntimeError, 'did not complete'):
            model.run_pass()


if __name__ == '__main__':
    unittest.main()
