# H-bank observed-port replay — 2026-11-15

Status: instrumentation and checker implemented; actual extended RTL trace pending.

The scheduler now has independent take/release bank selectors. Both trace
monitors still used the take selector for bank_release. Corrected both to
hbuf_release_bank. Historical CSV files remain untouched. In a D-to-GU
collision releasing bank 0 while taking bank 1, the old monitor could report
release of bank 1. This is an instrumentation defect, not new evidence of a
specific historical simulation failure.

Extended calibration events (existing schema-2 columns):

| Event | Sample | Fields |
| --- | --- | --- |
| bank_take | pre | bank, pass; payload contains ntok |
| bank_release | pre | bank from independent release selector |
| bank_write | pre | bank, kb=row, group=lane; emitted for every attempted write |
| bank_state | post | payload[20:0]={error,pass1,pass0,ready[1:0],owner[1:0]} |

bank_state is emitted on ownership/write operations and on the edge after
wr_err was high. This checks error clearing without logging every idle cycle.
No new DUT pipeline stage or interface was added by this instrumentation.

NPU_eval/af/hbank_trace_replay.py groups simultaneous inputs, advances the
ownership model, then compares the post-edge state. It never initializes model
state from the observed output. Required events, reset epochs, sampling stage,
duplicate events, missing states and missing error-clear observations are
checked. Inputs are observed H-buffer ports: this is component replay, not
independent command admission or end-to-end Tile prediction. Payload SRAM,
scales and internal row bits are not directly compared; readiness is compared.

Local verification: six unit tests passed (including early-ready and wrong-pass
mutations, wrong release selector, missing/duplicate/wrong-stage evidence,
error clearing and epoch reset). Tile top passed pyslang semantic elaboration;
checks.json contains compilation source hashes. No dynamic VCS run was performed.

Running the checker on vcs-20261115T095649Z-37967/calibration-events.csv returned
failed: missing required H-bank trace events; legacy trace is insufficient.
This is expected rejection of inadequate evidence, not reversal of the older
component latency checks. Old artifact hashes and reports are unchanged.

After syncing current sources, the next ordinary/overlap full Tile run with
--calibration-trace collects these events automatically. Replay from LNS_DSE:

```bash
python NPU_eval/af/hbank_trace_replay.py Tile_eval/logs/<new-run>/calibration-events.csv
```

Open pipeline boundary: H input admission uses current owner/pass, while
quantizer tags carry only bank/lane/row. The release-edge fence does not
identify an old result arriving after reassignment. In particular, a late
duplicate H input during D still passes routing and may be in the quantizer
when D releases the bank. Ordinary well-ordered H completion before D is not
proof against malformed late traffic. Generation-aware write validation or
an equivalent proved admission/flush invariant remains to be designed and
validated. This checker alone cannot infer an omitted pass/generation tag.
