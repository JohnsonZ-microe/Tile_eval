# D commit from external inputs

The conditional retirement predictor now emits the registered D commit edge (retirement+1), bank, lane mask, four slot fields and weights decoded from raw CMD. No observed commit event drives prediction. Existing assumptions remain: idle CTX, isolated GU bus, idle Y commit, six initial GU credits.

Four retirement tests passed, including raw slot-field propagation into Y control and the first visible slot at commit+221. Both received November 16 ordinary and overlap traces match 48 completion edges, 24 D commit edges/bank/mask values and 60 Y slot-ready edges. The CSV commit event does not expose weights; numerical accumulation remains outside this test. The first audit runs commit control without drains, so its ready comparison is appropriate to this workload's distinct output slots, not general repeated-slot accumulation.

The sibling predicted-y-output audit adds raw drains and finite persistent output state. Source hashes and detailed arrays are preserved. No RTL changed.
