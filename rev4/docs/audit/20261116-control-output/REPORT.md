# CTRL read replies integrated with continuous H/Y output

ControlDrivenOutputReplay connects raw CTRL reads to StatusReplay and raw DRAIN to DrainDrivenOutputReplay. All H, Y, queued STATUS replies and explicit ALARM messages use one persistent bus and its six-credit state. STATUS is sampled before each edge; queue updates use the same edge's arbiter ready. The two-entry queue retains RTL pre-edge-full semantics: a reply arriving when full is dropped even if another reply is popped on that edge.

Three integrated tests passed: H packet lock fills the reply queue and drops the third pending reply, then ALARM preempts without popping queued replies; invalid broadcast read returns the encoded error at the correct registered edge; reset flushes reply and capture state while unknown register reads are rejected.

The contention test predicts H at edges 61..65, ALARM at 66, and register replies at 67 and 68, with a queue drop at 63. These are directed model predictions, not newly measured RTL outputs. Existing status and bus waveform tests in the full AF regression validate components separately; they do not by themselves validate this combined workload in RTL.

The register reader is mandatory and explicit. This adapter does not invent CTX/counter/sticky-error values, generate alarms, predict D commits or arbitrate core slots. Other downstream operations remain outside its scope. The next end-to-end step is supplying register state and commit events from the same independently driven core/control state, then comparing all upstream output identities and timing under external credit edges. No RTL or historical logs were changed.
