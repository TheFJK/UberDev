<external-untrusted-input source="simplify-aggregate">
# Simplify aggregate (Phase 2)

| lens | severity | file | line | disposition | summary |
|---|---|---|---|---|---|
| reuse | critical | src/api.ts | 130 | DEFERRED | any-type leak in handler return |
| quality | critical | src/api.ts | 130 | DEFERRED | Handler returns any — narrow to ResponseEnvelope |
| efficiency | important | src/loop.ts | 12 | DEFERRED | O(n^2) inner loop — convert to Map |
| reuse | suggestion | src/dup.ts | 3 | APPLIED | DRY: extract helper |

</external-untrusted-input>
