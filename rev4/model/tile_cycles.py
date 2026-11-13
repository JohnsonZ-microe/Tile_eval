"""tile_cycles.py - cycle-accurate performance model of Tile FFN revision 4.

Single-file, self-contained (Python 3.6+, standard library only). Copy this
file into your LLM serving/profiling code and import TileCycleModel.

What it models (per-cycle discrete simulation mirroring the rev4 RTL
control path; see rev4/docs/CYCLE_MODEL.md for fidelity/approximations):
  - RRAM read port: fixed latency, 3-entry prefetch credit, 4-entry return
    queue, strictly in-order issue and consume
  - Per-phase word stream: bias tail words first (GU reads words 0-1, D
    rereads 1-2), then the matrix stream (scale groups interleaved with
    weight words, k-block major)
  - The frozen rev3 PE: 36-stage pipeline with the conservative RF-occupancy
    rule (a column group re-accepts no earlier than 36 cycles after its
    previous acceptance) - the dominant throughput limiter
  - Operand gating: X/XS staging fill (writability rules), h-bank full
    fence for D admission, H quantisation latency
  - GU epilogue: ACT (36 column pairs, 1/cycle, 24-cycle latency) and the
    H_UP packet through the credit-limited up launcher (H > Y > STATUS)
  - D epilogue: y commit RMW (n_tok x 10 rows, ~17 cycles/row) overlapping
    the next phase, DRAIN reads with same-bank yield
  - Two CMD slots with cross-phase prefetch overlap

Numbers are integer cycle counts. Deterministic; purely timing-level (no
datapath values are computed).
"""

from collections import deque

__all__ = ['LATENCIES', 'FORMATS', 'TileCycleModel', 'TileReport',
           'PhaseTiming', 'format_params']

LATENCIES = {
    'RRAM_LAT': 3,
    'RRAM_CREDITS': 3,
    'RQ_DEPTH': 4,        # scheduler return queue
    'SRAM_LAT': 2,        # pe4_sram staging/hbuf read latency
    'PE_COMMIT': 35,      # frozen rev3 PE: accept E0 -> out_valid E35
    'REACCEPT': 36,       # same column group re-accept >= E36
    'QUANT': 3,           # pe4_quant pipeline
    'ACT': 24,            # pe4_act latency (bias add + core)
    'ACT_COLS': 36,       # SwiGLU column pairs (H_COLS)
    'YACC_ROW': 17,       # y commit row: mul(4)+add(6)+add(6)+seq
    'YACC_WARM': 1,       # trigger -> first row read
    'DRAIN_ROW': 6,       # drain: read (SRAM_LAT) + build + beat gap
    'UP_CREDITS': 6,      # tile->L1 launcher credits
    'XFIFO': 128,         # x FIFO depth (hub-side credit seed)
    'HUB_TURN': 2,        # H broadcast start after the last H_UP beat
}

FORMATS = {0: 'fp4', 1: 'fp8', 2: 'fp8-f32', 3: 'fp8-bf16', 4: 'int4',
           5: 'bf16'}


def format_params(fmt):
    """(ncols, sw, period, ngroups_gu, ngroups_d, gu_words, d_words)."""
    ncols = 8 if fmt in (0, 4) else (2 if fmt == 5 else 4)
    if fmt == 5:
        sw, period = 0, 1
    elif fmt in (0, 1):
        sw, period = (72 * 8 + 1023) // 1024, 1
    elif fmt == 2:
        sw, period = (72 * 32 + 1023) // 1024, 4
    elif fmt == 3:
        sw, period = (72 * 16 + 1023) // 1024, 4
    else:
        sw, period = (72 * 16 + 1023) // 1024, 1
    ng_gu = (72 + ncols - 1) // ncols
    ng_d = (80 + ncols - 1) // ncols
    gu_words = ((160 + period - 1) // period) * sw + 160 * ng_gu
    d_words = ((72 + period - 1) // period) * sw + 72 * ng_d
    return ncols, sw, period, ng_gu, ng_d, gu_words, d_words


def _phase_words(phase, fmt, bias_en):
    """Word stream of one phase, mirroring pe4_sched iss_step:
    [bias tail words] + per k-block [scale words][weight words per group]."""
    ncols, sw, period, ng_gu, ng_d, _, _ = format_params(fmt)
    ngroups = ng_gu if phase == 'GU' else ng_d
    nkb = 160 if phase == 'GU' else 72
    words = []
    if bias_en:
        b0 = 0 if phase == 'GU' else 1
        for bidx in (b0, b0 + 1):
            words.append(dict(kind='B', kb=0, g=0, bidx=bidx))
    kb = 0
    while kb < nkb:
        if sw and kb % period == 0:
            for swi in range(sw):
                words.append(dict(kind='S', kb=kb, g=0, swi=swi))
        for g in range(ngroups):
            words.append(dict(kind='W', kb=kb, g=g,
                              last=(kb == nkb - 1 and g == ngroups - 1)))
        kb += 1
    return words, nkb, ngroups, ncols


class PhaseTiming(object):
    """Per-phase cycle timeline."""
    __slots__ = ('phase', 'fmt', 'latch', 'first_issue', 'last_issue',
                 'last_consume', 'last_commit', 'sync1', 'words',
                 'matrix_words')

    def __init__(self, phase, fmt):
        self.phase = phase
        self.fmt = fmt
        self.latch = None
        self.first_issue = None
        self.last_issue = None
        self.last_consume = None
        self.last_commit = None
        self.sync1 = None
        self.words = 0
        self.matrix_words = 0

    @property
    def issue_span(self):
        if self.first_issue is None:
            return 0
        return self.last_issue - self.first_issue + 1

    @property
    def matrix_rate(self):
        span = self.last_consume - self.first_issue + 1
        return self.matrix_words / float(span) if span > 0 else 0.0


class TileReport(object):
    """Aggregated timing report."""
    def __init__(self):
        self.phases = []
        self.stalls = {}
        self.counters = {}
        self.total_cycles = 0
        self.finish_cycle = 0

    def summary(self):
        gu = [p.sync1 - p.latch + 1 for p in self.phases
              if p.phase == 'GU' and p.sync1 is not None]
        d = [p.sync1 - p.latch + 1 for p in self.phases
             if p.phase == 'D' and p.sync1 is not None]
        return {
            'phases': len(self.phases),
            'gu_sync1_cycles': gu,
            'd_sync1_cycles': d,
            'finish_cycle': self.finish_cycle,
            'stalls': dict(self.stalls),
            'counters': dict(self.counters),
        }


class _Phase(object):
    """Mutable simulation state of one phase (GU or D)."""
    def __init__(self, index, phase, fmt, n_tok, bias_en):
        self.index = index
        self.phase = phase
        self.timing = PhaseTiming(phase, fmt)
        self.words, self.nkb, self.ngroups, self.ncols = _phase_words(
            phase, fmt, bias_en)
        self.wi = 0                 # next word to issue
        self.bias_valid = not bias_en
        # X/XS staging fill state (GU only)
        self.x_seq = self._x_sequence(n_tok) if phase == 'GU' else []
        self.x_si = 0               # next fill entry
        self.x_popped = [False] * 80
        self.xs_popped = [False] * 3
        # H quantisation state (D only)
        self.h_total = 72 * n_tok
        self.h_done = 0
        self.h_start = None
        # epilogue
        self.act_start = None
        self.hup_beats = (36 * n_tok + 7) // 8
        self.hup_ready = None
        self.pending_last_commit = None
        self.retired = False

    @staticmethod
    def _x_sequence(n_tok):
        seq = []
        for grp in range(3):
            for lane in range(n_tok):
                seq.append(('XS', grp, lane))
            limit = 16 if grp == 2 else 32
            for i in range(limit):
                for lane in range(n_tok):
                    seq.append(('X', 32 * grp + i, lane))
        return seq


class TileCycleModel(object):
    """Cycle-accurate single-tile FFN performance model (rev4 RTL).

    fmt (0..5 or 'fp4'..'bf16'), n_tok (1..4), bias_en,
    up_credit_period (cycles between up credit returns),
    x_gap / h_gap (hub-side flit arrival spacing), drain (model DRAIN).
    """

    def __init__(self, fmt=0, n_tok=4, bias_en=False, up_credit_period=1,
                 x_gap=1, h_gap=1, drain=True):
        if isinstance(fmt, str):
            keys = [k for k, v in FORMATS.items() if v == fmt]
            if not keys:
                raise ValueError('unknown format %r' % (fmt,))
            fmt = keys[0]
        if fmt not in FORMATS or not 1 <= n_tok <= 4:
            raise ValueError('bad fmt or n_tok')
        self.fmt = fmt
        self.n_tok = n_tok
        self.bias_en = bias_en
        self.up_credit_period = max(1, int(up_credit_period))
        self.x_gap = max(1, int(x_gap))
        self.h_gap = max(1, int(h_gap))
        self.drain = drain
        self.lat = dict(LATENCIES)
        self.events = []
        self.accepted = 0

    def _event(self, cycle, event, transaction, value=0):
        self.events.append(dict(cycle=cycle, event=event,
                                transaction=transaction, value=value))

    def run_pass(self):
        """One expert pass: GU then D. Returns TileReport."""
        return self.run_step(1)

    def run_step(self, n_passes):
        """n_passes expert passes in CMD order (overlap emerges)."""
        phases = []
        for _ in range(n_passes):
            phases.append(_Phase(len(phases), 'GU', self.fmt, self.n_tok,
                                 self.bias_en))
            phases.append(_Phase(len(phases), 'D', self.fmt, self.n_tok,
                                 self.bias_en))
        report = TileReport()
        report.phases = [p.timing for p in phases]
        self._simulate(phases, report)
        return report

    def _simulate(self, phases, report):
        self.events = []
        self.accepted = 0
        lat = self.lat
        st = _SimState(lat['UP_CREDITS'])
        max_cycles = getattr(self, 'max_cycles', 400000 * max(1, len(phases)))
        t = 0
        while t <= max_cycles:
            for entry in st.rq:
                if entry['ret'] == t:
                    self._event(t, 'rram_return', entry['sequence'])
            self._credits(st, t)
            self._latch(phases, t)
            self._fill(phases, t, st)
            self._issue(phases, st, t)
            self._consume(phases, st, t)
            self._commit(phases, st, t)
            self._launcher(phases, st, t)
            if (all(p.retired for p in phases) and not st.h_q
                    and not st.y_q and st.cur is None):
                break
            t += 1
        else:
            raise RuntimeError(
                'tile_cycles: simulation did not complete within %d cycles; '
                'this indicates a protocol deadlock, not a valid result'
                % max_cycles)
        report.stalls = st.stalls
        report.counters = st.counters
        report.total_cycles = t
        report.finish_cycle = t
        return report

    def _credits(self, st, t):
        if st.credit_debt > 0:
            st.credit_timer += 1
            if st.credit_timer >= self.up_credit_period:
                st.credits += 1
                st.credit_debt -= 1
                st.credit_timer = 0

    def _latch(self, phases, t):
        for p in phases:
            if p.timing.latch is None:
                if p.index == 0:
                    p.timing.latch = 0
                elif len([q for q in phases[:p.index]
                          if not q.retired]) <= 1:
                    p.timing.latch = t
                else:
                    break

    def _fill(self, phases, t, st):
        lat = self.lat
        for p in phases:
            if p.timing.latch is None or p.timing.latch > t:
                continue
            if p.phase == 'GU' and p.x_si < len(p.x_seq):
                kind, idx, lane = p.x_seq[p.x_si]
                arrival = p.timing.latch + 1 + p.x_si * self.x_gap
                if t >= arrival:
                    issue_kb = (p.words[p.wi]['kb']
                                if p.wi < len(p.words) else p.nkb)
                    if kind == 'XS':
                        ok = idx <= 1 or issue_kb >= 64 * (idx - 1)
                    else:
                        ok = idx <= 1 or issue_kb >= 2 * idx - 2
                    if ok:
                        if kind == 'XS' and lane == self.n_tok-1:
                            p.xs_popped[idx] = True
                        elif kind == 'X' and lane == self.n_tok-1:
                            p.x_popped[idx] = True
                        p.x_si += 1
                        st.counters['CNT_X_POP'] += 1
            if p.phase == 'D' and p.h_start is not None:
                while (p.h_done < p.h_total and
                        t >= p.h_start + p.h_done * self.h_gap):
                    p.h_done += 1
                    st.counters['CNT_H_IN'] += 1
                if (p.h_done >= p.h_total and
                        getattr(p, 'h_ready_cycle', None) is None):
                    p.h_ready_cycle = (p.h_start +
                                       (p.h_total - 1) * self.h_gap +
                                       lat['QUANT'])
        # H broadcast start for each paired D phase (hub turnaround)
        for p in phases:
            if p.phase == 'D' and p.h_start is None and p.index > 0:
                gu = phases[p.index - 1]
                if gu.timing.sync1 is not None:
                    p.h_start = gu.timing.sync1 + self.lat['HUB_TURN']

    def _issue(self, phases, st, t):
        lat = self.lat
        ip = None
        for p in phases:
            if p.wi < len(p.words):
                ip = p
                break
        if ip is None:
            return
        if ip.timing.latch is None or ip.timing.latch > t:
            return
        w = ip.words[ip.wi]
        blocked = None
        if ip.wi == 0 and st.rq:
            blocked = 'rq_empty_gap'
        elif sum(entry['ret'] >= t for entry in st.rq) >= lat['RRAM_CREDITS']:
            blocked = 'rram_inflight'
        elif len(st.rq) >= lat['RQ_DEPTH']:
            blocked = 'rq_full'
        else:
            first_of_kb = ((w['kind'] == 'S' and w['swi'] == 0) or
                           (w['kind'] == 'W' and w['g'] == 0))
            if first_of_kb:
                if ip.phase == 'GU':
                    if not (ip.x_popped[w['kb'] // 2] and
                            ip.xs_popped[w['kb'] // 64]):
                        blocked = 'operand_x'
                else:
                    hr = getattr(ip, 'h_ready_cycle', None)
                    if hr is None or hr > t:
                        blocked = 'operand_h'
        if blocked is not None:
            st.stalls[blocked] += 1
            if blocked == 'operand_x':
                st.counters['CNT_X_STALL'] += 1
            elif blocked in ('rram_inflight', 'rq_full'):
                st.stalls['rram_credit'] += 1
                st.counters['CNT_RRAM_STALL'] += 1
            return
        if ip.timing.first_issue is None:
            ip.timing.first_issue = t
        ip.timing.last_issue = t
        ip.timing.words += 1
        if w['kind'] == 'W':
            ip.timing.matrix_words += 1
        st.rq.append(dict(ret=t + lat['RRAM_LAT'], phase=ip, word=w,
                          sequence=st.issued))
        self._event(t, 'rram_issue', st.issued)
        st.issued += 1
        st.counters['CNT_RRAM_RD'] += 1
        ip.wi += 1

    def _consume(self, phases, st, t):
        lat = self.lat
        if not st.rq or st.rq[0]['ret'] >= t:
            return
        head = st.rq[0]
        hp = head['phase']
        hw = head['word']
        if hw['kind'] in ('B', 'S'):
            self._event(t, 'rram_consume', head['sequence'])
            st.rq.popleft()
            st.consumed += 1
            hp.timing.last_consume = t
            if hw['kind'] == 'B':
                last_bias = 1 if hp.phase == 'GU' else 2
                if hw['bidx'] == last_bias:
                    hp.bias_valid = True
            return
        base = hw['g'] * hp.ncols
        if max(st.release[base:base + hp.ncols]) > t:
            st.stalls['occupancy'] += 1
            return
        if t <= st.pe_last_accept:
            return
        st.rq.popleft()
        self._event(t, 'rram_consume', head['sequence'])
        hw['_accept_id'] = self.accepted
        self._event(t, 'pe_accept', self.accepted, base)
        self.accepted += 1
        st.consumed += 1
        hp.timing.last_consume = t
        for c in range(base, base + hp.ncols):
            st.release[c] = t + lat['REACCEPT']
        st.pe_last_accept = t
        st.commits.append((t + lat['PE_COMMIT'], hp, hw))

    def _commit(self, phases, st, t):
        lat = self.lat
        while st.commits and st.commits[0][0] <= t:
            _, cp, cw = st.commits.popleft()
            self._event(t, 'pe_commit', cw['_accept_id'], cw['g'] * cp.ncols)
            cp.timing.last_commit = t
            if cw['kb'] != cp.nkb - 1 or not cw['last']:
                continue
            if cp.phase == 'GU':
                # ACT streams 36 column pairs (1/cycle) after latency 24;
                # the bias tail words were consumed before the matrix words,
                # so the GU bias context is valid by the last commit
                cp.act_start = t + 1
                self._arm_hup(cp, st)
            else:
                trig = t + 1
                if trig <= st.yacc_free:
                    st.stalls['yacc_overlap'] += st.yacc_free + 1 - trig
                    trig = st.yacc_free + 1
                self._arm_dcommit(cp, st, trig)

    def _arm_hup(self, cp, st):
        lat = self.lat
        cp.hup_ready = cp.act_start + lat['ACT'] + lat['ACT_COLS']
        st.h_q.append((cp, cp.hup_ready, cp.hup_beats))

    def _arm_dcommit(self, cp, st, trig):
        lat = self.lat
        rows = self.n_tok * 10
        cp.timing.sync1 = trig
        cp.retired = True
        st.counters['CNT_SYNC1'] += 1
        st.counters['CNT_D'] += 1
        for i in range(rows):
            st.crd_cycles.add(trig + lat['YACC_WARM'] + i * lat['YACC_ROW'])
        st.yacc_free = trig + lat['YACC_WARM'] + rows * lat['YACC_ROW']
        if self.drain:
            for lane in range(self.n_tok):
                ready = (trig + lat['YACC_WARM'] +
                         (lane + 1) * 10 * lat['YACC_ROW'])
                st.y_q.append((ready, 10))

    def _launcher(self, phases, st, t):
        lat = self.lat
        if st.cur is None:
            ready_h = [pk for pk in st.h_q if pk[1] <= t]
            ready_y = [pk for pk in st.y_q if pk[0] <= t]
            if ready_h and st.credits > 0:
                pk = ready_h[0]
                st.h_q.remove(pk)
                st.cur = dict(kind='H', phase=pk[0], beats=pk[2],
                              next_beat=t, interval=1)
                st.counters['CNT_UP_PKT'] += 1
            elif ready_y and st.credits > 0:
                pk = ready_y[0]
                st.y_q.remove(pk)
                st.cur = dict(kind='Y', beats=pk[1], next_beat=t,
                              interval=lat['DRAIN_ROW'])
                st.counters['CNT_UP_PKT'] += 1
            elif (ready_h or ready_y) and st.credits == 0:
                st.stalls['up_credit'] += 1
                st.counters['CNT_UP_CRD_STALL'] += 1
            return
        if st.credits > 0 and t >= st.cur['next_beat']:
            if st.cur['kind'] == 'Y' and t in st.crd_cycles:
                st.stalls['drain_yield'] += 1
                st.counters['CNT_Y_YIELD'] += 1
                return
            st.credits -= 1
            st.credit_debt += 1
            st.cur['beats'] -= 1
            st.cur['next_beat'] = t + st.cur['interval']
            if st.cur['beats'] == 0:
                if st.cur['kind'] == 'H':
                    ph = st.cur['phase']
                    ph.timing.sync1 = t
                    ph.retired = True
                    st.counters['CNT_SYNC1'] += 1
                    st.counters['CNT_GU'] += 1
                st.cur = None
        elif (st.cur['kind'] == 'H' and st.credits == 0):
            st.stalls['up_credit'] += 1
            st.counters['CNT_UP_CRD_STALL'] += 1


class _SimState(object):
    """Mutable cross-cycle simulation state."""
    def __init__(self, up_credits):
        self.rq = deque()
        self.commits = deque()
        self.release = [0] * 80
        self.pe_last_accept = -1
        self.issued = 0
        self.consumed = 0
        self.credits = up_credits
        self.credit_debt = 0
        self.credit_timer = 0
        self.cur = None
        self.h_q = deque()
        self.y_q = deque()
        self.crd_cycles = set()
        self.yacc_free = -1
        self.stalls = dict((k, 0) for k in (
            'rram_credit', 'rram_inflight', 'rq_full', 'operand_x', 'operand_h', 'occupancy',
            'rq_empty_gap', 'up_credit', 'drain_yield', 'yacc_overlap'))
        self.counters = dict((k, 0) for k in (
            'CNT_GU', 'CNT_D', 'CNT_X_POP', 'CNT_H_IN', 'CNT_RRAM_RD',
            'CNT_X_STALL', 'CNT_RRAM_STALL', 'CNT_UP_PKT',
            'CNT_UP_CRD_STALL', 'CNT_Y_YIELD', 'CNT_SYNC1'))


def profile(fmt='fp4', n_tok=4, bias_en=False, n_passes=1, **kwargs):
    """Convenience one-call profiler: returns the summary dict."""
    model = TileCycleModel(fmt=fmt, n_tok=n_tok, bias_en=bias_en, **kwargs)
    return model.run_step(n_passes).summary()


def analytic_matrix_rate(fmt):
    """Steady-state matrix word rate after warm-up:
    min(1, ngroups/REACCEPT, RRAM_CREDITS/(RRAM_LAT+1)) words/cycle.
    The occupancy rule caps per-column-group re-acceptance; the 3-entry
    RRAM credit budget caps at 3/(3+1) = 0.75 words/cycle because each
    old-state ready cannot reuse the credit on its return sampling edge.
    Queue reservation is separate and lasts until consumption."""
    ncols, sw, period, ng_gu, ng_d, _, _ = format_params(fmt)
    lat = LATENCIES
    return min(1.0,
               ng_gu / float(lat['REACCEPT']),
               lat['RRAM_CREDITS'] / float(lat['RRAM_LAT'] + 1))

