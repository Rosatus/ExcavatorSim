# Design — Linux can0 hardening integration

## 1. Task boundary and decomposition

This parent owns the source requirements, child ordering, compatibility matrix,
and final integration review. Implementation is performed in two children:

```text
Secure helper lock
  /run (validated root-owned parent)
    └─ excavatorsim/  root:root 0700
         └─ can0.lock root:root 0600 regular singleton inode

Gateway producers
  ├─ CSV sink: immediate complete append
  └─ SocketCAN TX: bounded latest values → fair service → nonblocking send
       ├─ congestion errno: count/drop/yield, ICT remains active
       └─ other errno: terminal latch → existing ICT retirement
```

The secure-lock child runs first because both children touch can0 constants,
setup tests, README, and package validation. The low-latency child then changes
`txqueuelen` from 1000 to 10 on top of the hardened helper.

## 2. Cross-child contracts

- `CAN_TX_QUEUE_LEN` remains the only source constant for readiness, helper
  mutation, status text, and tests. The second child changes it to 10.
- Helper lock failures remain `CAN0_SETUP_FAILED`; send congestion never enters
  helper/readiness error categories.
- SocketCAN buffering is below encoded-frame production and above
  `pack_can_frame`; bytes and EFF packing are untouched.
- CSV receives each producer occurrence before/independently of physical TX
  queuing. A SocketCAN drop cannot roll back or suppress a CSV row.
- Gateway's owner loop retains lifecycle authority. No transport worker thread
  is introduced; non-blocking, budgeted service prevents the owner from waiting
  on the adapter.

## 3. Compatibility matrix

| Boundary | Required outcome |
|---|---|
| Encoders/DBC | No ID, DLC, payload, endian, scale, cadence, or hash change |
| EFF packing | Existing `pack_can_frame` remains the sole packing authority |
| CSV | Complete producer occurrences, independent of can0 congestion |
| Linux ICT | Recoverable congestion keeps active; terminal error retires |
| Timed CAN | 50 Hz logical schedule, 10 s fixed window, no replay/catch-up |
| Windows | PC001 queue/protocol/counters unchanged |
| CAN receive | Unchanged and outside both children |

## 4. Integration and rollback

Each child receives its own focused commit/check. Parent review then runs the
combined Gateway/backend/Web regressions, verifies generated Web resources and
Linux package contents, and records real-hardware checks separately.

Rollback restores the prior helper and Gateway package together. It does not
remove drivers, create/delete can0, or alter CAN frame sources.
