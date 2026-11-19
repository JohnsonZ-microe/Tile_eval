import unittest
from tile_cycles import TileCycleModel, _SimState

class DrainIntervalEvidence(unittest.TestCase):
    def test_baseline_no_collision_accepted_spacing(self):
        m=TileCycleModel();s=_SimState(100);s.y_q.append((0,10));edges=[]
        for t in range(100):
            before=s.credits;m._launcher([],s,t)
            if s.credits<before:edges.append(t)
        self.assertEqual(len(edges),10)
        self.assertEqual([b-a for a,b in zip(edges,edges[1:])],[7]*9)
        # First-beat admission is still an abstraction, not certified by this test.
