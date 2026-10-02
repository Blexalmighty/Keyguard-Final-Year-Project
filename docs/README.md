# FindX / FindMe — documentation

| Document | What it is for |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | The codebase as it stands: module map, protocol tables, state machines, data-flow and sequence diagrams, test inventory, known limits. Start here to work on the code. |
| [SECURITY_MODEL.md](SECURITY_MODEL.md) | Assets, adversaries, every design decision with the threat it answers, a threat matrix, and an explicit list of what the design does **not** defend against. Read §6 before changing anything that touches the radio. |
| [CHAPTER_3_DESIGN.md](CHAPTER_3_DESIGN.md) | Methodology, requirements, and the full design: architecture, circuit, protocol, ownership, algorithms, firmware. Includes the design decisions that were reversed, with reasons. |
| [CHAPTER_4_IMPLEMENTATION.md](CHAPTER_4_IMPLEMENTATION.md) | Implementation, testing and results. §4.7 documents the faults found and how each was diagnosed; §4.9 states the limitations. |
| [CHAPTER_5_CONCLUSION.md](CHAPTER_5_CONCLUSION.md) | Summary, conclusions, contributions, limitations, and recommendations for further work. |

## Figures

| Figure | File |
|---|---|
| 3.1 — Circuit diagram | [images/circuit_diagram.svg](images/circuit_diagram.svg) |

Diagrams inside the documents are Mermaid, which GitHub renders inline. To get
them as images for a printed report, paste the block into
[mermaid.live](https://mermaid.live) and export SVG or PNG.

## Where the diagrams are

| Diagram | Document | Section |
|---|---|---|
| System architecture | ARCHITECTURE | §1 |
| Layered architecture | CHAPTER_3 | §3.4.1 |
| Dependency direction | ARCHITECTURE | §2 |
| Deployment view | CHAPTER_3 | §3.4.4 |
| Background execution | CHAPTER_3 | §3.4.3 |
| Circuit diagram | CHAPTER_3 | §3.5.2 + Figure 3.1 |
| Device power states | CHAPTER_3 | §3.5.5 · ARCHITECTURE §5 |
| Claim sequence | CHAPTER_3 | §3.7.2 · ARCHITECTURE §4 |
| Authentication sequence | CHAPTER_3 | §3.7.3 |
| Ownership state machine | ARCHITECTURE | §5 |
| Connection lifecycle | ARCHITECTURE | §5 |
| Distance estimation flow | CHAPTER_3 | §3.8.1 |
| Allowance vs threshold flow | CHAPTER_3 | §3.8.2 |
| Reconnection flow | CHAPTER_3 | §3.8.3 |
| Boot reconnection flow | CHAPTER_3 | §3.8.4 · ARCHITECTURE §8 |
| Position push sequence | CHAPTER_3 | §3.8.5 · ARCHITECTURE §6 |
| Button press → phone rings | ARCHITECTURE | §6 |
| Use-case diagram | CHAPTER_3 | §3.9.1 |
| Screen flow | CHAPTER_3 | §3.9.2 |
| Data-flow diagram, level 0 | CHAPTER_3 | §3.9.3 |
| Data-flow diagram, level 1 | CHAPTER_3 | §3.9.4 |
| Firmware main loop | CHAPTER_3 | §3.10.1 |
| Command dispatch | CHAPTER_3 | §3.10.2 |
| Development cycle | CHAPTER_3 | §3.2.2 |

## Three things worth knowing before you change anything

1. **The protocol has two copies.** `lib/services/ble_protocol.dart` and the
   `#define`s in the firmware are one contract. Change both in the same commit.
   `test/alert_pattern_test.dart` parses the firmware from disk and will catch
   the alert table drifting; nothing catches the rest.
2. **Watch the MTU.** The default ATT MTU is 23 bytes, which leaves 20 bytes of
   payload. A longer frame will not arrive whole unless both sides have raised
   the MTU, and **nothing reports an error when it does not.** See
   ARCHITECTURE §3.
3. **Never put a per-unit identifier in an advertisement.** Not a nickname, not a
   serial, not a counter. SECURITY_MODEL §3.1 is the most important paragraph in
   this folder.
